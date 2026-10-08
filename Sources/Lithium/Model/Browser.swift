import AppKit
import Observation
import WebKit

/// Window state. Every open page is a `Tab`; a tab whose `pinID` is set is the live page of a
/// favorite and shows in the grid instead of the tab list. Pins and the open tabs are persisted.
/// With no tab selected the window shows the start page, and the address bar opens a new
/// tab, so empty tabs never pile up.
@MainActor
@Observable
final class Browser {
    private(set) var pins: [Pin] {
        didSet { PinStore.save(pins) }
    }
    private(set) var tabs: [Tab] = []
    private(set) var selectedTabID: Tab.ID? {
        didSet {
            guard oldValue != selectedTabID else { return }
            videoPopout.selectionChanged(from: tabs.first { $0.id == oldValue }, to: selectedTab)
        }
    }
    /// Empty until the user makes a second space (`Space`), then the main one first.
    private(set) var spaces: [Space] = []
    /// The space the sidebar shows; the selected tab is in it.
    private(set) var currentSpaceID = Space.mainID
    /// The tab each space showed when the user left it.
    @ObservationIgnored private var spaceSelections: [Space.ID: Tab.ID] = [:]
    @ObservationIgnored private var spaceStores: [Space.ID: WKWebsiteDataStore] = [:]
    /// The last switch went to a space further along: the sidebar slides that way.
    @ObservationIgnored private(set) var spaceStepsForward = true
    /// Clearing a deleted space's store; awaited in tests.
    @ObservationIgnored private(set) var storeCleanup: Task<Void, Never>?
    private(set) var addressFocusToken = 0
    /// Moves when the user switches to another tab or to the start page, not when closing one moves the selection
    /// or switching spaces shows the space's own, so the peeked sidebar can slide back on a pick yet stay out while
    /// tabs close or spaces switch in a row.
    private(set) var tabPickToken = 0
    /// Opens as the user last left it. Only `toggleSidebar()` saves, so a passing change such as
    /// the screenshot taking both looks never outlives the app.
    var isSidebarVisible = UserDefaults.standard.object(forKey: Preference.sidebarVisible) as? Bool ?? true
    /// Zen mode: the page alone in the window's frame, the sidebar and the top bar peeking from
    /// the edges. Kept apart from `isSidebarVisible`, so leaving it brings the sidebar back as it
    /// was. Saved like the sidebar, by `toggleZenMode()` only.
    var isZenMode = UserDefaults.standard.bool(forKey: Preference.zenMode)
    /// Whether the sidebar takes its column, rather than peeking over the page.
    var showsSidebar: Bool { isSidebarVisible && !isZenMode }
    /// Set by the address bar as it starts and ends editing: Zen mode's top bar stays out meanwhile.
    var isEditingAddress = false
    var renamingTabID: Tab.ID? {
        didSet { if renamingTabID != oldValue { renameDraft = nil } }
    }
    /// The name typed so far, for whichever field shows the rename next: ⌘B swaps the peeked
    /// sidebar's field for the sidebar's own.
    @ObservationIgnored var renameDraft: String?
    /// Settings › Advanced › Developer tools, on unless turned off. Pages already open follow at once.
    var developerTools = UserDefaults.standard.object(forKey: Preference.developerTools) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(developerTools, forKey: Preference.developerTools)
            for case let webView? in tabs.map(\.loadedWebView) { DeveloperTools.apply(developerTools, to: webView) }
        }
    }
    var canShowWebInspector: Bool { developerTools && selectedTab != nil }

    let privacy = Privacy()
    let history = HistoryStore()
    let find = FindInPage()
    let suggestions = AddressSuggestions()
    let permissions = SitePermissions()
    let appLinks = AppLinks()
    let tidyTitles = TidyTitles()
    let summaries = PageSummaries()
    let extensions = Extensions()
    let videoPopout = VideoPopout()
    let nowPlaying = NowPlaying()
    let pinnedPages = PinnedPages()
    let splits = TabSplits()
    let folders = TabFolders()
    let recentTabs = RecentTabs()
    let quickLinks = QuickLinks()
    let energy = EnergySaver()
    let favicons: Favicons
    @ObservationIgnored private(set) lazy var capture = ScreenCapture(browser: self)
    @ObservationIgnored private(set) lazy var translation = PageTranslation(summaries: summaries)
    @ObservationIgnored private var pinIcons: [Pin.ID: NSImage] = [:]

    /// Present only while agent access is on, so with it off every agent hook is a nil check.
    /// Observed, so the toolbar indicator appears and goes with the setting.
    private(set) var agent: AgentHub?

    @ObservationIgnored private(set) lazy var internalBridge = InternalBridge(browser: self)
    @ObservationIgnored private var eventMonitors: [Any] = []
    /// The window the browser shows in, set as it appears: the Escape monitor only acts there.
    @ObservationIgnored weak var window: NSWindow?

    /// Something opened from a peeked panel (the sidebar, Zen mode's top bar) is still in use: a
    /// tab's name being typed, a popover such as a space's editor, an alert, a menu or a drag.
    /// The panel stays out meanwhile, as they would go with it. Read only as the panel would go,
    /// so nothing watches for them.
    var holdsPeek: Bool {
        isRenaming || window.map(Self.hasOpenUI(in:)) == true
    }

    /// A tab's or a folder's name is being typed in the sidebar.
    var isRenaming: Bool { renamingTabID != nil || folders.renamingID != nil }

    /// Popovers are the window's child windows and alerts its sheets; menus and drags run the
    /// event tracking loop until they end.
    static func hasOpenUI(in window: NSWindow) -> Bool {
        window.attachedSheet != nil || window.childWindows?.contains(where: \.isVisible) == true
            || RunLoop.main.currentMode == .eventTracking
    }
    /// Observed, so Reopen Closed Tab is enabled as soon as there is one. Never saved.
    private var closedTabs: [ClosedTab] = []
    // Cancelled in deinit, which runs outside the main actor; both are safe to cancel from anywhere.
    @ObservationIgnored nonisolated(unsafe) private var sleepLoop: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var memoryPressure: DispatchSourceMemoryPressure?
    /// As macOS last reported it: the source only speaks when the level changes.
    @ObservationIgnored private var memoryLevel: DispatchSource.MemoryPressureEvent = .normal
    @ObservationIgnored private var savedSession: Session?
    /// The write a change to the session waits for (`saveSession`).
    @ObservationIgnored private var sessionSave: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var dayChange: (center: NotificationCenter, observer: any NSObjectProtocol)?
    /// The icons of sleeping favorites fetched at the last change of day; awaited in tests.
    @ObservationIgnored private(set) var sleepingIconsRefresh: Task<Void, Never>?

    struct ClosedTab {
        let url: URL
        let pinID: Pin.ID?
        let spaceID: Space.ID
        let customTitle: String?
        /// Its place in its folder, or among the tabs outside folders; nil for a favorite's page.
        let index: Int?
        let folderID: TabFolder.ID?
        /// From `Tab.history`.
        let history: Any?
    }

    /// 10 minutes, or 5 while the Mac saves energy (Low Power Mode, or running hot).
    /// `defaults write app.lithium.browser tabIdleSeconds N` overrides both.
    static var tabIdleInterval: TimeInterval { idleInterval(savingEnergy: isSavingEnergy) }
    static let shortIdleInterval: TimeInterval = 5 * 60

    private static func idleInterval(savingEnergy: Bool) -> TimeInterval {
        let custom = UserDefaults.standard.double(forKey: "tabIdleSeconds")
        if custom > 0 { return custom }
        return savingEnergy ? shortIdleInterval : 10 * 60
    }

    /// `tabIdleInterval`, short while Lithium's energy saving is on too.
    var idleInterval: TimeInterval { Self.idleInterval(savingEnergy: energy.isOn || Self.isSavingEnergy) }

    private static var isSavingEnergy: Bool {
        let info = ProcessInfo.processInfo
        return info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical
    }
    private static let closedTabsLimit = 25

    /// `notifications` posts the change of day (`NSCalendarDayChanged`); tests post it themselves.
    init(favicons: Favicons = .shared, notifications: NotificationCenter = .default) {
        self.favicons = favicons
        pins = PinStore.load()
        privacy.start()
        extensions.browser = self
        videoPopout.browser = self
        nowPlaying.browser = self
        quickLinks.browser = self
        extensions.start()
        restore(SessionStore.load())
        saveSession()
        Task { [tidyTitles] in
            // Off the launch path: the model loads once the window is up.
            try? await Task.sleep(for: .seconds(3))
            tidyTitles.prepare()
        }
        sleepLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(min(60, Self.tabIdleInterval / 2)))
                self?.sleepTabs()
                self?.pauseSilentMedia()
            }
        }
        energy.onChange = { [weak self] in self?.energyChanged() }
        watchMemoryPressure()
        let observer = notifications.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSleepingPinIcons() }
        }
        dayChange = (notifications, observer)
        if UserDefaults.standard.bool(forKey: Preference.agentAccess) {
            Task { await setAgentAccess(true) }
        }
    }

    deinit {
        sleepLoop?.cancel()
        memoryPressure?.cancel()
        if let dayChange { dayChange.center.removeObserver(dayChange.observer) }
    }

    /// A pass runs in one go on the main actor: nothing can change a tab between its check
    /// and its sleep, and two passes can't overlap. A popup window (a sign-in or payment
    /// window) and the page that opened it talk to each other, so neither sleeps while both
    /// are open, unless memory is critical. Nor does a page holding the user's unsaved input.
    private func sleepIdleTabs(idleFor interval: TimeInterval, sparingPopups: Bool, among candidates: (Tab) -> Bool = { _ in true }) {
        tabs.forEach { $0.noteSound() }
        for tab in tabsThatCanSleep(idleFor: interval, sparingPopups: sparingPopups, among: candidates) {
            tab.sleep(configuration: makeConfiguration(for: tab.url))
        }
    }

    private func tabsThatCanSleep(idleFor interval: TimeInterval, sparingPopups: Bool, among candidates: (Tab) -> Bool) -> [Tab] {
        var paired: Set<ObjectIdentifier> = []
        if sparingPopups {
            let open = Set(tabs.map { ObjectIdentifier($0) })
            for tab in tabs {
                guard let opener = tab.opener, open.contains(ObjectIdentifier(opener)) else { continue }
                paired.formUnion([ObjectIdentifier(tab), ObjectIdentifier(opener)])
            }
        }
        let partner = shownPartner
        // A tab an agent is working in is spared like a popup, or its next action would find a reloaded page.
        return tabs.filter { tab in
            candidates(tab) && tab.id != selectedTabID && tab !== videoPopout.tab && tab !== partner
                && !paired.contains(ObjectIdentifier(tab)) && !(sparingPopups && agent?.holds(tab) == true)
                && !(sparingPopups && tab.hasUnsavedInput)
                && tab.canSleep(idleFor: interval)
        }
    }

    /// When macOS runs short of memory, Lithium gives some back before the system starts
    /// compressing and swapping.
    private func watchMemoryPressure() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let event = self.memoryPressure?.data else { return }
                self.memoryLevel = event
                if event != .normal { self.sleepTabs() }
            }
        }
        source.activate()
        memoryPressure = source
    }

    /// For as long as memory is short, background tabs left alone for 5 minutes (or less, if
    /// `tabIdleSeconds` says so) sleep when memory runs low, and every one that can (not playing
    /// sound, recording or loading) when it is critical, like Firefox's tab unloading.
    private func sleepTabs() {
        if memoryLevel.contains(.critical) {
            sleepIdleTabs(idleFor: 0, sparingPopups: false)
        } else if memoryLevel.contains(.warning) {
            sleepIdleTabs(idleFor: min(idleInterval, Self.shortIdleInterval), sparingPopups: true)
        } else {
            sleepIdleTabs(idleFor: idleInterval, sparingPopups: true)
        }
    }

    /// Energy saving turned on or off: the open pages' timers follow, and turning it on applies
    /// it at once rather than at the next pass.
    private func energyChanged() {
        for case let webView? in tabs.map(\.loadedWebView) { BackgroundThrottling.apply(energy.isOn, to: webView) }
        guard energy.isOn else { return }
        sleepTabs()
        pauseSilentMedia()
    }

    /// While energy saving is on, a background tab's media that makes no sound (a muted autoplay
    /// video, a looping background) pauses: WebKit keeps decoding a video out of the window. A tab
    /// shown, in the floating player, playing sound or heard lately (between tracks), muted by the
    /// user, in a call or used by an agent is left alone, and so is every tab when WebKit can't
    /// tell sound apart. The page can play it again; the next pass pauses it again.
    func pauseSilentMedia() {
        guard energy.isOn else { return }
        let partner = shownPartner
        for tab in tabs where !tab.isAsleep && tab.id != selectedTabID && tab !== videoPopout.tab && tab !== partner
            && nowPlaying.isHeard(tab) == false && !tab.wasHeardLately && !tab.isMuted
            && !nowPlaying.isInCall(tab) && agent?.holds(tab) != true {
            nowPlaying.pause(tab)
        }
    }

    /// What a memory pressure event does, for tests.
    func relieveMemoryPressure(critical: Bool) {
        memoryLevel = critical ? .critical : .warning
        sleepTabs()
        memoryLevel = .normal
    }

    /// The rest of the tab list sleeps now, sparing what any sleep pass spares: the tab shown, a
    /// tab playing sound, in a call or loading, a popup and its opener, a page with unsaved
    /// input. Favorites' pages and the Agent group are left alone.
    func sleepOtherTabs(than tab: Tab) {
        sleepIdleTabs(idleFor: 0, sparingPopups: true) { $0 !== tab && $0.isInTabList }
    }

    /// Whether Sleep Other Tabs would put any tab to sleep, with sound as last noted.
    func canSleepOtherTabs(than tab: Tab) -> Bool {
        !tabsThatCanSleep(idleFor: 0, sparingPopups: true) { $0 !== tab && $0.isInTabList }.isEmpty
    }

    /// Pages of an extension get that extension's configuration; everything else Lithium's own.
    func makeConfiguration(for url: URL? = nil) -> WKWebViewConfiguration {
        if let configuration = extensions.configuration(for: url) { return configuration }
        let configuration = privacy.makeConfiguration()
        prepare(configuration)
        return configuration
    }

    /// Popups arrive with a configuration WebKit copied from their opener.
    func prepare(popup configuration: WKWebViewConfiguration) {
        privacy.harden(configuration)
        prepare(configuration)
    }

    private func prepare(_ configuration: WKWebViewConfiguration) {
        InternalSchemeHandler.shared.install(on: configuration)
        translation.install(on: configuration)
        nowPlaying.install(on: configuration.userContentController)
        configuration.webExtensionController = extensions.controller
    }

    func openSettings(section: String? = nil) {
        openInternal(section.flatMap { URL(string: "\(Internal.settingsURL.absoluteString)#\($0)") } ?? Internal.settingsURL)
    }

    func openHistory() { openInternal(Internal.historyURL) }

    func openAgentLog() { openInternal(Internal.agentsURL) }

    /// Settings › Agents. Off by default; the choice outlives the app. `folder` holds the endpoint
    /// file and the log: a test gives its own, so another test's calls can't land in the log it reads.
    func setAgentAccess(_ enabled: Bool, folder: URL = AgentFiles.folder) async {
        UserDefaults.standard.set(enabled, forKey: Preference.agentAccess)
        if enabled, agent == nil {
            let hub = AgentHub(browser: self, folder: folder, tools: AgentHub.tabTools + AgentHub.readTools + AgentHub.dialogTools + AgentHub.inputTools + AgentHub.parityTools + AgentHub.networkTools + AgentHub.evaluateTools + AgentHub.batchTools)
            agent = hub
            await hub.start()
        } else if !enabled, let hub = agent {
            agent = nil
            hub.shutdown()
        }
    }

    func setProtections(_ enabled: Bool, for tab: Tab?) {
        guard let tab, let host = Privacy.siteHost(tab.url) else { return }
        guard let session = tab.privateSession else { return setProtections(enabled, host: host) }
        // A private tab's choice holds for its private session only, and so do the reloads.
        privacy.setEnabled(enabled, for: tab.url, privateSession: session)
        tabs.filter { !$0.isAsleep && $0.privateSession == session && Privacy.siteHost($0.url) == host }.forEach { navigate($0, .reload) }
    }

    /// Reloads every open page of the site, not just the one the user changed it from, so their
    /// content blockers and scripts match the new setting. Sleeping tabs get it when they wake.
    func setProtections(_ enabled: Bool, host: String) {
        privacy.setEnabled(enabled, host: host)
        tabs.filter { !$0.isAsleep && Privacy.siteHost($0.url) == host }.forEach { navigate($0, .reload) }
    }

    /// Settings' font choices ("Use DM Sans on websites", a site's own font) reach the open pages
    /// they change, as protections do: the font is a script set up as a page loads, so those pages
    /// reload. Lithium's own pages stay, Settings among them. Sleeping tabs get it when they wake.
    func changePageFont(_ change: () -> Void) {
        let pages = tabs.compactMap { tab -> (Tab, URL, Bool)? in
            guard !tab.isAsleep, let url = tab.url, !Internal.isInternal(url) else { return nil }
            return (tab, url, PageStyle.usesDMSans(url, privateSession: tab.privateSession))
        }
        change()
        for (tab, url, used) in pages where PageStyle.usesDMSans(url, privateSession: tab.privateSession) != used {
            navigate(tab, .reload)
        }
    }

    /// Reuses a tab already showing that internal page, moving it to the requested section.
    private func openInternal(_ url: URL) {
        if let existing = tabs.first(where: { $0.url?.host() == url.host() && Internal.isInternal($0.url) }) {
            if url.fragment() != nil, existing.url != url { navigate(existing, .open(url)) }
            select(existing)
        } else {
            newTab(url: url)
        }
    }

    func windowDidAppear() {
        installEventMonitors()
        selectedTab?.markActive()
    }

    /// Installed once the window exists: a monitor added before NSApplication finishes launching is dropped.
    private func installEventMonitors() {
        guard eventMonitors.isEmpty else { return }
        // Escape is caught before any text field sees it, since a focused field editor swallows it.
        let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if Self.isZoomInWithoutShift(event), let self {
                return MainActor.assumeIsolated {
                    guard !NativeInput.isAgents(event), event.window === self.window, self.selectedTab != nil else { return false }
                    self.zoomSelectedTab(by: PageZoom.step)
                    return true
                } ? nil : event
            }
            // An agent's Escape that the page didn't handle comes back here; it isn't the user's.
            guard event.keyCode == 53, let self else { return event }
            return MainActor.assumeIsolated {
                !NativeInput.isAgents(event) && self.ownsEscape(in: event.window) && self.dismissOverlay()
            } ? nil : event
        }
        // A click only moves focus when it lands on something that takes focus (like the page).
        // Clicking the sidebar or toolbar background would otherwise leave a text field editing.
        let click = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                Self.endEditingIfOutside(event)
                self?.noteClick(event)
            }
            return event
        }
        eventMonitors = [escape, click].compactMap { $0 }
    }

    /// ⌘=, Zoom In as most people press it: the menu's "+" takes Shift on most layouts.
    nonisolated static func isZoomInWithoutShift(_ event: NSEvent) -> Bool {
        event.charactersIgnoringModifiers == "=" && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
    }

    /// Zoom In and Zoom Out: the PDF viewer's own steps, or the page's zoom.
    func zoomSelectedTab(by delta: Double) {
        guard let tab = commandTab else { return }
        if let pdf = tab.pdf {
            if delta > 0 { pdf.zoomIn() } else { pdf.zoomOut() }
            return
        }
        let webView = tab.webView
        webView.pageZoom = PageZoom.stepped(webView.pageZoom, by: delta)
    }

    /// Ends text editing when a click lands outside the field being edited. The click then goes
    /// on as usual; the field commits on its own (a tab rename keeps the new name).
    private static func endEditingIfOutside(_ event: NSEvent) {
        guard let window = event.window,
              let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSView, field.window === window else { return }
        // A little slack around the field: its rounded background is larger than the text itself.
        let point = field.convert(event.locationInWindow, from: nil)
        guard !field.bounds.insetBy(dx: -10, dy: -8).contains(point) else { return }
        window.makeFirstResponder(nil)
    }

    /// Whether an Escape in `window` is Lithium's to handle. Not in another window (a save panel)
    /// or under a sheet (the capture preview), and not while a text field edits (the address bar
    /// ends its editing itself), unless it is the find field or a tab's name, which Escape closes.
    func ownsEscape(in window: NSWindow?) -> Bool {
        guard let window, window === self.window, window.attachedSheet == nil else { return false }
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return true }
        return find.isFieldFocused || isRenaming
    }

    /// Closes the topmost Lithium overlay. Returns false when there was none.
    func dismissOverlay() -> Bool {
        if recentTabs.target != nil {
            endTabCycle(commit: false)
            return true
        }
        if isRenaming {
            renamingTabID = nil
            folders.renamingID = nil
            // The name field, when a field has it: Escape comes here only for find's or that one.
            let nameHadKeyboard = (selectedTab?.contentView.window?.firstResponder as? NSTextView)?.isFieldEditor == true
            returnKeyboardToPage(fieldHadKeyboard: nameHadKeyboard && !find.isFieldFocused)
            return true
        }
        if find.isVisible {
            let hadKeyboard = find.isFieldFocused
            find.hide()
            returnKeyboardToPage(fieldHadKeyboard: hadKeyboard)
            return true
        }
        // Opened with ⇧⌘S, the popover never takes the keyboard, so Escape reaches the window.
        if summaries.isPanelPresented {
            summaries.isPanelPresented = false
            return true
        }
        // The shown permission prompt, denied this once and not remembered. Not under an agent's
        // banner, whose Deny Escape triggers.
        if agent?.confirmations.front(selected: selectedTabID) == nil,
           let request = permissions.pending.first(where: { $0.tabID == selectedTabID }) {
            permissions.dismiss(request)
            return true
        }
        // Likewise "Open <App>?", cancelled.
        if agent?.confirmations.front(selected: selectedTabID) == nil,
           let request = appLinks.pending.first(where: { $0.tabID == selectedTabID }) {
            appLinks.answer(request, open: false)
            return true
        }
        return false
    }

    /// Hands the keyboard back to the page shown once a field of Lithium's own closes (the find
    /// bar, a tab's name), as ⌘F does: the field leaving would leave it on the window, where keys
    /// beep. Unless that field had it, a field still editing (the address bar) keeps it.
    func returnKeyboardToPage(fieldHadKeyboard: Bool) {
        guard let page = selectedTab?.contentView, let window = page.window else { return }
        if fieldHadKeyboard { window.makeFirstResponder(page) } else { focusPage(page) }
    }

    /// In Zen mode, Show Sidebar (⌘B, the top bar's button) asks for the sidebar back, which takes
    /// the window out of Zen mode.
    func toggleSidebar() {
        if isZenMode {
            toggleZenMode()
            isSidebarVisible = true
        } else {
            isSidebarVisible.toggle()
        }
        UserDefaults.standard.set(isSidebarVisible, forKey: Preference.sidebarVisible)
    }

    /// The top bar changes for another, so an edit in the address bar ends first: its field gone
    /// mid-edit would leave the keyboard nowhere and the new bar held out for it.
    func toggleZenMode() {
        if isEditingAddress { window?.makeFirstResponder(nil) }
        isZenMode.toggle()
        UserDefaults.standard.set(isZenMode, forKey: Preference.zenMode)
    }

    var selectedTab: Tab? { tabs.first { $0.id == selectedTabID } }
    /// The page the menu's page commands (Reload, Back, Print…) act on: a link's own window
    /// while it is in front, the selected tab otherwise.
    var commandTab: Tab? { quickLinks.keyTab ?? selectedTab }
    /// The tab list of the space shown. Tabs an agent opened sit apart, in the Agent group below it.
    var regularTabs: [Tab] { tabList(in: currentSpaceID) }
    var agentTabs: [Tab] { agentGroup(in: currentSpaceID) }
    /// The group a tab's bulk actions (Close Other Tabs, Close Tabs Below) stay within: the
    /// Agent group for its tabs, the tab list for the rest, in the tab's space.
    func peers(of tab: Tab) -> [Tab] {
        tab.isInAgentGroup ? agentGroup(in: tab.spaceID) : tabList(in: tab.spaceID)
    }

    func liveTab(for pin: Pin) -> Tab? { tabs.first { $0.pinID == pin.id } }

    func icon(for pin: Pin) -> NSImage? {
        if let live = liveTab(for: pin)?.favicon { return live }
        if let cached = pinIcons[pin.id] { return cached }
        let image = pin.favicon.flatMap(NSImage.init(data:))
        pinIcons[pin.id] = image
        return image
    }

    // MARK: Tabs

    /// `opener` is the tab whose page opened this one (a link, ⌘-click or `window.open`). The tab
    /// goes in `space`, else its opener's, else the space shown.
    @discardableResult
    func newTab(url: URL? = nil, selecting: Bool = true, configuration: WKWebViewConfiguration? = nil, privateStore: WKWebsiteDataStore? = nil, openedFrom opener: Tab? = nil, space: Space.ID? = nil) -> Tab {
        let tab = insertTab(at: 0, configuration: configuration ?? makeConfiguration(for: url), privateStore: privateStore, space: space ?? opener?.spaceID ?? currentSpaceID)
        if let opener { recentTabs.didOpen(tab, from: opener) }
        if let url { tab.load(url) }
        if selecting { select(tab) }
        return tab
    }

    /// A link from another app (`onOpenURL`): in a small window of its own when Settings says so,
    /// leaving the tab list alone; in a new tab otherwise. Either way in the space shown.
    func openFromOtherApp(_ url: URL) {
        if quickLinks.isEnabled, QuickLinks.takes(url) { quickLinks.open(url) } else { newTab(url: url) }
    }

    /// A page made outside the tab list (a link's own window) joins its space's at the top, selected.
    func adopt(_ tab: Tab) {
        tabs.insert(tab, at: Self.position(inTabList: 0, of: tabs, space: tab.spaceID))
        extensions.didOpen(tab)
        select(tab)
    }

    /// `index` is a place in the space's tab list (in `folder`, or outside folders), clamped to it.
    /// `tabs` also holds favorites' pages and other spaces' tabs, so the new tab goes just before
    /// the one it pushes down.
    private func insertTab(at index: Int, configuration: WKWebViewConfiguration, privateStore: WKWebsiteDataStore? = nil, space: Space.ID, folder: TabFolder.ID? = nil) -> Tab {
        let tab = Tab(browser: self, configuration: configuration, privateStore: privateStore, space: space)
        tab.folderID = folder
        tabs.insert(tab, at: Self.position(inTabList: index, of: tabs, space: space, folder: folder))
        extensions.didOpen(tab)
        return tab
    }

    private static func position(inTabList index: Int, of tabs: [Tab], space: Space.ID, folder: TabFolder.ID? = nil) -> Int {
        let list = tabs.filter { $0.isInTabList && $0.spaceID == space && $0.folderID == folder }
        return index <= 0 ? 0 : index >= list.count ? tabs.count : tabs.firstIndex { $0 === list[index] } ?? tabs.count
    }

    /// At the end of the Agent group, empty and unselected: the user's tab list and selection
    /// stay as they were. Agents open only web pages, which load in Lithium's own configuration.
    /// With `privateStore` the tab is private (`Tab.privateStore`). In the space shown, unless
    /// opened from a page of another.
    func newAgentTab(session: String, configuration: WKWebViewConfiguration? = nil, privateStore: WKWebsiteDataStore? = nil, space: Space.ID? = nil) -> Tab {
        let tab = Tab(browser: self, configuration: configuration ?? makeConfiguration(), privateStore: privateStore, space: space ?? currentSpaceID)
        tab.openedByAgent = session
        tabs.append(tab)
        extensions.didOpen(tab)
        return tab
    }

    /// Dragged or moved by the user into the tab list, a tab the agent opened becomes theirs:
    /// at `index` in the list, or at its end, just above the Agent group it leaves.
    func keep(_ tab: Tab, at index: Int? = nil) {
        guard tab.isInAgentGroup, let from = tabs.firstIndex(where: { $0 === tab }) else { return }
        extensions.moving(tab) {
            var reordered = tabs
            reordered.remove(at: from)
            tab.openedByAgent = nil
            reordered.insert(tab, at: Self.position(inTabList: index ?? .max, of: reordered, space: tab.spaceID))
            tabs = reordered
        }
    }

    enum TabDropTarget {
        /// Before the tab at this place among the tabs outside folders; nil past their end.
        case tabList(Int?)
        /// Before the tab at this place in the folder; nil past its end.
        case folder(TabFolder.ID, Int?)
        case agentGroup
    }

    /// A tab from the Agent group dropped on the tab list joins it there, and one from a folder
    /// leaves it for that place. Dropped on a folder, a tab goes in, or moves within it. The tab
    /// list outside folders has no drag order of its own: a tab already there stays, as one
    /// dropped among the Agent group does.
    func dropTab(_ items: [String], on target: TabDropTarget) -> Bool {
        endTabDrag()
        guard let tab = (regularTabs + agentTabs).first(where: { $0.id.uuidString == items.first }) else { return false }
        switch target {
        case .tabList(let index):
            guard tab.isInAgentGroup || tab.folderID != nil else { return false }
            moveTab(tab, toFolder: nil, at: index)
        case .folder(let id, let index):
            guard folderExists(id, in: tab.spaceID) else { return false }
            moveTab(tab, toFolder: id, at: index)
        case .agentGroup:
            return false
        }
        return true
    }

    /// Into a folder of its space, or out of folders with nil: before the tab at `index` of that
    /// folder (or of the tabs outside folders), at its end without one. An agent's tab becomes
    /// the user's, as with `keep`; a split's other side comes along, so the pair stays one row.
    func moveTab(_ tab: Tab, toFolder folder: TabFolder.ID?, at index: Int? = nil) {
        guard tab.pinID == nil, folder.map({ folderExists($0, in: tab.spaceID) }) ?? true else { return }
        let partner = split(of: tab)?.partner(of: tab.id).flatMap { id in tabs.first { $0.id == id } }
        let moving = [tab] + (partner.map { [$0] } ?? [])
        // Measured against the folder as shown, the moving tabs still in it.
        let anchor = index.flatMap { index in
            tabList(in: tab.spaceID, folder: folder).dropFirst(index).first { listed in !moving.contains { $0 === listed } }
        }
        place(moving, inFolder: folder, before: anchor)
    }

    /// Its tabs close (Reopen Closed Tab brings them back), or stay, at the top of the tabs
    /// outside folders, where the folder was. Either way the selection stays put when it can.
    func deleteFolder(_ id: TabFolder.ID, closingTabs: Bool) {
        let members = tabs.filter { $0.folderID == id && $0.isInTabList }
        if closingTabs, let selected = selectedTab, members.contains(where: { $0 === selected }) {
            // Off the folder first, so the selection doesn't walk through (and wake) its tabs.
            let list = tabList(in: selected.spaceID)
            let first = list.firstIndex { $0.folderID == id } ?? 0
            let next = list[first...].first { $0.folderID != id } ?? list[..<first].last
            if let next { select(next, picked: false) } else { showStartPage(picked: false) }
        }
        if closingTabs {
            members.reversed().forEach(close)
        } else if !members.isEmpty {
            place(members, inFolder: nil, before: tabList(in: members[0].spaceID, folder: nil).first)
        }
        removeFolder(id)
    }

    /// Moves `moving` into `folder` (nil: out of folders), just before `anchor`, or at the end.
    private func place(_ moving: [Tab], inFolder folder: TabFolder.ID?, before anchor: Tab?) {
        reportingMoves(of: moving[...]) {
            var reordered = tabs.filter { listed in !moving.contains { $0 === listed } }
            for tab in moving {
                tab.folderID = folder
                tab.openedByAgent = nil
            }
            let at = anchor.flatMap { anchor in reordered.firstIndex { $0 === anchor } } ?? reordered.count
            reordered.insert(contentsOf: moving, at: at)
            tabs = reordered
        }
    }

    /// `Extensions.moving` for each tab, each place read before the change and after it.
    private func reportingMoves(of moving: ArraySlice<Tab>, _ change: () -> Void) {
        guard let tab = moving.first else { return change() }
        extensions.moving(tab) { reportingMoves(of: moving.dropFirst(), change) }
    }

    func newTabFocusingAddress() {
        showStartPage()
        requestAddressFocus()
    }

    private func showStartPage(picked: Bool = true) {
        find.hide()
        // Left for the address bar: it counts as used until now, as does the other side of its split.
        selectedTab?.markActive()
        shownPartner?.markActive()
        if picked, selectedTabID != nil { tabPickToken &+= 1 }
        selectedTabID = nil
    }

    func open(_ input: String) {
        open(input, in: selectedTab)
    }

    /// Into `tab`, brought to the front if it no longer is; a new tab when nil.
    private func open(_ input: String, in tab: Tab?) {
        guard let url = AddressInput.url(for: input) else { return }
        open(url, in: tab)
    }

    private func open(_ url: URL, in tab: Tab?) {
        // A typed `mailto:` goes to Mail; the tab, which can't show it, stays on its page.
        if url.scheme?.lowercased() == "mailto" { return ExternalApps.open(url) }
        if let tab {
            if tab !== selectedTab { select(tab) }
            navigate(tab, .open(url))
        } else {
            newTab(url: url)
        }
    }

    enum Step { case open(URL), back, forward, reload, stop }

    /// Every navigation the user asks of an open tab (the address bar, Back, Forward, Reload and
    /// Stop, a reload after a change to the site's settings or data): it wins over an agent
    /// waiting on that tab. What Lithium or an extension does on its own doesn't come here.
    func navigate(_ tab: Tab?, _ step: Step) {
        guard let tab else { return }
        // Back or Forward with nowhere to go does nothing: an agent waiting on the tab goes on.
        if case .back = step, !tab.canGoBack { return }
        if case .forward = step, !tab.canGoForward { return }
        agent?.userNavigated(tab)
        tab.dialogOwner?.answerDialog(in: tab)
        tab.answerHiddenDialog()
        switch step {
        case .open(let url): tab.load(url)
        case .back: tab.goBack()
        case .forward: tab.goForward()
        case .reload: tab.reload()
        case .stop: tab.stopLoading()
        }
    }

    func addressTextChanged(_ text: String) {
        let edited = suggestions.editedTabID.flatMap { id in tabs.first { $0.id == id } }
        suggestions.update(query: text, tabs: tabs, pins: pins, history: history, actions: barActions(for: edited))
    }

    func submitAddress(_ text: String) {
        submitAddress(text, editing: selectedTabID)
    }

    /// Return in the address bar: the highlighted suggestion, or the typed text as is. It goes to
    /// `tabID`, the tab shown when editing began, even if the selection moved on its own since (a
    /// download-only tab closing hands it back to its opener); to a new tab once that one is gone.
    func submitAddress(_ text: String, editing tabID: Tab.ID?) {
        let tab = tabID.flatMap { id in tabs.first { $0.id == id } }
        if let suggestion = suggestions.selected, suggestions.selectedIndex > 0 {
            accept(suggestion, in: tab)
        } else {
            open(text, in: tab)
        }
        suggestions.clear()
    }

    /// A click on a row: to the tab being edited, as Return sends it (`submitAddress(_:editing:)`).
    func accept(_ suggestion: Suggestion) {
        accept(suggestion, in: suggestions.editedTabID.flatMap { id in tabs.first { $0.id == id } })
    }

    private func accept(_ suggestion: Suggestion, in tab: Tab?) {
        suggestions.clear()
        switch suggestion {
        case .search(let query): open(query, in: tab)
        case .address(let url), .history(_, let url): open(url, in: tab)
        case .openTab(let id, _, _): if let tab = tabs.first(where: { $0.id == id }) { select(tab) }
        case .pin(let id, _, _): if let pin = pins.first(where: { $0.id == id }) { activate(pin) }
        case .action(let action): perform(action, on: tab)
        }
    }

    func select(_ tab: Tab, picked: Bool = true) {
        let previous = selectedTab
        if picked { tab.didOpen() }
        if tab.id != selectedTabID {
            if picked { tabPickToken &+= 1 }
            find.hide()
            previous?.markActive()
            // Leaving the screen too, and no view says so: its idle time starts now.
            shownPartner?.markActive()
            recentTabs.didShow(tab, after: previous)
        }
        // A tab of another space (a suggestion, a link's own window moved in) brings its space.
        if tab.spaceID != currentSpaceID, spaces.contains(where: { $0.id == tab.spaceID }) { enterSpace(tab.spaceID) }
        selectedTabID = tab.id
        tab.markActive()
        // In split view the other side comes on screen too, maybe from another split: its pane
        // is reused, so it doesn't wake as it appears.
        shownPartner?.markActive()
        extensions.didSelect(tab)
    }

    /// The selection falls back on the tab's group, never on a favorite: the tab below the
    /// closed one (above, at the bottom). Once the Agent group is empty it falls on the bottom of
    /// the tab list, just above, and once the list is empty on the start page. Closing a
    /// favorite's page selects the top of the list. A tab the user went to straight from the one
    /// that opened it, and left for no other, goes back to its opener instead.
    func close(_ tab: Tab) {
        close(tab, remembering: true)
    }

    /// `remembering` false keeps the tab out of Reopen Closed Tab: a tab that closed itself once
    /// its address became a download would only start the download again.
    func close(_ tab: Tab, remembering: Bool) {
        if quickLinks.contains(tab) { return quickLinks.close(tab) }
        let order = peers(of: tab)
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        videoPopout.discard(tab)
        nowPlaying.discard(tab)
        if remembering, let url = tab.url, !tab.isEphemeral {
            // An agent's tab comes back the user's, at the bottom of the list, next to where it was.
            let group = tabList(in: tab.spaceID, folder: tab.folderID)
            let place = tab.pinID != nil ? nil : tab.isInAgentGroup ? group.count : group.firstIndex { $0 === tab }
            let closed = ClosedTab(url: url, pinID: tab.pinID, spaceID: tab.spaceID, customTitle: tab.customTitle, index: place,
                                   folderID: tab.folderID, history: tab.history)
            closedTabs.append(closed)
            if closedTabs.count > Self.closedTabsLimit { closedTabs.removeFirst() }
        }
        // In split view the other side fills the window.
        let partner = leaveSplit(tab)
        let wasSelected = tab.id == selectedTabID
        if wasSelected {
            let position = order.firstIndex { $0 === tab } ?? 0
            let remaining = order.filter { $0 !== tab }
            let opener = recentTabs.opener(returningFrom: tab).flatMap { opener in tabs.contains { $0 === opener } ? opener : nil }
            // In split view the partner wins: it is already on screen.
            selectedTabID = partner?.id ?? opener?.id ?? (remaining.isEmpty ? (tab.isInAgentGroup ? tabList(in: tab.spaceID).last?.id : nil)
                : remaining[min(position, remaining.count - 1)].id)
            // The tab shown next may be asleep.
            selectedTab?.markActive()
            if let selectedTab { recentTabs.didShow(selectedTab, after: nil) }
        }
        recentTabs.didClose(tab)
        tab.unpair()
        tab.dialogOwner?.answerDialog(in: tab)
        agent?.didClose(tab)
        permissions.cancel(tabID: tab.id)
        appLinks.cancel(tabID: tab.id)
        // A name field gone with its row would never end the rename, which holds Escape and the agent.
        if renamingTabID == tab.id { renamingTabID = nil }
        summaries.discard(tab)
        tab.tearDown()
        tabs.remove(at: index)
        extensions.didClose(tab)
        // Extensions would otherwise go on taking the closed tab for the active one.
        if wasSelected { extensions.didSelect(selectedTab) }
        dropPrivateData(of: tab)
    }

    /// The last open tab of a private store gone, its cookies and storage go at once, rather
    /// than whenever WebKit frees the store, and so do its permission answers and site settings.
    private func dropPrivateData(of tab: Tab) {
        guard let store = tab.privateStore, !tabs.contains(where: { $0.privateStore === store }) else { return }
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        permissions.forget(privateSession: ObjectIdentifier(store))
        privacy.forget(privateSession: ObjectIdentifier(store))
        PageStyle.forget(privateSession: ObjectIdentifier(store))
    }

    func closeSelectedTab() {
        if let tab = selectedTab { close(tab) }
    }

    /// ⌘W, which the menu sends whichever window is key: the selected tab only when that is the
    /// browser's window. Another one in front (a detached Web Inspector, a sheet) closes instead.
    /// A video in full screen is in WebKit's own window, holding the page: that is the tab's too.
    func closeTabOrWindow(keyWindow: NSWindow? = NSApp.keyWindow) {
        guard let keyWindow else { return }
        let page = selectedTab?.loadedWebView
        let isTabs = keyWindow === page?.window || page.map { $0.fullscreenState != .notInFullscreen } == true
        // Before the browser's window is known, it is the one in front.
        if window == nil || keyWindow === window || isTabs { closeSelectedTab() } else { keyWindow.performClose(nil) }
    }

    /// The others of its group: favorites' pages stay open, as Chrome keeps pinned tabs, and so
    /// does the Agent group for a tab of the list, or the list for an agent's tab. Tabs close
    /// bottom up, so ⇧⌘T brings them back top down, each where it was.
    func closeOtherTabs(than tab: Tab) {
        select(tab, picked: false)
        peers(of: tab).reversed().filter { $0 !== tab }.forEach(close)
    }

    func closeTabs(below tab: Tab) {
        let below = tabs(below: tab)
        // Selected first, so the selection doesn't walk through (and wake) the tabs about to close.
        if below.contains(where: { $0.id == selectedTabID }) { select(tab, picked: false) }
        below.reversed().forEach(close)
    }

    /// Below it in its group.
    func tabs(below tab: Tab) -> ArraySlice<Tab> {
        let list = peers(of: tab)
        guard let index = list.firstIndex(where: { $0 === tab }) else { return [] }
        return list[(index + 1)...]
    }

    /// Bottom up like the tabs below, so ⇧⌘T brings them back top down, each where it was.
    func closeTabs(above tab: Tab) {
        let above = tabs(above: tab)
        if above.contains(where: { $0.id == selectedTabID }) { select(tab, picked: false) }
        above.reversed().forEach(close)
    }

    /// Above it in its group.
    func tabs(above tab: Tab) -> ArraySlice<Tab> {
        let list = peers(of: tab)
        guard let index = list.firstIndex(where: { $0 === tab }) else { return [] }
        return list[..<index]
    }

    var canReopenClosedTab: Bool { !closedTabs.isEmpty }

    /// Like Chrome: back in its place, with its history. A favorite's page goes back to its
    /// favorite if that has no page open, or else to the top of the list. In its own space,
    /// which comes back with it, and its folder; at the top of the list if that is gone.
    func reopenClosedTab() {
        guard let closed = closedTabs.popLast() else { return }
        let pin = pins.first { $0.id == closed.pinID && liveTab(for: $0) == nil }
        let folder = closed.folderID.flatMap { folderExists($0, in: closed.spaceID) ? $0 : nil }
        let index = pin != nil || closed.folderID != folder ? 0 : closed.index ?? 0
        let tab = insertTab(at: index, configuration: makeConfiguration(for: closed.url), space: closed.spaceID, folder: pin == nil ? folder : nil)
        extensions.moving(tab) { tab.pinID = pin?.id }
        tab.customTitle = closed.customTitle
        tab.load(closed.url, history: closed.history)
        select(tab)
    }

    /// Just below the original, with its history and name, in its folder; a favorite's page has
    /// its copy at the top of the list. The copy is never a favorite, nor an agent's: an agent's
    /// tab has its copy at the bottom of the list, next to it.
    func duplicate(_ tab: Tab) {
        guard let url = tab.url else { return }
        let list = tabList(in: tab.spaceID, folder: tab.folderID)
        let index = tab.isInAgentGroup ? list.count : list.firstIndex { $0 === tab }.map { $0 + 1 } ?? 0
        // A private tab's copy shares its store, and is private too; any copy stays in its space.
        let copy = insertTab(at: index, configuration: makeConfiguration(for: url), privateStore: tab.privateStore, space: tab.spaceID, folder: tab.folderID)
        copy.customTitle = tab.customTitle
        copy.load(url, history: tab.history)
        select(copy)
    }

    func copyLink(of tab: Tab?) {
        copyLinks(of: tab.map { [$0] } ?? [])
    }

    /// One address per line, in the order given; tabs without one are skipped.
    func copyLinks(of tabs: [Tab]) {
        let links = Self.links(of: tabs)
        guard !links.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(links, forType: .string)
    }

    static func links(of tabs: [Tab]) -> String {
        tabs.compactMap { $0.url?.absoluteString }.joined(separator: "\n")
    }

    /// Empty or whitespace-only names give the tab back its page title. A tab without a name of
    /// its own keeps none when left with the title its field `shown` (a double-click, then a click
    /// away): that would freeze the page's title on it.
    func rename(_ tab: Tab, to name: String, shown: String? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if tab.customTitle != nil || trimmed != shown?.trimmingCharacters(in: .whitespacesAndNewlines) {
            tab.customTitle = trimmed.isEmpty ? nil : trimmed
        }
        renamingTabID = nil
    }

    func requestAddressFocus() {
        addressFocusToken &+= 1
    }

    /// Live favorites first (in grid order), then the tab list and the Agent group, which is how
    /// the sidebar reads top to bottom; space after space. Extensions and agents see every space.
    var navigationOrder: [Tab] {
        spaces.isEmpty ? navigationOrder(in: Space.mainID) : spaces.flatMap { navigationOrder(in: $0.id) }
    }

    /// Next Tab and Previous Tab stay in the space shown, as the sidebar does.
    func selectAdjacentTab(_ offset: Int) {
        let order = navigationOrder(in: currentSpaceID)
        guard !order.isEmpty else { return }
        // From the start page, forward starts at the first item and backward at the last.
        guard let current = order.firstIndex(where: { $0.id == selectedTabID }) else {
            select(offset > 0 ? order[0] : order[order.count - 1])
            return
        }
        select(order[(current + offset + order.count) % order.count])
    }

    /// Control-Tab and Control-Shift-Tab: through the tabs in the order they were last shown, as
    /// long as Control is held, and to the highlighted one when it is let go. Without Control held
    /// (the menu clicked), one step and done.
    func cycleRecentTabs(backward: Bool, holdingControl: Bool = NSEvent.modifierFlags.contains(.control)) {
        recentTabs.step(backward: backward, among: navigationOrder(in: currentSpaceID), current: selectedTab)
        if holdingControl {
            recentTabs.watchControl { [weak self] in self?.endTabCycle(commit: $0) }
        } else {
            endTabCycle(commit: true)
        }
    }

    func endTabCycle(commit: Bool) {
        guard let tab = recentTabs.endCycle(), commit, tabs.contains(where: { $0 === tab }) else { return }
        select(tab)
    }

    /// ⌘1…⌘9 walk the favorites grid, then the rows of the tab list and the Agent group, as the
    /// sidebar shows them: a split pair is one row, and its number shows the pair. Folder headers
    /// and the tabs of a collapsed folder have none.
    func selectItem(at index: Int) {
        let rows = tabListRows.compactMap(\.entry?.tab) + agentTabs
        let pins = spacePins
        if index < pins.count {
            activate(pins[index])
        } else if index - pins.count < rows.count {
            let tab = rows[index - pins.count]
            // The pair already shown keeps its focused side.
            if let selectedTab, split(of: tab)?.contains(selectedTab.id) == true { return }
            select(tab)
        }
    }

    // MARK: Session

    private var session: Session {
        var session = Session()
        var places: [Tab.ID: Int] = [:]
        for tab in tabs {
            guard let url = tab.url, !tab.isEphemeral else { continue }
            if tab.id == selectedTabID { session.selectedIndex = session.tabs.count }
            places[tab.id] = session.tabs.count
            // Not the error page's own title: the tab comes back named after its site.
            let title = tab.isShowingError ? "" : tab.title
            let lastShown = tab.spaceID != currentSpaceID && spaceSelections[tab.spaceID] == tab.id
            session.tabs.append(Session.Tab(url: url, title: title, customTitle: tab.customTitle, pinID: tab.pinID,
                                            spaceID: Space.saved(tab.spaceID), lastShown: lastShown ? true : nil, folderID: tab.folderID))
        }
        session.splits = savedSplits(at: places)
        session.folders = savedFolders
        if !spaces.isEmpty {
            session.spaces = spaces
            session.spaceID = Space.saved(currentSpaceID)
        }
        return session
    }

    /// Every tab comes back asleep. The selected one wakes in `windowDidAppear`: a page that
    /// finishes loading before its web view is in a window stays blank.
    private func restore(_ session: Session) {
        restoreSpaces(session)
        restoreFolders(session.folders)
        var selected: Tab?
        var restored: [Int: Tab] = [:]
        for (index, saved) in session.tabs.enumerated() {
            // An extension's own page needs its extension, which loads after the session comes back.
            guard saved.url.scheme != Extensions.scheme else { continue }
            let space = saved.spaceID.flatMap { id in spaces.contains { $0.id == id } ? id : nil } ?? Space.mainID
            let tab = Tab(browser: self, configuration: makeConfiguration(for: saved.url), space: space)
            tab.restore(url: saved.url, title: saved.title)
            tab.customTitle = saved.customTitle
            tab.pinID = saved.pinID.flatMap { id in pins.contains { $0.id == id && $0.space == space } ? id : nil }
            tab.folderID = saved.folderID.flatMap { id in tab.pinID == nil && folderExists(id, in: space) ? id : nil }
            if saved.lastShown == true { spaceSelections[space] = tab.id }
            // Asleep, it loads nothing that would tidy its title.
            tidyTitles.update(tab, askingModel: false)
            tabs.append(tab)
            extensions.didOpen(tab)
            restored[index] = tab
            if index == session.selectedIndex { selected = tab }
        }
        restoreSplits(session.splits, tabs: restored)
        if let selected {
            currentSpaceID = selected.spaceID
            selectedTabID = selected.id
            extensions.didSelect(selected)
        }
    }

    /// The main space comes first, whatever the file says. A favorite of a space no longer saved
    /// (a session file that couldn't be read) goes back to the main space rather than vanish.
    private func restoreSpaces(_ session: Session) {
        if let saved = session.spaces, !saved.isEmpty {
            let main = saved.first { $0.id == Space.mainID } ?? .main
            spaces = [main] + saved.filter { $0.id != Space.mainID }
            if let id = session.spaceID, spaces.contains(where: { $0.id == id }) { currentSpaceID = id }
        }
        let known = Set(allSpaces.map(\.id))
        if pins.contains(where: { !known.contains($0.space) }) {
            pins = pins.map { pin in
                var pin = pin
                if !known.contains(pin.space) { pin.spaceID = nil }
                return pin
            }
        }
    }

    /// Writes the session now, and again a moment after a tab it describes changes: a page that
    /// retitles itself (an unread count, a clock) costs one write a second at most. Nothing runs
    /// while nothing changes.
    private func saveSession() {
        sessionSave?.cancel()
        sessionSave = nil
        let session = withObservationTracking { self.session } onChange: { [weak self] in
            Task { @MainActor in self?.sessionChanged() }
        }
        guard session != savedSession else { return }
        SessionStore.save(session)
        savedSession = session
    }

    private func sessionChanged() {
        guard sessionSave == nil else { return }
        sessionSave = Task { [weak self] in
            try? await Task.sleep(for: Self.sessionSaveDelay)
            guard !Task.isCancelled else { return }
            self?.saveSession()
        }
    }

    static let sessionSaveDelay = Duration.seconds(1)

    /// What waits to be written, at once: when the app quits.
    func saveNow() {
        saveSession()
        history.writeTitles()
    }

    /// With the history cleared, the icons kept for the sites in it; favorites and open tabs
    /// keep theirs. A private tab's host doesn't count: keeping it would keep an earlier visit.
    func clearIcons() async {
        let hosts = pins.map(\.url) + tabs.filter { !$0.isEphemeral }.compactMap(\.url)
        await favicons.clear(keeping: Set(hosts.compactMap { $0.host() }))
    }

    // MARK: Spaces

    /// Every store that holds the user's (non-private) site data: the default one, and those of
    /// the spaces that keep theirs apart.
    var siteDataStores: [WKWebsiteDataStore] {
        [.default()] + spaces.filter(\.separatesData).compactMap { spaceStore(for: $0.id) }
    }

    /// The store of a space that keeps its data apart, made on first use and kept while the space
    /// is. Nil for the main space and those sharing its data, whose tabs use the default store.
    func spaceStore(for id: Space.ID) -> WKWebsiteDataStore? {
        guard id != Space.mainID, spaces.contains(where: { $0.id == id && $0.separatesData }) else { return nil }
        if let store = spaceStores[id] { return store }
        let store = WKWebsiteDataStore(forIdentifier: id)
        spaceStores[id] = store
        return store
    }

    /// Made and shown, empty, with the keyboard in the address bar to go somewhere.
    func addSpace(_ space: Space) {
        guard canAddSpace, !allSpaces.contains(where: { $0.id == space.id }) else { return }
        var space = space
        space.name = Space.trimmedName(space.name, fallback: "Space \(allSpaces.count + 1)")
        spaces = allSpaces + [space]
        switchToSpace(space.id)
        requestAddressFocus()
        // A deleted space's folder WebKit still held then goes now.
        if space.separatesData { storeCleanup = Task { await removeUnusedStores() } }
    }

    /// Its name, color and icon. Whether it keeps its data apart stays as chosen.
    func updateSpace(_ space: Space) {
        guard let index = spaces.firstIndex(where: { $0.id == space.id }) else { return }
        var updated = space
        updated.name = Space.trimmedName(space.name, fallback: spaces[index].name)
        updated.separatesData = spaces[index].separatesData
        if updated != spaces[index] { spaces[index] = updated }
    }

    /// Back to the tab last shown in the space, or to the start page. An edit in the address bar
    /// or a tab's name ends first: its field would be left editing a tab no longer shown. Not a
    /// pick (`tabPickToken`): a peeked sidebar stays out on the space switched to.
    func switchToSpace(_ id: Space.ID) {
        guard id != currentSpaceID, spaces.contains(where: { $0.id == id }) else { return }
        if isEditingAddress || isRenaming { window?.makeFirstResponder(nil) }
        renamingTabID = nil
        folders.renamingID = nil
        let order = spaces.map(\.id)
        spaceStepsForward = (order.firstIndex(of: id) ?? 0) > (order.firstIndex(of: currentSpaceID) ?? 0)
        if let last = spaceSelections[id], let tab = tabs.first(where: { $0.id == last && $0.spaceID == id }) {
            tab.didOpen()
            select(tab, picked: false)
        } else {
            enterSpace(id)
            showStartPage(picked: false)
        }
    }

    private func enterSpace(_ id: Space.ID) {
        spaceSelections[currentSpaceID] = selectedTabID
        currentSpaceID = id
    }

    /// Its tabs close, kept out of Reopen Closed Tab, and its favorites go; then its store, when
    /// it has one. The window moves to the space before it first.
    func deleteSpace(_ id: Space.ID) {
        guard id != Space.mainID, let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        let space = spaces[index]
        if currentSpaceID == id { switchToSpace(spaces[index - 1].id) }
        tabs.filter { $0.spaceID == id }.reversed().forEach { close($0, remembering: false) }
        quickLinks.tabs.filter { $0.spaceID == id }.forEach(quickLinks.close)
        closedTabs.removeAll { $0.spaceID == id }
        for pin in pins where pin.space == id { pinIcons[pin.id] = nil }
        pins.removeAll { $0.space == id }
        removeFolders(in: id)
        spaces.remove(at: index)
        spaceSelections[id] = nil
        if space.separatesData { removeStore(of: id) }
    }

    /// Its cookies, logins and storage go at once, even while WebKit still holds the store; its
    /// folder goes with any other no space uses once WebKit lets go: it refuses while a web view
    /// of the store lives. One still held now goes when the next space with its own data is made.
    private func removeStore(of id: Space.ID) {
        let store = spaceStores.removeValue(forKey: id) ?? WKWebsiteDataStore(forIdentifier: id)
        storeCleanup = Task {
            await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            await removeUnusedStores()
        }
    }

    /// The stores on disk no space keeps its data in.
    private func removeUnusedStores() async {
        let kept = Set(spaces.filter(\.separatesData).map(\.id))
        for id in await WKWebsiteDataStore.allDataStoreIdentifiers where !kept.contains(id) {
            try? await WKWebsiteDataStore.remove(forIdentifier: id)
        }
    }

    // MARK: Favorites

    func activate(_ pin: Pin) {
        if let tab = liveTab(for: pin) {
            select(tab)
        } else {
            let tab = newTab(url: pin.url, space: pin.space)
            extensions.moving(tab) { tab.pinID = pin.id }
        }
    }

    /// Where the slot `index` of a space's grid is in `pins`, which holds every space's favorites:
    /// just before the favorite in that slot, or after the space's last one.
    private func pinsIndex(forSlot index: Int, in space: Space.ID, of pins: [Pin]) -> Int {
        guard !spaces.isEmpty else { return min(max(index, 0), pins.count) }
        let grid = pins.filter { $0.space == space }
        if index < grid.count { return pins.firstIndex { $0.id == grid[max(index, 0)].id } ?? pins.count }
        return grid.last.flatMap { last in pins.firstIndex { $0.id == last.id } }.map { $0 + 1 } ?? pins.count
    }

    /// Without an index the favorite goes at the end of its space's grid; with one it takes that
    /// slot. A private tab can't be pinned: a favorite is saved, with its address and icon.
    func pin(_ tab: Tab, at index: Int? = nil) {
        guard tab.pinID == nil, !tab.isEphemeral, let url = tab.url else { return }
        let pin = Pin(id: UUID(), url: url, title: tab.displayTitle, favicon: tab.faviconData, spaceID: Space.saved(tab.spaceID))
        extensions.moving(tab) {
            pins.insert(pin, at: pinsIndex(forSlot: index ?? .max, in: tab.spaceID, of: pins))
            leaveSplit(tab)
            tab.pinID = pin.id
            // The user's from now on: unpinned, it goes to the tab list, outside folders.
            tab.openedByAgent = nil
            tab.folderID = nil
        }
        // Its name field was in the list, which no longer shows it.
        if renamingTabID == tab.id { renamingTabID = nil }
    }

    func pinTab(withID id: String, at index: Int? = nil) {
        if let tab = tabs.first(where: { $0.id.uuidString == id }) { pin(tab, at: index) }
    }

    /// Moves a favorite into the slot at `index`, the others shifting around it, as on a home screen.
    /// Built on a copy so `pins` is saved once, never without the moving favorite.
    /// `index` is a slot of the favorite's own space's grid.
    func movePin(id: UUID, to index: Int) {
        guard let from = pins.firstIndex(where: { $0.id == id }) else { return }
        let space = pins[from].space
        let grid = self.pins(in: space)
        let to = min(max(index, 0), grid.count - 1)
        guard grid.firstIndex(where: { $0.id == id }) != to else { return }
        var reordered = pins
        let moving = reordered.remove(at: from)
        reordered.insert(moving, at: pinsIndex(forSlot: to, in: space, of: reordered))
        extensions.moving(liveTab(for: pins[from])) { pins = reordered }
    }

    func unpin(_ pin: Pin) {
        let live = liveTab(for: pin)
        extensions.moving(live) {
            live?.pinID = nil
            pins.removeAll { $0.id == pin.id }
        }
        pinIcons[pin.id] = nil
    }

    func togglePinForSelectedTab() {
        guard let tab = selectedTab else { return }
        if let pin = pins.first(where: { $0.id == tab.pinID }) { unpin(pin) } else { pin(tab) }
    }

    func didLoadFavicon(_ data: Data, in tab: Tab) {
        guard let index = pins.firstIndex(where: { $0.id == tab.pinID }),
              pins[index].url.host() == tab.url?.host() else { return }
        storeIcon(data, from: nil, inPinAt: index)
    }

    /// Saved once, and only when something changed. `url` is where the page said its icon is;
    /// only an http(s) one is kept, the only kind fetched again later: a `data:` icon the page
    /// redraws would otherwise rewrite the favorites at each new address, pixels unchanged.
    private func storeIcon(_ data: Data, from url: URL?, inPinAt index: Int) {
        var pin = pins[index]
        pin.favicon = data
        if let url { pin.iconURL = ["http", "https"].contains(url.scheme?.lowercased()) ? url : nil }
        guard pin != pins[index] else { return }
        if pin.favicon != pins[index].favicon { pinIcons[pin.id] = nil }
        pins[index] = pin
    }

    /// The icon a pinned tab's page last named, for the tab to fetch when it wakes.
    func savedIconURL(of tab: Tab) -> URL? {
        guard let pin = pins.first(where: { $0.id == tab.pinID }), pin.url.host() == tab.url?.host(),
              let url = pin.iconURL, ["http", "https"].contains(url.scheme?.lowercased()) else { return nil }
        return url
    }

    /// The pinned page's icon, fetched afresh from where it says it is. A fetch that outlasts
    /// the page's site, the pin or the icon (a later one may come back first) isn't theirs.
    func refreshIcon(of tab: Tab, from url: URL) async {
        guard let pinID = tab.pinID, let host = tab.url?.host(),
              let data = await favicons.refresh(host: host, from: url),
              tab.pinID == pinID, tab.url?.host() == host, tab.liveIcon == url else { return }
        tab.showFavicon(data)
        if let index = pins.firstIndex(where: { $0.id == pinID }), pins[index].url.host() == host {
            storeIcon(data, from: url, inPinAt: index)
        }
    }

    /// A sleeping tab runs no script, so at each new day the icon its page last named is fetched
    /// once more for each favorite asleep or without a page; it stays asleep. Favorites whose
    /// page never named one are left alone.
    private func refreshSleepingPinIcons() {
        let due = pins.compactMap { pin -> (Pin.ID, URL)? in
            guard liveTab(for: pin)?.isAsleep != false, let url = pin.iconURL,
                  ["http", "https"].contains(url.scheme?.lowercased()) else { return nil }
            return (pin.id, url)
        }
        guard !due.isEmpty else { return }
        sleepingIconsRefresh = Task {
            for (id, url) in due {
                guard let host = pins.first(where: { $0.id == id })?.url.host(),
                      let data = await favicons.refresh(host: host, from: url),
                      // The tab may have woken meanwhile and its page named another.
                      let index = pins.firstIndex(where: { $0.id == id }), pins[index].iconURL == url else { continue }
                if let tab = liveTab(for: pins[index]), tab.isAsleep, tab.url?.host() == host { tab.showFavicon(data) }
                storeIcon(data, from: url, inPinAt: index)
            }
        }
    }
}


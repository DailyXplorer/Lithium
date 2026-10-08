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
    private(set) var addressFocusToken = 0
    /// Moves when the user switches to another tab or to the start page, not when closing one moves the selection, so
    /// the peeked sidebar can slide back on a pick yet stay out while tabs close in a row.
    private(set) var tabPickToken = 0
    /// Opens as the user last left it. Only `toggleSidebar()` saves, so a passing change such as
    /// the screenshot taking both looks never outlives the app.
    var isSidebarVisible = UserDefaults.standard.object(forKey: Preference.sidebarVisible) as? Bool ?? true
    var renamingTabID: Tab.ID?
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
    let recentTabs = RecentTabs()
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
        let customTitle: String?
        /// Its place in the tab list; nil for a favorite's page.
        let index: Int?
        /// From `Tab.history`.
        let history: Any?
    }

    /// 10 minutes, or 5 while the Mac saves energy (Low Power Mode, or running hot).
    /// `defaults write app.lithium.browser tabIdleSeconds N` overrides both.
    static var tabIdleInterval: TimeInterval {
        let custom = UserDefaults.standard.double(forKey: "tabIdleSeconds")
        if custom > 0 { return custom }
        return isSavingEnergy ? shortIdleInterval : 10 * 60
    }
    static let shortIdleInterval: TimeInterval = 5 * 60

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
            }
        }
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
            sleepIdleTabs(idleFor: min(Self.tabIdleInterval, Self.shortIdleInterval), sparingPopups: true)
        } else {
            sleepIdleTabs(idleFor: Self.tabIdleInterval, sparingPopups: true)
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

    /// Settings › Agents. Off by default; the choice outlives the app.
    func setAgentAccess(_ enabled: Bool) async {
        UserDefaults.standard.set(enabled, forKey: Preference.agentAccess)
        if enabled, agent == nil {
            let hub = AgentHub(browser: self, tools: AgentHub.tabTools + AgentHub.readTools + AgentHub.dialogTools + AgentHub.inputTools + AgentHub.parityTools + AgentHub.networkTools + AgentHub.evaluateTools + AgentHub.batchTools)
            agent = hub
            await hub.start()
        } else if !enabled, let hub = agent {
            agent = nil
            hub.shutdown()
        }
    }

    /// Reloads the page so its content blockers and scripts match the new setting.
    func setProtections(_ enabled: Bool, for tab: Tab?) {
        privacy.setEnabled(enabled, for: tab?.url)
        navigate(tab, .reload)
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
        return find.isFieldFocused || renamingTabID != nil
    }

    /// Closes the topmost Lithium overlay. Returns false when there was none.
    func dismissOverlay() -> Bool {
        if recentTabs.target != nil {
            endTabCycle(commit: false)
            return true
        }
        if renamingTabID != nil {
            renamingTabID = nil
            return true
        }
        if find.isVisible {
            find.hide()
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

    func toggleSidebar() {
        isSidebarVisible.toggle()
        UserDefaults.standard.set(isSidebarVisible, forKey: Preference.sidebarVisible)
    }

    var selectedTab: Tab? { tabs.first { $0.id == selectedTabID } }
    /// The tab list. Tabs an agent opened sit apart, in the Agent group below it.
    var regularTabs: [Tab] { tabs.filter(\.isInTabList) }
    var agentTabs: [Tab] { tabs.filter(\.isInAgentGroup) }
    /// The group a tab's bulk actions (Close Other Tabs, Close Tabs Below) stay within: the
    /// Agent group for its tabs, the tab list for the rest.
    func peers(of tab: Tab) -> [Tab] {
        tab.isInAgentGroup ? agentTabs : regularTabs
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

    /// `opener` is the tab whose page opened this one (a link, ⌘-click or `window.open`).
    @discardableResult
    func newTab(url: URL? = nil, selecting: Bool = true, configuration: WKWebViewConfiguration? = nil, privateStore: WKWebsiteDataStore? = nil, openedFrom opener: Tab? = nil) -> Tab {
        let tab = insertTab(at: 0, configuration: configuration ?? makeConfiguration(for: url), privateStore: privateStore)
        if let opener { recentTabs.didOpen(tab, from: opener) }
        if let url { tab.load(url) }
        if selecting { select(tab) }
        return tab
    }

    /// `index` is a place in the tab list, clamped to it. `tabs` also holds favorites' pages, in
    /// no particular order, so the new tab goes just before the one it pushes down.
    private func insertTab(at index: Int, configuration: WKWebViewConfiguration, privateStore: WKWebsiteDataStore? = nil) -> Tab {
        let tab = Tab(browser: self, configuration: configuration, privateStore: privateStore)
        tabs.insert(tab, at: Self.position(inTabList: index, of: tabs))
        extensions.didOpen(tab)
        return tab
    }

    private static func position(inTabList index: Int, of tabs: [Tab]) -> Int {
        let list = tabs.filter(\.isInTabList)
        return index <= 0 ? 0 : index >= list.count ? tabs.count : tabs.firstIndex { $0 === list[index] } ?? tabs.count
    }

    /// At the end of the Agent group, empty and unselected: the user's tab list and selection
    /// stay as they were. Agents open only web pages, which load in Lithium's own configuration.
    /// With `privateStore` the tab is private (`Tab.privateStore`).
    func newAgentTab(session: String, configuration: WKWebViewConfiguration? = nil, privateStore: WKWebsiteDataStore? = nil) -> Tab {
        let tab = Tab(browser: self, configuration: configuration ?? makeConfiguration(), privateStore: privateStore)
        tab.openedByAgent = session
        tabs.append(tab)
        extensions.didOpen(tab)
        return tab
    }

    /// Dragged or moved by the user into the tab list, a tab the agent opened becomes theirs:
    /// at `index` in the list, or at its end, just above the Agent group it leaves.
    func keep(_ tab: Tab, at index: Int? = nil) {
        guard tab.isInAgentGroup, let from = tabs.firstIndex(where: { $0 === tab }) else { return }
        var reordered = tabs
        reordered.remove(at: from)
        tab.openedByAgent = nil
        reordered.insert(tab, at: Self.position(inTabList: index ?? .max, of: reordered))
        tabs = reordered
    }

    enum TabDropTarget {
        /// Before the tab at this place in the tab list; nil past its end.
        case tabList(Int?)
        case agentGroup
    }

    /// A tab from the Agent group dropped on the tab list joins it there. Dropped among the
    /// Agent group, it stays: the group has no order of its own to change.
    func dropTab(_ items: [String], on target: TabDropTarget) -> Bool {
        guard case .tabList(let index) = target,
              let tab = agentTabs.first(where: { $0.id.uuidString == items.first }) else { return false }
        keep(tab, at: index)
        return true
    }

    func newTabFocusingAddress() {
        find.hide()
        // Left for the address bar: it counts as used until now.
        selectedTab?.markActive()
        if selectedTabID != nil { tabPickToken &+= 1 }
        selectedTabID = nil
        requestAddressFocus()
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
        agent?.userNavigated(tab)
        tab.dialogOwner?.answerDialog(in: tab)
        tab.answerHiddenDialog()
        switch step {
        case .open(let url): tab.load(url)
        case .back: tab.webView.goBack()
        case .forward: tab.webView.goForward()
        case .reload: tab.reload()
        case .stop: tab.stopLoading()
        }
    }

    func addressTextChanged(_ text: String) {
        suggestions.update(query: text, tabs: tabs, pins: pins, history: history)
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

    func accept(_ suggestion: Suggestion) {
        accept(suggestion, in: selectedTab)
    }

    private func accept(_ suggestion: Suggestion, in tab: Tab?) {
        suggestions.clear()
        switch suggestion {
        case .search(let query): open(query, in: tab)
        case .address(let url), .history(_, let url): open(url, in: tab)
        case .openTab(let id, _, _): if let tab = tabs.first(where: { $0.id == id }) { select(tab) }
        case .pin(let id, _, _): if let pin = pins.first(where: { $0.id == id }) { activate(pin) }
        }
    }

    func select(_ tab: Tab, picked: Bool = true) {
        let previous = selectedTab
        if picked { tab.didOpen() }
        if tab.id != selectedTabID {
            if picked { tabPickToken &+= 1 }
            find.hide()
            previous?.markActive()
            recentTabs.didShow(tab, after: previous)
        }
        selectedTabID = tab.id
        tab.markActive()
        // In split view the other side comes on screen too, maybe from another split: its pane
        // is reused, so it doesn't wake as it appears.
        shownPartner?.markActive()
        if previous !== tab { extensions.didActivate(tab, previous: previous) }
    }

    /// The selection falls back on the tab's group, never on a favorite: the tab below the
    /// closed one (above, at the bottom). Once the Agent group is empty it falls on the bottom of
    /// the tab list, just above, and once the list is empty on the start page. Closing a
    /// favorite's page selects the top of the list. A tab the user went to straight from the one
    /// that opened it, and left for no other, goes back to its opener instead.
    func close(_ tab: Tab) {
        let order = peers(of: tab)
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        videoPopout.discard(tab)
        nowPlaying.discard(tab)
        if let url = tab.url, !tab.isEphemeral {
            // An agent's tab comes back the user's, at the bottom of the list, next to where it was.
            let place = tab.pinID != nil ? nil : tab.isInAgentGroup ? regularTabs.count : order.firstIndex { $0 === tab }
            let closed = ClosedTab(url: url, pinID: tab.pinID, customTitle: tab.customTitle, index: place, history: tab.history)
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
            selectedTabID = partner?.id ?? opener?.id ?? (remaining.isEmpty ? (tab.isInAgentGroup ? regularTabs.last?.id : nil)
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
        if wasSelected, let selectedTab { extensions.didActivate(selectedTab, previous: nil) }
        dropPrivateData(of: tab)
    }

    /// The last open tab of a private store gone, its cookies and storage go at once, rather
    /// than whenever WebKit frees the store, and so do its permission answers.
    private func dropPrivateData(of tab: Tab) {
        guard let store = tab.privateStore, !tabs.contains(where: { $0.privateStore === store }) else { return }
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        permissions.forget(privateSession: ObjectIdentifier(store))
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
    /// favorite if that has no page open, or else to the top of the list.
    func reopenClosedTab() {
        guard let closed = closedTabs.popLast() else { return }
        let pin = pins.first { $0.id == closed.pinID && liveTab(for: $0) == nil }
        let tab = insertTab(at: pin == nil ? closed.index ?? 0 : 0, configuration: makeConfiguration(for: closed.url))
        tab.pinID = pin?.id
        tab.customTitle = closed.customTitle
        tab.load(closed.url, history: closed.history)
        select(tab)
    }

    /// Just below the original, with its history and name; a favorite's page has its copy at the
    /// top of the list. The copy is never a favorite, nor an agent's: an agent's tab has its copy
    /// at the bottom of the list, next to it.
    func duplicate(_ tab: Tab) {
        guard let url = tab.url else { return }
        let list = regularTabs
        let index = tab.isInAgentGroup ? list.count : list.firstIndex { $0 === tab }.map { $0 + 1 } ?? 0
        // A private tab's copy shares its store, and is private too.
        let copy = insertTab(at: index, configuration: makeConfiguration(for: url), privateStore: tab.privateStore)
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

    /// Empty or whitespace-only names give the tab back its page title.
    func rename(_ tab: Tab, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        tab.customTitle = trimmed.isEmpty ? nil : trimmed
        renamingTabID = nil
    }

    func requestAddressFocus() {
        addressFocusToken &+= 1
    }

    /// Live favorites first (in grid order), then the tab list and the Agent group, which is how
    /// the sidebar reads top to bottom.
    var navigationOrder: [Tab] {
        pins.compactMap(liveTab(for:)) + regularTabs + agentTabs
    }

    func selectAdjacentTab(_ offset: Int) {
        let order = navigationOrder
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
        recentTabs.step(backward: backward, among: navigationOrder, current: selectedTab)
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
    /// sidebar shows them: a split pair is one row, and its number shows the pair.
    func selectItem(at index: Int) {
        let rows = tabListEntries.map(\.tab) + agentTabs
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
            session.tabs.append(Session.Tab(url: url, title: title, customTitle: tab.customTitle, pinID: tab.pinID))
        }
        session.splits = savedSplits(at: places)
        return session
    }

    /// Every tab comes back asleep. The selected one wakes in `windowDidAppear`: a page that
    /// finishes loading before its web view is in a window stays blank.
    private func restore(_ session: Session) {
        let pinIDs = Set(pins.map(\.id))
        var selected: Tab?
        var restored: [Int: Tab] = [:]
        for (index, saved) in session.tabs.enumerated() {
            // An extension's own page needs its extension, which loads after the session comes back.
            guard saved.url.scheme != Extensions.scheme else { continue }
            let tab = Tab(browser: self, configuration: makeConfiguration(for: saved.url))
            tab.restore(url: saved.url, title: saved.title)
            tab.customTitle = saved.customTitle
            tab.pinID = saved.pinID.flatMap { pinIDs.contains($0) ? $0 : nil }
            tabs.append(tab)
            extensions.didOpen(tab)
            restored[index] = tab
            if index == session.selectedIndex { selected = tab }
        }
        restoreSplits(session.splits, tabs: restored)
        if let selected {
            selectedTabID = selected.id
            extensions.didActivate(selected, previous: nil)
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

    // MARK: Favorites

    func activate(_ pin: Pin) {
        if let tab = liveTab(for: pin) {
            select(tab)
        } else {
            let tab = newTab(url: pin.url)
            tab.pinID = pin.id
        }
    }

    /// Without an index the favorite goes at the end of the grid; with one it takes that slot.
    /// A private tab can't be pinned: a favorite is saved, with its address and icon.
    func pin(_ tab: Tab, at index: Int? = nil) {
        guard tab.pinID == nil, !tab.isEphemeral, let url = tab.url else { return }
        let pin = Pin(id: UUID(), url: url, title: tab.displayTitle, favicon: tab.faviconData)
        pins.insert(pin, at: min(max(index ?? pins.count, 0), pins.count))
        leaveSplit(tab)
        tab.pinID = pin.id
        // The user's from now on: unpinned, it goes to the tab list.
        tab.openedByAgent = nil
        // Its name field was in the list, which no longer shows it.
        if renamingTabID == tab.id { renamingTabID = nil }
    }

    func pinTab(withID id: String, at index: Int? = nil) {
        if let tab = tabs.first(where: { $0.id.uuidString == id }) { pin(tab, at: index) }
    }

    /// Moves a favorite into the slot at `index`, the others shifting around it, as on a home screen.
    /// Built on a copy so `pins` is saved once, never without the moving favorite.
    func movePin(id: UUID, to index: Int) {
        guard let from = pins.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(index, 0), pins.count - 1)
        guard from != to else { return }
        var reordered = pins
        reordered.insert(reordered.remove(at: from), at: to)
        pins = reordered
    }

    func unpin(_ pin: Pin) {
        liveTab(for: pin)?.pinID = nil
        pins.removeAll { $0.id == pin.id }
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


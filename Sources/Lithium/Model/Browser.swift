import AppKit
import Observation
import WebKit

/// Window state. Every open page is a `Tab`; one whose `pinID` is set is a favorite's live page.
/// With no tab selected the window shows the start page, so empty tabs never pile up.
@MainActor
@Observable
final class Browser {
    private(set) var pins: [Pin] {
        didSet { if holdsPinSave { pinsUnsaved = true } else { savePins() } }
    }
    private(set) var tabs: [Tab] = []
    private(set) var selectedTabID: Tab.ID? {
        didSet {
            guard oldValue != selectedTabID else { return }
            videoPopout.selectionChanged(from: tabs.first { $0.id == oldValue }, to: selectedTab)
            // The summary popover is one tab's. Here, not in its button, which a hidden Zen bar lacks.
            if summaries.isPanelPresented { summaries.isPanelPresented = false }
        }
    }
    /// Empty until the user makes a second space (`Space`), then the main one first.
    private(set) var spaces: [Space] = []
    private(set) var currentSpaceID = Space.mainID
    @ObservationIgnored private var spaceSelections: [Space.ID: Tab.ID] = [:]
    @ObservationIgnored private(set) var spaceStores: [Space.ID: WKWebsiteDataStore] = [:]
    /// The last switch went to a space further along: the sidebar slides that way.
    @ObservationIgnored private(set) var spaceStepsForward = true
    /// Clearing a deleted space's store; awaited in tests.
    @ObservationIgnored private(set) var storeCleanup: Task<Void, Never>?
    /// The last session's session cookies going back in their stores (`SessionCookies`), nil once
    /// they are: pages wait for it, or they'd load signed out.
    @ObservationIgnored private(set) var cookieRestore: Task<Void, Never>?
    /// The same restore, without the bound pages have: saves wait for all of it, or a save would
    /// drop the cookies still going back.
    @ObservationIgnored private var cookieRestoreToEnd: Task<Void, Never>?
    /// Saves of the session cookies run one after another; the last, awaited in tests.
    @ObservationIgnored private(set) var cookieSave: Task<Void, Never>?
    /// A site's data being cleared (`clearData`), which a cookie save waits for.
    @ObservationIgnored private var dataClear: Task<Void, Never>?
    /// Clears whose cookie save hasn't rewritten the file yet.
    @ObservationIgnored private var runningClears = 0
    /// The sites those clears remove, by store: a restore past its bound skips them, and a quit
    /// that can't wait for the save drops them from the file.
    @ObservationIgnored private var clearedSites: [(store: Space.ID, site: String)] = []
    /// How often at most the session save also saves the session cookies; nil for none, as in
    /// tests, which save them themselves.
    @ObservationIgnored var cookieSaveInterval: Duration? = ExternalApps.runsTests ? nil : .seconds(60)
    @ObservationIgnored private var cookieSaveDue = ContinuousClock.now
    /// The save a session change too soon after the last one waits for.
    @ObservationIgnored private var nextCookieSave: Task<Void, Never>?
    private(set) var addressFocusToken = 0
    /// Moves only when the user picks a tab or the start page, so the peeked sidebar slides back on a
    /// pick yet stays out while tabs close or spaces switch in a row.
    private(set) var tabPickToken = 0
    /// Opens as the user last left it. Only `toggleSidebar()` saves, so a passing change such as
    /// the screenshot taking both looks never outlives the app.
    var isSidebarVisible = UserDefaults.standard.object(forKey: Preference.sidebarVisible) as? Bool ?? true
    /// Zen mode: the page alone, sidebar and top bar peeking from the edges. Kept apart from
    /// `isSidebarVisible`, so leaving it brings the sidebar back as it was.
    var isZenMode = UserDefaults.standard.bool(forKey: Preference.zenMode)
    var showsSidebar: Bool { isSidebarVisible && !isZenMode }
    /// Set by the address bar as it starts and ends editing: Zen mode's top bar stays out meanwhile.
    var isEditingAddress = false
    var renamingTabID: Tab.ID? {
        didSet { if renamingTabID != oldValue { renameDraft = nil } }
    }
    /// The name typed so far, for whichever field shows the rename next: ⌘B swaps the peeked
    /// sidebar's field for the sidebar's own.
    @ObservationIgnored var renameDraft: String?
    var developerTools = UserDefaults.standard.object(forKey: Preference.developerTools) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(developerTools, forKey: Preference.developerTools)
            // Quick Link windows' pages too: they are kept out of `tabs`.
            for case let webView? in (tabs + quickLinks.tabs).map(\.loadedWebView) { DeveloperTools.apply(developerTools, to: webView) }
        }
    }
    var canShowWebInspector: Bool { developerTools && commandTab != nil }

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
    @ObservationIgnored private(set) lazy var translator = PageTranslator(browser: self)
    @ObservationIgnored private var pinIcons: [Pin.ID: NSImage] = [:]
    /// A favorite's page can change its icon every few seconds (a timer, a progress ring): such
    /// changes write pins.json at most once a minute, the last one at the next write or at quit.
    @ObservationIgnored private var pinsSaved = Date.distantPast
    @ObservationIgnored private var pinsUnsaved = false
    @ObservationIgnored private var holdsPinSave = false
    private static let pinIconSaveInterval: TimeInterval = 60

    /// Present only while agent access is on, so with it off every agent hook is a nil check.
    private(set) var agent: AgentHub?

    @ObservationIgnored private(set) lazy var internalBridge = InternalBridge(browser: self)
    @ObservationIgnored private(set) lazy var colorPicker = PageColorPicker()
    @ObservationIgnored private var eventMonitors: [Any] = []
    /// The window the browser shows in, set as it appears: the Escape monitor only acts there.
    @ObservationIgnored weak var window: NSWindow?

    /// Something opened from a peeked panel (a rename, popover, alert, menu or drag) is still in
    /// use, so the panel stays out, as they would go with it.
    var holdsPeek: Bool {
        isRenaming || window.map(Self.hasOpenUI(in:)) == true
    }

    var isRenaming: Bool { renamingTabID != nil || folders.renamingID != nil }

    /// Popovers are the window's child windows and alerts its sheets; menus and drags run the
    /// event tracking loop until they end.
    static func hasOpenUI(in window: NSWindow) -> Bool {
        window.attachedSheet != nil || window.childWindows?.contains(where: \.isVisible) == true
            || RunLoop.main.currentMode == .eventTracking
    }
    private var closedTabs: [ClosedTab] = []
    // Cancelled in deinit, which runs outside the main actor; both are safe to cancel from anywhere.
    @ObservationIgnored nonisolated(unsafe) private var sleepLoop: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var memoryPressure: DispatchSourceMemoryPressure?
    /// As macOS last reported it: the source only speaks when the level changes.
    @ObservationIgnored private var memoryLevel: DispatchSource.MemoryPressureEvent = .normal
    @ObservationIgnored private var savedSession: Session?
    /// The file's, history included, when the last write was a quit's or the file was read at
    /// launch: `savedSession` leaves the history out, as saves before quitting do.
    @ObservationIgnored private var savedWithHistory: Session?
    /// The last one handed to a write off the main thread, which may not have ended.
    @ObservationIgnored private var queuedSession: Session?
    @ObservationIgnored private var sessionSave: Task<Void, Never>?
    /// The write of a change of titles alone, held for `titleSaveDelay`.
    @ObservationIgnored private var titleSave: Task<Void, Never>?
    /// A page that retitles itself (an unread count, a clock) rewrites the session this often at
    /// most: a title lost to a crash costs little, and quitting writes the last one. Other
    /// changes still go out a moment later. Shorter in tests.
    @ObservationIgnored var titleSaveDelay = Duration.seconds(30)
    @ObservationIgnored nonisolated(unsafe) private var dayChange: (center: NotificationCenter, observer: any NSObjectProtocol)?
    /// The icons of sleeping favorites fetched at the last change of day; awaited in tests.
    @ObservationIgnored private(set) var sleepingIconsRefresh: Task<Void, Never>?
    /// Restored favorites wake this far apart once the window is up, not all at once. Shorter in tests.
    @ObservationIgnored var favoriteWakeDelay = Duration.seconds(3)
    /// Started by the first `windowDidAppear`; awaited in tests.
    @ObservationIgnored private(set) var launchFavorites: Task<Void, Never>?
    @ObservationIgnored private var favoriteWake: Task<Void, Never>?

    struct ClosedTab {
        let url: URL
        let pinID: Pin.ID?
        let spaceID: Space.ID
        let customTitle: String?
        /// Its place in its folder, or among the tabs outside folders; nil for a favorite's page.
        let index: Int?
        let folderID: TabFolder.ID?
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

    /// `tabIdleInterval`, short while Lithium's energy saving is on too. Off is the user's choice
    /// over the Mac's: Low Power Mode or heat don't shorten it then.
    var idleInterval: TimeInterval { idleInterval(macSavesEnergy: Self.isSavingEnergy) }

    func idleInterval(macSavesEnergy: Bool) -> TimeInterval {
        Self.idleInterval(savingEnergy: energy.isOn || (energy.mode != .off && macSavesEnergy))
    }

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
        tidyTitles.browser = self
        extensions.start()
        // Tests leave extensions they add in place: they'd ask the store for them at each Browser.
        extensions.checksForUpdates = !ExternalApps.runsTests
        if extensions.checksForUpdates { Task { [extensions] in await extensions.updateIfDue() } }
        let saved = SessionStore.load()
        restore(saved)
        // After the spaces, whose stores get their own cookies back.
        if let restoring = SessionCookies.restore(into: { [weak self] id in id == Space.mainID ? .default() : self?.spaceStore(for: id) }, skipping: { [weak self] id, cookie in
            self?.clearedSites.contains { $0.store == id && $0.site == SiteInfo.site(ofCookieDomain: cookie.domain) } ?? false
        }) {
            cookieRestoreToEnd = restoring
            cookieRestore = Task { [weak self] in
                // Bounded like the quit: a stuck network process mustn't keep pages from ever loading.
                await restoring.wait(atMost: .seconds(5))
                self?.cookieRestore = nil
            }
        }
        // Written only when restoring changed it (a tab left out, a space gone), not at every launch.
        (savedSession, savedWithHistory) = (saved.withoutHistory, saved)
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

    /// Runs in one go on the main actor, so nothing changes a tab between its check and its sleep.
    /// A popup and its opener talk to each other: neither sleeps while both are open, unless memory is critical.
    private func sleepIdleTabs(idleFor interval: TimeInterval, sparingPopups: Bool, among candidates: (Tab) -> Bool = { _ in true }) {
        tabs.forEach { $0.noteSound() }
        for tab in tabsThatCanSleep(idleFor: interval, sparingPopups: sparingPopups, among: candidates) {
            tab.sleep(configuration: makeConfiguration(for: tab.url))
        }
    }

    private func tabsThatCanSleep(idleFor interval: TimeInterval, sparingPopups: Bool, among candidates: (Tab) -> Bool) -> [Tab] {
        let canSleep = sleepCheck(idleFor: interval, sparingPopups: sparingPopups)
        return tabs.filter { candidates($0) && canSleep($0) }
    }

    private func sleepCheck(idleFor interval: TimeInterval, sparingPopups: Bool) -> (Tab) -> Bool {
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
        // Unsaved input is spared for one more idle interval: typed on screen, it is never newer than the
        // tab's going idle, so `interval` alone would never spare it; an upload of files, while it runs.
        // "Sleep Other Tabs" (none) is the user's own choice.
        // A favorite's page is spared too: asleep, it can't update its unread badge, which would stay as it was.
        return { [self] tab in
            tab.id != selectedTabID && tab !== videoPopout.tab && tab !== partner
                && !paired.contains(ObjectIdentifier(tab)) && !(sparingPopups && agent?.holds(tab) == true)
                && !(sparingPopups && tab.hasUnsavedInput(within: 2 * interval))
                && !(sparingPopups && tab.pinID != nil)
                && tab.canSleep(idleFor: interval)
        }
    }

    private func watchMemoryPressure() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let event = self.memoryPressure?.data else { return }
                self.memoryLevelChanged(to: event)
            }
        }
        source.activate()
        memoryPressure = source
    }

    /// Back to normal, the favorites critical memory put to sleep wake again, or their badges
    /// would stay as they were. Internal for tests.
    func memoryLevelChanged(to event: DispatchSource.MemoryPressureEvent) {
        memoryLevel = event
        if event != .normal { sleepTabs() } else { wakeSleepingFavorites() }
    }

    /// Like Firefox's tab unloading: when memory runs low, tabs idle for 5 minutes sleep; when it
    /// is critical, every one that can.
    private func sleepTabs() {
        if memoryLevel.contains(.critical) {
            sleepIdleTabs(idleFor: 0, sparingPopups: false)
        } else if memoryLevel.contains(.warning) {
            sleepIdleTabs(idleFor: min(idleInterval, Self.shortIdleInterval), sparingPopups: true)
        } else {
            sleepIdleTabs(idleFor: idleInterval, sparingPopups: true)
        }
    }

    /// Links' windows follow too: made under it, they would keep it, even once in the main window.
    private func energyChanged() {
        for case let webView? in (tabs + quickLinks.tabs).map(\.loadedWebView) { BackgroundThrottling.apply(energy.isOn, to: webView) }
        guard energy.isOn else { return }
        sleepTabs()
        pauseSilentMedia()
    }

    /// While energy saving is on, a background tab's silent media pauses: WebKit keeps decoding a
    /// video out of the window. Tabs heard lately (between tracks) or muted by the user are spared.
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

    func sleepOtherTabs(than tab: Tab) {
        sleepIdleTabs(idleFor: 0, sparingPopups: true) { $0 !== tab && $0.isInTabList }
    }

    /// Stops at the first tab that can: the tab menu asks it each time it is built.
    func canSleepOtherTabs(than tab: Tab) -> Bool {
        let canSleep = sleepCheck(idleFor: 0, sparingPopups: true)
        return tabs.contains { $0 !== tab && $0.isInTabList && canSleep($0) }
    }

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

    /// `folder` holds the endpoint file and the log: a test gives its own, so another test's calls
    /// can't land in the log it reads.
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
        let (session, space) = (tab.privateSession, tab.siteSpace)
        guard session != nil || space != nil else { return setProtections(enabled, host: host, from: tab) }
        // A private tab's choice holds for its session only, a separate space's for that space.
        privacy.setEnabled(enabled, for: tab.url, privateSession: session, space: space)
        reloadForProtections(pages.filter { $0.privateSession == session && $0.siteSpace == space && Privacy.siteHost($0.url) == host }, from: tab)
    }

    /// Reloads every open page of the site, so their content blockers and scripts match.
    func setProtections(_ enabled: Bool, host: String, from tab: Tab? = nil) {
        privacy.setEnabled(enabled, host: host)
        reloadForProtections(pages.filter { Privacy.siteHost($0.url) == host }, from: tab)
    }

    /// A reload would lose what another page holds (a draft, an upload), and nothing asks first, not
    /// even once it is shown again: that page keeps its document and gets the new protections on its
    /// next load. The page the change was made from reloads at once.
    private func reloadForProtections(_ pages: [Tab], from tab: Tab?) {
        for page in pages where !page.isAsleep && (page === tab || !page.hasUnsavedInput(within: .infinity)) {
            navigate(page, .reload)
        }
    }

    private var pages: [Tab] { tabs + quickLinks.tabs }

    /// Applies a font setting to open pages without a reload; sleeping tabs get it when they wake.
    func changePageFont(_ change: () -> Void) {
        let font = { (tab: Tab, url: URL) in
            PageStyle.usesPageFont(url, privateSession: tab.privateSession, space: tab.siteSpace) ? PageStyle.websiteFamily : nil
        }
        // Links' windows too, like `setProtections`.
        let pages = self.pages.compactMap { tab -> (Tab, URL, String?)? in
            guard !tab.isAsleep, let url = tab.url, !Internal.isInternal(url) else { return nil }
            return (tab, url, font(tab, url))
        }
        change()
        for (tab, url, used) in pages {
            let family = font(tab, url)
            guard family != used, let webView = tab.loadedWebView else { continue }
            let source = family == nil ? PageStyle.fontOffSource : PageStyle.fontScript.source
            webView.evaluateJavaScript(source, in: nil, in: .defaultClient)
        }
    }

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
        if launchFavorites == nil { wakeRestoredFavorites() }
    }

    /// A favorite's notification that came while the window wasn't key put a dot on its tile; the
    /// user is now looking at that page.
    func windowDidBecomeKey() {
        quickLinks.mainWindowBecameKey()
        selectedTab?.didOpen()
    }

    /// Restored asleep, a favorite's page counts nothing until clicked: each wakes, unselected, a
    /// few seconds apart, and idle sleep spares it after. Then the favorites still without a page
    /// fetch their icon, as at a change of day: the date may have changed since the last session.
    private func wakeRestoredFavorites() {
        wakeSleepingFavorites()
        launchFavorites = Task { [weak self, wake = favoriteWake, delay = favoriteWakeDelay] in
            await wake?.value
            try? await Task.sleep(for: delay)
            self?.refreshSleepingPinIcons()
        }
    }

    /// Also once memory is back to normal and after a favorite's page crashed out of sight. One
    /// pass at a time, which picks up a favorite put to sleep meanwhile but wakes each once, so a
    /// page that keeps crashing can't keep it going; it stops while memory is short, and the next
    /// normal level starts it again.
    func wakeSleepingFavorites() {
        guard favoriteWake == nil, tabs.contains(where: { $0.pinID != nil && $0.isAsleep }) else { return }
        favoriteWake = Task { [weak self, delay = favoriteWakeDelay] in
            var woken: Set<ObjectIdentifier> = []
            await self?.cookieRestore?.value
            while true {
                try? await Task.sleep(for: delay)
                guard let self, memoryLevel == .normal, let tab = tabs.first(where: {
                    $0.pinID != nil && $0.isAsleep && $0.url != nil && !woken.contains(ObjectIdentifier($0))
                }) else { break }
                woken.insert(ObjectIdentifier(tab))
                tab.wakeIfAsleep()
            }
            self?.favoriteWake = nil
        }
    }

    /// Installed once the window exists: a monitor added before NSApplication finishes launching is dropped.
    private func installEventMonitors() {
        guard eventMonitors.isEmpty else { return }
        // Escape is caught before any text field sees it, since a focused field editor swallows it.
        let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if Self.isZoomInWithoutShift(event), let self {
                return MainActor.assumeIsolated {
                    guard !NativeInput.isAgents(event), self.ownsZoomIn(in: event.window) else { return false }
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
        // Clicking the sidebar or toolbar background would otherwise leave a text field editing.
        let click = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.endEditingIfOutside(event)
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

    /// A link's window too: the menu's ⌘+ never sees a plain ⌘=, wherever it is pressed.
    func ownsZoomIn(in window: NSWindow?) -> Bool {
        guard let window, window === self.window || window === quickLinks.keyWindow else { return false }
        return commandTab != nil
    }

    func zoomSelectedTab(by delta: Double) {
        guard let tab = commandTab else { return }
        if let pdf = tab.pdf {
            if delta > 0 { pdf.zoomIn() } else { pdf.zoomOut() }
            return
        }
        let webView = tab.webView
        webView.pageZoom = PageZoom.stepped(webView.pageZoom, by: delta)
    }

    /// Ends text editing when a click lands outside the field being edited; the field commits on its own.
    /// The address bar hands the keyboard back to the page, as Return does: left on the window, keys beep.
    func endEditingIfOutside(_ event: NSEvent) {
        guard let window = event.window,
              let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSView, field.window === window else { return }
        // A little slack around the field: its rounded background is larger than the text itself.
        let point = field.convert(event.locationInWindow, from: nil)
        guard !field.bounds.insetBy(dx: -10, dy: -8).contains(point) else { return }
        window.makeFirstResponder(nil)
        if field is URLTextField { returnKeyboardToPage(fieldHadKeyboard: true) }
    }

    /// Not in another window or under a sheet, and not while a text field edits (the address bar
    /// ends its editing itself), unless it is the find field or a tab's name, which Escape closes.
    func ownsEscape(in window: NSWindow?) -> Bool {
        guard let window, window.attachedSheet == nil else { return false }
        // A link's window has only the find bar to close.
        if window !== self.window { return window === quickLinks.keyWindow && findBarIsInFront }
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return true }
        return find.isFieldFocused || isRenaming
    }

    func dismissOverlay() -> Bool {
        // A link's window has only its find bar: a tab's name editing in the main window stays.
        if quickLinks.keyTab != nil { return closeFindBar() }
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
        if closeFindBar() { return true }
        // Opened with ⇧⌘S, the popover never takes the keyboard, so Escape reaches the window.
        if summaries.isPanelPresented {
            summaries.isPanelPresented = false
            return true
        }
        // The shown permission prompt, denied this once and not remembered. Not under an agent's
        // banner, whose Deny Escape triggers.
        if agent?.confirmations.front(selected: selectedTabID) == nil,
           let request = shownPermissionRequest {
            permissions.dismiss(request)
            return true
        }
        if agent?.confirmations.front(selected: selectedTabID) == nil,
           let request = shownAppLinkRequest {
            appLinks.answer(request, open: false)
            return true
        }
        return false
    }

    /// Hands the keyboard back to the page once a field of Lithium's own closes: left on the
    /// window, keys beep. Unless that field had it, a field still editing keeps it.
    func returnKeyboardToPage(fieldHadKeyboard: Bool) {
        guard let page = commandTab?.contentView, let window = page.window else { return }
        if fieldHadKeyboard { window.makeFirstResponder(page) } else { focusPage(page) }
    }

    /// Not while the page has the keyboard: the Escape is the page's, and the bar stays open.
    private func closeFindBar() -> Bool {
        guard findBarIsInFront, !(commandTab?.contentView.window?.firstResponder is WKWebView) else { return false }
        let hadKeyboard = find.isFieldFocused
        find.hide()
        returnKeyboardToPage(fieldHadKeyboard: hadKeyboard)
        return true
    }

    /// Acts on the window in front (`commandTab`): ⌘F in a link's window moves the bar from the main one.
    func toggleFind() {
        if findBarIsInFront {
            find.hide()
            returnKeyboardToPage(fieldHadKeyboard: true)
        } else if commandTab != nil {
            find.show(inLink: quickLinks.keyTab)
        }
    }

    func findStep(forward: Bool) async {
        guard let tab = commandTab else { return }
        find.show(focusingField: false, inLink: quickLinks.keyTab)
        await find.step(forward: forward, in: tab.findTarget)
    }

    /// The window the bar was opened in keeps it while another is in front, so going back to it
    /// doesn't search again or take the keyboard.
    func showsFindBar(over tab: Tab) -> Bool {
        find.isVisible && (find.linkTab ?? selectedTab) === tab
    }

    var findBarIsInFront: Bool { commandTab.map(showsFindBar(over:)) ?? false }

    /// In Zen mode, asking for the sidebar back takes the window out of Zen mode.
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
    /// The page the menu's page commands (Reload, Back, Print…) act on.
    var commandTab: Tab? { quickLinks.keyTab ?? selectedTab }
    /// The Tabs menu's selection and tab-list commands act on the main window: not while a link's
    /// window is in front, where they would wake and switch tabs out of sight.
    var canChangeTabs: Bool { quickLinks.keyTab == nil }

    /// Settings, History and Reopen Closed Tab from the menu: they open or select a tab in the main
    /// window, which comes forward first from a link's window or the Dock, or that tab would change
    /// out of sight. A closed main window opens again (`open`).
    func inMainWindow(open: () -> Void, _ command: () -> Void) {
        if let window, window.isVisible || window.isMiniaturized {
            if window.isMiniaturized || !canChangeTabs {
                // Ordering front alone leaves a minimized window in the Dock.
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
            }
        } else {
            open()
        }
        command()
    }
    /// The tab list of the space shown. Tabs an agent opened sit apart, in the Agent group below it.
    var regularTabs: [Tab] { tabList(in: currentSpaceID) }
    var agentTabs: [Tab] { agentGroup(in: currentSpaceID) }
    /// The group a tab's bulk actions (Close Other Tabs, Close Tabs Below) stay within.
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

    /// `opener` is the tab whose page opened this one (a link, ⌘-click or `window.open`).
    @discardableResult
    func newTab(url: URL? = nil, selecting: Bool = true, configuration: WKWebViewConfiguration? = nil, privateStore: WKWebsiteDataStore? = nil, openedFrom opener: Tab? = nil, space: Space.ID? = nil) -> Tab {
        let tab = insertTab(at: 0, configuration: configuration ?? makeConfiguration(for: url), privateStore: privateStore, space: space ?? opener?.spaceID ?? currentSpaceID)
        if let opener { recentTabs.didOpen(tab, from: opener) } else if selecting { recentTabs.didOpen(tab, replacing: selectedTab) }
        if let url { tab.load(url) }
        if selecting { select(tab) }
        return tab
    }

    /// A link from another app: in a small window of its own when Settings says so, else a new tab.
    /// A link that launched Lithium waits for the restored cookies, like the restored tabs.
    func openFromOtherApp(_ url: URL) {
        if let cookieRestore {
            Task { [weak self] in
                await cookieRestore.value
                self?.openFromOtherApp(url)
            }
            return
        }
        if quickLinks.isEnabled, QuickLinks.takes(url) { quickLinks.open(url) } else { newTab(url: url) }
    }

    func adopt(_ tab: Tab) {
        tabs.insert(tab, at: Self.position(inTabList: 0, of: tabs, space: tab.spaceID))
        extensions.didOpen(tab)
        select(tab)
    }

    /// `index` is a place in the space's tab list (in `folder`, or outside folders), clamped to it.
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
    /// stay as they were.
    func newAgentTab(session: String, configuration: WKWebViewConfiguration? = nil, privateStore: WKWebsiteDataStore? = nil, space: Space.ID? = nil) -> Tab {
        let tab = Tab(browser: self, configuration: configuration ?? makeConfiguration(), privateStore: privateStore, space: space ?? currentSpaceID)
        tab.openedByAgent = session
        tabs.append(tab)
        extensions.didOpen(tab)
        return tab
    }

    /// Moved by the user into the tab list, a tab the agent opened becomes theirs.
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

    /// The tab list outside folders has no drag order of its own: a tab already there stays, as
    /// one dropped among the Agent group does.
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

    /// Into a folder of its space, or out of folders with nil. A split's other side comes along,
    /// so the pair stays one row.
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

    /// Its tabs close, or stay at the top of the tabs outside folders, where the folder was.
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
            // In list order: with the folder gone, each reopens at the top of the list, so the
            // last closed coming back first puts them back in their order.
            members.forEach(close)
        } else if !members.isEmpty {
            place(members, inFolder: nil, before: tabList(in: members[0].spaceID, folder: nil).first)
        }
        removeFolder(id)
    }

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
        // A link's window keeps its bar.
        if find.linkTab == nil { find.hide() }
        // Left for the address bar: it counts as used until now, as does the other side of its split.
        selectedTab?.markActive()
        shownPartner?.markActive()
        if picked, selectedTabID != nil { tabPickToken &+= 1 }
        selectedTabID = nil
    }

    func open(_ input: String) {
        open(input, in: selectedTab)
    }

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

    /// Every navigation the user asks of an open tab: it wins over an agent waiting on that tab.
    /// What Lithium or an extension does on its own doesn't come here.
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
        // A space keeping its cookies apart is kept out of the others' suggestions, and they out of
        // its: their titles and addresses are another identity's.
        let (current, apart) = (currentSpaceID, Set(spaces.filter(\.separatesData).map(\.id)))
        let shown = { (space: Space.ID) in space == current || !apart.contains(space) && !apart.contains(current) }
        suggestions.update(query: text, tabs: tabs.filter { shown($0.spaceID) }, pins: pins.filter { shown($0.space) }, history: history, actions: barActions(for: edited))
    }

    func submitAddress(_ text: String) {
        submitAddress(text, editing: selectedTabID)
    }

    /// Goes to `tabID`, the tab shown when editing began, even if the selection moved on its own
    /// since; to a new tab once that one is gone.
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
            if find.linkTab == nil { find.hide() }
            previous?.markActive()
            // Leaving the screen too, and no view says so: its idle time starts now.
            shownPartner?.markActive()
            recentTabs.didShow(tab, after: previous)
        }
        if tab.spaceID != currentSpaceID, spaces.contains(where: { $0.id == tab.spaceID }) { enterSpace(tab.spaceID) }
        selectedTabID = tab.id
        tab.markActive()
        // In split view the other side comes on screen too, maybe from another split: its pane
        // is reused, so it doesn't wake as it appears.
        shownPartner?.markActive()
        extensions.didSelect(tab)
    }

    /// A split's sidebar row: the pair already shown keeps its focused side, as ⌘1…⌘9 does.
    func selectSplit(showing first: Tab) {
        if let selectedTab, split(of: first)?.contains(selectedTab.id) == true { return select(selectedTab) }
        select(first)
    }

    /// The selection falls back on the tab's group, never on a favorite. A tab the user went to
    /// straight from its opener, and left for no other, goes back to its opener instead.
    func close(_ tab: Tab) {
        close(tab, remembering: true)
    }

    /// `remembering` false keeps the tab out of Reopen Closed Tab: a tab that closed itself once
    /// its address became a download would only start the download again. `goingBack` shows again
    /// what such a tab was opened over, rather than its neighbour, which may be asleep and unrelated.
    func close(_ tab: Tab, remembering: Bool, goingBack: Bool = false) {
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
        let partner = leaveSplit(tab)
        let wasSelected = tab.id == selectedTabID
        if wasSelected {
            // As `select` does: left open, the bar would search the tab shown next. A link's window keeps its bar.
            if find.linkTab == nil { find.hide() }
            let position = order.firstIndex { $0 === tab } ?? 0
            let remaining = order.filter { $0 !== tab }
            let opener = recentTabs.opener(returningFrom: tab).flatMap { opener in tabs.contains { $0 === opener } ? opener : nil }
            if partner == nil, goingBack, let before = recentTabs.shownBefore(tab),
               before.map({ id in tabs.contains { $0.id == id && $0 !== tab && $0.spaceID == tab.spaceID } }) ?? true {
                selectedTabID = before
            } else {
                selectedTabID = partner?.id ?? opener?.id ?? (remaining.isEmpty ? (tab.isInAgentGroup ? tabList(in: tab.spaceID).last?.id : nil)
                    : remaining[min(position, remaining.count - 1)].id)
            }
            // The tab shown next may be asleep. As `select` does, the user now sees its page: a
            // favorite's dot left by a notification while its popup was in front goes. Not while the
            // window isn't key: `windowDidBecomeKey` clears it when the user looks.
            selectedTab?.markActive()
            if window?.isKeyWindow != false { selectedTab?.didOpen() }
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

    /// Once a private store's last tab is gone, its data goes at once, not whenever WebKit frees it.
    private func dropPrivateData(of tab: Tab) {
        guard let store = tab.privateStore, !tabs.contains(where: { $0.privateStore === store }) else { return }
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        permissions.forget(privateSession: ObjectIdentifier(store))
        privacy.forget(privateSession: ObjectIdentifier(store))
        PageStyle.forget(privateSession: ObjectIdentifier(store))
        translator.forget(privateSession: ObjectIdentifier(store))
    }

    func closeSelectedTab() {
        if let tab = selectedTab { close(tab) }
    }

    /// ⌘W closes the selected tab only when the browser's window is key; another window closes
    /// instead. A full-screen video is in WebKit's own window, which counts as the tab's.
    func closeTabOrWindow(keyWindow: NSWindow? = NSApp.keyWindow) {
        guard let keyWindow else { return }
        let page = selectedTab?.loadedWebView
        let isTabs = keyWindow === page?.window || page.map { $0.fullscreenState != .notInFullscreen } == true
        // Before the browser's window is known, it is the one in front.
        if window == nil || keyWindow === window || isTabs { closeSelectedTab() } else { keyWindow.performClose(nil) }
    }

    /// The others of its group; favorites' pages stay, as Chrome keeps pinned tabs. Tabs close
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
        let folder = closed.folderID.flatMap { folderExists($0, in: closed.spaceID) ? $0 : nil }
        let index = pin != nil || closed.folderID != folder ? 0 : closed.index ?? 0
        let tab = insertTab(at: index, configuration: makeConfiguration(for: closed.url), space: closed.spaceID, folder: pin == nil ? folder : nil)
        extensions.moving(tab) { tab.pinID = pin?.id }
        tab.customTitle = closed.customTitle
        tab.load(closed.url, history: closed.history)
        select(tab)
    }

    /// Just below the original, with its history and name. The copy is never a favorite, nor an agent's.
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

    func copyLinks(of tabs: [Tab]) {
        let links = Self.links(of: tabs)
        guard !links.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(links, forType: .string)
    }

    static func links(of tabs: [Tab]) -> String {
        tabs.compactMap { $0.url?.absoluteString }.joined(separator: "\n")
    }

    /// A tab without a name of its own keeps none when left with the title its field `shown`:
    /// that would freeze the page's title on it.
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

    /// The menu's New Tab and Open Location: the address field is the main window's, which comes
    /// forward first, or from a link's window the keys typed next would go on to the link's page.
    func focusAddressFromMenu(newTab: Bool) {
        window?.makeKeyAndOrderFront(nil)
        if newTab { newTabFocusingAddress() } else { requestAddressFocus() }
    }

    /// The sidebar's order, top to bottom, space after space. Extensions and agents see every space.
    var navigationOrder: [Tab] {
        spaces.isEmpty ? navigationOrder(in: Space.mainID) : spaces.flatMap { navigationOrder(in: $0.id) }
    }

    func selectAdjacentTab(_ offset: Int) {
        let order = navigationOrder(in: currentSpaceID)
        guard !order.isEmpty else { return }
        guard let current = order.firstIndex(where: { $0.id == selectedTabID }) else {
            select(offset > 0 ? order[0] : order[order.count - 1])
            return
        }
        select(order[(current + offset + order.count) % order.count])
    }

    /// Through the tabs in the order last shown while Control is held; without it (the menu
    /// clicked), one step and done.
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

    /// ⌘1…⌘9 walk the favorites grid, then the rows as the sidebar shows them: a split pair is
    /// one row. Folder headers and the tabs of a collapsed folder have none.
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

    /// `quitting` adds the tabs' back and forward pages, left out of other saves: WebKit serializes a
    /// loaded tab's on the main thread, and every save would rewrite each sleeping tab's.
    private func session(quitting: Bool) -> Session {
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
                                            spaceID: Space.saved(tab.spaceID), lastShown: lastShown ? true : nil, folderID: tab.folderID,
                                            history: quitting ? tab.history as? Data : nil))
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
            // Its configuration is made as it wakes: most restored tabs stay asleep for a while.
            let tab = Tab(browser: self, configuration: nil, space: space)
            tab.restore(url: saved.url, title: saved.title, history: saved.history)
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

    /// A favorite of a space no longer saved goes back to the main space rather than vanish.
    private func restoreSpaces(_ session: Session) {
        if let saved = session.spaces, !saved.isEmpty {
            let main = saved.first { $0.id == Space.mainID } ?? .main
            // An edited file's spaces past `Space.limit` are left out; their tabs go to the main space.
            spaces = Array(([main] + saved.filter { $0.id != Space.mainID }).prefix(Space.limit))
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

    /// Writes the session now, and again a moment after it changes, or `titleSaveDelay` after
    /// when only titles changed. Encoded and written off the main thread, except `now`
    /// (quitting), which waits for it.
    private func saveSession(now: Bool = false, titlesDue: Bool = false) {
        sessionSave?.cancel()
        sessionSave = nil
        let session = withObservationTracking { self.session(quitting: false) } onChange: { [weak self] in
            Task { @MainActor in self?.sessionChanged() }
        }
        // A failed write leaves the old file: the next save tries again rather than taking it as written.
        // Compared with the last session handed to the queue: one still being written would
        // otherwise land after a change back to the saved one, and stay.
        if now {
            titleSave?.cancel()
            titleSave = nil
            // Kept as written without the history, which later saves leave out.
            let quitting = self.session(quitting: true)
            guard session != savedSession || queuedSession != session || quitting != (savedWithHistory ?? session) else { return }
            if SessionStore.save(quitting) { (savedSession, queuedSession, savedWithHistory) = (session, session, quitting) }
            return
        }
        let written = queuedSession ?? savedSession
        guard session != written else { return }
        if !titlesDue, let written, session.differsOnlyInTitles(from: written) {
            guard titleSave == nil else { return }
            titleSave = Task { [weak self, titleSaveDelay] in
                try? await Task.sleep(for: titleSaveDelay)
                guard !Task.isCancelled else { return }
                self?.titleSave = nil
                self?.saveSession(titlesDue: true)
            }
            return
        }
        titleSave?.cancel()
        titleSave = nil
        queuedSession = session
        savedWithHistory = nil
        saveSessionCookiesIfDue()
        SessionStore.saveInBackground(session) { [weak self] written in
            guard let self else { return }
            if written {
                savedSession = session
            } else if queuedSession == session {
                queuedSession = nil
            }
        }
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

    func saveNow() {
        saveSession(now: true)
        history.writeTitles()
        if pinsUnsaved { savePins() }
    }

    /// At quit, with the session and after a clear. Private tabs' stores are never saved; a deleted
    /// space's store is no longer here. One after another, each after a clear under way: one that
    /// read the stores before it would otherwise write the cleared cookies back. `replacing`, after a
    /// clear: only over a file there is, which would otherwise keep what was cleared.
    func saveSessionCookies(replacing: Bool = false) async {
        let save = Task { [weak self, previous = cookieSave] in
            await previous?.value
            guard let self else { return }
            // A save as Lithium opens: the last session's cookies are still going back.
            await cookieRestoreToEnd?.value
            await dataClear?.value
            guard !replacing || FileManager.default.fileExists(atPath: SessionCookies.fileURL.path) else { return }
            // Only the stores in use: one a space hasn't opened this session holds no session cookies.
            var stores = spaceStores
            stores[Space.mainID] = .default()
            await SessionCookies.save(stores)
        }
        cookieSave = save
        await save.value
    }

    /// With the session, so a crash loses only the cookies since; not more often than
    /// `cookieSaveInterval`, as each save reads every cookie of the stores in use. A change too
    /// soon is saved once that time comes, or a sign-in followed by no change would never be.
    private func saveSessionCookiesIfDue() {
        guard let cookieSaveInterval, nextCookieSave == nil else { return }
        let due = max(cookieSaveDue, .now)
        cookieSaveDue = due + cookieSaveInterval
        nextCookieSave = Task { [weak self] in
            try? await Task.sleep(until: due)
            // Not queued behind a restore held up (a Keychain prompt): the one save reads the
            // stores once it is back, so it covers every change meanwhile.
            await self?.cookieRestoreToEnd?.value
            self?.nextCookieSave = nil
            await self?.saveSessionCookies()
        }
    }

    /// The site panel's and Settings' clear, through here so a cookie save waits for it. After the
    /// restored cookies are back, or they'd land after it, but no longer than pages wait: a
    /// restore held up past that skips the cleared sites. Then the saved ones go too.
    @discardableResult
    func clearData(_ infos: [SiteInfo]) -> Task<Void, Never> {
        // Shown at once, though the clear may wait for another or for the restore.
        infos.forEach { $0.willClear() }
        runningClears += 1
        // Private stores are never saved: only the default store and the spaces' (by identifier).
        clearedSites += infos.compactMap { info in
            (info.store.identifier ?? (info.store.isPersistent ? Space.mainID : nil)).map { ($0, info.site) }
        }
        let clear = Task { [cookieRestore, previous = dataClear] in
            await previous?.value
            await cookieRestore?.value
            for info in infos {
                await info.load()
                await info.clear()
            }
        }
        dataClear = clear
        return Task { [weak self] in
            await clear.value
            await self?.saveSessionCookies(replacing: true)
            guard let self else { return }
            runningClears -= 1
            if runningClears == 0 { clearedSites = [] }
        }
    }

    /// A quit that stopped waiting for its cookie save. During a clear, the file may still hold
    /// what it clears, which the next launch would put back: those sites go, as clearing wins.
    func cookieSaveCutShort() {
        if !clearedSites.isEmpty { SessionCookies.drop(clearedSites) }
    }

    /// Also the closed tabs ⇧⌘T would bring back, with their back and forward lists, and the open
    /// tabs' lists, which the session saves at quit. Quick Links' too: moved in, they become tabs.
    func clearHistory() async {
        // Before the clears below, which can take seconds: a quit meanwhile saves the session as is.
        closedTabs.removeAll()
        pages.filter { !$0.isEphemeral }.forEach { $0.forgetHistory() }
        // The file keeps the lists the last quit wrote until the session is written again, which
        // a crash or force quit may never get to. Even after a save without them: it may have failed.
        saveSession(now: true)
        await history.clear()
        await clearIcons()
        // Again for a tab closed, or put to sleep and woken, meanwhile. The quit save above already leaves lists out.
        closedTabs.removeAll()
        pages.filter { !$0.isEphemeral }.forEach { $0.forgetHistory() }
    }

    /// A private tab's host doesn't count: keeping its icon would keep an earlier visit.
    func clearIcons() async {
        let hosts = pins.map(\.url) + tabs.filter { !$0.isEphemeral }.compactMap(\.url)
        await favicons.clear(keeping: Set(hosts.compactMap { $0.host() }))
    }

    // MARK: Spaces

    var siteDataStores: [WKWebsiteDataStore] {
        [.default()] + spaces.filter(\.separatesData).compactMap { spaceStore(for: $0.id) }
    }

    /// Nil for the main space and those sharing its data, whose tabs use the default store.
    func spaceStore(for id: Space.ID) -> WKWebsiteDataStore? {
        guard id != Space.mainID, spaces.contains(where: { $0.id == id && $0.separatesData }) else { return nil }
        if let store = spaceStores[id] { return store }
        let store = WKWebsiteDataStore(forIdentifier: id)
        spaceStores[id] = store
        return store
    }

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

    func updateSpace(_ space: Space) {
        guard let index = spaces.firstIndex(where: { $0.id == space.id }) else { return }
        var updated = space
        updated.name = Space.trimmedName(space.name, fallback: spaces[index].name)
        updated.separatesData = spaces[index].separatesData
        if updated != spaces[index] { spaces[index] = updated }
    }

    /// An edit in the address bar or a tab's name ends first: its field would be left editing a
    /// tab no longer shown. Not a pick (`tabPickToken`).
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
        if space.separatesData {
            removeStore(of: id)
            // Its site choices were that store's.
            permissions.forget(space: id)
            privacy.forget(space: id)
            PageStyle.forget(space: id)
        }
    }

    /// Its data goes at once; its folder only once WebKit lets go, which it refuses while a web
    /// view of the store lives. One still held goes when the next space with its own data is made.
    private func removeStore(of id: Space.ID) {
        let store = spaceStores.removeValue(forKey: id) ?? WKWebsiteDataStore(forIdentifier: id)
        storeCleanup = Task { [cookieRestore] in
            // Its restored cookies would otherwise land after; a restore held up past the bound
            // finds no store for the deleted space (`spaceStore(for:)`).
            await cookieRestore?.value
            await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            await removeUnusedStores()
            // Its saved ones go too.
            await saveSessionCookies(replacing: true)
        }
    }

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

    /// A private tab can't be pinned: a favorite is saved, with its address and icon.
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

    /// `index` is a slot of the favorite's own space's grid. Built on a copy so `pins` is saved
    /// once, never without the moving favorite.
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

    /// Only an http(s) `url` is kept: a `data:` icon the page redraws would otherwise rewrite the
    /// favorites at each new address, pixels unchanged.
    private func storeIcon(_ data: Data, from url: URL?, inPinAt index: Int) {
        var pin = pins[index]
        pin.favicon = data
        if let url { pin.iconURL = ["http", "https"].contains(url.scheme?.lowercased()) ? url : nil }
        guard pin != pins[index] else { return }
        if pin.favicon != pins[index].favicon { pinIcons[pin.id] = nil }
        holdsPinSave = Date().timeIntervalSince(pinsSaved) < Self.pinIconSaveInterval
        pins[index] = pin
        holdsPinSave = false
    }

    private func savePins() {
        PinStore.save(pins)
        pinsSaved = Date()
        pinsUnsaved = false
    }

    func savedIconURL(of tab: Tab) -> URL? {
        guard let pin = pins.first(where: { $0.id == tab.pinID }), pin.url.host() == tab.url?.host(),
              let url = pin.iconURL, ["http", "https"].contains(url.scheme?.lowercased()) else { return nil }
        return url
    }

    /// A fetch that outlasts the page's site, the pin or the icon isn't theirs; nor one named just
    /// before the page's count came in, likely the copy with the count drawn in.
    func refreshIcon(of tab: Tab, from url: URL) async {
        guard let pinID = tab.pinID, let host = tab.url?.host(),
              let data = await favicons.refresh(host: host, from: url, keeping: { tab.unread.shown == nil }),
              tab.pinID == pinID, tab.url?.host() == host, tab.liveIcon == url, tab.unread.shown == nil else { return }
        tab.showFavicon(data)
        if let index = pins.firstIndex(where: { $0.id == pinID }), pins[index].url.host() == host {
            storeIcon(data, from: url, inPinAt: index)
        }
    }

    /// A sleeping tab runs no script, so at each new day the icon its page last named is fetched
    /// once more for each favorite asleep or without a page; it stays asleep.
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


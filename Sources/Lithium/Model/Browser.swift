import AppKit
import Observation
import WebKit

/// App state shared by every window; `BrowserWindow` is one window's. Every open page is a `Tab`,
/// listed in the sidebar of its window (`Tab.windowID`); one whose `pinID` is set is a favorite's
/// live page in that window. Favorites are shared, their pages are not: each window opens its own,
/// with the same cookies. With no tab selected a window shows the start page, so empty tabs never pile up.
@MainActor
@Observable
final class Browser {
    private(set) var pins: [Pin] {
        didSet { if holdsPinSave { pinsUnsaved = true } else { savePins() } }
    }
    private(set) var tabs: [Tab] = []
    /// Every browser window, in the order opened. Never empty after `init`: the session's windows,
    /// or one new window. The last window closed stays here, hidden (`BrowserWindow.isHidden`).
    private(set) var windows: [BrowserWindow] = []
    /// The browser window last in front; nil until one is, and once the last one closed. A sheet
    /// or a popover taking the key from it leaves it, as the window is still the one in front.
    private(set) var keyWindow: BrowserWindow?
    /// The browser window the user was last in, for a Dock click. Unlike `keyWindow`, a window
    /// minimized stays it while AppKit hands the key to another in its place.
    @ObservationIgnored private(set) var lastActiveWindowID: BrowserWindow.ID?
    @ObservationIgnored private var isMinimizingWindow = false
    /// Puts a window on screen. Tests open none.
    @ObservationIgnored var showWindow: @MainActor (BrowserWindow, Browser) -> NSWindow? = Browser.openOnScreen
    /// Empty until the user makes a second space (`Space`), then the main one first.
    private(set) var spaces: [Space] = []
    @ObservationIgnored private(set) var spaceStores: [Space.ID: WKWebsiteDataStore] = [:]
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
    let permissions = SitePermissions()
    let appLinks = AppLinks()
    let tidyTitles = TidyTitles()
    let summaries = PageSummaries()
    let extensions = Extensions()
    let nowPlaying = NowPlaying()
    let pinnedPages = PinnedPages()
    let splits = TabSplits()
    let folders = TabFolders()
    let quickLinks = QuickLinks()
    let energy = EnergySaver()
    let favicons: Favicons
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
    @ObservationIgnored private(set) lazy var passwords = PasswordManager()
    @ObservationIgnored private var eventMonitors: [Any] = []
    /// Marks the Escapes passed on, on the event itself: WebKit sends one the page didn't handle
    /// back through `NSApp.sendEvent`, maybe after the next press, and the prompts may take it then.
    private static let passedOnKey = UnsafeRawPointer(UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1))

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
    @ObservationIgnored private var refreshedIconsAtLaunch = false

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
    /// How many closed tabs ⇧⌘T keeps: the limit, plus the tabs of the window closed last, so a big
    /// window loses none of them, nor what was closed before it.
    @ObservationIgnored private var closedTabsKept = closedTabsLimit

    /// `notifications` posts the change of day (`NSCalendarDayChanged`); tests post it themselves.
    init(favicons: Favicons = .shared, notifications: NotificationCenter = .default) {
        self.favicons = favicons
        pins = PinStore.load()
        privacy.start()
        extensions.browser = self
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
        // A tab an agent is working in is spared like a popup, or its next action would find a reloaded page.
        // Unsaved input is spared for one more idle interval: typed on screen, it is never newer than the
        // tab's going idle, so `interval` alone would never spare it; an upload of files, while it runs.
        // "Sleep Other Tabs" (none) is the user's own choice.
        return { [self] tab in
            !isShown(tab) && !isPoppedOut(tab)
                && !paired.contains(ObjectIdentifier(tab)) && !(sparingPopups && agent?.holds(tab) == true)
                && !(sparingPopups && tab.hasUnsavedInput(within: 2 * interval))
                && tab.canSleep(idleFor: interval)
        }
    }

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

    /// The ⋯ menu's and the address bar's quick switch: Settings' Always or Off, since a switch
    /// flipped by hand shouldn't then wait on the power source. An open Settings page renders the
    /// mode only when it is shown, and may be on screen now, so it is told.
    func turnEnergySaving(on: Bool) {
        energy.mode = on ? .always : .off
        for tab in tabs where Internal.isInternal(tab.url) && tab.url?.host() == Internal.settingsURL.host() {
            tab.loadedWebView?.evaluateJavaScript("call('state').then(render)", in: nil, in: .page)
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
        for tab in tabs where !tab.isAsleep && !isShown(tab) && !isPoppedOut(tab)
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

    func openSettings(section: String? = nil, in window: BrowserWindow? = nil) {
        openInternal(section.flatMap { URL(string: "\(Internal.settingsURL.absoluteString)#\($0)") } ?? Internal.settingsURL, in: window)
    }

    func openHistory(in window: BrowserWindow? = nil) { openInternal(Internal.historyURL, in: window) }

    func openAgentLog(in window: BrowserWindow? = nil) { openInternal(Internal.agentsURL, in: window) }

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

    /// Reloads every open page of the site (of `space` only, for a separate space's choice), so
    /// their content blockers and scripts match.
    func setProtections(_ enabled: Bool, host: String, space: Space.ID? = nil, from tab: Tab? = nil) {
        privacy.setEnabled(enabled, host: host, space: space)
        reloadForProtections(pages.filter { Privacy.siteHost($0.url) == host && (space == nil || $0.siteSpace == space) }, from: tab)
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

    /// An internal page open in any window is shown there; a new one opens in `window`.
    private func openInternal(_ url: URL, in window: BrowserWindow?) {
        if let existing = tabs.first(where: { $0.url?.host() == url.host() && Internal.isInternal($0.url) }) {
            if url.fragment() != nil, existing.url != url { navigate(existing, .open(url)) }
            // Already in front, the page gets no visibilitychange to refresh on, though what it
            // lists may have changed meanwhile in a tab never selected (an agent's, a background link).
            if existing === self.window(of: existing).selectedTab {
                existing.loadedWebView?.evaluateJavaScript("window.shownAgain?.()", in: nil, in: .page)
            }
            select(existing)
        } else {
            newTab(url: url, in: window)
        }
    }

    // MARK: Windows

    /// The window a tab list command acts on: the one in front, else the first.
    var commandWindow: BrowserWindow { keyWindow ?? windows[0] }

    func window(of tab: Tab) -> BrowserWindow {
        windows.first { $0.id == tab.windowID } ?? windows[0]
    }

    /// A window closed while an agent or a page awaited leaves its id behind: the tab opened for
    /// it goes to the window in front, never into no window's list.
    private func liveWindow(_ id: BrowserWindow.ID?) -> BrowserWindow {
        windows.first { $0.id == id } ?? commandWindow
    }

    func window(for nsWindow: NSWindow?) -> BrowserWindow? {
        guard let nsWindow else { return nil }
        return windows.first { $0.nsWindow === nsWindow }
    }

    /// Any window shows it: its selection, or its split partner. The last window, closed and
    /// hidden, shows nothing, so its tabs can sleep.
    func isShown(_ tab: Tab) -> Bool {
        windows.contains { !$0.isHidden && ($0.selectedTabID == tab.id || $0.shownPartner === tab) }
    }

    private func isPoppedOut(_ tab: Tab) -> Bool {
        windows.contains { $0.videoPopout.tab === tab }
    }

    /// At launch: every saved window, the one the user was last in shown last, so it is in front.
    func showRestoredWindows() {
        // Read first: each window shown becomes key, and the last active with it.
        let front = lastActiveWindowID
        windows.filter { $0.id != front }.forEach(show)
        windows.filter { $0.id == front }.forEach(show)
        windowsDidShow()
    }

    /// Once a window is on screen.
    func windowsDidShow() {
        installEventMonitors()
        // The date may have changed since the last session, as at a change of day.
        if !refreshedIconsAtLaunch {
            refreshedIconsAtLaunch = true
            refreshSleepingPinIcons()
        }
    }

    /// Settings, History and Reopen Closed Tab from the menu, and links from other apps: they
    /// open or select a tab in a browser window, which comes forward first from a link's window
    /// or the Dock, or that tab would change out of sight. The last window, closed, opens again.
    func inBrowserWindow(_ command: (BrowserWindow) -> Void) {
        let window = commandWindow
        if window.isHidden {
            show(window)
        } else if let nsWindow = window.nsWindow, nsWindow.isMiniaturized || !canChangeTabs {
            bringForward(nsWindow)
        }
        command(window)
    }

    /// Ordering front alone leaves a minimized window in the Dock.
    private func bringForward(_ nsWindow: NSWindow) {
        if nsWindow.isMiniaturized { nsWindow.deminiaturize(nil) }
        nsWindow.makeKeyAndOrderFront(nil)
    }

    private func show(_ window: BrowserWindow) {
        window.isHidden = false
        window.nsWindow = showWindow(window, self)
    }

    private static func openOnScreen(_ window: BrowserWindow, browser: Browser) -> NSWindow? {
        ExternalApps.runsTests ? nil : BrowserNSWindow.open(window, browser: browser)
    }

    /// New Window, and the Dock clicked with no window showing: the last window closed shows again
    /// with its tabs, else a new window opens on the start page, in the space of the window in front.
    @discardableResult
    func openWindow(space: Space.ID? = nil) -> BrowserWindow {
        if let hidden = windows.first(where: \.isHidden) {
            show(hidden)
            return hidden
        }
        let window = BrowserWindow(browser: self, space: space ?? commandWindow.currentSpaceID)
        windows.append(window)
        show(window)
        window.newTabFocusingAddress()
        return window
    }

    /// Its tabs go into Reopen Closed Tab, bottom up so ⇧⌘T brings them back top down, each where
    /// it was. The last window keeps its tabs, hidden, until New Window or the Dock shows it again;
    /// its private tabs close, or their sign-ins would live on for that Dock click.
    func windowWillClose(_ window: BrowserWindow) {
        window.nsWindow = nil
        window.videoPopout.hide()
        if keyWindow === window { keyWindow = nil }
        if windows.count == 1 {
            window.isHidden = true
            let closing = tabs.filter { $0.windowID == window.id && $0.isEphemeral }
            // Off a private tab first, so the selection doesn't wake a neighbour no window shows.
            if window.selectedTab?.isEphemeral == true { window.showStartPage(picked: false) }
            closing.forEach { close($0) }
            // WebKit plays on in a page out of any window: nothing the user closed keeps sounding.
            for tab in tabs where tab.windowID == window.id { nowPlaying.pause(tab) }
            // Off screen now, as when deselected: their idle time starts here, not when they were
            // selected, or the page read for a while would sleep, and reload, before a Dock click.
            window.selectedTab?.markActive()
            window.shownPartner?.markActive()
            // Pausing leaves a call's microphone and camera on, and a tab in a call never sleeps
            // by itself: it would go on sending them with no window. After `markActive`, which wakes.
            for tab in tabs where tab.windowID == window.id && nowPlaying.isInCall(tab) {
                tab.sleep(configuration: makeConfiguration(for: tab.url))
            }
            return
        }
        // Off the tabs first, so the selection doesn't walk through (and wake) the tabs closing.
        window.showStartPage(picked: false)
        let closing = tabs.filter { $0.windowID == window.id }
        closedTabsKept = Self.closedTabsLimit + closing.count
        closing.reversed().forEach { close($0) }
        windows.removeAll { $0 === window }
    }

    /// A favorite's notification that came while the window wasn't key put a dot on its tile; the
    /// user is now looking at that page. Extensions' active tab is the one in front.
    func windowBecameKey(_ window: BrowserWindow) {
        keyWindow = window
        if !isMinimizingWindow { lastActiveWindowID = window.id }
        quickLinks.browserWindowBecameKey()
        window.selectedTab?.didOpen()
        extensions.didSelect(window.selectedTab)
    }

    /// Brackets a minimize, so the window that takes the key meanwhile doesn't become the last active.
    func windowMinimizing(_ minimizing: Bool) {
        isMinimizingWindow = minimizing
    }

    enum WindowShowing { case onScreen, minimized, closed }
    enum DockClick: Equatable { case comeForward, restore(BrowserWindow.ID), openWindow }

    /// The last active window comes back from the Dock even with another on screen; with one on
    /// screen otherwise, or a link's window, Lithium only comes forward. With none, the first
    /// minimized one comes back, as before, else the last one closed or a new one.
    nonisolated static func dockClick(on windows: [(id: BrowserWindow.ID, showing: WindowShowing)], lastActive: BrowserWindow.ID?, linkOnScreen: Bool = false) -> DockClick {
        let minimized = windows.filter { $0.showing == .minimized }.map(\.id)
        if let lastActive, minimized.contains(lastActive) { return .restore(lastActive) }
        if linkOnScreen || windows.contains(where: { $0.showing == .onScreen }) { return .comeForward }
        return minimized.first.map(DockClick.restore) ?? .openWindow
    }

    /// From the browser windows alone: AppKit's `hasVisibleWindows` also counts the agent stage,
    /// a link's window and panels, so with any of them up a minimized window stayed in the Dock.
    func reopenFromDock() {
        let showing = windows.map { window in
            (id: window.id, showing: window.isHidden ? WindowShowing.closed : window.nsWindow?.isMiniaturized == true ? .minimized : .onScreen)
        }
        switch Self.dockClick(on: showing, lastActive: lastActiveWindowID, linkOnScreen: quickLinks.hasWindowOnScreen) {
        case .comeForward: break
        case .restore(let id): if let nsWindow = windows.first(where: { $0.id == id })?.nsWindow { bringForward(nsWindow) }
        case .openWindow: openWindow()
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
            guard event.keyCode == 53, let self else { return event }
            return MainActor.assumeIsolated { self.takesEscape(event) } ? nil : event
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
        guard let window, self.window(for: window) != nil || window === quickLinks.keyWindow else { return false }
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
        if field is URLTextField { self.window(for: window)?.returnKeyboardToPage(fieldHadKeyboard: true) }
    }

    /// The key monitor's Escape: true when Lithium acted on it, false to let it go on. A page with
    /// the keyboard has it before the prompts, which take only one it sends back unhandled.
    func takesEscape(_ event: NSEvent) -> Bool {
        // An agent's Escape that the page didn't handle comes back here; it isn't the user's.
        guard !NativeInput.isAgents(event), ownsEscape(in: event.window) else { return false }
        if dismissOverlay(in: event.window, pageDeclined: objc_getAssociatedObject(event, Self.passedOnKey) != nil) { return true }
        objc_setAssociatedObject(event, Self.passedOnKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return false
    }

    /// Not in another window or under a sheet, and not while a text field edits (the address bar
    /// ends its editing itself), unless it is the find field or a tab's name, which Escape closes.
    func ownsEscape(in window: NSWindow?) -> Bool {
        guard let window, window.attachedSheet == nil else { return false }
        // A link's window has only the find bar to close.
        guard let browserWindow = self.window(for: window) else { return window === quickLinks.keyWindow && quickLinks.findBarIsInFront }
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return true }
        return browserWindow.find.isFieldFocused || browserWindow.isRenaming
    }

    /// Escape in `nsWindow`, or with none given in the window in front. A link's window has only
    /// its find bar: a tab's name editing in a browser window stays.
    func dismissOverlay(in nsWindow: NSWindow? = nil, pageDeclined: Bool = false) -> Bool {
        if let window = window(for: nsWindow) { return window.dismissOverlay(pageDeclined: pageDeclined) }
        if quickLinks.keyTab != nil { return quickLinks.closeFindBar() }
        return commandWindow.dismissOverlay(pageDeclined: pageDeclined)
    }

    /// Hands the keyboard back to `tab`'s page once a field of Lithium's own closes: left on the
    /// window, keys beep. Unless that field had it, a field still editing keeps it.
    func returnKeyboardToPage(to tab: Tab?, fieldHadKeyboard: Bool) {
        guard let page = tab?.contentView, let window = page.window else { return }
        if fieldHadKeyboard { window.makeFirstResponder(page) } else { focusPage(page) }
    }

    /// Find acts on the window in front: a link's, or the browser window the menu's commands act on.
    func toggleFind() {
        if quickLinks.keyTab != nil { quickLinks.toggleFind() } else { commandWindow.toggleFind() }
    }

    func findStep(forward: Bool) async {
        if quickLinks.keyTab != nil { await quickLinks.findStep(forward: forward) } else { await commandWindow.findStep(forward: forward) }
    }

    func useSelectionForFind() async {
        if quickLinks.keyTab != nil { await quickLinks.useSelectionForFind() } else { await commandWindow.useSelectionForFind() }
    }

    var findBarIsInFront: Bool {
        quickLinks.keyTab != nil ? quickLinks.findBarIsInFront : commandWindow.findBarIsInFront
    }

    /// The find bar open over `tab`'s page: its window's, or the links' one.
    func findBar(over tab: Tab) -> FindInPage? {
        if quickLinks.contains(tab) { return quickLinks.showsFindBar(over: tab) ? quickLinks.find : nil }
        let window = window(of: tab)
        return window.showsFindBar(over: tab) ? window.find : nil
    }

    func showsFindBar(over tab: Tab) -> Bool { findBar(over: tab) != nil }

    /// The page the menu's page commands (Reload, Back, Print…) act on.
    /// None while the last window is closed: its page is out of sight.
    var commandTab: Tab? { quickLinks.keyTab ?? (commandWindow.isHidden ? nil : commandWindow.selectedTab) }
    /// The Tabs menu's selection and tab-list commands act on the browser window in front
    /// (`commandWindow`): not while a link's window is, or the last window is closed, where they
    /// would wake and switch tabs out of sight.
    var canChangeTabs: Bool { quickLinks.keyTab == nil && !commandWindow.isHidden }

    /// The group a tab's bulk actions (Close Other Tabs, Close Tabs Below) stay within.
    func peers(of tab: Tab) -> [Tab] {
        tab.isInAgentGroup ? agentGroup(in: tab.spaceID, window: tab.windowID) : tabList(in: tab.spaceID, window: tab.windowID)
    }

    /// The favorite's page in `window`, which no other window shows.
    func liveTab(for pin: Pin, in window: BrowserWindow.ID) -> Tab? { tabs.first { $0.pinID == pin.id && $0.windowID == window } }

    /// One page per window the favorite is open in.
    func liveTabs(for pin: Pin) -> [Tab] { tabs.filter { $0.pinID == pin.id } }

    /// Every window's tile shows what any of the favorite's pages says: one site, one account.
    func badge(for pin: Pin) -> UnreadBadge.Shown? {
        UnreadBadge.merged(liveTabs(for: pin).map(\.unread.shown))
    }

    func icon(for pin: Pin) -> NSImage? {
        if let live = liveTabs(for: pin).lazy.compactMap(\.favicon).first { return live }
        if let cached = pinIcons[pin.id] { return cached }
        let image = pin.favicon.flatMap(NSImage.init(data:))
        pinIcons[pin.id] = image
        return image
    }

    // MARK: Tabs

    /// `opener` is the tab whose page opened this one (a link, ⌘-click or `window.open`): the tab
    /// goes in its window; without one, in `window`, else the window in front.
    @discardableResult
    func newTab(url: URL? = nil, selecting: Bool = true, configuration: WKWebViewConfiguration? = nil, privateStore: WKWebsiteDataStore? = nil, openedFrom opener: Tab? = nil, space: Space.ID? = nil, in window: BrowserWindow? = nil) -> Tab {
        let window = opener.map(self.window(of:)) ?? liveWindow(window?.id)
        // A link's window opens its tabs in the last window, which may have closed since: out of sight.
        if window.isHidden, let opener, quickLinks.contains(opener) { show(window) }
        let tab = insertTab(at: 0, configuration: configuration ?? makeConfiguration(for: url), privateStore: privateStore, space: space ?? opener?.spaceID ?? window.currentSpaceID, window: window.id)
        if let opener { window.recentTabs.didOpen(tab, from: opener) } else if selecting { window.recentTabs.didOpen(tab, replacing: window.selectedTab) }
        if let url { tab.load(url) }
        if selecting { window.select(tab) }
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
        if quickLinks.isEnabled, QuickLinks.takes(url) { quickLinks.open(url) } else { inBrowserWindow { newTab(url: url, in: $0) } }
    }

    /// A link's page, into the top of `window`'s tab list.
    func adopt(_ tab: Tab, into window: BrowserWindow) {
        tab.move(toWindow: window.id)
        tabs.insert(tab, at: Self.position(inTabList: 0, of: tabs, space: tab.spaceID, window: window.id))
        extensions.didOpen(tab)
        window.select(tab)
    }

    /// `index` is a place in the window's tab list for the space (in `folder`, or outside folders), clamped to it.
    private func insertTab(at index: Int, configuration: WKWebViewConfiguration, privateStore: WKWebsiteDataStore? = nil, space: Space.ID, window: BrowserWindow.ID, folder: TabFolder.ID? = nil) -> Tab {
        let tab = Tab(browser: self, configuration: configuration, privateStore: privateStore, space: space, window: window)
        tab.folderID = folder
        tabs.insert(tab, at: Self.position(inTabList: index, of: tabs, space: space, window: window, folder: folder))
        extensions.didOpen(tab)
        return tab
    }

    private static func position(inTabList index: Int, of tabs: [Tab], space: Space.ID, window: BrowserWindow.ID, folder: TabFolder.ID? = nil) -> Int {
        let list = tabs.filter { $0.isInTabList && $0.spaceID == space && $0.windowID == window && $0.folderID == folder }
        return index <= 0 ? 0 : index >= list.count ? tabs.count : tabs.firstIndex { $0 === list[index] } ?? tabs.count
    }

    /// At the end of the Agent group, empty and unselected: the user's tab list and selection
    /// stay as they were.
    func newAgentTab(session: String, configuration: WKWebViewConfiguration? = nil, privateStore: WKWebsiteDataStore? = nil, space: Space.ID? = nil, window: BrowserWindow.ID? = nil) -> Tab {
        let window = liveWindow(window)
        let tab = Tab(browser: self, configuration: configuration ?? makeConfiguration(), privateStore: privateStore, space: space ?? window.currentSpaceID, window: window.id)
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
            reordered.insert(tab, at: Self.position(inTabList: index ?? .max, of: reordered, space: tab.spaceID, window: tab.windowID))
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

    /// Into a folder of its space, or out of folders with nil. A split's other side comes along,
    /// so the pair stays one row.
    func moveTab(_ tab: Tab, toFolder folder: TabFolder.ID?, at index: Int? = nil) {
        guard tab.pinID == nil, folder.map({ folderExists($0, in: tab.spaceID) }) ?? true else { return }
        let partner = split(of: tab)?.partner(of: tab.id).flatMap { id in tabs.first { $0.id == id } }
        let moving = [tab] + (partner.map { [$0] } ?? [])
        // Measured against the folder as shown, the moving tabs still in it.
        let anchor = index.flatMap { index in
            tabList(in: tab.spaceID, window: tab.windowID, folder: folder).dropFirst(index).first { listed in !moving.contains { $0 === listed } }
        }
        place(moving, inFolder: folder, before: anchor)
    }

    /// Its tabs in `acting` close, or stay at the top of the tabs outside folders, where the folder
    /// was. Other windows' tabs in it always stay that way: the user saw and chose for one window.
    func deleteFolder(_ id: TabFolder.ID, closingTabs: Bool, in acting: BrowserWindow) {
        let members = tabs.filter { $0.folderID == id && $0.isInTabList }
        if closingTabs {
            let closing = members.filter { $0.windowID == acting.id }
            if let selected = acting.selectedTab, closing.contains(where: { $0 === selected }) {
                // Off the folder first, so the selection doesn't walk through (and wake) its tabs.
                let list = tabList(in: selected.spaceID, window: acting.id)
                let first = list.firstIndex { $0.folderID == id } ?? 0
                let next = list[first...].first { $0.folderID != id } ?? list[..<first].last
                if let next { acting.select(next, picked: false) } else { acting.showStartPage(picked: false) }
            }
            // In list order: with the folder gone, each reopens at the top of the list, so the
            // last closed coming back first puts them back in their order.
            closing.forEach(close)
        }
        for window in windows where !(closingTabs && window === acting) {
            let listed = members.filter { $0.windowID == window.id }
            guard !listed.isEmpty else { continue }
            place(listed, inFolder: nil, before: tabList(in: listed[0].spaceID, window: window.id, folder: nil).first)
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

    /// Shows `tab` in its window. A tab the user picked brings its window forward; an agent's or
    /// an extension's choice leaves the window in front, and the keys, where they are.
    func select(_ tab: Tab, picked: Bool = true) {
        let window = window(of: tab)
        window.select(tab, picked: picked)
        guard picked, let nsWindow = window.nsWindow, window !== commandWindow || nsWindow.isMiniaturized else { return }
        bringForward(nsWindow)
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
        let window = window(of: tab)
        window.videoPopout.discard(tab)
        nowPlaying.discard(tab)
        if remembering, let url = tab.url, !tab.isEphemeral {
            // An agent's tab comes back the user's, at the bottom of the list, next to where it was.
            let group = tabList(in: tab.spaceID, window: tab.windowID, folder: tab.folderID)
            let place = tab.pinID != nil ? nil : tab.isInAgentGroup ? group.count : group.firstIndex { $0 === tab }
            let closed = ClosedTab(url: url, pinID: tab.pinID, spaceID: tab.spaceID, customTitle: tab.customTitle, index: place,
                                   folderID: tab.folderID, history: tab.history)
            closedTabs.append(closed)
            if closedTabs.count > closedTabsKept { closedTabs.removeFirst(closedTabs.count - closedTabsKept) }
        }
        let partner = leaveSplit(tab)
        let wasSelected = tab.id == window.selectedTabID
        if wasSelected { window.selectAfterClosing(tab, partner: partner, among: order, goingBack: goingBack) }
        window.recentTabs.didClose(tab)
        tab.unpair()
        tab.dialogOwner?.answerDialog(in: tab)
        agent?.didClose(tab)
        permissions.cancel(tabID: tab.id)
        appLinks.cancel(tabID: tab.id)
        passwords.cancel(tabID: tab.id)
        // A name field gone with its row would never end the rename, which holds Escape and the agent.
        if window.renamingTabID == tab.id { window.renamingTabID = nil }
        summaries.discard(tab)
        tab.tearDown()
        tabs.remove(at: index)
        extensions.didClose(tab)
        // Extensions would otherwise go on taking the closed tab for the active one.
        if wasSelected { extensions.didSelect(window.selectedTab) }
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

    /// ⌘W closes the selected tab of the browser window that is key, or whose page holds the key
    /// window: a full-screen video is in WebKit's own window, which counts as the tab's. A browser
    /// window with no tab at all closes, as in Safari and Chrome; one on its start page with tabs
    /// elsewhere in it stays, since closing it would take them all. Favorites' pages don't count:
    /// ⌘W never goes back to one, and they close with the window. Another window in front closes.
    func closeTabOrWindow(keyWindow: NSWindow? = NSApp.keyWindow) {
        guard let keyWindow else { return }
        let holdsPage = { (window: BrowserWindow) in
            window.selectedTab?.loadedWebView.map { keyWindow === $0.window || $0.fullscreenState != .notInFullscreen } == true
        }
        guard let window = window(for: keyWindow) ?? windows.first(where: holdsPage) else { return keyWindow.performClose(nil) }
        if window.selectedTab != nil {
            window.closeSelectedTab()
        } else if !tabs.contains(where: { $0.windowID == window.id && $0.pinID == nil }) {
            keyWindow.performClose(nil)
        }
    }

    /// The others of its group; favorites' pages stay, as Chrome keeps pinned tabs. Tabs close
    /// bottom up, so ⇧⌘T brings them back top down, each where it was.
    func closeOtherTabs(than tab: Tab) {
        window(of: tab).select(tab, picked: false)
        peers(of: tab).reversed().filter { $0 !== tab }.forEach(close)
    }

    func closeTabs(below tab: Tab) {
        let below = tabs(below: tab)
        // Selected first, so the selection doesn't walk through (and wake) the tabs about to close.
        let window = window(of: tab)
        if below.contains(where: { $0.id == window.selectedTabID }) { window.select(tab, picked: false) }
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
        let window = window(of: tab)
        if above.contains(where: { $0.id == window.selectedTabID }) { window.select(tab, picked: false) }
        above.reversed().forEach(close)
    }

    func tabs(above tab: Tab) -> ArraySlice<Tab> {
        let list = peers(of: tab)
        guard let index = list.firstIndex(where: { $0 === tab }) else { return [] }
        return list[..<index]
    }

    var canReopenClosedTab: Bool { !closedTabs.isEmpty }

    /// Like Chrome: back in its place, with its history, in the window ⇧⌘T was pressed in. A
    /// favorite's page goes back to its favorite if that has no page open in the window, or else
    /// to the top of the list.
    func reopenClosedTab(into window: BrowserWindow? = nil) {
        guard let closed = closedTabs.popLast() else { return }
        let window = window ?? commandWindow
        let pin = pins.first { $0.id == closed.pinID && liveTab(for: $0, in: window.id) == nil }
        let folder = closed.folderID.flatMap { folderExists($0, in: closed.spaceID) ? $0 : nil }
        let index = pin != nil || closed.folderID != folder ? 0 : closed.index ?? 0
        let tab = insertTab(at: index, configuration: makeConfiguration(for: closed.url), space: closed.spaceID, window: window.id, folder: pin == nil ? folder : nil)
        extensions.moving(tab) { tab.pinID = pin?.id }
        tab.customTitle = closed.customTitle
        tab.load(closed.url, history: closed.history)
        window.select(tab)
    }

    /// Just below the original, with its history and name. The copy is never a favorite, nor an agent's.
    func duplicate(_ tab: Tab) {
        guard let url = tab.url else { return }
        let list = tabList(in: tab.spaceID, window: tab.windowID, folder: tab.folderID)
        let index = tab.isInAgentGroup ? list.count : list.firstIndex { $0 === tab }.map { $0 + 1 } ?? 0
        // A private tab's copy shares its store, and is private too; any copy stays in its space.
        let copy = insertTab(at: index, configuration: makeConfiguration(for: url), privateStore: tab.privateStore, space: tab.spaceID, window: tab.windowID, folder: tab.folderID)
        copy.customTitle = tab.customTitle
        copy.load(url, history: tab.history)
        window(of: tab).select(copy)
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
        window(of: tab).renamingTabID = nil
    }

    /// The sidebars' order, top to bottom, window after window and space after space. Extensions
    /// and agents see every window and space.
    var navigationOrder: [Tab] {
        windows.flatMap { navigationOrder(of: $0.id) }
    }

    /// One window's sidebar order, space after space.
    func navigationOrder(of window: BrowserWindow.ID) -> [Tab] {
        let spaces = spaces.isEmpty ? [Space.mainID] : spaces.map(\.id)
        return spaces.flatMap { navigationOrder(in: $0, window: window) }
    }

    // MARK: Session

    /// `quitting` adds the tabs' back and forward pages, left out of other saves: WebKit serializes a
    /// loaded tab's on the main thread, and every save would rewrite each sleeping tab's.
    /// The top-level selection and space are the first window's, as a file before windows had them.
    private func session(quitting: Bool) -> Session {
        var session = Session()
        var places: [Tab.ID: Int] = [:]
        var selected: [BrowserWindow.ID: Int] = [:]
        let first = windows[0]
        for tab in tabs {
            guard let url = tab.url, !tab.isEphemeral else { continue }
            let window = window(of: tab)
            if tab.id == window.selectedTabID { selected[window.id] = session.tabs.count }
            places[tab.id] = session.tabs.count
            // Not the error page's own title: the tab comes back named after its site.
            let title = tab.isShowingError ? "" : tab.title
            let lastShown = window.lastShownTab(in: tab.spaceID) == tab.id
            session.tabs.append(Session.Tab(url: url, title: title, customTitle: tab.customTitle, pinID: tab.pinID,
                                            spaceID: Space.saved(tab.spaceID), lastShown: lastShown ? true : nil, folderID: tab.folderID,
                                            history: quitting ? tab.history as? Data : nil, windowID: window === first ? nil : window.id))
        }
        session.selectedIndex = selected[first.id]
        session.splits = savedSplits(at: places)
        session.folders = savedFolders
        if !spaces.isEmpty {
            session.spaces = spaces
            session.spaceID = Space.saved(first.currentSpaceID)
        }
        session.windows = windows.map { window in
            Session.Window(id: window.id, frame: window.frame, selectedIndex: selected[window.id], spaceID: Space.saved(window.currentSpaceID),
                           isSidebarVisible: window.isSidebarVisible, isZenMode: window.isZenMode)
        }
        session.lastActiveWindowID = lastActiveWindowID
        return session
    }

    /// Every tab comes back asleep, in its window; a file from before windows were saved has one.
    /// A tab of a window no longer saved goes to the first, as one of a space gone goes to the main space.
    private func restore(_ session: Session) {
        restoreSpaces(session)
        restoreFolders(session.folders)
        let saved = session.windows?.isEmpty == false ? session.windows! : [Session.Window(id: UUID(), selectedIndex: session.selectedIndex, spaceID: session.spaceID)]
        windows = saved.map { window in
            BrowserWindow(browser: self, id: window.id, space: knownSpace(window.spaceID), frame: window.frame,
                          isSidebarVisible: window.isSidebarVisible, isZenMode: window.isZenMode)
        }
        lastActiveWindowID = session.lastActiveWindowID.flatMap { id in windows.contains { $0.id == id } ? id : nil }
        var restored: [Int: Tab] = [:]
        var lastShown: [Tab] = []
        for (index, tab) in session.tabs.enumerated() {
            // An extension's own page needs its extension, which loads after the session comes back.
            guard tab.url.scheme != Extensions.scheme else { continue }
            let space = knownSpace(tab.spaceID)
            let window = tab.windowID.flatMap { id in windows.first { $0.id == id } } ?? windows[0]
            // Its configuration is made as it wakes: most restored tabs stay asleep for a while.
            let restoring = Tab(browser: self, configuration: nil, space: space, window: window.id)
            restoring.restore(url: tab.url, title: tab.title, history: tab.history)
            restoring.customTitle = tab.customTitle
            restoring.pinID = tab.pinID.flatMap { id in pins.contains { $0.id == id && $0.space == space } ? id : nil }
            restoring.folderID = tab.folderID.flatMap { id in restoring.pinID == nil && folderExists(id, in: space) ? id : nil }
            if tab.lastShown == true { lastShown.append(restoring) }
            // Asleep, it loads nothing that would tidy its title.
            tidyTitles.update(restoring, askingModel: false)
            tabs.append(restoring)
            extensions.didOpen(restoring)
            restored[index] = restoring
        }
        restoreSplits(session.splits, tabs: restored)
        for (window, saved) in zip(windows, saved) {
            let selected = saved.selectedIndex.flatMap { restored[$0] }.flatMap { $0.windowID == window.id ? $0 : nil }
            window.restore(selected: selected, lastShown: lastShown.filter { $0.windowID == window.id })
            if let selected { extensions.didSelect(selected) }
        }
    }

    private func knownSpace(_ id: Space.ID?) -> Space.ID {
        id.flatMap { id in spaces.contains { $0.id == id } ? id : nil } ?? Space.mainID
    }

    /// A favorite of a space no longer saved goes back to the main space rather than vanish.
    private func restoreSpaces(_ session: Session) {
        if let saved = session.spaces, !saved.isEmpty {
            let main = saved.first { $0.id == Space.mainID } ?? .main
            // An edited file's spaces past `Space.limit` are left out; their tabs go to the main space.
            spaces = Array(([main] + saved.filter { $0.id != Space.mainID }).prefix(Space.limit))
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
        // A page retitling itself on screen (a chat left open) would otherwise read every cookie each minute.
        if !titlesDue { saveSessionCookiesIfDue() }
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
            await SessionCookies.save(stores, replacing: replacing)
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

    /// Made from `window`, which shows it.
    func addSpace(_ space: Space, in window: BrowserWindow? = nil) {
        guard canAddSpace, !allSpaces.contains(where: { $0.id == space.id }) else { return }
        var space = space
        space.name = Space.trimmedName(space.name, fallback: "Space \(allSpaces.count + 1)")
        spaces = allSpaces + [space]
        let window = window ?? commandWindow
        window.switchToSpace(space.id)
        window.requestAddressFocus()
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

    /// Every window showing the space moves to the one before it first.
    func deleteSpace(_ id: Space.ID) {
        guard id != Space.mainID, let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        let space = spaces[index]
        for window in windows where window.currentSpaceID == id { window.switchToSpace(spaces[index - 1].id) }
        tabs.filter { $0.spaceID == id }.reversed().forEach { close($0, remembering: false) }
        quickLinks.tabs.filter { $0.spaceID == id }.forEach(quickLinks.close)
        closedTabs.removeAll { $0.spaceID == id }
        for pin in pins where pin.space == id { pinIcons[pin.id] = nil }
        pins.removeAll { $0.space == id }
        removeFolders(in: id)
        spaces.remove(at: index)
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
            // finds no store for the deleted space (`spaceStore(for:)`), or sets them in memory
            // only, in a store no page uses and no save reads.
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

    /// Every window shows the favorites, each with its own page: open in another window only, the
    /// favorite opens a second page in `window` (the window in front with none given), and the
    /// first stays as it is, as Safari and Chrome do with one site in two windows.
    func activate(_ pin: Pin, in window: BrowserWindow? = nil) {
        let window = liveWindow(window?.id)
        if let tab = liveTab(for: pin, in: window.id) {
            select(tab)
        } else {
            let tab = newTab(url: pin.url, space: pin.space, in: window)
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
            // The other side leaves the screen, as by `exitSplit`.
            window(of: tab).shownPartner?.markActive()
            leaveSplit(tab)
            tab.pinID = pin.id
            // The user's from now on: unpinned, it goes to the tab list, outside folders.
            tab.openedByAgent = nil
            tab.folderID = nil
        }
        // Its name field was in the list, which no longer shows it.
        let window = window(of: tab)
        if window.renamingTabID == tab.id { window.renamingTabID = nil }
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
        reportingMoves(of: liveTabs(for: pins[from])[...]) { pins = reordered }
    }

    /// The window in front keeps its page.
    func unpin(_ pin: Pin) {
        unpin(pin, keepingPageIn: commandWindow)
    }

    /// The page in `window`, the one the user unpinned from, stays there as a tab; the favorite's
    /// pages in other windows close, as nothing would list them any more.
    func unpin(_ pin: Pin, keepingPageIn window: BrowserWindow) {
        let pages = liveTabs(for: pin)
        pages.filter { $0.windowID != window.id }.reversed().forEach(close)
        let kept = pages.first { $0.windowID == window.id }
        extensions.moving(kept) {
            kept?.pinID = nil
            pins.removeAll { $0.id == pin.id }
        }
        pinIcons[pin.id] = nil
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
    /// once more for each favorite whose pages are all asleep, or that has none; they stay asleep.
    private func refreshSleepingPinIcons() {
        let due = pins.compactMap { pin -> (Pin.ID, URL)? in
            guard liveTabs(for: pin).allSatisfy(\.isAsleep), let url = pin.iconURL,
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
                for tab in liveTabs(for: pins[index]) where tab.isAsleep && tab.url?.host() == host { tab.showFavicon(data) }
                storeIcon(data, from: url, inPinAt: index)
            }
        }
    }
}


import AppKit
import Observation
import WebKit

/// Window state. Every open page is a `Tab`; a tab whose `pinID` is set is the live page of a
/// favorite and shows in the grid instead of the tab list. Pins and the open tabs are persisted.
/// With no tab selected the window shows `home` (Brave Search), which hands every navigation
/// off to a new tab, so empty tabs never pile up.
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
    var isSidebarVisible = true
    var renamingTabID: Tab.ID?

    let privacy = Privacy()
    let history = HistoryStore()
    let find = FindInPage()
    let suggestions = AddressSuggestions()
    let permissions = SitePermissions()
    let tidyTitles = TidyTitles()
    let summaries = PageSummaries()
    let textCorrections = TextCorrections()
    let extensions = Extensions()
    let videoPopout = VideoPopout()
    @ObservationIgnored private(set) lazy var capture = ScreenCapture(browser: self)
    @ObservationIgnored private var pinIcons: [Pin.ID: NSImage] = [:]
    @ObservationIgnored private(set) lazy var home: Tab = {
        let tab = Tab(browser: self, configuration: makeConfiguration(), isHome: true)
        tab.load(Self.homeURL)
        return tab
    }()

    static var homeURL: URL { SearchEngine.current.home }

    static func isHomeURL(_ url: URL) -> Bool {
        url.host() == homeURL.host() && (url.path().isEmpty || url.path() == "/")
    }

    func setSearchEngine(_ engine: SearchEngine) {
        UserDefaults.standard.set(engine.rawValue, forKey: SearchEngine.preferenceKey)
        home.load(Self.homeURL)
    }

    @ObservationIgnored private(set) lazy var internalBridge = InternalBridge(browser: self)
    @ObservationIgnored private var eventMonitors: [Any] = []
    @ObservationIgnored private var closedTabs: [ClosedTab] = []
    // Cancelled in deinit, which runs outside the main actor; both are safe to cancel from anywhere.
    @ObservationIgnored nonisolated(unsafe) private var sleepLoop: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var memoryPressure: DispatchSourceMemoryPressure?
    /// As macOS last reported it: the source only speaks when the level changes.
    @ObservationIgnored private var memoryLevel: DispatchSource.MemoryPressureEvent = .normal
    @ObservationIgnored private var savedSession: Session?

    struct ClosedTab {
        let url: URL
        let pinID: Pin.ID?
        let customTitle: String?
    }

    /// 30 minutes, or 5 while the Mac saves energy (Low Power Mode, or running hot), as in
    /// Orion. `defaults write app.lithium.browser tabIdleSeconds N` overrides both.
    static var tabIdleInterval: TimeInterval {
        let custom = UserDefaults.standard.double(forKey: "tabIdleSeconds")
        if custom > 0 { return custom }
        return isSavingEnergy ? shortIdleInterval : 30 * 60
    }
    static let shortIdleInterval: TimeInterval = 5 * 60

    private static var isSavingEnergy: Bool {
        let info = ProcessInfo.processInfo
        return info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical
    }
    private static let closedTabsLimit = 25

    init() {
        pins = PinStore.load()
        privacy.start()
        extensions.browser = self
        videoPopout.browser = self
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
    }

    deinit {
        sleepLoop?.cancel()
        memoryPressure?.cancel()
    }

    /// A pass runs in one go on the main actor: nothing can change a tab between its check
    /// and its sleep, and two passes can't overlap. A popup window (a sign-in or payment
    /// window) and the page that opened it talk to each other, so neither sleeps while both
    /// are open, unless memory is critical.
    private func sleepIdleTabs(idleFor interval: TimeInterval, sparingPopups: Bool) {
        tabs.forEach { $0.noteSound() }
        var paired: Set<ObjectIdentifier> = []
        if sparingPopups {
            let open = Set(tabs.map { ObjectIdentifier($0) })
            for tab in tabs {
                guard let opener = tab.opener, open.contains(ObjectIdentifier(opener)) else { continue }
                paired.formUnion([ObjectIdentifier(tab), ObjectIdentifier(opener)])
            }
        }
        for tab in tabs where tab.id != selectedTabID && tab !== videoPopout.tab
            && !paired.contains(ObjectIdentifier(tab)) && tab.canSleep(idleFor: interval) {
            tab.sleep(configuration: makeConfiguration(for: tab.url))
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
        textCorrections.install(on: configuration)
        configuration.webExtensionController = extensions.controller
    }

    func openSettings(section: String? = nil) {
        openInternal(section.flatMap { URL(string: "\(Internal.settingsURL.absoluteString)#\($0)") } ?? Internal.settingsURL)
    }

    func openHistory() { openInternal(Internal.historyURL) }

    /// Reloads the page so its content blockers and scripts match the new setting.
    func setProtections(_ enabled: Bool, for tab: Tab?) {
        privacy.setEnabled(enabled, for: tab?.url)
        tab?.reload()
    }

    /// Reuses a tab already showing that internal page, moving it to the requested section.
    private func openInternal(_ url: URL) {
        if let existing = tabs.first(where: { $0.url?.host() == url.host() && Internal.isInternal($0.url) }) {
            if url.fragment() != nil, existing.url != url { existing.load(url) }
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
            guard event.keyCode == 53, let self else { return event }
            return MainActor.assumeIsolated { self.dismissOverlay() } ? nil : event
        }
        // A click only moves focus when it lands on something that takes focus (like the page).
        // Clicking the sidebar or toolbar background would otherwise leave a text field editing.
        let click = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            MainActor.assumeIsolated { Self.endEditingIfOutside(event) }
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

    /// Closes the topmost Lithium overlay. Returns false when there was none.
    func dismissOverlay() -> Bool {
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
        return false
    }

    var selectedTab: Tab? { tabs.first { $0.id == selectedTabID } }
    var regularTabs: [Tab] { tabs.filter { $0.pinID == nil } }

    func liveTab(for pin: Pin) -> Tab? { tabs.first { $0.pinID == pin.id } }

    func icon(for pin: Pin) -> NSImage? {
        if let live = liveTab(for: pin)?.favicon { return live }
        if let cached = pinIcons[pin.id] { return cached }
        let image = pin.favicon.flatMap(NSImage.init(data:))
        pinIcons[pin.id] = image
        return image
    }

    // MARK: Tabs

    @discardableResult
    func newTab(url: URL? = nil, selecting: Bool = true, configuration: WKWebViewConfiguration? = nil) -> Tab {
        let tab = Tab(browser: self, configuration: configuration ?? makeConfiguration(for: url))
        tabs.insert(tab, at: 0)
        extensions.didOpen(tab)
        if let url { tab.load(url) }
        if selecting { select(tab) }
        return tab
    }

    /// A navigation the home page hands off, with its method and form data.
    func newTab(request: URLRequest) {
        newTab(configuration: makeConfiguration(for: request.url)).load(request)
    }

    func newTabFocusingAddress() {
        find.hide()
        // Left for the address bar: it counts as used until now.
        selectedTab?.markActive()
        if selectedTabID == nil { resetHome() }
        selectedTabID = nil
        requestAddressFocus()
    }

    /// The home page keeps whatever was typed into it (its URL never changes), so every
    /// visit has to start from a fresh load. Done on the way out, the reload is out of sight.
    private func resetHome() {
        home.load(Self.homeURL)
    }

    func open(_ input: String) {
        guard let url = AddressInput.url(for: input) else { return }
        open(url)
    }

    private func open(_ url: URL) {
        if let tab = selectedTab { tab.load(url) } else { newTab(url: url) }
    }

    func addressTextChanged(_ text: String) {
        suggestions.update(query: text, tabs: tabs, pins: pins, history: history)
    }

    /// Return in the address bar: the highlighted suggestion, or the typed text as is.
    func submitAddress(_ text: String) {
        if let suggestion = suggestions.selected, suggestions.selectedIndex > 0 {
            accept(suggestion)
        } else {
            open(text)
        }
        suggestions.clear()
    }

    func accept(_ suggestion: Suggestion) {
        suggestions.clear()
        switch suggestion {
        case .search(let query): open(query)
        case .address(let url), .history(_, let url): open(url)
        case .openTab(let id, _, _): if let tab = tabs.first(where: { $0.id == id }) { select(tab) }
        case .pin(let id, _, _): if let pin = pins.first(where: { $0.id == id }) { activate(pin) }
        }
    }

    func select(_ tab: Tab) {
        if selectedTabID == nil { resetHome() }
        let previous = selectedTab
        if tab.id != selectedTabID {
            find.hide()
            previous?.markActive()
        }
        selectedTabID = tab.id
        tab.markActive()
        if previous !== tab { extensions.didActivate(tab, previous: previous) }
    }

    /// The selection falls back on the tab list only, never on a favorite: the tab below the
    /// closed one (above, at the bottom), and the home page once the list is empty. Closing a
    /// favorite's page selects the top of the list.
    func close(_ tab: Tab) {
        let order = regularTabs
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        videoPopout.discard(tab)
        if let url = tab.url {
            closedTabs.append(ClosedTab(url: url, pinID: tab.pinID, customTitle: tab.customTitle))
            if closedTabs.count > Self.closedTabsLimit { closedTabs.removeFirst() }
        }
        if tab.id == selectedTabID {
            let position = order.firstIndex { $0 === tab } ?? 0
            let remaining = order.filter { $0 !== tab }
            selectedTabID = remaining.isEmpty ? nil : remaining[min(position, remaining.count - 1)].id
            // The tab shown next may be asleep.
            selectedTab?.markActive()
        }
        tab.unpair()
        permissions.cancel(tabID: tab.id)
        summaries.discard(tab)
        tab.tearDown()
        tabs.remove(at: index)
        extensions.didClose(tab)
    }

    func closeSelectedTab() {
        if let tab = selectedTab { close(tab) }
    }

    var canReopenClosedTab: Bool { !closedTabs.isEmpty }

    func reopenClosedTab() {
        guard let closed = closedTabs.popLast() else { return }
        let tab = newTab(url: closed.url)
        tab.customTitle = closed.customTitle
        if let pin = pins.first(where: { $0.id == closed.pinID }), liveTab(for: pin) == nil {
            tab.pinID = pin.id
        }
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

    /// Live favorites first (in grid order), then the tab list, which is how the sidebar reads top to bottom.
    var navigationOrder: [Tab] {
        pins.compactMap(liveTab(for:)) + regularTabs
    }

    func selectAdjacentTab(_ offset: Int) {
        let order = navigationOrder
        guard !order.isEmpty else { return }
        // From the home page, forward starts at the first item and backward at the last.
        guard let current = order.firstIndex(where: { $0.id == selectedTabID }) else {
            select(offset > 0 ? order[0] : order[order.count - 1])
            return
        }
        select(order[(current + offset + order.count) % order.count])
    }

    /// ⌘1…⌘9 walk the favorites grid, then the tab list.
    func selectItem(at index: Int) {
        if index < pins.count {
            activate(pins[index])
        } else if index - pins.count < regularTabs.count {
            select(regularTabs[index - pins.count])
        }
    }

    // MARK: Session

    private var session: Session {
        var session = Session()
        for tab in tabs {
            guard let url = tab.url else { continue }
            if tab.id == selectedTabID { session.selectedIndex = session.tabs.count }
            session.tabs.append(Session.Tab(url: url, title: tab.title, customTitle: tab.customTitle, pinID: tab.pinID))
        }
        return session
    }

    /// Every tab comes back asleep. The selected one wakes in `windowDidAppear`: a page that
    /// finishes loading before its web view is in a window stays blank.
    private func restore(_ session: Session) {
        let pinIDs = Set(pins.map(\.id))
        var selected: Tab?
        for (index, saved) in session.tabs.enumerated() {
            // An extension's own page needs its extension, which loads after the session comes back.
            guard saved.url.scheme != Extensions.scheme else { continue }
            let tab = Tab(browser: self, configuration: makeConfiguration(for: saved.url))
            tab.restore(url: saved.url, title: saved.title)
            tab.customTitle = saved.customTitle
            tab.pinID = saved.pinID.flatMap { pinIDs.contains($0) ? $0 : nil }
            tabs.append(tab)
            extensions.didOpen(tab)
            if index == session.selectedIndex { selected = tab }
        }
        if let selected {
            selectedTabID = selected.id
            extensions.didActivate(selected, previous: nil)
        }
    }

    /// Writes the session now and again whenever a tab it describes changes.
    private func saveSession() {
        let session = withObservationTracking { self.session } onChange: { [weak self] in
            Task { @MainActor in self?.saveSession() }
        }
        guard session != savedSession else { return }
        SessionStore.save(session)
        savedSession = session
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

    func pin(_ tab: Tab) {
        guard tab.pinID == nil, let url = tab.url else { return }
        let pin = Pin(id: UUID(), url: url, title: tab.displayTitle, favicon: tab.faviconData)
        pins.append(pin)
        tab.pinID = pin.id
    }

    func pinTab(withID id: String) {
        if let tab = tabs.first(where: { $0.id.uuidString == id }) { pin(tab) }
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
              pins[index].url.host() == tab.url?.host(),
              pins[index].favicon != data else { return }
        pins[index].favicon = data
        pinIcons[pins[index].id] = nil
    }
}


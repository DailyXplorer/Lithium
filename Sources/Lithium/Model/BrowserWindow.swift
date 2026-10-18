import AppKit
import Observation
import WebKit

/// What one window shows: its selection, its space and its chrome. Everything shared between
/// windows (the tabs, favorites, spaces, history, settings) is `Browser`'s.
@MainActor
@Observable
final class BrowserWindow: Identifiable {
    typealias ID = UUID

    let id: ID
    @ObservationIgnored unowned let browser: Browser

    private(set) var selectedTabID: Tab.ID? {
        didSet {
            guard oldValue != selectedTabID else { return }
            videoPopout.selectionChanged(from: browser.tabs.first { $0.id == oldValue }, to: selectedTab)
            // The summary popover is one tab's. Here, not in its button, which a hidden Zen bar lacks.
            if isSummaryPresented { isSummaryPresented = false }
        }
    }
    var isSummaryPresented = false
    private(set) var currentSpaceID: Space.ID
    @ObservationIgnored private var spaceSelections: [Space.ID: Tab.ID] = [:]
    /// The last switch went to a space further along: the sidebar slides that way.
    @ObservationIgnored private(set) var spaceStepsForward = true
    private(set) var addressFocusToken = 0
    /// Moves only when the user picks a tab or the start page, so the peeked sidebar slides back on a
    /// pick yet stays out while tabs close or spaces switch in a row.
    private(set) var tabPickToken = 0
    /// Opens as the user last left it. Only `toggleSidebar()` saves, so a passing change such as
    /// the screenshot taking both looks never outlives the app.
    var isSidebarVisible: Bool
    /// Zen mode: the page alone, sidebar and top bar peeking from the edges. Kept apart from
    /// `isSidebarVisible`, so leaving it brings the sidebar back as it was.
    var isZenMode: Bool
    var showsSidebar: Bool { isSidebarVisible && !isZenMode }
    /// Set by the address bar as it starts and ends editing: Zen mode's top bar stays out meanwhile.
    var isEditingAddress = false
    var renamingTabID: Tab.ID? {
        didSet {
            if renamingTabID != oldValue { renameDraft = nil }
            if renamingTabID != nil, renamingFolderID != nil { renamingFolderID = nil }
        }
    }
    var renamingFolderID: TabFolder.ID? {
        didSet { if renamingFolderID != nil, renamingTabID != nil { renamingTabID = nil } }
    }
    /// The name typed so far, for whichever field shows the rename next: ⌘B swaps the peeked
    /// sidebar's field for the sidebar's own.
    @ObservationIgnored var renameDraft: String?

    let find = FindInPage()
    let suggestions = AddressSuggestions()
    let videoPopout = VideoPopout()
    let recentTabs = RecentTabs()
    @ObservationIgnored private(set) lazy var capture = ScreenCapture(window: self)

    /// The window on screen: nil in tests, and once the window closed.
    @ObservationIgnored weak var nsWindow: NSWindow?
    /// Closed as the last window: its tabs stay, and New Window or a Dock click shows it again.
    var isHidden = false
    /// `NSWindow.frameDescriptor` as last seen, saved with the session.
    private(set) var frame: String?

    /// A nil look (sidebar, Zen mode) is the one the user last left in any window.
    init(browser: Browser, id: ID = UUID(), space: Space.ID, frame: String? = nil, isSidebarVisible: Bool? = nil, isZenMode: Bool? = nil) {
        self.browser = browser
        self.id = id
        currentSpaceID = space
        self.frame = frame
        self.isSidebarVisible = isSidebarVisible ?? (UserDefaults.standard.object(forKey: Preference.sidebarVisible) as? Bool ?? true)
        self.isZenMode = isZenMode ?? UserDefaults.standard.bool(forKey: Preference.zenMode)
        videoPopout.window = self
    }

    var selectedTab: Tab? { browser.tabs.first { $0.id == selectedTabID } }
    /// The tab list of the space shown. Tabs an agent opened sit apart, in the Agent group below it.
    var regularTabs: [Tab] { browser.tabList(in: currentSpaceID, window: id) }
    var agentTabs: [Tab] { browser.agentGroup(in: currentSpaceID, window: id) }

    var isRenaming: Bool { renamingTabID != nil || renamingFolderID != nil }

    /// Something opened from a peeked panel (a rename, popover, alert, menu or drag) is still in
    /// use, so the panel stays out, as they would go with it.
    var holdsPeek: Bool {
        isRenaming || nsWindow.map(Browser.hasOpenUI(in:)) == true
    }

    func noteFrame(_ descriptor: String) {
        if frame != descriptor { frame = descriptor }
    }

    /// The selected tab, restored asleep, counts as in use from the moment it is on screen.
    func didAppear() {
        selectedTab?.markActive()
    }

    /// At launch, before the window shows: the saved selection, and the tab each other space
    /// showed last, without the wake and the bookkeeping a pick does.
    func restore(selected: Tab?, lastShown: [Tab]) {
        for tab in lastShown { spaceSelections[tab.spaceID] = tab.id }
        guard let selected else { return }
        currentSpaceID = selected.spaceID
        selectedTabID = selected.id
    }

    /// For the session: the tab a space other than the one shown would show again.
    func lastShownTab(in space: Space.ID) -> Tab.ID? {
        space == currentSpaceID ? nil : spaceSelections[space]
    }

    // MARK: Selection

    /// Only this window's tabs: a page shown in two windows draws in one of them only.
    func select(_ tab: Tab, picked: Bool = true) {
        guard tab.windowID == id else { return }
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
        if tab.spaceID != currentSpaceID, browser.spaces.contains(where: { $0.id == tab.spaceID }) { enterSpace(tab.spaceID) }
        selectedTabID = tab.id
        tab.markActive()
        // In split view the other side comes on screen too, maybe from another split: its pane
        // is reused, so it doesn't wake as it appears.
        shownPartner?.markActive()
        browser.extensions.didSelect(tab)
    }

    /// A split's sidebar row: the pair already shown keeps its focused side, as ⌘1…⌘9 does.
    func selectSplit(showing first: Tab) {
        if let selectedTab, browser.split(of: first)?.contains(selectedTab.id) == true { return select(selectedTab) }
        select(first)
    }

    func newTabFocusingAddress() {
        showStartPage()
        requestAddressFocus()
    }

    func showStartPage(picked: Bool = true) {
        find.hide()
        // Left for the address bar: it counts as used until now, as does the other side of its split.
        selectedTab?.markActive()
        shownPartner?.markActive()
        if picked, selectedTabID != nil { tabPickToken &+= 1 }
        selectedTabID = nil
    }

    /// The selection falls back on the closing tab's group (`order`), never on a favorite. A tab
    /// the user went to straight from its opener, and left for no other, goes back to its opener;
    /// one `goingBack` shows again what it was opened over.
    func selectAfterClosing(_ tab: Tab, partner: Tab?, among order: [Tab], goingBack: Bool) {
        // As `select` does: left open, the bar would search the tab shown next.
        find.hide()
        let position = order.firstIndex { $0 === tab } ?? 0
        let remaining = order.filter { $0 !== tab }
        // A link's page that opened it may have been taken into another window since: it stays there.
        let opener = recentTabs.opener(returningFrom: tab).flatMap { opener in browser.tabs.contains { $0 === opener && $0.windowID == id } ? opener : nil }
        if partner == nil, goingBack, let before = recentTabs.shownBefore(tab),
           before.map({ id in browser.tabs.contains { $0.id == id && $0 !== tab && $0.spaceID == tab.spaceID && $0.windowID == self.id } }) ?? true {
            selectedTabID = before
        } else {
            selectedTabID = partner?.id ?? opener?.id ?? (remaining.isEmpty ? (tab.isInAgentGroup ? browser.tabList(in: tab.spaceID, window: id).last?.id : nil)
                : remaining[min(position, remaining.count - 1)].id)
        }
        // The tab shown next may be asleep. As `select` does, the user now sees its page: a
        // favorite's dot left by a notification while its popup was in front goes. Not while the
        // window isn't key: `Browser.windowBecameKey` clears it when the user looks.
        selectedTab?.markActive()
        if nsWindow?.isKeyWindow != false { selectedTab?.didOpen() }
        if let selectedTab { recentTabs.didShow(selectedTab, after: nil) }
    }

    func closeSelectedTab() {
        if let tab = selectedTab { browser.close(tab) }
    }

    func togglePinForSelectedTab() {
        guard let tab = selectedTab else { return }
        if let pin = browser.pins.first(where: { $0.id == tab.pinID }) { browser.unpin(pin, keepingPageIn: self) } else { browser.pin(tab) }
    }

    func selectAdjacentTab(_ offset: Int) {
        let order = browser.navigationOrder(in: currentSpaceID, window: id)
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
        recentTabs.step(backward: backward, among: browser.navigationOrder(in: currentSpaceID, window: id), current: selectedTab)
        if holdingControl {
            recentTabs.watchControl { [weak self] in self?.endTabCycle(commit: $0) }
        } else {
            endTabCycle(commit: true)
        }
    }

    func endTabCycle(commit: Bool) {
        guard let tab = recentTabs.endCycle(), commit, browser.tabs.contains(where: { $0 === tab }) else { return }
        select(tab)
    }

    /// ⌘1…⌘9 walk the favorites grid, then the rows as the sidebar shows them: a split pair is
    /// one row. Folder headers and the tabs of a collapsed folder have none.
    func selectItem(at index: Int) {
        let rows = tabListRows.compactMap(\.entry?.tab) + agentTabs
        let pins = spacePins
        if index < pins.count {
            browser.activate(pins[index], in: self)
        } else if index - pins.count < rows.count {
            let tab = rows[index - pins.count]
            // The pair already shown keeps its focused side.
            if let selectedTab, browser.split(of: tab)?.contains(selectedTab.id) == true { return }
            select(tab)
        }
    }

    /// The tab list outside folders has no drag order of its own: a tab already there stays, as
    /// one dropped among the Agent group does.
    func dropTab(_ items: [String], on target: Browser.TabDropTarget) -> Bool {
        browser.endTabDrag()
        guard let tab = (regularTabs + agentTabs).first(where: { $0.id.uuidString == items.first }) else { return false }
        switch target {
        case .tabList(let index):
            guard tab.isInAgentGroup || tab.folderID != nil else { return false }
            browser.moveTab(tab, toFolder: nil, at: index)
        case .folder(let id, let index):
            guard browser.folderExists(id, in: tab.spaceID) else { return false }
            browser.moveTab(tab, toFolder: id, at: index)
        case .agentGroup:
            return false
        }
        return true
    }

    // MARK: Spaces

    /// An edit in the address bar or a tab's name ends first: its field would be left editing a
    /// tab no longer shown. Not a pick (`tabPickToken`).
    func switchToSpace(_ space: Space.ID) {
        guard space != currentSpaceID, browser.spaces.contains(where: { $0.id == space }) else { return }
        if isEditingAddress || isRenaming { nsWindow?.makeFirstResponder(nil) }
        renamingTabID = nil
        renamingFolderID = nil
        let order = browser.spaces.map(\.id)
        spaceStepsForward = (order.firstIndex(of: space) ?? 0) > (order.firstIndex(of: currentSpaceID) ?? 0)
        // The tab last shown there may have moved to another window since.
        if let last = spaceSelections[space], let tab = browser.tabs.first(where: { $0.id == last && $0.spaceID == space && $0.windowID == id }) {
            tab.didOpen()
            select(tab, picked: false)
        } else {
            enterSpace(space)
            showStartPage(picked: false)
        }
    }

    private func enterSpace(_ space: Space.ID) {
        spaceSelections[currentSpaceID] = selectedTabID
        currentSpaceID = space
    }

    // MARK: Address bar

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
            browser.navigate(tab, .open(url))
        } else {
            browser.newTab(url: url, in: self)
        }
    }

    func addressTextChanged(_ text: String) {
        let edited = suggestions.editedTabID.flatMap { id in browser.tabs.first { $0.id == id } }
        // A space keeping its cookies apart is kept out of the others' suggestions, and they out of
        // its: their titles and addresses are another identity's. Another window's tabs are its own:
        // a favorite open there opens its own page here.
        let (current, apart) = (currentSpaceID, Set(browser.spaces.filter(\.separatesData).map(\.id)))
        let shown = { (space: Space.ID) in space == current || !apart.contains(space) && !apart.contains(current) }
        suggestions.update(query: text, tabs: browser.tabs.filter { $0.windowID == id && shown($0.spaceID) }, pins: browser.pins.filter { shown($0.space) },
                           history: browser.history, actions: barActions(for: edited))
    }

    func submitAddress(_ text: String) {
        submitAddress(text, editing: selectedTabID)
    }

    /// Goes to `tabID`, the tab shown when editing began, even if the selection moved on its own
    /// since; to a new tab once that one is gone.
    func submitAddress(_ text: String, editing tabID: Tab.ID?) {
        let tab = tabID.flatMap { id in browser.tabs.first { $0.id == id } }
        if let suggestion = suggestions.selected, suggestions.selectedIndex > 0 {
            accept(suggestion, in: tab)
        } else {
            open(text, in: tab)
        }
        suggestions.clear()
    }

    /// A click on a row: to the tab being edited, as Return sends it (`submitAddress(_:editing:)`).
    func accept(_ suggestion: Suggestion) {
        accept(suggestion, in: suggestions.editedTabID.flatMap { id in browser.tabs.first { $0.id == id } })
    }

    private func accept(_ suggestion: Suggestion, in tab: Tab?) {
        suggestions.clear()
        switch suggestion {
        case .search(let query): open(query, in: tab)
        case .address(let url), .history(_, let url): open(url, in: tab)
        case .openTab(let id, _, _): if let tab = browser.tabs.first(where: { $0.id == id }) { browser.select(tab) }
        case .pin(let id, _, _): if let pin = browser.pins.first(where: { $0.id == id }) { browser.activate(pin, in: self) }
        case .action(let action): perform(action, on: tab)
        }
    }

    func requestAddressFocus() {
        addressFocusToken &+= 1
    }

    /// The menu's New Tab and Open Location: the window comes forward first, or from a link's
    /// window the keys typed next would go on to the link's page.
    func focusAddressFromMenu(newTab: Bool) {
        nsWindow?.makeKeyAndOrderFront(nil)
        if newTab { newTabFocusingAddress() } else { requestAddressFocus() }
    }

    // MARK: Chrome

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
        if isEditingAddress { nsWindow?.makeFirstResponder(nil) }
        isZenMode.toggle()
        UserDefaults.standard.set(isZenMode, forKey: Preference.zenMode)
    }

    func returnKeyboardToPage(fieldHadKeyboard: Bool) {
        browser.returnKeyboardToPage(to: selectedTab, fieldHadKeyboard: fieldHadKeyboard)
    }

    /// `pageDeclined`: the Escape came back from a page that had the keyboard and didn't handle it.
    func dismissOverlay(pageDeclined: Bool = false) -> Bool {
        if recentTabs.target != nil {
            endTabCycle(commit: false)
            return true
        }
        if isRenaming {
            renamingTabID = nil
            renamingFolderID = nil
            // The name field, when a field has it: Escape comes here only for find's or that one.
            let nameHadKeyboard = (selectedTab?.contentView.window?.firstResponder as? NSTextView)?.isFieldEditor == true
            returnKeyboardToPage(fieldHadKeyboard: nameHadKeyboard && !find.isFieldFocused)
            return true
        }
        if closeFindBar() { return true }
        // Opened with ⇧⌘S, the popover never takes the keyboard, so Escape reaches the window.
        if isSummaryPresented {
            isSummaryPresented = false
            return true
        }
        // The page has the keyboard: its menu or dialog gets the Escape first, the prompts only if it declines.
        guard pageDeclined || !(selectedTab?.contentView.window?.firstResponder is WKWebView) else { return false }
        // The shown permission prompt, denied this once and not remembered. Not under an agent's
        // banner, whose Deny Escape triggers.
        if browser.agent?.confirmations.front(selected: selectedTabID) == nil,
           let request = shownPermissionRequest {
            browser.permissions.dismiss(request)
            return true
        }
        if browser.agent?.confirmations.front(selected: selectedTabID) == nil,
           let request = shownAppLinkRequest {
            browser.appLinks.answer(request, open: false)
            return true
        }
        if browser.agent?.confirmations.front(selected: selectedTabID) == nil,
           let request = shownPasswordSave {
            browser.passwords.answer(request, .notNow)
            return true
        }
        return false
    }

    func toggleSummary() {
        guard let tab = selectedTab else { return }
        isSummaryPresented.toggle()
        // Read now: the task runs later, and `browser` is unowned.
        let summaries = browser.summaries
        if isSummaryPresented { Task { await summaries.summarize(tab) } }
    }

    // MARK: Find

    func toggleFind() {
        if findBarIsInFront {
            find.hide()
            returnKeyboardToPage(fieldHadKeyboard: true)
        } else if selectedTab != nil {
            find.show()
        }
    }

    func findStep(forward: Bool) async {
        guard let tab = selectedTab else { return }
        find.show(focusingField: false)
        await find.step(forward: forward, in: tab.findTarget)
    }

    func useSelectionForFind() async {
        guard let tab = selectedTab else { return }
        await find.useSelection(in: tab.findTarget)
    }

    /// Over the selected tab only: in split view, the focused side's.
    func showsFindBar(over tab: Tab) -> Bool {
        find.isVisible && selectedTab === tab
    }

    var findBarIsInFront: Bool { selectedTab.map(showsFindBar(over:)) ?? false }

    /// Not while the page has the keyboard: the Escape is the page's, and the bar stays open.
    private func closeFindBar() -> Bool {
        guard findBarIsInFront, !(selectedTab?.contentView.window?.firstResponder is WKWebView) else { return false }
        let hadKeyboard = find.isFieldFocused
        find.hide()
        returnKeyboardToPage(fieldHadKeyboard: hadKeyboard)
        return true
    }
}

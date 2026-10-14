import AppKit

/// The first window's state, as the views, the menu, agents and tests read it from `Browser`
/// until they read their `BrowserWindow`. Deleted with that migration.
extension Browser {
    private var first: BrowserWindow { windows[0] }

    var selectedTabID: Tab.ID? { first.selectedTabID }
    var selectedTab: Tab? { first.selectedTab }
    var currentSpaceID: Space.ID { first.currentSpaceID }
    var currentSpace: Space { first.currentSpace }
    var spaceStepsForward: Bool { first.spaceStepsForward }
    var isSidebarVisible: Bool {
        get { first.isSidebarVisible }
        set { first.isSidebarVisible = newValue }
    }
    var isZenMode: Bool {
        get { first.isZenMode }
        set { first.isZenMode = newValue }
    }
    var showsSidebar: Bool { first.showsSidebar }
    var isEditingAddress: Bool {
        get { first.isEditingAddress }
        set { first.isEditingAddress = newValue }
    }
    var renamingTabID: Tab.ID? {
        get { first.renamingTabID }
        set { first.renamingTabID = newValue }
    }
    var renameDraft: String? {
        get { first.renameDraft }
        set { first.renameDraft = newValue }
    }
    var addressFocusToken: Int { first.addressFocusToken }
    var tabPickToken: Int { first.tabPickToken }
    var find: FindInPage { first.find }
    var suggestions: AddressSuggestions { first.suggestions }
    var videoPopout: VideoPopout { first.videoPopout }
    var recentTabs: RecentTabs { first.recentTabs }
    var capture: ScreenCapture { first.capture }
    var holdsPeek: Bool { first.holdsPeek }
    var isRenaming: Bool { first.isRenaming }
    var regularTabs: [Tab] { first.regularTabs }
    var agentTabs: [Tab] { first.agentTabs }
    var tabListEntries: [TabListEntry] { first.tabListEntries }
    var tabListRows: [TabListRow] { first.tabListRows }
    var spacePins: [Pin] { first.spacePins }
    var spaceFolders: [TabFolder] { first.spaceFolders }
    var shownPartner: Tab? { first.shownPartner }
    var shownPermissionRequest: PermissionRequest? { first.shownPermissionRequest }
    var shownAppLinkRequest: AppLinkRequest? { first.shownAppLinkRequest }
    var window: NSWindow? {
        get { first.nsWindow }
        set { first.nsWindow = newValue }
    }

    func tabList(in space: Space.ID, folder: TabFolder.ID?) -> [Tab] { tabList(in: space, window: first.id, folder: folder) }
    func splitPartner(for tab: Tab) -> Tab? { first.splitPartner(for: tab) }
    func dropForSplit(_ item: String, on side: TabSplit.Side) -> Bool { first.dropForSplit(item, on: side) }
    func dropTab(_ items: [String], on target: TabDropTarget) -> Bool { first.dropTab(items, on: target) }
    func newTabFocusingAddress() { first.newTabFocusingAddress() }
    func focusAddressFromMenu(newTab: Bool) { first.focusAddressFromMenu(newTab: newTab) }
    func requestAddressFocus() { first.requestAddressFocus() }
    func switchToSpace(_ id: Space.ID) { first.switchToSpace(id) }
    func switchToSpace(at index: Int) { first.switchToSpace(at: index) }
    func switchSpace(by offset: Int) { first.switchSpace(by: offset) }
    func toggleSidebar() { first.toggleSidebar() }
    func toggleZenMode() { first.toggleZenMode() }
    func closeSelectedTab() { first.closeSelectedTab() }
    func selectAdjacentTab(_ offset: Int) { first.selectAdjacentTab(offset) }
    func cycleRecentTabs(backward: Bool, holdingControl: Bool = NSEvent.modifierFlags.contains(.control)) {
        first.cycleRecentTabs(backward: backward, holdingControl: holdingControl)
    }
    func endTabCycle(commit: Bool) { first.endTabCycle(commit: commit) }
    func selectItem(at index: Int) { first.selectItem(at: index) }
    func togglePinForSelectedTab() { first.togglePinForSelectedTab() }
    func submitAddress(_ text: String) { first.submitAddress(text) }
    func submitAddress(_ text: String, editing tabID: Tab.ID?) { first.submitAddress(text, editing: tabID) }
    func addressTextChanged(_ text: String) { first.addressTextChanged(text) }
    func accept(_ suggestion: Suggestion) { first.accept(suggestion) }
    func open(_ input: String) { first.open(input) }
    func selectSplit(showing tab: Tab) { first.selectSplit(showing: tab) }
    func returnKeyboardToPage(fieldHadKeyboard: Bool) { first.returnKeyboardToPage(fieldHadKeyboard: fieldHadKeyboard) }
    func barActions(for tab: Tab?) -> [BarAction] { first.barActions(for: tab) }
    func perform(_ action: BarAction, on tab: Tab?) { first.perform(action, on: tab) }
    func showsFindBar(over tab: Tab) -> Bool { findBar(over: tab) != nil }
    func windowDidAppear() {
        windowsDidShow()
        first.didAppear()
    }
    func windowDidBecomeKey() { windowBecameKey(first) }

    func inMainWindow(open: () -> Void, _ command: () -> Void) {
        if let window, window.isVisible || window.isMiniaturized {
            if window.isMiniaturized || !canChangeTabs {
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
            }
        } else {
            open()
        }
        command()
    }
}

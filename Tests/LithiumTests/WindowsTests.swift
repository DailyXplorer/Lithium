import AppKit
import Testing
import WebKit
@testable import Lithium

/// Browser windows: each with its own tabs and space, all sharing one `Browser`. No window reaches
/// the screen (`Browser.showWindow` opens none under tests). A whole Browser keeps its data in the
/// home folder, so this suite only runs in a throwaway one: `scripts/test --filter WindowsTests`.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct WindowsTests {
    /// New Window opens on the start page, the address bar focused, in the space of the window in front.
    @Test func aNewWindowOpensOnTheStartPageInTheSameSpace() {
        let browser = makeBrowser()
        defer { reset(browser) }
        let first = browser.windows[0]
        browser.newTab(url: page("a"))
        var work = browser.newSpaceDraft()
        work.name = "Work"
        browser.addSpace(work, in: first)
        browser.windowBecameKey(first)

        let second = browser.openWindow()
        #expect(browser.windows.map(\.id) == [first.id, second.id])
        #expect(second.selectedTab == nil)
        #expect(second.regularTabs.isEmpty)
        #expect(second.currentSpaceID == work.id)
        #expect(second.addressFocusToken == 1)
        #expect(second.isHidden == false)
        first.switchToSpace(Space.mainID)
        #expect(first.selectedTab?.url == page("a"), "the first window keeps its tab")
    }

    /// Each window lists and selects its own tabs; Next Tab, Close Tab and the tab list stay in it.
    @Test func tabsAreTheirWindowsOwn() throws {
        let browser = makeBrowser()
        defer { reset(browser) }
        let first = browser.windows[0]
        let a = browser.newTab(url: page("a"))
        let second = browser.openWindow()
        let b = browser.newTab(url: page("b"), in: second)
        let c = browser.newTab(url: page("c"), in: second)

        #expect(first.regularTabs.map(\.url) == [page("a")])
        #expect(second.regularTabs.map(\.url) == [page("c"), page("b")])
        #expect(browser.tabs.count == 3)
        #expect(browser.window(of: b) === second)
        #expect(browser.window(of: a) === first)
        #expect(first.selectedTab === a)
        #expect(second.selectedTab === c)
        #expect(browser.isShown(a) && browser.isShown(c) && !browser.isShown(b))
        #expect(browser.navigationOrder.map(\.url) == [page("a"), page("c"), page("b")], "window after window")
        #expect(!first.dropForSplit(c.id.uuidString, on: .second), "another window's tab doesn't pair, so the drop isn't taken")
        #expect(browser.splits.pairs.isEmpty)

        second.selectAdjacentTab(1)
        #expect(second.selectedTab === b)
        #expect(first.selectedTab === a, "the other window's selection stays")

        second.closeSelectedTab()
        #expect(second.regularTabs.map(\.url) == [page("c")])
        #expect(first.regularTabs.map(\.url) == [page("a")])
        #expect(browser.canReopenClosedTab)

        // A tab's own commands act in its window.
        browser.closeOtherTabs(than: a)
        #expect(browser.tabs.count == 2, "the other window's tabs aren't the first's others")
        _ = try #require(browser.tabs.first { $0 === c })
    }

    /// Closing a window puts its tabs into Reopen Closed Tab, bottom up, so ⇧⌘T brings them back
    /// top down into the window it is pressed in. Closing the only window keeps its tabs for the
    /// next New Window or Dock click, which shows that window again.
    @Test func closingAWindowRemembersItsTabsAndTheLastOneKeepsThem() {
        let browser = makeBrowser()
        defer { reset(browser) }
        let first = browser.windows[0]
        browser.newTab(url: page("a"))
        let second = browser.openWindow()
        browser.newTab(url: page("b1"), in: second)
        browser.newTab(url: page("b2"), in: second)
        browser.windowBecameKey(second)
        #expect(browser.commandWindow === second)

        browser.windowWillClose(second)
        #expect(browser.windows.map(\.id) == [first.id])
        #expect(browser.tabs.count == 1)
        #expect(first.regularTabs.map(\.url) == [page("a")])
        #expect(browser.commandWindow === first)
        #expect(browser.canReopenClosedTab)
        browser.reopenClosedTab(into: first)
        browser.reopenClosedTab(into: first)
        #expect(first.regularTabs.map(\.url) == [page("b2"), page("b1"), page("a")])
        #expect(!browser.canReopenClosedTab)

        browser.windowWillClose(first)
        #expect(browser.windows.count == 1)
        #expect(first.isHidden)
        #expect(first.nsWindow == nil)
        #expect(browser.tabs.count == 3, "the last window's tabs stay")
        #expect(browser.openWindow() === first, "shown again, with its tabs")
        #expect(!first.isHidden)
        #expect(browser.windows.count == 1)
    }

    /// ⌘W in a window with no tab left closes the window, as in Safari and Chrome: one of two
    /// goes, the last one hides. On the start page with tabs still in the window, it does nothing.
    @Test func commandWInAWindowWithNoTabClosesIt() {
        let browser = makeBrowser()
        defer { reset(browser) }
        browser.showWindow = { window, browser in ClosableWindow(window, browser: browser) }
        let first = browser.windows[0]
        first.nsWindow = ClosableWindow(first, browser: browser)
        let a = browser.newTab(url: page("a"))
        let second = browser.openWindow()
        browser.newTab(url: page("b"), in: second)

        first.newTabFocusingAddress()
        browser.closeTabOrWindow(keyWindow: first.nsWindow)
        #expect(browser.windows.map(\.id) == [first.id, second.id], "the start page over a tab keeps its window")
        #expect(!first.isHidden)
        #expect(first.regularTabs.map(\.id) == [a.id])
        first.select(a)

        browser.closeTabOrWindow(keyWindow: second.nsWindow)
        #expect(second.selectedTab == nil)
        #expect(browser.windows.count == 2, "the tab closes first")
        browser.closeTabOrWindow(keyWindow: second.nsWindow)
        #expect(browser.windows.map(\.id) == [first.id])
        #expect(browser.canReopenClosedTab)

        browser.closeTabOrWindow(keyWindow: first.nsWindow)
        #expect(first.selectedTab == nil)
        #expect(!first.isHidden)
        browser.closeTabOrWindow(keyWindow: first.nsWindow)
        #expect(first.isHidden)
        #expect(browser.windows.count == 1)
    }

    /// Close Tabs on deleting a folder closes only the tabs the acting window showed in it; another
    /// window's stay, out of the folder, where it was.
    @Test func deletingAFolderClosesOnlyTheActingWindowsTabs() {
        let browser = makeBrowser()
        defer { reset(browser) }
        let first = browser.windows[0]
        let a = browser.newTab(url: page("a"))
        let second = browser.openWindow()
        let b1 = browser.newTab(url: page("b1"), in: second)
        let b2 = browser.newTab(url: page("b2"), in: second)
        let folder = browser.newFolder(with: a)
        browser.moveTab(b1, toFolder: folder.id)

        browser.deleteFolder(folder.id, closingTabs: true, in: first)
        #expect(browser.folders.all.isEmpty)
        #expect(first.regularTabs.isEmpty)
        #expect(second.regularTabs.map(\.id) == [b1.id, b2.id])
        #expect(b1.folderID == nil)
        #expect(second.selectedTab === b2)
    }

    /// A tab an agent or a page opens for a window that closed while it awaited goes into the
    /// window in front, not into no window's list.
    @Test func aTabForAClosedWindowGoesToTheWindowInFront() {
        let browser = makeBrowser()
        defer { reset(browser) }
        let first = browser.windows[0]
        let second = browser.openWindow()
        browser.windowWillClose(second)

        let agentTab = browser.newAgentTab(session: "s", window: second.id)
        #expect(agentTab.windowID == first.id)
        #expect(first.agentTabs.contains { $0 === agentTab })
        let tab = browser.newTab(url: page("c"), in: second)
        #expect(tab.windowID == first.id)
        #expect(first.selectedTab === tab)
    }

    /// The session saves every window with its tabs, selection, space and look, and brings them back.
    @Test func theSessionRoundTripsTwoWindows() {
        let browser = makeBrowser()
        defer { reset(browser) }
        let first = browser.windows[0]
        browser.newTab(url: page("a"))
        let second = browser.openWindow()
        browser.newTab(url: page("b"), in: second)
        var work = browser.newSpaceDraft()
        work.name = "Work"
        browser.addSpace(work, in: second)
        browser.newTab(url: page("w"), in: second)
        first.isZenMode = true
        second.noteFrame("100 100 900 700 0 0 1440 877 ")
        browser.saveNow()

        let saved = SessionStore.load()
        #expect(saved.windows?.map(\.id) == [first.id, second.id])
        #expect(saved.tabs.filter { $0.windowID == nil }.map(\.url) == [page("a")], "the first window's tabs name no window")
        #expect(saved.tabs.filter { $0.windowID == second.id }.map(\.url) == [page("w"), page("b")])
        #expect(saved.windows?[1].frame == "100 100 900 700 0 0 1440 877 ")

        let again = Browser()
        defer { reset(again) }
        #expect(again.windows.map(\.id) == [first.id, second.id])
        #expect(again.windows[0].regularTabs.map(\.url) == [page("a")])
        #expect(again.windows[0].selectedTab?.url == page("a"))
        #expect(again.windows[0].currentSpaceID == Space.mainID)
        #expect(again.windows[0].isZenMode)
        #expect(again.windows[1].currentSpaceID == work.id)
        #expect(again.windows[1].regularTabs.map(\.url) == [page("w")])
        #expect(again.windows[1].selectedTab?.url == page("w"))
        #expect(again.windows[1].isZenMode == false)
        #expect(again.windows[1].frame == "100 100 900 700 0 0 1440 877 ")
        again.windows[1].switchToSpace(Space.mainID)
        #expect(again.windows[1].regularTabs.map(\.url) == [page("b")])
    }

    /// An agent's `tab_select` or an extension's activate shows the tab in its window but leaves
    /// the window in front, and the keys, where they are. The user's pick brings the window
    /// forward, out of the Dock if minimized.
    @Test func onlyTheUsersPickBringsAnotherWindowForward() {
        let browser = makeBrowser()
        defer { reset(browser) }
        let first = browser.windows[0]
        browser.newTab(url: page("a"))
        let second = browser.openWindow()
        let b = browser.newTab(url: page("b"), in: second)
        let c = browser.newTab(url: page("c"), in: second)
        let nsWindow = FrontingWindow(contentRect: NSRect(x: -30000, y: -30000, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
        second.nsWindow = nsWindow
        browser.windowBecameKey(first)

        browser.select(b, picked: false)
        #expect(second.selectedTab === b)
        #expect(nsWindow.frontings == 0)
        #expect(browser.commandWindow === first)

        nsWindow.minimized = true
        browser.select(c)
        #expect(second.selectedTab === c)
        #expect(nsWindow.frontings == 1)
        #expect(!nsWindow.minimized, "out of the Dock")
    }

    /// The window minimized from the front comes back from the Dock, though the other took the key
    /// meanwhile; once the user is in the other, a Dock click leaves the minimized one be.
    @Test func aDockClickRestoresTheWindowLastActive() {
        let browser = makeBrowser()
        defer { reset(browser) }
        let first = browser.windows[0]
        let second = browser.openWindow()
        let firstNS = FrontingWindow(contentRect: NSRect(x: -30000, y: -30000, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
        let secondNS = FrontingWindow(contentRect: NSRect(x: -30000, y: -30000, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
        first.nsWindow = firstNS
        second.nsWindow = secondNS
        browser.windowBecameKey(first)

        // The minimize calls AppKit makes on the real window's delegate, in order; never shown.
        let minimizing = BrowserNSWindow(first, browser: browser)
        minimizing.windowWillMiniaturize(Notification(name: NSWindow.willMiniaturizeNotification, object: minimizing))
        firstNS.minimized = true
        browser.windowBecameKey(second)
        minimizing.windowDidMiniaturize(Notification(name: NSWindow.didMiniaturizeNotification, object: minimizing))
        #expect(browser.commandWindow === second, "menu commands go to the window on screen")
        browser.reopenFromDock()
        #expect(!firstNS.minimized, "out of the Dock")
        #expect(firstNS.frontings == 1)

        browser.windowBecameKey(second)
        firstNS.minimized = true
        browser.reopenFromDock()
        #expect(firstNS.minimized)
        #expect(browser.windows.count == 2, "no new window")
    }

    /// The last window closed stays hidden while a link's window is on screen, as before; with no
    /// window left, the Dock shows it again.
    @Test func aDockClickShowsTheLastWindowClosedUnlessALinksWindowIsUp() throws {
        let browser = makeBrowser()
        defer { reset(browser) }
        browser.quickLinks.showWindow = { _, _ in ShownWindow(contentRect: NSRect(x: -30000, y: -30000, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: true) }
        let first = browser.windows[0]
        let link = try #require(browser.quickLinks.open())
        browser.windowWillClose(first)
        #expect(first.isHidden)

        browser.reopenFromDock()
        #expect(first.isHidden, "Lithium only comes forward")

        browser.quickLinks.windowClosed(link)
        browser.reopenFromDock()
        #expect(!first.isHidden)
        #expect(browser.windows.count == 1)
    }

    /// Extensions see one window: its active tab is the selected tab of the window in front, and a
    /// selection in a window behind waits until that window comes forward.
    @Test func extensionsActiveTabIsTheWindowInFronts() {
        let browser = makeBrowser()
        defer { reset(browser) }
        let first = browser.windows[0]
        let a = browser.newTab(url: page("a"))
        let second = browser.openWindow()
        browser.windowBecameKey(first)
        let b = browser.newTab(url: page("b"), in: second)
        #expect(browser.extensions.activeTab === a, "a tab opened behind isn't the active one")

        browser.windowBecameKey(second)
        #expect(browser.extensions.activeTab === b)
        browser.windowBecameKey(first)
        #expect(browser.extensions.activeTab === a)
    }

    /// The summary popover and a folder's name field are one window's: ⇧⌘S in one window leaves
    /// the other's closed, a tab picked in the other window keeps it, and a folder made in one
    /// window takes its name there, in place of a tab's rename.
    @Test func theSummaryAndARenameAreTheirWindowsOwn() {
        let browser = makeBrowser()
        defer { reset(browser) }
        let first = browser.windows[0]
        browser.newTab(url: page("a"))
        let second = browser.openWindow()
        let b = browser.newTab(url: page("b"), in: second)
        let c = browser.newTab(url: page("c"), in: second)

        first.toggleSummary()
        #expect(first.isSummaryPresented)
        #expect(!second.isSummaryPresented)
        browser.select(b, picked: false)
        #expect(first.isSummaryPresented, "a pick in the other window leaves it")
        browser.newTab(url: page("a2"))
        #expect(!first.isSummaryPresented, "a pick in its window closes it")
        second.toggleSummary()
        #expect(second.isSummaryPresented && !first.isSummaryPresented)
        browser.setSummaries(enabled: false)
        defer { browser.setSummaries(enabled: true) }
        #expect(!second.isSummaryPresented)

        let folder = browser.newFolder(in: second)
        #expect(second.renamingFolderID == folder.id)
        #expect(second.isRenaming)
        #expect(first.renamingFolderID == nil)
        #expect(!first.isRenaming)
        second.renamingTabID = c.id
        #expect(second.renamingFolderID == nil, "one name is typed at a time")
        second.renamingFolderID = folder.id
        #expect(second.renamingTabID == nil)
        browser.renameFolder(folder.id, to: "Work")
        #expect(second.renamingFolderID == nil)
        #expect(!second.isRenaming)
    }

    /// Every window shows the same favorites, but a favorite has one page. Picked in the second
    /// window, that page comes into it, and the first goes on to its own tab: before, the first
    /// window came forward with the page, so the second only drove the first.
    @Test func aFavoritePickedInTheOtherWindowComesIntoIt() throws {
        let browser = makeBrowser()
        defer { reset(browser) }
        let first = browser.windows[0]
        let a = restored(browser, "a")
        let favorite = restored(browser, "favorite")
        browser.pin(favorite)
        let pin = try #require(browser.pins.first)
        browser.activate(pin, in: first)
        #expect(first.selectedTab === favorite)
        let second = browser.openWindow()
        browser.windowBecameKey(second)

        browser.activate(pin, in: second)
        #expect(second.selectedTab === favorite)
        #expect(browser.window(of: favorite) === second)
        #expect(first.selectedTab === a)
        #expect(browser.liveTab(for: pin) === favorite, "the same page, not a second one")
        #expect(browser.tabs.count == 2)
        #expect(browser.navigationOrder(in: Space.mainID, window: first.id).map(\.id) == [a.id])
    }

    /// Move to This Window takes the tab itself, its web view and folder kept, to the top of this
    /// window's list and shows it; the window it leaves goes on as after a close, out of its split.
    @Test func moveToThisWindowTakesTheSameTab() throws {
        let browser = makeBrowser()
        defer { reset(browser) }
        let first = browser.windows[0]
        let a = restored(browser, "a")
        first.select(a)
        let second = browser.openWindow()
        let b1 = restored(browser, "b1", in: second)
        let b2 = restored(browser, "b2", in: second)
        let folder = browser.newFolder(with: b2)
        browser.moveTab(b1, toFolder: folder.id)
        #expect(browser.pair(b2, with: b1, on: .second))
        #expect(second.selectedTab === b2)
        let webView = b2.webView

        browser.move(b2, to: first)
        #expect(first.selectedTab === b2)
        #expect(b2.webView === webView, "the same page, not a reload")
        #expect(b2.folderID == folder.id)
        #expect(first.regularTabs.map(\.id) == [b2.id, a.id])
        #expect(second.regularTabs.map(\.id) == [b1.id])
        #expect(second.selectedTab === b1, "its split partner fills the window")
        #expect(browser.split(of: b1) == nil)
        #expect(browser.tabs.count == 3)

        browser.move(b2, to: first)
        #expect(first.regularTabs.map(\.id) == [b2.id, a.id], "already there, it stays")
    }

    /// A tab moved to the other window is no longer its old window's: closing the tab it opened
    /// there, or going back to the space it was last shown in, doesn't select it in the old window,
    /// which would take its page from the window it is in.
    @Test func aTabMovedAwayIsNotSelectedAgainInItsOldWindow() {
        let browser = makeBrowser()
        defer { reset(browser) }
        let first = browser.windows[0]
        let a = restored(browser, "a")
        let opener = browser.newTab(url: page("opener"))
        browser.newTab(url: page("opened"), openedFrom: opener)
        let second = browser.openWindow()

        browser.move(opener, to: second)
        first.closeSelectedTab()
        #expect(first.selectedTab === a, "not its opener, now in the other window")
        #expect(second.selectedTab === opener)

        var work = browser.newSpaceDraft()
        work.name = "Work"
        browser.addSpace(work, in: first)
        let w = browser.newTab(url: page("w"), in: first)
        first.switchToSpace(Space.mainID)
        browser.move(w, to: second)
        first.switchToSpace(work.id)
        #expect(first.selectedTab == nil, "the start page, not the tab moved away")
        #expect(second.selectedTab === w)
    }

    /// The last window closed hides with its tabs: their media pauses, its page counts as off
    /// screen so it can sleep, and the page and tab commands are off until the window shows again.
    @Test func theLastWindowClosedPausesItsTabsAndTakesNoCommands() {
        let browser = makeBrowser()
        defer { reset(browser) }
        let first = browser.windows[0]
        let a = browser.newTab(url: page("a"))
        let b = browser.newTab(url: page("b"))
        let mine = Set([a.id, b.id])
        var paused: Set<Lithium.Tab.ID> = []
        browser.nowPlaying.pause = { if mine.contains($0.id) { paused.insert($0.id) } }
        #expect(browser.isShown(b) && browser.commandTab === b && browser.canChangeTabs)

        browser.windowWillClose(first)
        #expect(paused == mine)
        #expect(!browser.isShown(b))
        #expect(browser.commandTab == nil)
        #expect(!browser.canChangeTabs)

        #expect(browser.openWindow() === first)
        #expect(browser.isShown(b) && browser.commandTab === b && browser.canChangeTabs)
    }

    /// Each window's sidebar lists every other window's tabs in that window's order, live, under
    /// "Other window", numbered once there are several; none with one window.
    @Test func otherWindowSectionsListTheOtherWindowsTabs() throws {
        let browser = makeBrowser()
        defer { reset(browser) }
        let first = browser.windows[0]
        let a = restored(browser, "a")
        #expect(first.otherWindowSections.isEmpty)

        let second = browser.openWindow()
        let b1 = restored(browser, "b1", in: second)
        let sections = first.otherWindowSections
        #expect(sections.map(\.title) == ["Other window"])
        #expect(sections.first?.id == second.id)
        #expect(sections.first?.tabs.map(\.id) == [b1.id])
        #expect(second.otherWindowSections.first?.tabs.map(\.id) == [a.id])
        let b2 = restored(browser, "b2", in: second)
        #expect(first.otherWindowSections.first?.tabs.map(\.id) == [b2.id, b1.id], "kept in its order as it changes")

        let third = browser.openWindow()
        #expect(first.otherWindowSections.map(\.title) == ["Other window 1", "Other window 2"])
        #expect(first.otherWindowSections.map(\.id) == [second.id, third.id])
        #expect(third.otherWindowSections.map(\.id) == [first.id, second.id])

        first.toggleOtherWindow(second.id)
        #expect(first.collapsedOtherWindows == [second.id])
        #expect(second.collapsedOtherWindows.isEmpty, "folded in one window only")
        first.toggleOtherWindow(second.id)
        #expect(first.collapsedOtherWindows.isEmpty)
    }

    /// A session written before windows were saved comes back as one window.
    @Test func anOldSessionOpensInOneWindow() {
        SessionStore.save(Session(tabs: [.init(url: page("old"), title: "Old", customTitle: nil, pinID: nil)], selectedIndex: 0))
        PinStore.save([])
        let browser = Browser()
        defer { reset(browser) }
        #expect(browser.windows.count == 1)
        #expect(browser.windows[0].selectedTab?.url == page("old"))
        #expect(browser.windows[0].regularTabs.map(\.url) == [page("old")])
        #expect(browser.windows[0].frame == nil)
        #expect(browser.windows[0].isHidden == false)
    }

    private func makeBrowser() -> Browser {
        SessionStore.save(Session())
        PinStore.save([])
        return Browser()
    }

    /// Closes every window but the first, then everything in it, so the next test's browser starts empty.
    private func reset(_ browser: Browser) {
        for window in browser.windows.dropFirst().reversed() { browser.windowWillClose(window) }
        browser.tabs.forEach { browser.close($0, remembering: false) }
        browser.pins.forEach(browser.unpin)
        for space in browser.spaces.reversed() { browser.deleteSpace(space.id) }
        if browser.windows[0].isZenMode { browser.windows[0].isZenMode = false }
        SessionStore.save(Session())
    }

    private func page(_ name: String) -> URL { URL(string: "data:text/html,\(name)")! }

    /// Asleep with its address, as a restored tab: pinning needs an address, and nothing loads.
    private func restored(_ browser: Browser, _ name: String, in window: BrowserWindow? = nil) -> Lithium.Tab {
        let tab = browser.newTab(selecting: false, in: window)
        tab.restore(url: page(name), title: name)
        return tab
    }
}

/// Closes as a `BrowserNSWindow` does, through `Browser.windowWillClose`, and stays off screen.
private final class ClosableWindow: NSWindow, NSWindowDelegate {
    private let model: BrowserWindow
    private weak var browser: Browser?

    init(_ model: BrowserWindow, browser: Browser) {
        self.model = model
        self.browser = browser
        super.init(contentRect: NSRect(x: -30000, y: -30000, width: 400, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        isReleasedWhenClosed = false
        delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        browser?.windowWillClose(model)
    }
}

/// Taken as on screen, never ordered in.
private final class ShownWindow: NSWindow {
    override var isVisible: Bool { true }
}

/// Counts the requests to come forward, minimizes only on paper, and stays off screen.
private final class FrontingWindow: NSWindow {
    private(set) var frontings = 0
    var minimized = false

    override var isMiniaturized: Bool { minimized }

    override func deminiaturize(_ sender: Any?) {
        minimized = false
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        frontings += 1
    }
}

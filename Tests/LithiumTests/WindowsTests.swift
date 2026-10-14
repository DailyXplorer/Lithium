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
}

import AppKit
import Testing
import WebKit
@testable import Lithium

/// Spaces: tab lists of their own, with their own favorites and, if asked, their own cookies. A
/// whole Browser keeps its data in the home folder, so this suite only runs in a throwaway one:
/// `scripts/test --filter SpacesTests`.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct SpacesTests {
    /// Never made one: a single implicit space, and the saved files say nothing of spaces.
    @Test func withoutSpacesNothingChanges() throws {
        let browser = makeBrowser()
        defer { reset(browser) }
        #expect(browser.spaces.isEmpty)
        #expect(!browser.hasSpaces)
        #expect(browser.allSpaces == [.main])
        let tab = browser.newTab(url: page("a"))
        #expect(tab.spaceID == Space.mainID)
        #expect(browser.regularTabs.map(\.id) == [tab.id])
        #expect(browser.spaceStore(for: Space.mainID) == nil)
        browser.pin(tab)
        #expect(browser.spacePins.map(\.id) == browser.pins.map(\.id))
        #expect(browser.pins.first?.spaceID == nil)

        browser.switchSpace(by: 1)
        browser.switchToSpace(at: 1)
        #expect(browser.currentSpaceID == Space.mainID)
        #expect(browser.selectedTab === tab)

        browser.saveNow()
        let session = try String(decoding: Data(contentsOf: SessionStore.fileURL), as: UTF8.self)
        let pins = try String(decoding: Data(contentsOf: PinStore.fileURL), as: UTF8.self)
        #expect(!session.contains("space") && !session.contains("lastShown"))
        #expect(!pins.contains("spaceID"))
    }

    /// Each space shows its own favorites and tabs; ⌘1…⌘9, Next Tab and new tabs stay in it, and
    /// switching back shows the tab last shown there.
    @Test func eachSpaceHasItsOwnTabsAndFavorites() throws {
        let browser = makeBrowser()
        defer { reset(browser) }
        let home = browser.newTab(url: page("home"))
        let homeFavorite = browser.newTab(url: page("home-favorite"))
        browser.pin(homeFavorite)
        browser.select(home)

        var work = browser.newSpaceDraft()
        work.name = "Work"
        browser.addSpace(work)
        #expect(browser.spaces.map(\.id) == [Space.mainID, work.id])
        #expect(browser.currentSpaceID == work.id)
        #expect(browser.selectedTab == nil, "a new space starts on the start page")
        #expect(browser.regularTabs.isEmpty)
        #expect(browser.spacePins.isEmpty)

        let mail = browser.newTab(url: page("mail"))
        let docs = browser.newTab(url: page("docs"))
        #expect(mail.spaceID == work.id)
        browser.pin(mail)
        #expect(browser.spacePins.count == 1)
        #expect(browser.pins.count == 2)
        #expect(browser.regularTabs.map(\.id) == [docs.id])
        browser.selectItem(at: 0)
        #expect(browser.selectedTab === mail)
        browser.selectAdjacentTab(1)
        #expect(browser.selectedTab === docs)
        browser.selectAdjacentTab(1)
        #expect(browser.selectedTab === mail, "Next Tab wraps around within the space")

        browser.switchToSpace(Space.mainID)
        #expect(browser.selectedTab === home)
        #expect(browser.regularTabs.map(\.id) == [home.id])
        #expect(browser.spacePins.map(\.url) == [page("home-favorite")])
        browser.selectItem(at: 0)
        #expect(browser.selectedTab === homeFavorite)

        browser.switchSpace(by: 1)
        #expect(browser.currentSpaceID == work.id)
        #expect(browser.selectedTab === mail)
        browser.switchSpace(by: 1)
        #expect(browser.currentSpaceID == work.id, "the last space is the end")

        // Extensions and agents see every space's tabs.
        #expect(Set(browser.navigationOrder.map(\.id)) == Set(browser.tabs.map(\.id)))
    }

    /// A tab of another space selected (a suggestion, an agent) brings its space; the last tab of
    /// a space closing leaves the start page, never another space's tab.
    @Test func selectingATabOfAnotherSpaceShowsThatSpace() {
        let browser = makeBrowser()
        defer { reset(browser) }
        let home = browser.newTab(url: page("home"))
        let work = browser.newSpaceDraft()
        browser.addSpace(work)
        let report = browser.newTab(url: page("report"))

        browser.select(home)
        #expect(browser.currentSpaceID == Space.mainID)
        browser.select(report)
        #expect(browser.currentSpaceID == work.id)

        browser.close(report)
        #expect(browser.currentSpaceID == work.id)
        #expect(browser.selectedTab == nil)
    }

    /// With its own data, a space's pages (popups, pages it opens, after sleep too) use its own
    /// store; a private tab keeps its own; the main space keeps the default one.
    @Test func aSpaceCanKeepItsOwnCookies() async throws {
        let browser = makeBrowser()
        defer { reset(browser) }
        var work = browser.newSpaceDraft()
        work.separatesData = true
        browser.addSpace(work)
        let tab = browser.newTab(url: page("work"))
        #expect(tab.webView.configuration.websiteDataStore.identifier == work.id)
        #expect(tab.dataStore.identifier == work.id)

        let opened = browser.newTab(url: page("opened"), openedFrom: tab)
        #expect(opened.spaceID == work.id)
        #expect(opened.webView.configuration.websiteDataStore.identifier == work.id)
        let popup = browser.newTab(configuration: browser.makeConfiguration(), openedFrom: tab)
        #expect(popup.webView.configuration.websiteDataStore.identifier == work.id)
        let secret = browser.newTab(url: page("private"), privateStore: .nonPersistent(), openedFrom: tab)
        #expect(secret.spaceID == work.id)
        #expect(!secret.webView.configuration.websiteDataStore.isPersistent)
        #expect(secret.webView.configuration.websiteDataStore.identifier == nil)

        browser.select(opened)
        tab.sleep(configuration: browser.makeConfiguration(for: tab.url))
        #expect(tab.webView.configuration.websiteDataStore.identifier == work.id, "a tab waking keeps its space's cookies")

        browser.switchToSpace(Space.mainID)
        let home = browser.newTab(url: page("home"))
        #expect(home.webView.configuration.websiteDataStore.identifier == nil)
        #expect(home.webView.configuration.websiteDataStore.isPersistent)

        let cookie = try #require(HTTPCookie(properties: [.domain: "example.com", .path: "/", .name: "account", .value: "work"]))
        await tab.dataStore.httpCookieStore.setCookie(cookie)
        let inSpace = await tab.dataStore.httpCookieStore.allCookies()
        let shared = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        #expect(inSpace.contains { $0.name == "account" })
        #expect(!shared.contains { $0.name == "account" && $0.value == "work" })
    }

    /// Settings › Clear site data counts and clears the site's cookies in every space's store, not
    /// only the default one: a space's login doesn't survive it.
    @Test func clearingSiteDataReachesSpacesWithTheirOwnCookies() async throws {
        let browser = makeBrowser()
        defer { reset(browser) }
        var work = browser.newSpaceDraft()
        work.separatesData = true
        browser.addSpace(work)
        let store = try #require(browser.spaceStore(for: work.id))
        let host = "clear-\(UUID().uuidString.prefix(8).lowercased()).example"
        for (target, value) in [(store, "work"), (WKWebsiteDataStore.default(), "home")] {
            let cookie = try #require(HTTPCookie(properties: [.domain: host, .path: "/", .name: "account", .value: value]))
            await target.httpCookieStore.setCookie(cookie)
        }

        browser.switchToSpace(Space.mainID)
        let settings = browser.newTab(url: Internal.settingsURL)
        #expect(await poll(30) { (try? await settings.webView.evaluateJavaScript("typeof call", in: nil, contentWorld: .page) as? String) == "function" })
        let site = try await settings.webView.callAsyncJavaScript("return await call('site', host)", arguments: ["host": host], contentWorld: .page) as? [String: Any]
        #expect(site?["cookies"] as? Int == 2)
        #expect(site?["hasData"] as? Bool == true)

        let cleared = try await settings.webView.callAsyncJavaScript("return await call('clearSiteData', host)", arguments: ["host": host], contentWorld: .page) as? [String: Any]
        #expect(cleared?["cookies"] as? Int == 0)
        let inSpace = await store.httpCookieStore.allCookies()
        #expect(!inSpace.contains { $0.domain.hasSuffix(host) }, "the space's login is gone too")
    }

    /// Deleting a space closes its tabs for good, drops its favorites, shows the space before it,
    /// and deletes its cookies. The main space stays.
    @Test func deletingASpaceClosesItsTabsAndDeletesItsData() async throws {
        let browser = makeBrowser()
        defer { reset(browser) }
        let home = browser.newTab(url: page("home"))
        var work = browser.newSpaceDraft()
        work.separatesData = true
        browser.addSpace(work)
        let tab = browser.newTab(url: page("work"))
        let favorite = browser.newTab(url: page("work-favorite"))
        browser.pin(favorite)
        let store = tab.dataStore
        let cookie = try #require(HTTPCookie(properties: [.domain: "example.com", .path: "/", .name: "login", .value: "1"]))
        await store.httpCookieStore.setCookie(cookie)

        browser.deleteSpace(Space.mainID)
        #expect(browser.spaces.count == 2)
        browser.deleteSpace(work.id)
        #expect(browser.spaces.map(\.id) == [Space.mainID])
        #expect(!browser.hasSpaces)
        #expect(browser.currentSpaceID == Space.mainID)
        #expect(browser.selectedTab === home)
        #expect(browser.tabs.map(\.id) == [home.id])
        #expect(browser.pins.isEmpty)
        #expect(!browser.canReopenClosedTab)
        #expect(browser.spaceStore(for: work.id) == nil)
        await browser.storeCleanup?.value
        #expect(await store.httpCookieStore.allCookies().isEmpty)
    }

    /// The spaces, the one shown and each one's last tab come back after a relaunch; a tab of a
    /// space the file no longer has comes back in the main space.
    @Test func spacesComeBackAfterARelaunch() throws {
        let browser = makeBrowser()
        defer { reset(browser) }
        browser.newTab(url: page("home"))
        var work = browser.newSpaceDraft()
        work.name = "Work"
        work.separatesData = true
        browser.addSpace(work)
        browser.pin(browser.newTab(url: page("work-favorite")))
        let docs = browser.newTab(url: page("docs"))
        browser.newTab(url: page("mail"))
        browser.select(docs)
        browser.switchToSpace(Space.mainID)
        browser.saveNow()

        let again = Browser()
        defer { reset(again) }
        #expect(again.spaces == browser.spaces)
        #expect(again.currentSpaceID == Space.mainID)
        #expect(again.selectedTab?.url == page("home"))
        #expect(again.regularTabs.map(\.url) == [page("home")])
        #expect(again.spacePins.isEmpty)
        again.switchToSpace(work.id)
        #expect(again.selectedTab?.url == page("docs"))
        #expect(again.regularTabs.map(\.url) == [page("mail"), page("docs")])
        #expect(again.spacePins.map(\.url) == [page("work-favorite")])
        #expect(again.selectedTab?.dataStore.identifier == work.id)

        SessionStore.save(Session(tabs: [.init(url: page("lost"), title: "Lost", customTitle: nil, pinID: nil, spaceID: UUID())], selectedIndex: 0))
        let lost = Browser()
        defer { reset(lost) }
        #expect(lost.spaces.isEmpty)
        #expect(lost.regularTabs.map(\.url) == [page("lost")])
        #expect(lost.selectedTab?.spaceID == Space.mainID)
    }

    /// A link from another app opens in the space shown; a closed tab reopens in its own space,
    /// which comes back with it; a copy stays in its space.
    @Test func linksFromOtherAppsOpenInTheSpaceShown() throws {
        UserDefaults.standard.removeObject(forKey: Preference.quickLinks)
        let browser = makeBrowser()
        defer { reset(browser) }
        browser.newTab(url: page("home"))
        let work = browser.newSpaceDraft()
        browser.addSpace(work)

        browser.openFromOtherApp(page("link"))
        let link = try #require(browser.selectedTab)
        #expect(link.spaceID == work.id)

        browser.close(link)
        browser.switchToSpace(Space.mainID)
        browser.reopenClosedTab()
        #expect(browser.currentSpaceID == work.id)
        let reopened = try #require(browser.selectedTab)
        #expect(reopened.url == page("link"))
        #expect(reopened.spaceID == work.id)

        browser.duplicate(reopened)
        #expect(browser.selectedTab?.spaceID == work.id)
        #expect(browser.regularTabs.count == 2)
    }

    /// Favorites move within their own space's grid, and a tab pinned at a slot lands there.
    @Test func favoritesMoveWithinTheirSpace() {
        let browser = makeBrowser()
        defer { reset(browser) }
        for name in ["a", "b"] { browser.pin(browser.newTab(url: page(name))) }
        browser.addSpace(browser.newSpaceDraft())
        for name in ["c", "d"] { browser.pin(browser.newTab(url: page(name))) }
        let d = browser.spacePins[1]
        browser.movePin(id: d.id, to: 0)
        #expect(browser.spacePins.map(\.url) == [page("d"), page("c")])
        browser.pin(browser.newTab(url: page("e")), at: 1)
        #expect(browser.spacePins.map(\.url) == [page("d"), page("e"), page("c")])
        #expect(browser.pins(in: Space.mainID).map(\.url) == [page("a"), page("b")])
    }

    /// A blank name keeps a usable one, an edit can't change where a space's data lives, a new
    /// draft takes a color and an icon no space has, and ⌃1…⌃9 reach at most nine spaces.
    @Test func editingASpace() {
        let browser = makeBrowser()
        defer { reset(browser) }
        var blank = browser.newSpaceDraft()
        blank.name = "  "
        blank.separatesData = true
        browser.addSpace(blank)
        #expect(browser.currentSpace.name == "Space 2")
        #expect(browser.newSpaceDraft().color != blank.color)
        #expect(browser.newSpaceDraft().icon != blank.icon)

        var edited = browser.currentSpace
        edited.name = "Clients"
        edited.icon = Phosphor.folder.rawValue
        edited.separatesData = false
        browser.updateSpace(edited)
        #expect(browser.currentSpace.name == "Clients")
        #expect(browser.currentSpace.icon == Phosphor.folder.rawValue)
        #expect(browser.currentSpace.separatesData)

        while browser.canAddSpace { browser.addSpace(browser.newSpaceDraft()) }
        #expect(browser.spaces.count == Space.limit)
        browser.switchToSpace(at: 1)
        #expect(browser.currentSpace.name == "Clients")
        browser.switchToSpace(at: 0)
        #expect(browser.currentSpaceID == Space.mainID)
    }

    /// The peeked sidebar slides back on `tabPickToken`: making, switching (a click, ⌃1…⌃9, a
    /// swipe) and deleting spaces keep it out, still showing the space's last tab as read.
    @Test func switchingSpacesIsNotATabPick() {
        let browser = makeBrowser()
        defer { reset(browser) }
        let home = browser.newTab(url: page("home"))
        browser.addSpace(browser.newSpaceDraft())
        let work = browser.currentSpaceID
        browser.newTab(url: page("work"))
        let picks = browser.tabPickToken

        browser.switchToSpace(Space.mainID)
        #expect(browser.selectedTab === home)
        browser.switchToSpace(at: 1)
        browser.switchSpace(by: -1)
        browser.addSpace(browser.newSpaceDraft())
        #expect(browser.selectedTab == nil)
        browser.deleteSpace(browser.currentSpaceID)
        #expect(browser.currentSpaceID == work)
        browser.deleteSpace(work)
        #expect(browser.currentSpaceID == Space.mainID)
        #expect(browser.tabPickToken == picks)
    }

    /// Something opened from the peeked sidebar keeps it out until it is done: a tab's name being
    /// typed, or a popover such as a space's editor (the window's child, standing in here).
    @Test func aRenameOrAPopoverHoldsThePeekedSidebar() {
        let browser = makeBrowser()
        defer { reset(browser) }
        let tab = browser.newTab(url: page("home"))
        let window = PeekWindow(contentRect: NSRect(x: -30000, y: -30000, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        browser.window = window
        defer { browser.window = nil }
        #expect(!browser.holdsPeek)

        browser.renamingTabID = tab.id
        #expect(browser.holdsPeek, "the name field")
        browser.renamingTabID = nil
        #expect(!browser.holdsPeek)

        window.children = [ShownWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)]
        #expect(browser.holdsPeek, "a popover")
        window.children = [NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)]
        #expect(!browser.holdsPeek, "a child window already gone")
        window.children = []
        #expect(!browser.holdsPeek)
    }

    private func makeBrowser() -> Browser {
        SessionStore.save(Session())
        PinStore.save([])
        return Browser()
    }

    /// Closes everything, so the next test's browser starts empty, and deletes the stores made.
    private func reset(_ browser: Browser) {
        browser.tabs.forEach { browser.close($0, remembering: false) }
        browser.pins.forEach(browser.unpin)
        for space in browser.spaces.reversed() { browser.deleteSpace(space.id) }
        SessionStore.save(Session())
    }

    private func page(_ name: String) -> URL { URL(string: "data:text/html,\(name)")! }

    private func poll(_ seconds: Double, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return await condition()
    }
}

/// A window whose child windows a test sets, never ordered in.
private final class PeekWindow: NSWindow {
    var children: [NSWindow] = []
    override var childWindows: [NSWindow]? { children }
}

/// Says it is visible, as a popover's window does, without ever being on screen.
private final class ShownWindow: NSWindow {
    override var isVisible: Bool { true }
}

/// The sidebar's two-finger swipe, as the events of a trackpad gesture reach it.
struct SpaceSwipeTests {
    /// Fingers to the left bring the next space, whatever the scrolling direction setting: with
    /// natural scrolling the content follows the fingers, so the deltas flip.
    @Test func fingersToTheLeftBringTheNextSpace() {
        var natural = SpaceSwipe()
        #expect(natural.handle(phase: .began, momentumPhase: [], dx: 0, dy: 0, inverted: true) == .pass)
        #expect(natural.handle(phase: .changed, momentumPhase: [], dx: -50, dy: 2, inverted: true) == .step(1))
        var classic = SpaceSwipe()
        _ = classic.handle(phase: .began, momentumPhase: [], dx: 0, dy: 0, inverted: false)
        #expect(classic.handle(phase: .changed, momentumPhase: [], dx: 50, dy: 0, inverted: false) == .step(1))
        var back = SpaceSwipe()
        _ = back.handle(phase: .began, momentumPhase: [], dx: 0, dy: 0, inverted: true)
        #expect(back.handle(phase: .changed, momentumPhase: [], dx: 25, dy: 0, inverted: true) == .pass)
        #expect(back.handle(phase: .changed, momentumPhase: [], dx: 25, dy: 0, inverted: true) == .step(-1))
    }

    /// One switch per gesture: the rest of it and the momentum after it are swallowed, until the
    /// next gesture.
    @Test func oneSwitchPerGesture() {
        var swipe = SpaceSwipe()
        _ = swipe.handle(phase: .began, momentumPhase: [], dx: 0, dy: 0, inverted: true)
        #expect(swipe.handle(phase: .changed, momentumPhase: [], dx: -60, dy: 0, inverted: true) == .step(1))
        #expect(swipe.handle(phase: .changed, momentumPhase: [], dx: -200, dy: 0, inverted: true) == .consume)
        #expect(swipe.handle(phase: .ended, momentumPhase: [], dx: 0, dy: 0, inverted: true) == .consume)
        #expect(swipe.handle(phase: [], momentumPhase: .changed, dx: -80, dy: 0, inverted: true) == .consume)
        #expect(swipe.handle(phase: .began, momentumPhase: [], dx: 0, dy: 0, inverted: true) == .pass)
        #expect(swipe.handle(phase: [], momentumPhase: .changed, dx: -80, dy: 0, inverted: true) == .pass)
    }

    /// A mouse wheel (no phase), a scroll of the tab list and a short nudge switch nothing.
    @Test func scrollsAndWheelsDontSwitch() {
        var wheel = SpaceSwipe()
        #expect(wheel.handle(phase: [], momentumPhase: [], dx: -300, dy: 0, inverted: true) == .pass)

        var scroll = SpaceSwipe()
        _ = scroll.handle(phase: .began, momentumPhase: [], dx: 0, dy: 0, inverted: true)
        #expect(scroll.handle(phase: .changed, momentumPhase: [], dx: 5, dy: 30, inverted: true) == .pass)
        #expect(scroll.handle(phase: .changed, momentumPhase: [], dx: -200, dy: 0, inverted: true) == .pass)

        var nudge = SpaceSwipe()
        _ = nudge.handle(phase: .began, momentumPhase: [], dx: 0, dy: 0, inverted: true)
        #expect(nudge.handle(phase: .changed, momentumPhase: [], dx: -30, dy: 0, inverted: true) == .pass)
        #expect(nudge.handle(phase: .ended, momentumPhase: [], dx: 0, dy: 0, inverted: true) == .pass)
        #expect(nudge.handle(phase: [], momentumPhase: .changed, dx: -30, dy: 0, inverted: true) == .pass)
    }
}

import AppKit
import SwiftUI
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
        #expect(browser.commandWindow.regularTabs.map(\.id) == [tab.id])
        #expect(browser.spaceStore(for: Space.mainID) == nil)
        browser.pin(tab)
        #expect(browser.commandWindow.spacePins.map(\.id) == browser.pins.map(\.id))
        #expect(browser.pins.first?.spaceID == nil)

        browser.commandWindow.switchSpace(by: 1)
        browser.commandWindow.switchToSpace(at: 1)
        #expect(browser.commandWindow.currentSpaceID == Space.mainID)
        #expect(browser.commandWindow.selectedTab === tab)

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
        #expect(browser.commandWindow.currentSpaceID == work.id)
        #expect(browser.commandWindow.selectedTab == nil, "a new space starts on the start page")
        #expect(browser.commandWindow.regularTabs.isEmpty)
        #expect(browser.commandWindow.spacePins.isEmpty)

        let mail = browser.newTab(url: page("mail"))
        let docs = browser.newTab(url: page("docs"))
        #expect(mail.spaceID == work.id)
        browser.pin(mail)
        #expect(browser.commandWindow.spacePins.count == 1)
        #expect(browser.pins.count == 2)
        #expect(browser.commandWindow.regularTabs.map(\.id) == [docs.id])
        browser.commandWindow.selectItem(at: 0)
        #expect(browser.commandWindow.selectedTab === mail)
        browser.commandWindow.selectAdjacentTab(1)
        #expect(browser.commandWindow.selectedTab === docs)
        browser.commandWindow.selectAdjacentTab(1)
        #expect(browser.commandWindow.selectedTab === mail, "Next Tab wraps around within the space")

        browser.commandWindow.switchToSpace(Space.mainID)
        #expect(browser.commandWindow.selectedTab === home)
        #expect(browser.commandWindow.regularTabs.map(\.id) == [home.id])
        #expect(browser.commandWindow.spacePins.map(\.url) == [page("home-favorite")])
        browser.commandWindow.selectItem(at: 0)
        #expect(browser.commandWindow.selectedTab === homeFavorite)

        browser.commandWindow.switchSpace(by: 1)
        #expect(browser.commandWindow.currentSpaceID == work.id)
        #expect(browser.commandWindow.selectedTab === mail)
        browser.commandWindow.switchSpace(by: 1)
        #expect(browser.commandWindow.currentSpaceID == work.id, "the last space is the end")

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
        #expect(browser.commandWindow.currentSpaceID == Space.mainID)
        browser.select(report)
        #expect(browser.commandWindow.currentSpaceID == work.id)

        browser.close(report)
        #expect(browser.commandWindow.currentSpaceID == work.id)
        #expect(browser.commandWindow.selectedTab == nil)
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

        browser.commandWindow.switchToSpace(Space.mainID)
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

        browser.commandWindow.switchToSpace(Space.mainID)
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
        #expect(browser.commandWindow.currentSpaceID == Space.mainID)
        #expect(browser.commandWindow.selectedTab === home)
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
        browser.commandWindow.switchToSpace(Space.mainID)
        browser.saveNow()

        let again = Browser()
        defer { reset(again) }
        #expect(again.spaces == browser.spaces)
        #expect(again.commandWindow.currentSpaceID == Space.mainID)
        #expect(again.commandWindow.selectedTab?.url == page("home"))
        #expect(again.commandWindow.regularTabs.map(\.url) == [page("home")])
        #expect(again.commandWindow.spacePins.isEmpty)
        again.commandWindow.switchToSpace(work.id)
        #expect(again.commandWindow.selectedTab?.url == page("docs"))
        #expect(again.commandWindow.regularTabs.map(\.url) == [page("mail"), page("docs")])
        #expect(again.commandWindow.spacePins.map(\.url) == [page("work-favorite")])
        #expect(again.commandWindow.selectedTab?.dataStore.identifier == work.id)

        SessionStore.save(Session(tabs: [.init(url: page("lost"), title: "Lost", customTitle: nil, pinID: nil, spaceID: UUID())], selectedIndex: 0))
        let lost = Browser()
        defer { reset(lost) }
        #expect(lost.spaces.isEmpty)
        #expect(lost.commandWindow.regularTabs.map(\.url) == [page("lost")])
        #expect(lost.commandWindow.selectedTab?.spaceID == Space.mainID)
    }

    /// A file with more spaces than any build saves (edited by hand) brings back the first
    /// `Space.limit`, the others' tabs in the main space, rather than trap in the Tabs menu.
    @Test func extraSavedSpacesAreLeftOut() {
        let extra = (0..<Space.limit + 1).map { Space(id: UUID(), name: "Space \($0)", color: nil, icon: Space.main.icon) }
        let last = extra[extra.count - 1]
        SessionStore.save(Session(tabs: [.init(url: page("last"), title: "Last", customTitle: nil, pinID: nil, spaceID: last.id)],
                                  selectedIndex: 0, spaces: [.main] + extra, spaceID: last.id))
        PinStore.save([])
        let browser = Browser()
        defer { reset(browser) }
        #expect(browser.spaces.count == Space.limit)
        #expect(browser.spaces.first == .main)
        #expect(!browser.spaces.contains { $0.id == last.id })
        #expect(browser.commandWindow.currentSpaceID == Space.mainID)
        #expect(browser.commandWindow.regularTabs.map(\.url) == [page("last")])
    }

    /// The address bar suggests another space's tabs and favorites only while neither space keeps
    /// its cookies apart: a separate space's are another identity's.
    @Test func suggestionsStayInsideSpacesWithTheirOwnCookies() {
        let browser = makeBrowser()
        defer { reset(browser) }
        browser.newTab(url: page("home-mail"))
        browser.addSpace(browser.newSpaceDraft())
        browser.newTab(url: page("side-mail"))
        var work = browser.newSpaceDraft()
        work.separatesData = true
        browser.addSpace(work)
        browser.newTab(url: page("work-mail"))
        browser.pin(browser.newTab(url: page("work-favorite-mail")))
        defer { browser.commandWindow.suggestions.clear() }
        func suggested() -> Set<URL> { Set(browser.commandWindow.suggestions.items.compactMap(\.url)) }

        browser.commandWindow.addressTextChanged("mail")
        #expect(suggested() == [page("work-mail"), page("work-favorite-mail")])

        browser.commandWindow.switchToSpace(Space.mainID)
        browser.commandWindow.addressTextChanged("mail")
        #expect(suggested() == [page("home-mail"), page("side-mail")], "spaces sharing cookies still suggest each other's")
    }

    /// A space keeping its cookies apart has its own permission answers, protections and site
    /// fonts: another account there isn't granted what the main one was. They go with the space.
    @Test func spacesWithTheirOwnCookiesKeepTheirOwnSiteChoices() async {
        let browser = makeBrowser()
        defer { reset(browser) }
        let host = "choices-\(UUID().uuidString.prefix(8).lowercased()).example"
        let url = URL(string: "https://\(host)/")!
        defer {
            browser.permissions.set(nil, for: .camera, host: host)
            browser.privacy.setEnabled(true, host: host)
        }
        let home = browser.newTab(url: page("home"))
        browser.addSpace(browser.newSpaceDraft())
        let side = browser.newTab(url: page("side"))
        var work = browser.newSpaceDraft()
        work.separatesData = true
        browser.addSpace(work)
        let tab = browser.newTab(url: page("work"))
        let secret = browser.newTab(url: page("private"), privateStore: .nonPersistent(), openedFrom: tab)
        #expect(home.siteSpace == nil && side.siteSpace == nil && secret.siteSpace == nil)
        #expect(tab.siteSpace == work.id)

        // Allowed in the main space, the camera is asked for again in Work; denied there, it
        // stays allowed in the main space.
        browser.permissions.answer(PermissionRequest(tabID: home.id, host: host, kinds: [.camera]), allow: true)
        #expect(await browser.permissions.request([.camera], host: host, tabID: home.id))
        #expect(browser.permissions.decisions(for: host, privateSession: nil, space: work.id).isEmpty)
        browser.permissions.answer(PermissionRequest(tabID: tab.id, host: host, kinds: [.camera], space: work.id), allow: false)
        #expect(await !browser.permissions.request([.camera], host: host, tabID: tab.id, space: work.id))
        #expect(browser.permissions.decisions(for: host, privateSession: nil) == [.camera: .allow])

        // Protections and the site's font: the space's own choice wins, then the shared one.
        browser.privacy.setEnabled(true, for: url, space: work.id)
        browser.privacy.setEnabled(false, host: host)
        #expect(!browser.privacy.isEnabled(for: url))
        #expect(browser.privacy.isEnabled(for: url, space: work.id))
        PageStyle.setKeepsSiteFont(true, for: host, space: work.id)
        #expect(PageStyle.keepsSiteFont(host, space: work.id))
        #expect(!PageStyle.keepsSiteFont(host))

        browser.deleteSpace(work.id)
        #expect(browser.permissions.decisions(for: host, privateSession: nil, space: work.id).isEmpty)
        #expect(!browser.privacy.isEnabled(for: url, space: work.id), "back to the shared choice")
        #expect(!PageStyle.keepsSiteFont(host, space: work.id))
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
        let link = try #require(browser.commandWindow.selectedTab)
        #expect(link.spaceID == work.id)

        browser.close(link)
        browser.commandWindow.switchToSpace(Space.mainID)
        browser.reopenClosedTab()
        #expect(browser.commandWindow.currentSpaceID == work.id)
        let reopened = try #require(browser.commandWindow.selectedTab)
        #expect(reopened.url == page("link"))
        #expect(reopened.spaceID == work.id)

        browser.duplicate(reopened)
        #expect(browser.commandWindow.selectedTab?.spaceID == work.id)
        #expect(browser.commandWindow.regularTabs.count == 2)
    }

    /// Favorites move within their own space's grid, and a tab pinned at a slot lands there.
    @Test func favoritesMoveWithinTheirSpace() {
        let browser = makeBrowser()
        defer { reset(browser) }
        for name in ["a", "b"] { browser.pin(browser.newTab(url: page(name))) }
        browser.addSpace(browser.newSpaceDraft())
        for name in ["c", "d"] { browser.pin(browser.newTab(url: page(name))) }
        let d = browser.commandWindow.spacePins[1]
        browser.movePin(id: d.id, to: 0)
        #expect(browser.commandWindow.spacePins.map(\.url) == [page("d"), page("c")])
        browser.pin(browser.newTab(url: page("e")), at: 1)
        #expect(browser.commandWindow.spacePins.map(\.url) == [page("d"), page("e"), page("c")])
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
        #expect(browser.commandWindow.currentSpace.name == "Space 2")
        #expect(browser.newSpaceDraft().color != blank.color)
        #expect(browser.newSpaceDraft().icon != blank.icon)

        var edited = browser.commandWindow.currentSpace
        edited.name = "Clients"
        edited.icon = Phosphor.folder.rawValue
        edited.separatesData = false
        browser.updateSpace(edited)
        #expect(browser.commandWindow.currentSpace.name == "Clients")
        #expect(browser.commandWindow.currentSpace.icon == Phosphor.folder.rawValue)
        #expect(browser.commandWindow.currentSpace.separatesData)

        while browser.canAddSpace { browser.addSpace(browser.newSpaceDraft()) }
        #expect(browser.spaces.count == Space.limit)
        browser.commandWindow.switchToSpace(at: 1)
        #expect(browser.commandWindow.currentSpace.name == "Clients")
        browser.commandWindow.switchToSpace(at: 0)
        #expect(browser.commandWindow.currentSpaceID == Space.mainID)
    }

    /// The peeked sidebar slides back on `tabPickToken`: making, switching (a click, ⌃1…⌃9, a
    /// swipe) and deleting spaces keep it out, still showing the space's last tab as read.
    @Test func switchingSpacesIsNotATabPick() {
        let browser = makeBrowser()
        defer { reset(browser) }
        let home = browser.newTab(url: page("home"))
        browser.addSpace(browser.newSpaceDraft())
        let work = browser.commandWindow.currentSpaceID
        browser.newTab(url: page("work"))
        let picks = browser.commandWindow.tabPickToken

        browser.commandWindow.switchToSpace(Space.mainID)
        #expect(browser.commandWindow.selectedTab === home)
        browser.commandWindow.switchToSpace(at: 1)
        browser.commandWindow.switchSpace(by: -1)
        browser.addSpace(browser.newSpaceDraft())
        #expect(browser.commandWindow.selectedTab == nil)
        browser.deleteSpace(browser.commandWindow.currentSpaceID)
        #expect(browser.commandWindow.currentSpaceID == work)
        browser.deleteSpace(work)
        #expect(browser.commandWindow.currentSpaceID == Space.mainID)
        #expect(browser.commandWindow.tabPickToken == picks)
    }

    /// Something opened from the peeked sidebar keeps it out until it is done: a tab's name being
    /// typed, or a popover such as a space's editor (the window's child, standing in here).
    @Test func aRenameOrAPopoverHoldsThePeekedSidebar() {
        let browser = makeBrowser()
        defer { reset(browser) }
        let tab = browser.newTab(url: page("home"))
        let window = PeekWindow(contentRect: NSRect(x: -30000, y: -30000, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        browser.windows[0].nsWindow = window
        defer { browser.windows[0].nsWindow = nil }
        #expect(!browser.commandWindow.holdsPeek)

        browser.commandWindow.renamingTabID = tab.id
        #expect(browser.commandWindow.holdsPeek, "the name field")
        browser.commandWindow.renamingTabID = nil
        #expect(!browser.commandWindow.holdsPeek)

        window.children = [ShownWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)]
        #expect(browser.commandWindow.holdsPeek, "a popover")
        window.children = [NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)]
        #expect(!browser.commandWindow.holdsPeek, "a child window already gone")
        window.children = []
        #expect(!browser.commandWindow.holdsPeek)
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

/// The space buttons at the foot of the sidebar, on every kind of sidebar the palette handles.
@MainActor
struct SpaceButtonTests {
    /// Light, saturated, very dark, near-black (lifted) and translucent sidebars.
    static let backdrops: [(style: SidebarStyle, hex: String, scheme: ColorScheme)] = [
        (.solid, Theme.defaultSidebarHex, .light), (.solid, "#C0392B", .light), (.solid, "#1E1E24", .dark),
        (.solid, "#0A0A14", .dark), (.translucent, "#E7E5EA", .light), (.translucent, "#2C2B30", .dark),
    ]

    /// The current space sits on the current tab row's resting surface, not the darker selected
    /// favorite; the others have none, a hovered one less than the current one, and the current
    /// one stands a visible step off the sidebar.
    @Test(arguments: 0..<6)
    func currentSpaceTakesTheSelectedTabRowsSurface(_ index: Int) {
        let backdrop = Self.backdrops[index]
        let palette = SidebarPalette(style: backdrop.style, colorHex: backdrop.hex, scheme: backdrop.scheme)
        let current = rgba(SpaceButton.fill(palette, isCurrent: true, isHovered: false))
        #expect(current == rgba(palette.rowFill(isSelected: true, isHovered: false)))
        #expect(current == rgba(palette.tile))
        #expect(current != rgba(palette.selection))
        #expect(rgba(SpaceButton.fill(palette, isCurrent: true, isHovered: true)) == current)
        #expect(rgba(SpaceButton.fill(palette, isCurrent: false, isHovered: false)).a == 0)
        #expect(rgba(SpaceButton.fill(palette, isCurrent: false, isHovered: true)).a < current.a)

        let sidebar = rgba(Color(hex: backdrop.hex))
        let step = max(abs(current.r - sidebar.r), abs(current.g - sidebar.g), abs(current.b - sidebar.b)) * current.a
        #expect(step >= 5.0 / 255, "\(backdrop.hex): the current space is lost on the sidebar")
    }

    private func rgba(_ color: Color) -> (r: Double, g: Double, b: Double, a: Double) {
        let c = NSColor(color).usingColorSpace(.sRGB)!
        return (c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
    }
}

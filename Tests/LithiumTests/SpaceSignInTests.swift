import Foundation
import Network
import Testing
import WebKit
@testable import Lithium

/// A site signed in from a space keeping its own data stays signed in however its page comes back
/// after a switch to another space: the sign-in lives in session cookies, held only by that
/// space's store. A whole Browser keeps its data in the home folder, so this suite only runs in a
/// throwaway one: `scripts/test --filter SpaceSignInTests`.
@MainActor
/// Three minutes: a check waits its full 30 seconds only when no page settles, and a test makes
/// up to four, so a regression fails on its check rather than on the time limit.
@Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct SpaceSignInTests {
    @Test func aFavoriteStaysSignedInAcrossSpaceSwitches() async throws {
        let site = try await SignInSite.start()
        defer { site.stop() }
        let (browser, work, favorite) = try await signedInFavorite(on: site)
        defer { reset(browser) }

        browser.commandWindow.switchToSpace(Space.mainID)
        browser.commandWindow.switchToSpace(work.id)
        #expect(browser.commandWindow.selectedTab === favorite)
        #expect(await reloadsSignedIn(favorite, in: browser), "reloaded")
        let commits = favorite.commits
        browser.navigate(favorite, .open(site.home))
        #expect(await signedIn(favorite, after: commits), "sent to the site again")
        browser.commandWindow.switchToSpace(Space.mainID)
        browser.activate(try #require(browser.pins.first))
        #expect(browser.commandWindow.currentSpaceID == work.id)
        #expect(browser.commandWindow.selectedTab === favorite)
        #expect(favorite.webView.configuration.websiteDataStore.identifier == work.id)
        #expect(await reloadsSignedIn(favorite, in: browser), "picked from another space")
    }

    /// Put to sleep while its space is hidden, the favorite wakes in a new web view: shown again,
    /// or in the background.
    @Test func aFavoriteThatSleptWhileHiddenWakesSignedIn() async throws {
        let site = try await SignInSite.start()
        defer { site.stop() }
        let (browser, work, favorite) = try await signedInFavorite(on: site)
        defer { reset(browser) }

        browser.commandWindow.switchToSpace(Space.mainID)
        favorite.sleep(configuration: browser.makeConfiguration(for: favorite.url))
        browser.commandWindow.switchToSpace(work.id)
        #expect(!favorite.isAsleep)
        #expect(favorite.webView.configuration.websiteDataStore.identifier == work.id)
        #expect(await reloadsSignedIn(favorite, in: browser), "woken on being shown")

        browser.commandWindow.switchToSpace(Space.mainID)
        favorite.sleep(configuration: browser.makeConfiguration(for: favorite.url))
        favorite.wakeIfAsleep()
        #expect(favorite.webView.configuration.websiteDataStore.identifier == work.id)
        #expect(await reloadsSignedIn(favorite, in: browser), "woken in the background")
    }

    /// Memory pressure puts the favorite to sleep while hidden; shown again, it wakes signed in.
    @Test func aFavoriteWokenAfterMemoryPressureIsSignedIn() async throws {
        let site = try await SignInSite.start()
        defer { site.stop() }
        let (browser, work, favorite) = try await signedInFavorite(on: site)
        defer { reset(browser) }

        browser.commandWindow.switchToSpace(Space.mainID)
        browser.relieveMemoryPressure(critical: true)
        #expect(favorite.isAsleep)
        browser.commandWindow.switchToSpace(work.id)
        #expect(!favorite.isAsleep)
        #expect(favorite.webView.configuration.websiteDataStore.identifier == work.id)
        #expect(await reloadsSignedIn(favorite, in: browser))
    }

    /// The favorite restored asleep with the session (a new Browser, as at launch) uses the space's
    /// store from its first web view.
    @Test func aRestoredFavoriteIsSignedIn() async throws {
        let site = try await SignInSite.start()
        defer { site.stop() }
        let (browser, work, _) = try await signedInFavorite(on: site)
        browser.commandWindow.switchToSpace(Space.mainID)
        browser.saveNow()
        browser.tabs.forEach { browser.close($0, remembering: false) }

        let again = Browser()
        defer { reset(again) }
        defer { reset(browser) }
        let restored = try #require(again.tabs.first { $0.pinID != nil })
        #expect(restored.isAsleep)
        again.commandWindow.switchToSpace(work.id)
        again.activate(try #require(again.pins.first))
        #expect(again.commandWindow.selectedTab === restored)
        #expect(!restored.isAsleep)
        #expect(restored.webView.configuration.websiteDataStore.identifier == work.id)
        #expect(await reloadsSignedIn(restored, in: again))
    }

    /// Its tab closed, the favorite opens a new one in its space, from whichever space is shown.
    @Test func aClosedFavoriteReopensSignedIn() async throws {
        let site = try await SignInSite.start()
        defer { site.stop() }
        let (browser, work, favorite) = try await signedInFavorite(on: site)
        defer { reset(browser) }

        browser.close(favorite)
        browser.commandWindow.switchToSpace(Space.mainID)
        browser.activate(try #require(browser.pins.first))
        let reopened = try #require(browser.commandWindow.selectedTab)
        #expect(reopened !== favorite)
        #expect(reopened.spaceID == work.id)
        #expect(reopened.webView.configuration.websiteDataStore.identifier == work.id)
        #expect(await signedIn(reopened))
    }

    /// The site's sign-in window (`window.open` with a size) signs its opener in.
    @Test func aSignInWindowSignsItsOpenerIn() async throws {
        let site = try await SignInSite.start()
        defer { site.stop() }
        let (browser, work) = makeBrowserWithWorkSpace()
        defer { reset(browser) }
        let opener = browser.newTab(url: site.opener)
        #expect(await poll(30) { opener.title == "Opener" && !opener.isLoading })
        _ = try await opener.webView.evaluateJavaScript("document.getElementById('signin').click(); 0")
        #expect(await poll(30) { browser.tabs.contains { $0.scriptOpener === opener && $0.title == "Signed in" && !$0.isLoading } })
        let popup = try #require(browser.tabs.first { $0.scriptOpener === opener })
        #expect(popup.spaceID == work.id)
        #expect(popup.webView.configuration.websiteDataStore.identifier == work.id)

        browser.commandWindow.switchToSpace(Space.mainID)
        browser.commandWindow.switchToSpace(work.id)
        let commits = opener.commits
        browser.navigate(opener, .open(site.home))
        #expect(await signedIn(opener, after: commits))
    }

    /// A link's own window opened while the space is shown is that space's.
    @Test func aQuickLinkWindowSharesTheSpaceSignIn() async throws {
        let site = try await SignInSite.start()
        defer { site.stop() }
        let (browser, work, _) = try await signedInFavorite(on: site)
        defer { reset(browser) }
        browser.quickLinks.showWindow = { _, _ in nil }

        browser.commandWindow.switchToSpace(Space.mainID)
        browser.commandWindow.switchToSpace(work.id)
        let link = try #require(browser.quickLinks.open(site.home))
        defer { browser.quickLinks.close(link) }
        #expect(link.spaceID == work.id)
        #expect(link.webView.configuration.websiteDataStore.identifier == work.id)
        #expect(await signedIn(link))
    }

    /// A second window showing the space shares its store: the site sees the sign-in's cookie on
    /// the second window's request too.
    @Test func aSecondWindowSharesTheSpaceSignIn() async throws {
        let site = try await SignInSite.start()
        defer { site.stop() }
        let (browser, work, favorite) = try await signedInFavorite(on: site)
        defer { reset(browser) }

        let second = browser.openWindow(space: work.id)
        let tab = browser.newTab(url: site.home, in: second)
        #expect(second.selectedTab === tab)
        #expect(tab.spaceID == work.id)
        #expect(tab.webView.configuration.websiteDataStore === favorite.webView.configuration.websiteDataStore)
        #expect(await signedIn(tab))
    }

    /// Back from an extension's page, which keeps a store of its own, the tab gets a new web view
    /// with the space's store (`needsNewWebView`). No extension is installed: an unknown one's page
    /// takes the same branches.
    @Test func aTabBackFromAnExtensionPageIsSignedIn() async throws {
        let site = try await SignInSite.start()
        defer { site.stop() }
        let (browser, work, favorite) = try await signedInFavorite(on: site)
        defer { reset(browser) }

        browser.commandWindow.switchToSpace(Space.mainID)
        browser.commandWindow.switchToSpace(work.id)
        let page = try #require(URL(string: "\(Extensions.scheme)://lithium-test/page.html"))
        browser.navigate(favorite, .open(page))
        let extensionPage = favorite.webView
        #expect(extensionPage.configuration.websiteDataStore.identifier == nil)
        let commits = favorite.commits
        browser.navigate(favorite, .open(site.home))
        #expect(favorite.webView !== extensionPage)
        #expect(favorite.webView.configuration.websiteDataStore.identifier == work.id)
        #expect(await signedIn(favorite, after: commits))
    }

    /// The main space, a space sharing its data and a private tab of the separate space keep their
    /// own stores, so none of them gets its sign-in.
    @Test func otherStoresDontGetTheSpaceSignIn() async throws {
        let site = try await SignInSite.start()
        defer { site.stop() }
        let (browser, work, _) = try await signedInFavorite(on: site)
        defer { reset(browser) }

        let privateStore = WKWebsiteDataStore.nonPersistent()
        let privateTab = browser.newTab(url: site.home, privateStore: privateStore, space: work.id)
        #expect(privateTab.webView.configuration.websiteDataStore === privateStore)
        #expect(await settledTitle(privateTab) == "Sign in", "private tab")

        var shared = browser.newSpaceDraft()
        shared.name = "Shared"
        browser.addSpace(shared)
        let sharedTab = browser.newTab(url: site.home)
        #expect(sharedTab.spaceID == shared.id)
        browser.commandWindow.switchToSpace(Space.mainID)
        let mainTab = browser.newTab(url: site.home)
        #expect(mainTab.spaceID == Space.mainID)
        for (tab, name) in [(sharedTab, "shared space"), (mainTab, "main space")] {
            #expect(tab.webView.configuration.websiteDataStore === WKWebsiteDataStore.default(), "\(name)")
            #expect(await settledTitle(tab) == "Sign in", "\(name)")
        }
    }

    // MARK: Helpers

    /// A space with its own data, shown, and a favorite of it signed in to `site`.
    private func signedInFavorite(on site: SignInSite) async throws -> (Browser, Space, Lithium.Tab) {
        let (browser, work) = makeBrowserWithWorkSpace()
        let favorite = browser.newTab(url: site.signIn)
        #expect(await signedIn(favorite), "signed in")
        browser.pin(favorite)
        #expect(favorite.webView.configuration.websiteDataStore.identifier == work.id)
        return (browser, work, favorite)
    }

    private func makeBrowserWithWorkSpace() -> (Browser, Space) {
        SessionStore.save(Session())
        PinStore.save([])
        let browser = Browser()
        browser.newTab(url: URL(string: "data:text/html,home")!)
        var work = browser.newSpaceDraft()
        work.name = "Work"
        work.separatesData = true
        browser.addSpace(work)
        return (browser, work)
    }

    /// Closes everything and deletes the space's store, so the next test starts signed out.
    private func reset(_ browser: Browser) {
        for window in browser.windows.dropFirst().reversed() { browser.windowWillClose(window) }
        browser.tabs.forEach { browser.close($0, remembering: false) }
        browser.pins.forEach(browser.unpin)
        for space in browser.spaces.reversed() { browser.deleteSpace(space.id) }
        SessionStore.save(Session())
    }

    /// Whether the next page the tab shows, past any redirects, is the signed-in one.
    private func signedIn(_ tab: Lithium.Tab, after commits: Int = 0) async -> Bool {
        await settledTitle(tab, after: commits) == "Signed in"
    }

    /// Nil when no new page settles: the title shown meanwhile is the last page's.
    private func settledTitle(_ tab: Lithium.Tab, after commits: Int = 0) async -> String? {
        let settled = await poll(30) { tab.commits > commits && !tab.isLoading && ["Signed in", "Sign in"].contains(tab.title) }
        return settled ? tab.title : nil
    }

    private func reloadsSignedIn(_ tab: Lithium.Tab, in browser: Browser) async -> Bool {
        let commits = tab.commits
        browser.navigate(tab, .reload)
        return await signedIn(tab, after: commits)
    }

    private func poll(_ seconds: Double, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return await condition()
    }
}

/// A site signing in through another host's sign-in service, as a school or company site does:
/// its page sends a visitor without its session cookie to the service, which sends one it knows
/// back with a ticket, which the site trades for its session cookie. Both cookies are session
/// cookies (no expiry). Two listeners on 127.0.0.1 stand for the two hosts.
private final class SignInSite: @unchecked Sendable {
    private let app: NWListener
    private let service: NWListener
    private(set) var appBase = ""
    private(set) var serviceBase = ""

    var signIn: URL { URL(string: "\(serviceBase)/signin")! }
    var home: URL { URL(string: "\(appBase)/home")! }
    var opener: URL { URL(string: "\(appBase)/opener")! }

    private init() throws {
        app = try NWListener(using: .tcp, on: .any)
        service = try NWListener(using: .tcp, on: .any)
    }

    static func start() async throws -> SignInSite {
        let site = try SignInSite()
        site.appBase = try await site.listen(site.app)
        site.serviceBase = try await site.listen(site.service).replacingOccurrences(of: "127.0.0.1", with: "localhost")
        return site
    }

    func stop() {
        app.cancel()
        service.cancel()
    }

    private func listen(_ listener: NWListener) async throws -> String {
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let response = self?.answer(request) ?? "HTTP/1.1 500 Gone\r\nContent-Length: 0\r\n\r\n"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .global())
        for _ in 0..<500 {
            if let port = listener.port, listener.state == .ready { return "http://127.0.0.1:\(port.rawValue)" }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw URLError(.cannotConnectToHost)
    }

    private func answer(_ request: String) -> String {
        let lines = request.components(separatedBy: "\r\n")
        let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let cookies = lines.first { $0.lowercased().hasPrefix("cookie:") } ?? ""
        switch path {
        case "/signin":
            return redirect(to: "\(appBase)/ticket", setting: "service=signed-in")
        case "/sso" where cookies.contains("service=signed-in"):
            return redirect(to: "\(appBase)/ticket")
        case "/sso":
            return page("Sign in")
        case "/ticket":
            return redirect(to: "\(appBase)/home", setting: "session=signed-in")
        case "/home" where cookies.contains("session=signed-in"):
            return page("Signed in")
        case "/home":
            return redirect(to: "\(serviceBase)/sso")
        case "/opener":
            return page("Opener", body: #"<button id="signin" onclick="window.open('\#(serviceBase)/signin', '', 'width=400,height=300')">Sign in</button>"#)
        default:
            return "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        }
    }

    private func redirect(to location: String, setting cookie: String? = nil) -> String {
        let setCookie = cookie.map { "Set-Cookie: \($0); Path=/\r\n" } ?? ""
        return "HTTP/1.1 302 Found\r\nLocation: \(location)\r\n\(setCookie)Cache-Control: no-store\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    }

    private func page(_ title: String, body: String = "") -> String {
        let html = "<title>\(title)</title>\(body)"
        return "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nCache-Control: no-store\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
    }
}

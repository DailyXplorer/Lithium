import Foundation
import Network
import Testing
import WebKit
@testable import Lithium

/// Sign-ins kept in session cookies come back after a relaunch. The file lives in the home
/// folder, so this suite only runs in a throwaway one: `scripts/test --filter SessionCookiesTests`.
/// Three minutes: a check waits its full 20 seconds only when no page settles, and a test makes up
/// to seven, so a regression fails on its check rather than on the time limit.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct SessionCookiesTests {
    private static let day: TimeInterval = 24 * 60 * 60

    @Test func aSavedSessionCookieGoesBackAndTheFileGoes() async throws {
        let saved = try await store(with: [sessionCookie("sid")])
        await SessionCookies.save([Space.mainID: saved])
        let permissions = try FileManager.default.attributesOfItem(atPath: SessionCookies.fileURL.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)

        let restored = WKWebsiteDataStore.nonPersistent()
        await SessionCookies.restore(into: { $0 == Space.mainID ? restored : nil })?.value
        #expect(await restored.httpCookieStore.allCookies().map(\.name) == ["sid"])
        #expect(await restored.httpCookieStore.allCookies().first?.isSessionOnly == true)
        #expect(!FileManager.default.fileExists(atPath: SessionCookies.fileURL.path))
        #expect(SessionCookies.restore(into: { _ in restored }) == nil, "read once")
    }

    @Test func cookiesThatExpireAreLeftToWebKit() async throws {
        let expiring = try #require(HTTPCookie(properties: [.name: "kept", .value: "1", .domain: "127.0.0.1", .path: "/",
                                                            .expires: Date().addingTimeInterval(Self.day)]))
        await SessionCookies.save([Space.mainID: try await store(with: [expiring])])
        #expect(!FileManager.default.fileExists(atPath: SessionCookies.fileURL.path))
    }

    @Test func aFileOlderThanThirtyDaysRestoresNothing() async throws {
        await SessionCookies.save([Space.mainID: try await store(with: [sessionCookie("sid")])], now: Date().addingTimeInterval(-31 * Self.day))
        #expect(SessionCookies.restore(into: { _ in .nonPersistent() }) == nil)
        #expect(!FileManager.default.fileExists(atPath: SessionCookies.fileURL.path))
    }

    @Test func aFileItsKeyCantOpenRestoresNothing() async throws {
        let key = SessionCookies.key
        defer { SessionCookies.key = key }
        await SessionCookies.save([Space.mainID: try await store(with: [sessionCookie("sid")])])
        SessionCookies.key = .memory()
        #expect(SessionCookies.restore(into: { _ in .nonPersistent() }) == nil)
        #expect(!FileManager.default.fileExists(atPath: SessionCookies.fileURL.path))

        SessionCookies.key = SessionCookies.FileKey { _ in nil }
        await SessionCookies.save([Space.mainID: try await store(with: [sessionCookie("sid")])])
        #expect(!FileManager.default.fileExists(atPath: SessionCookies.fileURL.path), "no key, no file")
    }

    @Test func aDamagedFileRestoresNothing() throws {
        try FileManager.default.createDirectory(at: SessionCookies.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a cookie file".utf8).write(to: SessionCookies.fileURL)
        #expect(SessionCookies.restore(into: { _ in .nonPersistent() }) == nil)
        #expect(!FileManager.default.fileExists(atPath: SessionCookies.fileURL.path))
    }

    /// A relaunch: each store gets its own sign-in back, a private tab's stays out, and no page
    /// loads before: neither a restored tab woken at once nor a link opened at once from another app.
    @Test func aRelaunchKeepsEachStoresSignInsAndOnlyItsOwn() async throws {
        let site = try await EchoSite.start()
        defer { site.stop() }
        let (browser, work) = await makeBrowserWithWorkSpace()
        defer { reset(browser) }
        #expect(await title(of: browser.newTab(url: site.set("main"), space: Space.mainID)) == "set")
        #expect(await title(of: browser.newTab(url: site.set("work"), space: work.id)) == "set")
        #expect(await title(of: browser.newTab(url: site.set("private"), privateStore: .nonPersistent())) == "set")
        #expect(await title(of: browser.newTab(url: site.echo, space: Space.mainID)) == "main=1")
        browser.saveNow()
        await browser.saveSessionCookies()
        await forgetLiveCookies(browser)

        let again = Browser()
        defer { reset(again) }
        #expect(again.cookieRestore != nil)
        let restored = try #require(again.tabs.first { $0.url == site.echo && $0.spaceID == Space.mainID })
        restored.markActive()
        again.switchToSpace(work.id)
        again.openFromOtherApp(site.echo)
        #expect(await title(of: restored) == "main=1")
        #expect(await poll { again.tabs.contains { $0.url == site.echo && $0.spaceID == work.id } })
        let opened = try #require(again.tabs.first { $0.url == site.echo && $0.spaceID == work.id })
        #expect(await title(of: opened) == "work=1")
        #expect(!FileManager.default.fileExists(atPath: SessionCookies.fileURL.path))
    }

    /// The site's data cleared from its panel, and a space deleted, before the quit.
    @Test func clearedDataIsntSaved() async throws {
        let site = try await EchoSite.start()
        defer { site.stop() }
        let (browser, work) = await makeBrowserWithWorkSpace()
        defer { reset(browser) }
        #expect(await title(of: browser.newTab(url: site.set("main"), space: Space.mainID)) == "set")
        #expect(await title(of: browser.newTab(url: site.set("work"), space: work.id)) == "set")
        let info = SiteInfo(host: "127.0.0.1", store: .default())
        await info.load()
        await info.clear()
        browser.deleteSpace(work.id)
        await browser.storeCleanup?.value
        await browser.saveSessionCookies()

        // Every store's saved cookies, the deleted space's included, into one.
        let everything = WKWebsiteDataStore.nonPersistent()
        await SessionCookies.restore(into: { _ in everything })?.value
        #expect(await everything.httpCookieStore.allCookies().filter { $0.domain == "127.0.0.1" }.isEmpty)
    }

    // MARK: Helpers

    private func sessionCookie(_ name: String) -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: "1", .domain: "127.0.0.1", .path: "/"])!
    }

    private func store(with cookies: [HTTPCookie]) async throws -> WKWebsiteDataStore {
        let store = WKWebsiteDataStore.nonPersistent()
        for cookie in cookies { await store.httpCookieStore.setCookie(cookie) }
        return store
    }

    /// Without the 127.0.0.1 cookies an earlier test left in the default store.
    private func makeBrowserWithWorkSpace() async -> (Browser, Space) {
        SessionCookies.forget()
        SessionStore.save(Session())
        PinStore.save([])
        let browser = Browser()
        await forgetLiveCookies(browser)
        var work = browser.newSpaceDraft()
        work.name = "Work"
        work.separatesData = true
        browser.addSpace(work)
        return (browser, work)
    }

    /// WebKit keeps session cookies for as long as the process runs: a relaunch starts without them.
    private func forgetLiveCookies(_ browser: Browser) async {
        for store in browser.siteDataStores {
            for cookie in await store.httpCookieStore.allCookies() where cookie.domain == "127.0.0.1" {
                await store.httpCookieStore.deleteCookie(cookie)
            }
        }
    }

    private func reset(_ browser: Browser) {
        browser.tabs.forEach { browser.close($0, remembering: false) }
        for space in browser.spaces.reversed() { browser.deleteSpace(space.id) }
        SessionStore.save(Session())
        SessionCookies.forget()
    }

    /// Nil when no page settles.
    private func title(of tab: Lithium.Tab) async -> String? {
        await poll { tab.commits > 0 && !tab.isLoading && !tab.title.isEmpty } ? tab.title : nil
    }

    private func poll(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}

/// `/set/<name>` sets the session cookie `<name>=1`; `/echo` shows the Cookie header as its title.
private final class EchoSite: @unchecked Sendable {
    private let listener: NWListener
    private(set) var base = ""

    var echo: URL { URL(string: "\(base)/echo")! }
    func set(_ name: String) -> URL { URL(string: "\(base)/set/\(name)")! }

    private init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    static func start() async throws -> EchoSite {
        let site = try EchoSite()
        site.listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                let response = Self.answer(data.map { String(decoding: $0, as: UTF8.self) } ?? "")
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        site.listener.start(queue: .global())
        for _ in 0..<500 {
            if let port = site.listener.port, site.listener.state == .ready {
                site.base = "http://127.0.0.1:\(port.rawValue)"
                return site
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw URLError(.cannotConnectToHost)
    }

    func stop() {
        listener.cancel()
    }

    private static func answer(_ request: String) -> String {
        let lines = request.components(separatedBy: "\r\n")
        let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let cookie = lines.first { $0.lowercased().hasPrefix("cookie:") }.map { $0.dropFirst("cookie:".count).trimmingCharacters(in: .whitespaces) }
        if path.hasPrefix("/set/") {
            return page("set", headers: "Set-Cookie: \(path.dropFirst("/set/".count))=1; Path=/\r\n")
        }
        return path == "/echo" ? page(cookie ?? "none") : "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    }

    private static func page(_ title: String, headers: String = "") -> String {
        let html = "<title>\(title)</title>"
        return "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\(headers)Cache-Control: no-store\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
    }
}

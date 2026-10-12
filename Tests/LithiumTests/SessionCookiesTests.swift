import CryptoKit
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

    @Test func aSavedSessionCookieGoesBackAndTheFileStays() async throws {
        let saved = try await store(with: [sessionCookie("sid")])
        await SessionCookies.save([Space.mainID: saved])
        let permissions = try FileManager.default.attributesOfItem(atPath: SessionCookies.fileURL.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)

        #expect(try FileManager.default.contentsOfDirectory(atPath: SessionCookies.fileURL.deletingLastPathComponent().path)
            .filter { $0.contains("session-cookies") } == ["session-cookies"], "no temporary file left")

        let restored = WKWebsiteDataStore.nonPersistent()
        await SessionCookies.restore(into: { $0 == Space.mainID ? restored : nil })?.value
        #expect(await restored.httpCookieStore.allCookies().map(\.name) == ["sid"])
        #expect(await restored.httpCookieStore.allCookies().first?.isSessionOnly == true)
        #expect(FileManager.default.fileExists(atPath: SessionCookies.fileURL.path), "kept for a crash before the next save")
    }

    @Test func cookiesThatExpireAreLeftToWebKit() async throws {
        let expiring = try #require(HTTPCookie(properties: [.name: "kept", .value: "1", .domain: "127.0.0.1", .path: "/",
                                                            .expires: Date().addingTimeInterval(Self.day)]))
        await SessionCookies.save([Space.mainID: try await store(with: [expiring])])
        #expect(!FileManager.default.fileExists(atPath: SessionCookies.fileURL.path))
    }

    @Test func aFileOlderThanThirtyDaysRestoresNothing() async throws {
        await SessionCookies.save([Space.mainID: try await store(with: [sessionCookie("sid")])], now: Date().addingTimeInterval(-31 * Self.day))
        #expect(await restoresNothing())
    }

    @Test func aFileItsKeyCantOpenRestoresNothing() async throws {
        let key = SessionCookies.key
        defer { SessionCookies.key = key }
        await SessionCookies.save([Space.mainID: try await store(with: [sessionCookie("sid")])])
        SessionCookies.key = .memory()
        #expect(await restoresNothing())

        SessionCookies.key = SessionCookies.FileKey { _ in nil }
        await SessionCookies.save([Space.mainID: try await store(with: [sessionCookie("sid")])])
        #expect(!FileManager.default.fileExists(atPath: SessionCookies.fileURL.path), "no key, no file")
    }

    /// The Keychain may block on a prompt: a key that only comes off the main thread still works.
    @Test func theKeyIsReadOffTheMainThread() async throws {
        let key = SessionCookies.key
        defer { SessionCookies.key = key }
        let secret = SymmetricKey(size: .bits256)
        SessionCookies.key = SessionCookies.FileKey { _ in Thread.isMainThread ? nil : secret }
        await SessionCookies.save([Space.mainID: try await store(with: [sessionCookie("sid")])])
        let restored = WKWebsiteDataStore.nonPersistent()
        await SessionCookies.restore(into: { _ in restored })?.value
        #expect(await restored.httpCookieStore.allCookies().map(\.name) == ["sid"])
    }

    @Test func aDamagedFileRestoresNothing() async throws {
        try FileManager.default.createDirectory(at: SessionCookies.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a cookie file".utf8).write(to: SessionCookies.fileURL)
        #expect(await restoresNothing())
    }

    /// A site cleared after the restore picked its cookies, while one is still on its way to WebKit
    /// (held past the pages' bound): the clear ran without it, so it goes once it lands.
    @Test func aCookieClearedOnItsWayIsGoneOnceItLands() async throws {
        await SessionCookies.save([Space.mainID: try await store(with: [sessionCookie("sid")])])
        let restored = WKWebsiteDataStore.nonPersistent()
        var cleared = false
        let restoring = try #require(SessionCookies.restore(into: { _ in restored }, skipping: { _, _ in
            defer { cleared = true }
            return cleared
        }))
        await restoring.value
        #expect(await restored.httpCookieStore.allCookies().isEmpty)
    }

    /// A restore stuck in WebKit holds pages back no longer than the limit.
    @Test func aStuckRestoreIsWaitedForAtMostItsLimit() async {
        let stuck = Task<Void, Never> { try? await Task<Never, Never>.sleep(for: .seconds(60)) }
        defer { stuck.cancel() }
        let start = ContinuousClock.now
        await stuck.wait(atMost: .milliseconds(100))
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(!stuck.isCancelled, "goes on")
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
        #expect(restored.isAsleep, "waits for the cookies")
        again.switchToSpace(work.id)
        again.openFromOtherApp(site.echo)
        #expect(!again.tabs.contains { $0.url == site.echo && $0.spaceID == work.id }, "waits for the cookies")
        #expect(await title(of: restored) == "main=1")
        #expect(await poll { again.tabs.contains { $0.url == site.echo && $0.spaceID == work.id } })
        let opened = try #require(again.tabs.first { $0.url == site.echo && $0.spaceID == work.id })
        #expect(await title(of: opened) == "work=1")
        // A crash now, before any save, still finds them at the next launch.
        #expect(await savedCookies(of: [Space.mainID, work.id]) == [Space.mainID: ["main"], work.id: ["work"]])
    }

    /// Without a quit: the session save alone writes them, for a relaunch after a crash.
    @Test func theSessionSaveKeepsThemForACrash() async throws {
        let site = try await EchoSite.start()
        defer { site.stop() }
        let (browser, work) = await makeBrowserWithWorkSpace()
        defer { reset(browser) }
        browser.cookieSaveInterval = .zero
        #expect(await title(of: browser.newTab(url: site.set("main"), space: Space.mainID)) == "set")
        #expect(await title(of: browser.newTab(url: site.set("work"), space: work.id)) == "set")
        // A session save comes a second after this tab opens.
        #expect(await title(of: browser.newTab(url: site.echo, space: Space.mainID)) == "main=1")
        try await Task.sleep(for: Browser.sessionSaveDelay * 2)
        browser.cookieSaveInterval = nil
        await browser.cookieSave?.value

        #expect(await savedCookies(of: [Space.mainID, work.id]) == [Space.mainID: ["main"], work.id: ["work"]])
    }

    /// A sign-in soon after a session save, then no change: saved once the next save is due.
    @Test func aSignInSoonAfterASaveIsSavedWhenTheNextIsDue() async throws {
        let site = try await EchoSite.start()
        defer { site.stop() }
        let (browser, _) = await makeBrowserWithWorkSpace()
        defer { reset(browser) }
        browser.cookieSaveInterval = .seconds(4)
        #expect(await title(of: browser.newTab(url: site.echo, space: Space.mainID)) == "none")
        try await Task.sleep(for: Browser.sessionSaveDelay * 2)
        await (try #require(browser.cookieSave, "saved with the session")).value
        #expect(await title(of: browser.newTab(url: site.set("main"), space: Space.mainID)) == "set")
        #expect(await poll { FileManager.default.fileExists(atPath: SessionCookies.fileURL.path) })
        browser.cookieSaveInterval = nil
        await browser.cookieSave?.value

        #expect(await savedCookies(of: [Space.mainID]) == [Space.mainID: ["main"]])
    }

    /// A restore held up past the pages' limit (a Keychain prompt left open): a save waits for
    /// it rather than drop the cookies still going back.
    @Test func aSaveWaitsForARestorePastItsLimit() async throws {
        let site = try await EchoSite.start()
        defer { site.stop() }
        let key = SessionCookies.key
        defer { SessionCookies.key = key }
        let secret = SymmetricKey(size: .bits256)
        SessionCookies.key = SessionCookies.FileKey { _ in secret }
        let (browser, _) = await makeBrowserWithWorkSpace()
        defer { reset(browser) }
        #expect(await title(of: browser.newTab(url: site.set("main"), space: Space.mainID)) == "set")
        browser.saveNow()
        await browser.saveSessionCookies()
        await forgetLiveCookies(browser)

        let answered = DispatchSemaphore(value: 0)
        defer { answered.signal() }
        SessionCookies.key = SessionCookies.FileKey { creating in
            if !creating { answered.wait() }
            return secret
        }
        let again = Browser()
        defer { reset(again) }
        let saving = Task { await again.saveSessionCookies() }
        try await Task.sleep(for: .seconds(6))
        #expect(again.cookieRestore == nil, "pages stopped waiting")
        #expect(FileManager.default.fileExists(atPath: SessionCookies.fileURL.path), "kept while the cookies are still going back")
        answered.signal()
        await saving.value

        SessionCookies.key = SessionCookies.FileKey { _ in secret }
        #expect(await savedCookies(of: [Space.mainID]) == [Space.mainID: ["main"]])
    }

    /// The site's data cleared from its panel, and a space deleted, after the cookies were saved.
    @Test func clearedDataIsntSaved() async throws {
        let site = try await EchoSite.start()
        defer { site.stop() }
        let (browser, work) = await makeBrowserWithWorkSpace()
        defer { reset(browser) }
        #expect(await title(of: browser.newTab(url: site.set("main"), space: Space.mainID)) == "set")
        #expect(await title(of: browser.newTab(url: site.set("work"), space: work.id)) == "set")
        await browser.saveSessionCookies()
        #expect(FileManager.default.fileExists(atPath: SessionCookies.fileURL.path), "saved before the clears")
        await browser.clearData([SiteInfo(host: "127.0.0.1", store: .default())]).value
        browser.deleteSpace(work.id)
        await browser.storeCleanup?.value

        #expect(await savedCookies(of: [Space.mainID, work.id]) == [:])
    }

    /// A quit while a site's data is still being cleared waits for the clear.
    @Test func aQuitDuringAClearDoesntSaveWhatItClears() async throws {
        let site = try await EchoSite.start()
        defer { site.stop() }
        let (browser, _) = await makeBrowserWithWorkSpace()
        defer { reset(browser) }
        #expect(await title(of: browser.newTab(url: site.set("main"), space: Space.mainID)) == "set")
        await browser.saveSessionCookies()
        #expect(FileManager.default.fileExists(atPath: SessionCookies.fileURL.path), "saved before the clear")
        let clearing = browser.clearData([SiteInfo(host: "127.0.0.1", store: .default())])
        await browser.saveSessionCookies()
        #expect(await savedCookies(of: [Space.mainID]) == [:])
        await clearing.value
    }

    /// A quit that stops waiting for its save during a clear: the cleared site's cookies leave the
    /// file rather than come back at the next launch, and other sites' stay.
    @Test func aQuitCutShortDuringAClearDropsOnlyWhatItClears() async throws {
        let site = try await EchoSite.start()
        defer { site.stop() }
        let (browser, _) = await makeBrowserWithWorkSpace()
        defer { reset(browser) }
        let other = sessionCookie("other", domain: "example.test")
        await WKWebsiteDataStore.default().httpCookieStore.setCookie(other)
        #expect(await title(of: browser.newTab(url: site.set("main"), space: Space.mainID)) == "set")
        await browser.saveSessionCookies()
        browser.cookieSaveCutShort()
        #expect(await savedCookies(of: [Space.mainID]) == [Space.mainID: ["main"]], "kept without a clear")

        let clearing = browser.clearData([SiteInfo(host: "127.0.0.1", store: .default())])
        browser.cookieSaveCutShort()
        #expect(await savedCookies(of: [Space.mainID]) == [:])
        #expect(await savedCookies(of: [Space.mainID], domain: "example.test") == [Space.mainID: ["other"]])
        await clearing.value

        // Once the clear's save is done, a quit cut short leaves a new sign-in alone.
        #expect(await title(of: browser.newTab(url: site.set("again"), space: Space.mainID)) == "set")
        await browser.saveSessionCookies()
        browser.cookieSaveCutShort()
        #expect(await savedCookies(of: [Space.mainID]) == [Space.mainID: ["again"]])
        await WKWebsiteDataStore.default().httpCookieStore.deleteCookie(other)
    }

    /// The Clear button stops at the click, though the clear may wait for the restore.
    @Test func aClearShowsAtOnce() async {
        let (browser, _) = await makeBrowserWithWorkSpace()
        defer { reset(browser) }
        let info = SiteInfo(host: "127.0.0.1", store: .default())
        let clearing = browser.clearData([info])
        #expect(info.isClearing)
        await clearing.value
        #expect(!info.isClearing)
    }

    /// Cleared as Lithium opens, before the restored cookies are back: they don't come back after.
    @Test func aClearAtLaunchWinsOverTheRestore() async throws {
        let site = try await EchoSite.start()
        defer { site.stop() }
        let (browser, _) = await makeBrowserWithWorkSpace()
        defer { reset(browser) }
        #expect(await title(of: browser.newTab(url: site.set("main"), space: Space.mainID)) == "set")
        browser.saveNow()
        await browser.saveSessionCookies()
        await forgetLiveCookies(browser)

        let again = Browser()
        defer { reset(again) }
        #expect(again.cookieRestore != nil)
        await again.clearData([SiteInfo(host: "127.0.0.1", store: .default())]).value
        await again.cookieRestore?.value
        #expect(await WKWebsiteDataStore.default().httpCookieStore.allCookies().filter { $0.domain == "127.0.0.1" }.isEmpty)
    }

    /// A clear while the restore is held up (a Keychain prompt left open) goes ahead once pages
    /// stop waiting, and the restore, when it comes, leaves the cleared site out.
    @Test func aClearDuringAHeldUpRestoreGoesAheadAndWins() async throws {
        let site = try await EchoSite.start()
        defer { site.stop() }
        let key = SessionCookies.key
        defer { SessionCookies.key = key }
        let secret = SymmetricKey(size: .bits256)
        SessionCookies.key = SessionCookies.FileKey { _ in secret }
        let (browser, _) = await makeBrowserWithWorkSpace()
        defer { reset(browser) }
        #expect(await title(of: browser.newTab(url: site.set("main"), space: Space.mainID)) == "set")
        browser.saveNow()
        await browser.saveSessionCookies()
        await forgetLiveCookies(browser)

        let answered = DispatchSemaphore(value: 0)
        defer { answered.signal() }
        SessionCookies.key = SessionCookies.FileKey { creating in
            if !creating { answered.wait() }
            return secret
        }
        let again = Browser()
        defer { reset(again) }
        let info = SiteInfo(host: "127.0.0.1", store: .default())
        let clearing = again.clearData([info])
        try await Task.sleep(for: .seconds(6))
        #expect(!info.isClearing, "went ahead")
        answered.signal()
        await clearing.value

        #expect(await WKWebsiteDataStore.default().httpCookieStore.allCookies().filter { $0.domain == "127.0.0.1" }.isEmpty)
        SessionCookies.key = SessionCookies.FileKey { _ in secret }
        #expect(await savedCookies(of: [Space.mainID]) == [:])
    }

    /// Session changes while the restore is held up: one save once it is back, not one per change.
    @Test func savesHeldUpByTheRestoreAreOne() async throws {
        let site = try await EchoSite.start()
        defer { site.stop() }
        let key = SessionCookies.key
        defer { SessionCookies.key = key }
        let secret = SymmetricKey(size: .bits256)
        SessionCookies.key = SessionCookies.FileKey { _ in secret }
        let (browser, _) = await makeBrowserWithWorkSpace()
        defer { reset(browser) }
        #expect(await title(of: browser.newTab(url: site.set("main"), space: Space.mainID)) == "set")
        browser.saveNow()
        await browser.saveSessionCookies()
        await forgetLiveCookies(browser)

        let answered = DispatchSemaphore(value: 0)
        defer { answered.signal() }
        let saves = Count()
        SessionCookies.key = SessionCookies.FileKey { creating in
            if creating { saves.add() } else { answered.wait() }
            return secret
        }
        let again = Browser()
        defer { reset(again) }
        again.cookieSaveInterval = .milliseconds(100)
        for name in ["a", "b", "c"] {
            #expect(await title(of: again.newTab(url: site.set(name), space: Space.mainID)) == "set")
            try await Task.sleep(for: Browser.sessionSaveDelay * 2)
        }
        // Only the saves the changes above asked for.
        again.cookieSaveInterval = nil
        answered.signal()
        #expect(await poll { saves.value > 0 })
        try await Task.sleep(for: .seconds(1))
        #expect(saves.value == 1)
    }

    /// A space's store opens with its first page: a save doesn't open one to look in it.
    @Test func aSaveLeavesStoresNotInUseAlone() async {
        let (browser, work) = await makeBrowserWithWorkSpace()
        defer { reset(browser) }
        await browser.saveSessionCookies()
        #expect(browser.spaceStores[work.id] == nil)
    }

    // MARK: Helpers

    private func sessionCookie(_ name: String, domain: String = "127.0.0.1") -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: "1", .domain: domain, .path: "/"])!
    }

    private func store(with cookies: [HTTPCookie]) async throws -> WKWebsiteDataStore {
        let store = WKWebsiteDataStore.nonPersistent()
        for cookie in cookies { await store.httpCookieStore.setCookie(cookie) }
        return store
    }

    /// Restored into a store of its own, which a file that can't be read leaves empty.
    private func restoresNothing() async -> Bool {
        let probe = WKWebsiteDataStore.nonPersistent()
        await SessionCookies.restore(into: { _ in probe })?.value
        return await probe.httpCookieStore.allCookies().isEmpty
    }

    /// The names of the `domain` cookies saved for each store, read by a restore.
    private func savedCookies(of ids: [Space.ID], domain: String = "127.0.0.1") async -> [Space.ID: [String]] {
        let probes = Dictionary(uniqueKeysWithValues: ids.map { ($0, WKWebsiteDataStore.nonPersistent()) })
        await SessionCookies.restore(into: { probes[$0] })?.value
        var names: [Space.ID: [String]] = [:]
        for (id, probe) in probes {
            let found = await probe.httpCookieStore.allCookies().filter { $0.domain == domain }.map(\.name).sorted()
            if !found.isEmpty { names[id] = found }
        }
        return names
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

/// Bumped from the Keychain seam, off the main thread.
private final class Count: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

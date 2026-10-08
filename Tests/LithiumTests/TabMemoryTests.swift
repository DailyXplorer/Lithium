import Darwin
import Foundation
import Testing
import WebKit
@testable import Lithium

/// What a tab holds once it is closed or asleep. A whole Browser, so only in a throwaway home:
/// `CFFIXED_USER_HOME=$(mktemp -d) swift test --filter TabMemoryTests`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct TabMemoryTests {
    @Test func closedTabIsFreed() async throws {
        let (listener, base) = try await LocalHTTP.serve(["/": ("Content-Type: text/html", "<title>Page</title>page")])
        defer { listener.cancel() }
        let browser = Browser()
        weak var weakTab: Tab?
        weak var weakWebView: WKWebView?
        var process: pid_t = 0
        do {
            let tab = browser.newTab(url: base)
            #expect(await waitUntil(60) { loaded(tab) })
            weakTab = tab
            weakWebView = tab.webView
            process = pid(tab)
            browser.close(tab)
        }
        #expect(await waitUntil(10) { weakTab == nil }, "the closed tab is freed")
        #expect(await waitUntil(10) { weakWebView == nil }, "its web view is freed")
        #expect(await waitUntil(10) { !isRunning(process) }, "its page's process exits")
    }

    /// An icon that takes its time doesn't keep a closed tab, or its page, alive until it comes.
    @Test func closedTabIsFreedWhileItsIconIsStillLoading() async throws {
        let iconRequested = Flag()
        let (iconServer, iconBase) = try await LocalHTTP.serve(
            ["/icon.png": ("Content-Type: image/png", Data())], delay: 60, requested: { _ in iconRequested.set() }
        )
        defer { iconServer.cancel() }
        let page = #"<title>Page</title><link rel="icon" href="\#(iconBase.appending(path: "icon.png").absoluteString)">page"#
        let (listener, base) = try await LocalHTTP.serve(["/": ("Content-Type: text/html", page)])
        defer { listener.cancel() }
        let favicons = Favicons(folder: FileManager.default.temporaryDirectory.appending(path: "tab-memory-icons-\(UUID().uuidString)"))
        let browser = Browser(favicons: favicons, notifications: NotificationCenter())
        weak var weakTab: Tab?
        weak var weakWebView: WKWebView?
        do {
            let tab = browser.newTab(url: base)
            #expect(await waitUntil(60) { loaded(tab) })
            #expect(await waitUntil(30) { iconRequested.isSet })
            weakTab = tab
            weakWebView = tab.webView
            browser.close(tab)
        }
        #expect(await waitUntil(10) { weakTab == nil }, "the closed tab is freed")
        #expect(await waitUntil(10) { weakWebView == nil }, "its web view is freed")
    }

    @Test func sleepingTabDropsItsWebView() async throws {
        let (listener, base) = try await LocalHTTP.serve(["/": ("Content-Type: text/html", "<title>Page</title>page")])
        defer { listener.cancel() }
        let browser = Browser()
        let tab = browser.newTab(url: base)
        defer { browser.close(tab) }
        weak var weakWebView: WKWebView?
        var process: pid_t = 0
        do {
            #expect(await waitUntil(60) { loaded(tab) })
            weakWebView = tab.webView
            process = pid(tab)
            browser.newTab(url: URL(string: "data:text/html,other")!)
            tab.sleep(configuration: browser.makeConfiguration(for: tab.url))
        }
        #expect(tab.isAsleep)
        #expect(await waitUntil(10) { weakWebView == nil }, "the sleeping tab's web view is freed")
        #expect(await waitUntil(10) { !isRunning(process) }, "its page's process exits")
    }

    /// Reload on a sleeping tab (its sidebar menu) wakes it on its page, rather than leaving an
    /// empty web view on a tab that stays asleep.
    @Test func reloadingASleepingTabWakesIt() async throws {
        let (listener, base) = try await LocalHTTP.serve(["/": ("Content-Type: text/html", "<title>Page</title>page")])
        defer { listener.cancel() }
        let browser = Browser()
        let tab = browser.newTab(url: base)
        defer { browser.close(tab) }
        #expect(await waitUntil(60) { loaded(tab) })
        let other = browser.newTab(url: URL(string: "data:text/html,other")!)
        defer { browser.close(other) }
        tab.sleep(configuration: browser.makeConfiguration(for: tab.url))
        #expect(tab.isAsleep)

        browser.navigate(tab, .reload)
        #expect(!tab.isAsleep)
        #expect(await waitUntil(30) { loaded(tab) && tab.webView.title == "Page" })
        #expect(tab.webView.url == base)
    }

    /// Low memory spares tabs used a moment ago, a popup and its opener included. Critical memory
    /// puts every background tab to sleep, a favorite's page and a popup pair too, and their
    /// processes exit; the selected tab stays awake, and a slept one wakes on its page.
    @Test func memoryPressureSleepsEveryBackgroundTabButTheSelectedOne() async throws {
        let browser = Browser()
        let idle = browser.newTab(url: URL(string: "data:text/html,<title>Idle</title>idle")!, selecting: false)
        let favorite = browser.newTab(url: URL(string: "data:text/html,favorite")!, selecting: false)
        browser.pin(favorite)
        defer { browser.pins.filter { $0.id == favorite.pinID }.forEach(browser.unpin) }
        let opener = browser.newTab(url: URL(string: "data:text/html,opener")!, selecting: false)
        let popup = browser.newTab(url: URL(string: "data:text/html,popup")!, selecting: false)
        popup.opener = opener
        let selected = browser.newTab(url: URL(string: "data:text/html,selected")!)
        let background = [idle, favorite, opener, popup]
        defer { (background + [selected]).forEach(browser.close) }
        #expect(await waitUntil(120) { (background + [selected]).allSatisfy(loaded) })
        let processes = background.map(pid)

        browser.relieveMemoryPressure(critical: false)
        #expect(background.allSatisfy { !$0.isAsleep }, "tabs used a moment ago stay awake while memory is only low")

        browser.relieveMemoryPressure(critical: true)
        #expect(background.allSatisfy { $0.isAsleep })
        #expect(!selected.isAsleep)
        #expect(await waitUntil(10) { !processes.contains(where: isRunning) }, "the slept tabs' processes exit")

        browser.select(idle)
        #expect(await waitUntil(10) { loaded(idle) && idle.webView.title == "Idle" })
    }

    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private func pid(_ tab: Tab) -> pid_t {
        (tab.webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value ?? 0
    }

    private func loaded(_ tab: Tab) -> Bool {
        !tab.isAsleep && !tab.webView.isLoading && tab.webView.url != nil && pid(tab) > 0
    }

    private func isRunning(_ process: pid_t) -> Bool {
        process > 0 && kill(process, 0) == 0
    }

    /// Set from Network's queue, read on the main actor.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }
}

@MainActor
struct FaviconCacheTests {
    /// Past its limit, the memory cache drops the least recently used icon, which is read from disk again.
    @Test func memoryCacheEvictsLeastRecentlyUsed() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "lithium-favicons-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let favicons = Favicons(folder: folder, cacheLimit: 2)
        let hosts = ["a.example", "b.example", "c.example"]
        for host in hosts { try Data(host.utf8).write(to: folder.appending(path: "\(host).png")) }
        #expect(favicons.cachedData(host: "a.example") == Data("a.example".utf8))
        #expect(favicons.cachedData(host: "b.example") == Data("b.example".utf8))
        #expect(favicons.cachedData(host: "a.example") == Data("a.example".utf8))
        #expect(favicons.cachedData(host: "c.example") == Data("c.example".utf8))

        for host in hosts { try FileManager.default.removeItem(at: folder.appending(path: "\(host).png")) }
        #expect(favicons.cachedData(host: "a.example") == Data("a.example".utf8), "a recent read kept it in memory")
        #expect(favicons.cachedData(host: "c.example") == Data("c.example".utf8), "the newest icon is in memory")
        #expect(favicons.cachedData(host: "b.example") == nil, "the least recently used icon was dropped")
    }

    @Test func memoryCacheNeverExceedsItsLimit() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "lithium-favicons-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let favicons = Favicons(folder: folder, cacheLimit: 2)
        let hosts = (0..<10).map { "\($0).example" }
        for host in hosts { try Data(host.utf8).write(to: folder.appending(path: "\(host).png")) }
        for host in hosts { _ = favicons.cachedData(host: host) }

        for host in hosts { try FileManager.default.removeItem(at: folder.appending(path: "\(host).png")) }
        #expect(hosts.filter { favicons.cachedData(host: $0) != nil } == ["8.example", "9.example"])
    }
}

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
}

@MainActor
struct FaviconCacheTests {
    /// Past its limit, the memory cache starts over; icons dropped from it are read from disk again.
    @Test func memoryCacheIsBounded() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "lithium-favicons-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let favicons = Favicons(folder: folder, cacheLimit: 2)
        let hosts = ["a.example", "b.example", "c.example"]
        for host in hosts { try Data(host.utf8).write(to: folder.appending(path: "\(host).png")) }
        for host in hosts { #expect(favicons.cachedData(host: host) == Data(host.utf8)) }

        for host in hosts { try FileManager.default.removeItem(at: folder.appending(path: "\(host).png")) }
        #expect(favicons.cachedData(host: "c.example") == Data("c.example".utf8), "the last icon is still in memory")
        #expect(favicons.cachedData(host: "a.example") == nil, "the first one was dropped from memory")
        #expect(favicons.cachedData(host: "b.example") == nil)
    }
}

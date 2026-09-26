import Darwin
import Foundation
import Testing
import WebKit
@testable import Lithium

/// A whole Browser: its tabs, their web processes and its background loops. It keeps its data
/// in the home folder, so this suite only runs in a throwaway one:
/// `CFFIXED_USER_HOME=$(mktemp -d) swift test --filter BrowserTests`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct BrowserTests {
    /// The tab restored at launch opens before the in-page engine is built (first launch, new lists,
    /// new uBO scriptlets); it must still get uBO's YouTube scriptlets, or its video plays an ad.
    @Test func restoredTabGetsTheAdScriptletsWhileTheEngineBuilds() async throws {
        try? FileManager.default.removeItem(at: URL.applicationSupportDirectory.appending(path: "Lithium/AdvancedEngine"))
        let url = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
        SessionStore.save(Session(tabs: [.init(url: url, title: "YouTube", customTitle: nil, pinID: nil)], selectedIndex: 0))
        let browser = Browser()
        let tab = try #require(browser.selectedTab)
        browser.windowDidAppear()
        let controller = tab.webView.configuration.userContentController
        #expect(await waitUntil(120) { !controller.userScripts.isEmpty })
        #expect(controller.userScripts.contains { $0.source.contains("function trustedJsonEditXhrRequest(") })
    }

    /// A tab out of sight waits to be selected; the visible one reloads once, then stops.
    @Test func crashedTabs() async throws {
        let browser = Browser()
        let visible = browser.newTab(url: URL(string: "data:text/html,<title>Visible</title>visible")!)
        let background = browser.newTab(url: URL(string: "data:text/html,<title>Background</title>background")!, selecting: false)
        #expect(await waitUntil(120) { loaded(visible) && loaded(background) })

        try crash(background)
        #expect(await waitUntil(5) { background.isAsleep })
        #expect(pid(background) == 0)

        var before = pid(visible)
        try crash(visible)
        #expect(await waitUntil(5) { pid(visible) != before && loaded(visible) })
        #expect(visible.webView.title == "Visible")

        before = pid(visible)
        try crash(visible)
        #expect(await waitUntil(5) { visible.webView.title == "Can’t open this page" })

        browser.select(background)
        #expect(await waitUntil(10) { loaded(background) })
        #expect(background.webView.title == "Background")
    }

    /// Putting a tab to sleep waits on its page's process; a tab selected meanwhile stays awake.
    @Test func selectedTabNeverFallsAsleep() async throws {
        UserDefaults.standard.set(0.002, forKey: "tabIdleSeconds")
        defer { UserDefaults.standard.removeObject(forKey: "tabIdleSeconds") }
        let browser = Browser()
        let first = browser.newTab(url: URL(string: "data:text/html,first")!)
        let second = browser.newTab(url: URL(string: "data:text/html,second")!)
        #expect(await waitUntil(120) { loaded(second) })
        for _ in 0..<200 {
            browser.select(second)
            guard await waitUntil(5, { loaded(second) }) else { continue }
            browser.select(first)
            try await Task.sleep(for: .microseconds(Int.random(in: 1_500...3_500)))
            browser.select(second)
            try await Task.sleep(for: .milliseconds(5))
            #expect(!second.isAsleep, "the selected tab was put to sleep")
            if second.isAsleep { break }
        }
    }

    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func pid(_ tab: Tab) -> pid_t {
        (tab.webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value ?? 0
    }

    private func loaded(_ tab: Tab) -> Bool {
        !tab.isAsleep && !tab.webView.isLoading && tab.webView.url != nil && pid(tab) > 0
    }

    /// Kills the tab's own web process, the way a crash would.
    private func crash(_ tab: Tab) throws {
        let target = pid(tab)
        var name = [UInt8](repeating: 0, count: 256)
        proc_name(target, &name, 256)
        try #require(target > 0 && String(decoding: name.prefix { $0 != 0 }, as: UTF8.self) == "com.apple.WebKit.WebContent")
        kill(target, SIGKILL)
    }
}

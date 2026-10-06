import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Lithium

/// Control-Tab through recently used tabs, closing back to the opener, and the tab menu's Sleep
/// Other Tabs, Copy Link and Close Tabs Above. A whole Browser, so only in a throwaway home:
/// `./scripts/test --filter TabCommandsTests`.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct TabCommandsTests {
    private static let prefix = "data:text/html,"

    /// A browser whose tab list reads `names` top to bottom, the top one shown last, and no other
    /// tab open: a favorite's page left by another suite would join the recent tabs.
    private func browser(with names: [String]) -> Browser {
        let browser = Browser()
        browser.tabs.forEach(browser.close)
        for name in names.reversed() { browser.newTab(url: page(name)) }
        return browser
    }

    private func page(_ name: String) -> URL {
        URL(string: Self.prefix + name)!
    }

    private func names(_ browser: Browser) -> [String] {
        browser.regularTabs.map(name)
    }

    private func name(_ tab: Lithium.Tab?) -> String {
        String(tab?.url?.absoluteString.dropFirst(Self.prefix.count) ?? "")
    }

    private func tab(_ name: String, in browser: Browser) -> Lithium.Tab {
        browser.tabs.first { $0.url == page(name) }!
    }

    @Test func controlTabGoesThroughRecentTabsAndLettingGoCommits() {
        let browser = browser(with: ["a", "b", "c", "d"])
        for name in ["b", "c", "d"] { browser.select(tab(name, in: browser)) }

        browser.cycleRecentTabs(backward: false, holdingControl: true)
        #expect(name(browser.recentTabs.target) == "c")
        browser.cycleRecentTabs(backward: false, holdingControl: true)
        #expect(name(browser.recentTabs.target) == "b")
        #expect(browser.recentTabs.cycle.map(name) == ["d", "c", "b", "a"])
        #expect(name(browser.selectedTab) == "d", "nothing switches while Control is held")

        browser.endTabCycle(commit: true)
        #expect(name(browser.selectedTab) == "b")
        #expect(browser.recentTabs.cycle.isEmpty)

        browser.cycleRecentTabs(backward: false, holdingControl: false)
        #expect(name(browser.selectedTab) == "d", "a single press goes back to the tab shown before")

        browser.cycleRecentTabs(backward: true, holdingControl: true)
        #expect(name(browser.recentTabs.target) == "a", "back goes to the tab shown longest ago")
        browser.cycleRecentTabs(backward: true, holdingControl: true)
        #expect(name(browser.recentTabs.target) == "c")
        #expect(browser.dismissOverlay(), "Escape ends the cycle")
        #expect(name(browser.selectedTab) == "d")
        #expect(browser.recentTabs.target == nil)

        browser.selectAdjacentTab(-1)
        #expect(name(browser.selectedTab) == "c", "⌘⌥← still walks the list in its order")
    }

    @Test func controlTabSkipsATabClosedMidCycle() {
        let browser = browser(with: ["a", "b"])
        browser.cycleRecentTabs(backward: false, holdingControl: true)
        #expect(name(browser.recentTabs.target) == "b")
        browser.close(tab("b", in: browser))
        browser.endTabCycle(commit: true)
        #expect(name(browser.selectedTab) == "a")
    }

    @Test func closingATabOpenedFromTheShownOneGoesBackToItsOpener() {
        let browser = browser(with: ["a", "b", "c"])
        let b = tab("b", in: browser)
        browser.select(b)

        browser.close(browser.newTab(url: page("link"), openedFrom: b))
        #expect(name(browser.selectedTab) == "b", "a link opened in front")

        let background = browser.newTab(url: page("command-click"), selecting: false, openedFrom: b)
        browser.select(background)
        browser.close(background)
        #expect(name(browser.selectedTab) == "b", "a ⌘-click, then straight to it")

        let visited = browser.newTab(url: page("visited"), openedFrom: b)
        browser.select(tab("c", in: browser))
        browser.select(visited)
        browser.close(visited)
        #expect(name(browser.selectedTab) == "a", "after another tab was shown, the neighbour")

        browser.select(b)
        let later = browser.newTab(url: page("later"), selecting: false, openedFrom: b)
        browser.select(tab("c", in: browser))
        browser.select(b)
        browser.select(later)
        browser.close(later)
        #expect(name(browser.selectedTab) == "a", "opened, then another tab shown before it")

        browser.select(b)
        let orphan = browser.newTab(url: page("orphan"), openedFrom: b)
        browser.close(b)
        browser.close(orphan)
        #expect(name(browser.selectedTab) == "a", "its opener closed, the neighbour")
    }

    @Test func sleepOtherTabsSparesTheShownOneFavoritesAndAgentTabs() async throws {
        let browser = browser(with: ["shown", "other", "clicked"])
        let favorite = browser.newTab(url: page("favorite"), selecting: false)
        browser.pin(favorite)
        defer { browser.pins.filter { $0.id == favorite.pinID }.forEach(browser.unpin) }
        let agents = browser.newAgentTab(session: "s1")
        agents.load(page("agent"))
        browser.select(tab("shown", in: browser))
        let all = browser.tabs
        #expect(await waitUntil(30) { all.allSatisfy { !$0.webView.isLoading && $0.webView.url != nil } })

        browser.sleepOtherTabs(than: tab("clicked", in: browser))
        #expect(browser.tabs.filter { $0.isAsleep }.map(name) == ["other"])
    }

    @Test func copyLinkPutsOneAddressPerLine() {
        let browser = browser(with: ["a", "b"])
        let blank = browser.newTab()
        #expect(Browser.links(of: [tab("b", in: browser), blank, tab("a", in: browser)]) == "\(Self.prefix)b\n\(Self.prefix)a")
    }

    @Test func closeTabsAbove() {
        let browser = browser(with: ["a", "b", "c", "d", "e"])
        browser.select(tab("b", in: browser))
        browser.closeTabs(above: tab("d", in: browser))
        #expect(names(browser) == ["d", "e"])
        #expect(name(browser.selectedTab) == "d")
        #expect(browser.tabs(above: tab("d", in: browser)).isEmpty)

        browser.reopenClosedTab()
        #expect(names(browser) == ["a", "d", "e"])
        browser.reopenClosedTab()
        #expect(names(browser) == ["a", "b", "d", "e"])
    }

    @Test func closeTabsAboveStaysInTheTabsGroup() {
        let browser = browser(with: ["a", "b"])
        for name in ["x", "y", "z"] { browser.newAgentTab(session: "s1").load(page(name)) }
        browser.closeTabs(above: tab("y", in: browser))
        #expect(browser.agentTabs.map(name) == ["y", "z"])
        #expect(names(browser) == ["a", "b"])
    }

    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !Task.isCancelled {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}

/// The Control-Tab list, for a look without launching the app:
/// `LITHIUM_SNAPSHOT_DIR=/tmp/shots ./scripts/test --filter TabCycleSnapshotTests`.
@MainActor
@Suite(.timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["LITHIUM_SNAPSHOT_DIR"] != nil, "Writes PNGs only when LITHIUM_SNAPSHOT_DIR is set"))
struct TabCycleSnapshotTests {
    @Test func tabCycleSnapshots() throws {
        let directory = URL(filePath: ProcessInfo.processInfo.environment["LITHIUM_SNAPSHOT_DIR"] ?? "/tmp")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Theme.registerFonts()
        let rows = [("github.com", "Pull requests · lithium"), ("news.ycombinator.com", "Hacker News"),
                    ("developer.apple.com", "WKWebView | Apple Developer Documentation"), ("example.com", "")]
            .map { TabCycleOverlay.Row(id: UUID(), icon: nil, host: $0.0, title: $0.1) }
        for isDark in [false, true] {
            let view = TabCycleOverlay(rows: rows, highlighted: 1).padding(24)
            let hosting = NSHostingView(rootView: view.background(isDark ? Color(white: 0.17) : Color(white: 0.97)))
            hosting.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
            hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
            let window = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: hosting.frame.width, height: hosting.frame.height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = hosting
            defer { window.contentView = nil }
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            bitmap.size = hosting.bounds.size
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appending(path: "tab-cycle-\(isDark ? "dark" : "light").png"))
        }
    }
}

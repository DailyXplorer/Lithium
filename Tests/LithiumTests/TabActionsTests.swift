import Foundation
import Testing
import WebKit
@testable import Lithium

/// Reopening, duplicating, closing others or below, muting. A whole Browser keeps its data in the
/// home folder, so this suite only runs in a throwaway one:
/// `CFFIXED_USER_HOME=$(mktemp -d) swift test --filter TabActionsTests`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct TabActionsTests {
    private static let prefix = "data:text/html,"

    /// A browser whose tab list reads `names` top to bottom, and nothing else in it.
    private func browser(with names: [String]) -> Browser {
        let browser = Browser()
        browser.regularTabs.forEach(browser.close)
        for name in names.reversed() { browser.newTab(url: page(name)) }
        return browser
    }

    private func page(_ name: String) -> URL {
        URL(string: Self.prefix + name)!
    }

    private func names(_ browser: Browser) -> [String] {
        browser.regularTabs.map(name)
    }

    private func name(_ tab: Tab?) -> String {
        String(tab?.url?.absoluteString.dropFirst(Self.prefix.count) ?? "")
    }

    private func tab(_ name: String, in browser: Browser) -> Tab {
        browser.tabs.first { $0.url == page(name) }!
    }

    @Test func reopenedTabComesBackInItsPlace() {
        let browser = browser(with: ["a", "b", "c", "d", "e"])
        let c = tab("c", in: browser)
        c.customTitle = "Mine"
        browser.select(tab("a", in: browser))
        browser.close(c)
        #expect(names(browser) == ["a", "b", "d", "e"])

        browser.reopenClosedTab()
        #expect(names(browser) == ["a", "b", "c", "d", "e"])
        #expect(name(browser.selectedTab) == "c")
        #expect(browser.selectedTab?.customTitle == "Mine")
    }

    @Test func tabsClosedByCloseOtherTabsComeBackOneByOneInTheirPlaces() {
        let browser = browser(with: ["a", "b", "c", "d", "e"])
        browser.select(tab("e", in: browser))
        browser.closeOtherTabs(than: tab("c", in: browser))
        #expect(names(browser) == ["c"])
        #expect(name(browser.selectedTab) == "c")

        var steps: [[String]] = []
        while browser.canReopenClosedTab, names(browser).count < 5 {
            browser.reopenClosedTab()
            steps.append(names(browser))
        }
        #expect(steps == [["a", "c"], ["a", "b", "c"], ["a", "b", "c", "d"], ["a", "b", "c", "d", "e"]])
    }

    @Test func closeOtherTabsKeepsFavorites() {
        let browser = browser(with: ["a", "b", "c"])
        let favorite = browser.newTab(url: page("favorite"))
        browser.pin(favorite)
        defer { browser.pins.filter { $0.id == favorite.pinID }.forEach(browser.unpin) }

        browser.closeOtherTabs(than: tab("b", in: browser))
        #expect(names(browser) == ["b"])
        #expect(browser.tabs.contains(favorite))
        #expect(name(browser.selectedTab) == "b")
    }

    @Test func closeTabsBelow() {
        let browser = browser(with: ["a", "b", "c", "d", "e"])
        browser.select(tab("d", in: browser))
        browser.closeTabs(below: tab("b", in: browser))
        #expect(names(browser) == ["a", "b"])
        #expect(name(browser.selectedTab) == "b")
        #expect(browser.tabs(below: tab("b", in: browser)).isEmpty)

        browser.reopenClosedTab()
        #expect(names(browser) == ["a", "b", "c"])
    }

    @Test func canReopenOnlyWhatWasClosed() {
        let browser = Browser()
        #expect(!browser.canReopenClosedTab)
        browser.newTab()
        browser.closeSelectedTab()
        #expect(!browser.canReopenClosedTab, "a start page has nothing to reopen")

        browser.newTab(url: page("a"))
        browser.closeSelectedTab()
        #expect(browser.canReopenClosedTab)
        browser.reopenClosedTab()
        #expect(!browser.canReopenClosedTab)
    }

    @Test func closedFavoritePageGoesBackToItsFavoriteOrToTheTopOfTheList() throws {
        let browser = browser(with: ["a", "b"])
        let favorite = browser.newTab(url: page("favorite"))
        browser.pin(favorite)
        let pin = try #require(browser.pins.first { $0.id == favorite.pinID })
        defer { browser.unpin(pin) }

        browser.close(favorite)
        browser.reopenClosedTab()
        #expect(browser.liveTab(for: pin)?.url == page("favorite"))
        #expect(names(browser) == ["a", "b"])

        browser.close(browser.liveTab(for: pin)!)
        browser.activate(pin)
        browser.reopenClosedTab()
        #expect(names(browser) == ["favorite", "a", "b"], "its favorite has a page already")
    }

    @Test func duplicateGoesJustBelowAndIsSelected() throws {
        let browser = browser(with: ["a", "b", "c"])
        let b = tab("b", in: browser)
        b.customTitle = "Mine"
        browser.duplicate(b)
        #expect(names(browser) == ["a", "b", "b", "c"])
        let copy = try #require(browser.selectedTab)
        #expect(copy !== b)
        #expect(browser.regularTabs[2] === copy)
        #expect(copy.customTitle == "Mine")
        #expect(copy.pinID == nil)
    }

    @Test func duplicateOfAFavoritePageGoesToTheTopOfTheList() {
        let browser = browser(with: ["a", "b"])
        let favorite = browser.newTab(url: page("favorite"))
        browser.pin(favorite)
        defer { browser.pins.filter { $0.id == favorite.pinID }.forEach(browser.unpin) }

        browser.duplicate(favorite)
        #expect(names(browser) == ["favorite", "a", "b"])
        #expect(browser.selectedTab?.pinID == nil)
        #expect(favorite.pinID != nil)
    }

    @Test func startPageCannotBeDuplicated() {
        let browser = browser(with: ["a"])
        let empty = browser.newTab()
        browser.duplicate(empty)
        #expect(browser.tabs.count(where: { $0.pinID == nil }) == 2)
        #expect(browser.selectedTab === empty)
    }

    @Test func reopenedTabHasItsHistory() async throws {
        let browser = browser(with: [])
        let tab = try await tabWithHistory(in: browser)
        browser.close(tab)
        browser.reopenClosedTab()
        let reopened = try #require(browser.selectedTab)
        try await expectHistory(of: reopened)
    }

    @Test func reopenedSleepingTabHasItsHistory() async throws {
        let browser = browser(with: [])
        let tab = try await tabWithHistory(in: browser)
        browser.newTab(url: page("other"))
        tab.sleep(configuration: browser.makeConfiguration(for: tab.url))
        browser.close(tab)
        browser.reopenClosedTab()
        let reopened = try #require(browser.selectedTab)
        try await expectHistory(of: reopened)
    }

    @Test func duplicateHasTheHistory() async throws {
        let browser = browser(with: [])
        let tab = try await tabWithHistory(in: browser)
        browser.duplicate(tab)
        let copy = try #require(browser.selectedTab)
        #expect(copy !== tab)
        try await expectHistory(of: copy)
    }

    @Test(.enabled(if: Tab.canMute)) func mutedTabStaysMutedThroughSleep() async throws {
        let browser = browser(with: [])
        let tab = browser.newTab(url: page("<title>Sound</title>sound"))
        #expect(await waitUntil(120) { loaded(tab) })
        tab.isMuted = true
        #expect(mutedState(tab) & 1 == 1)

        browser.newTab(url: page("other"))
        tab.sleep(configuration: browser.makeConfiguration(for: tab.url))
        browser.select(tab)
        #expect(await waitUntil(10) { loaded(tab) })
        #expect(tab.isMuted)
        #expect(mutedState(tab) & 1 == 1)

        tab.isMuted = false
        #expect(mutedState(tab) & 1 == 0)
    }

    /// A tab on "Second", one Back away from "First".
    private func tabWithHistory(in browser: Browser) async throws -> Tab {
        let tab = browser.newTab(url: page("<title>First</title>first"))
        #expect(await waitUntil(120) { loaded(tab) })
        tab.load(page("<title>Second</title>second"))
        #expect(await waitUntil(10) { loaded(tab) && tab.webView.title == "Second" && tab.canGoBack })
        return tab
    }

    private func expectHistory(of tab: Tab) async throws {
        #expect(await waitUntil(10) { loaded(tab) && tab.webView.title == "Second" })
        #expect(await waitUntil(5) { tab.canGoBack })
        tab.webView.goBack()
        #expect(await waitUntil(10) { loaded(tab) && tab.webView.title == "First" })
    }

    private func mutedState(_ tab: Tab) -> Int {
        tab.webView.value(forKey: "_mediaMutedState") as? Int ?? 0
    }

    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func loaded(_ tab: Tab) -> Bool {
        let pid = (tab.webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value ?? 0
        return !tab.isAsleep && !tab.webView.isLoading && tab.webView.url != nil && pid > 0
    }
}

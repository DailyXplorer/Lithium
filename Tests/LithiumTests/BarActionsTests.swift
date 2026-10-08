import AppKit
import Foundation
import Testing
import WebKit
@testable import Lithium

private typealias Tab = Lithium.Tab

/// Which actions typed words bring up in the address bar, and where: no Browser needed.
@MainActor
struct BarActionMatchTests {
    private let all = BarAction.allCases

    private func named(_ query: String, among actions: [BarAction] = BarAction.allCases) -> [BarAction] {
        BarAction.matches(query, among: actions).map(\.action)
    }

    private func history() -> HistoryStore {
        HistoryStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "history-\(UUID()).sqlite"))
    }

    /// A word's start, any word of four letters or more, or an alias, names an action.
    @Test func wordStartsAndAliasesNameAnAction() {
        #expect(named("copy") == [.copyLink])
        #expect(named("Settings") == [.settings])
        #expect(named("dupl") == [.duplicateTab])
        #expect(named("private") == [.newPrivateTab])
        #expect(named("zen", among: [.enterZenMode]) == [.enterZenMode], "through its alias Zen")
        #expect(BarAction.matches("zen", among: [.enterZenMode]).first?.match.isWhole == true)
        #expect(named("cookies") == [.clearSiteData])
        #expect(named("incognito") == [.newPrivateTab])
        #expect(named("reopen tab") == [.reopenClosedTab], "words may skip words of the name")
        #expect(named("Paramètres").isEmpty)
    }

    /// Everyday searches stay searches: too short, three letters that aren't a whole name, past a
    /// name's first word with three letters, a typo under five letters, out of order, or more
    /// than one typo.
    @Test func everydaySearchesBringNoAction() {
        for query in ["", "co", "tab", "new", "res", "pin", "del", "set", "deli", "clou", "pres", "clear cache",
                      "new york", "news", "link copy", "weather", "stuff", "setigns x", "pin code"] {
            #expect(named(query).isEmpty, "\(query)")
        }
    }

    /// One letter wrong, missing, extra or swapped still names it.
    @Test func oneSmallTypoIsForgiven() {
        #expect(named("settigns") == [.settings])
        #expect(named("dupicate") == [.duplicateTab])
        #expect(named("settingss") == [.settings])
        #expect(named("sttings") == [.settings])
        #expect(named("clera site") == [.clearSiteData])
        #expect(named("clera stie").isEmpty, "two typos")
    }

    /// At most two, the best first: a name typed out whole before one only started.
    @Test func atMostTwoBestFirst() {
        #expect(named("exit") == [.exitSplitView, .exitZenMode])
        let three: [BarAction] = [.pinTab, .newPrivateTab, .settings]
        #expect(BarAction.matches("p", among: three).isEmpty)
        #expect(named("pin tab") == [.pinTab])
        #expect(named("unpin") == [.unpinTab])
        #expect(named("zen mode", among: [.enterZenMode]).count == 1)
        #expect(BarAction.matches("zen mode", among: [.enterZenMode]).first?.match.isWhole == true)
    }

    /// Only what can run now shows.
    @Test func unavailableActionsNeverShow() {
        #expect(named("copy link", among: [.settings, .newPrivateTab]).isEmpty)
        #expect(named("split", among: [.settings, .newPrivateTab]).isEmpty)
        #expect(named("split", among: [.exitSplitView]) == [.exitSplitView])
    }

    /// Rows go just below the typed text and never lengthen the list. Return still searches,
    /// unless the text names an action whole, without a typo.
    @Test func actionRowsSitBelowTheTypedTextAndReturnRunsOnlyAWholeName() {
        let suggestions = AddressSuggestions()
        suggestions.update(query: "copy", tabs: [], pins: [], history: history(), actions: all)
        #expect(suggestions.items.map(\.id) == ["search:copy", "action:copyLink"])
        #expect(suggestions.selectedIndex == 0, "Return searches for a name only started")

        suggestions.update(query: "copy link", tabs: [], pins: [], history: history(), actions: all)
        #expect(suggestions.selected == .action(.copyLink))

        suggestions.update(query: "settigns", tabs: [], pins: [], history: history(), actions: all)
        #expect(suggestions.items.map(\.id) == ["search:settigns", "action:settings"])
        #expect(suggestions.selectedIndex == 0, "a typo shows the row but Return still searches")

        suggestions.update(query: "settings.com", tabs: [], pins: [], history: history(), actions: all)
        #expect(suggestions.items.map(\.id) == ["address:https://settings.com"], "an address never brings actions")

        suggestions.update(query: "settings", tabs: [], pins: [], history: history())
        #expect(suggestions.items.map(\.id) == ["search:settings"], "none can run")
    }

    /// History arriving after the actions keeps them and the list's length.
    @Test func historyComesAfterTheActionsWithinTheLimit() async {
        let store = history()
        for index in 0..<10 {
            store.record(URL(string: "https://settings\(index).example/")!, title: "Settings \(index)")
        }
        let suggestions = AddressSuggestions()
        suggestions.update(query: "settings", tabs: [], pins: [], history: store, actions: all)
        await suggestions.historyQuery?.value
        #expect(suggestions.items.count == 8)
        #expect(suggestions.items.prefix(2).map(\.id) == ["search:settings", "action:settings"])
        #expect(suggestions.items.dropFirst(2).allSatisfy { $0.id.hasPrefix("history:") })
        #expect(suggestions.selected == .action(.settings), "late rows don't move the selection")
    }
}

/// What the bar offers for the tab being edited, and what Return on an action does. A whole
/// Browser, so only in a throwaway home: `./scripts/test --filter BarActionsTests`.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct BarActionsTests {
    private static let prefix = "data:text/html,"

    private func browser(with names: [String]) -> Browser {
        let browser = Browser()
        reset(browser)
        for name in names.reversed() { browser.newTab(url: page(name)) }
        return browser
    }

    private func reset(_ browser: Browser) {
        browser.tabs.forEach { browser.close($0, remembering: false) }
        browser.pins.forEach(browser.unpin)
        if browser.isZenMode { browser.toggleZenMode() }
        UserDefaults.standard.removeObject(forKey: Preference.zenMode)
    }

    private func page(_ name: String) -> URL { URL(string: Self.prefix + name)! }

    private func name(_ tab: Tab?) -> String {
        String(tab?.url?.absoluteString.dropFirst(Self.prefix.count) ?? "")
    }

    private func tab(_ name: String, in browser: Browser) -> Tab {
        browser.tabs.first { $0.url == page(name) }!
    }

    /// Types `text` in the address bar while `tab` is shown, then presses Return.
    private func type(_ text: String, on tab: Tab?, in browser: Browser) {
        browser.suggestions.editedTabID = tab?.id
        browser.addressTextChanged(text)
        browser.submitAddress(text, editing: tab?.id)
    }

    /// Only what the menus would enable, and a toggle's current side.
    @Test func offersOnlyWhatCanRunNow() {
        let browser = browser(with: ["a", "b"])
        defer { reset(browser) }
        #expect(browser.barActions(for: nil) == [.newPrivateTab, .enterZenMode, .settings])

        let a = tab("a", in: browser)
        #expect(browser.barActions(for: a) == [.copyLink, .newPrivateTab, .duplicateTab, .pinTab, .openSplitView, .enterZenMode, .settings],
                "a data: page has no site data to clear")
        browser.close(tab("b", in: browser))
        #expect(browser.barActions(for: a).contains(.reopenClosedTab))
        #expect(!browser.barActions(for: a).contains(.openSplitView), "alone in the list")

        let secret = browser.newTab(url: page("secret"), privateStore: .nonPersistent())
        #expect(!browser.barActions(for: secret).contains(.pinTab), "a private tab is never pinned")
    }

    /// Return on a name typed whole runs the action on the tab shown; a name only started still searches.
    @Test func returnRunsTabActions() {
        let browser = browser(with: ["a", "b"])
        defer { reset(browser) }
        let a = tab("a", in: browser)
        browser.select(a)

        type("duplicate tab", on: a, in: browser)
        #expect(browser.regularTabs.map(name) == ["a", "a", "b"])
        #expect(browser.selectedTab !== a)
        browser.close(browser.selectedTab!)

        type("pin tab", on: a, in: browser)
        #expect(browser.pins.map(\.url) == [page("a")])
        #expect(browser.barActions(for: a).contains(.unpinTab))
        type("unpin tab", on: a, in: browser)
        #expect(browser.pins.isEmpty)

        browser.select(a)
        type("open in split view", on: a, in: browser)
        #expect(browser.split(of: a) != nil)
        type("exit split view", on: a, in: browser)
        #expect(browser.split(of: a) == nil)

        browser.close(tab("b", in: browser))
        type("reopen closed tab", on: browser.selectedTab, in: browser)
        #expect(browser.regularTabs.map(name).sorted() == ["a", "b"])
        #expect(name(browser.selectedTab) == "b")
    }

    /// A new private tab starts empty, shown, with the address bar asked for focus.
    @Test func newPrivateTabFocusesTheAddressBar() {
        let browser = browser(with: ["a"])
        defer { reset(browser) }
        let token = browser.addressFocusToken
        type("new private tab", on: tab("a", in: browser), in: browser)
        let made = browser.selectedTab
        #expect(made?.isEphemeral == true)
        #expect(made?.url == nil)
        #expect(browser.addressFocusToken != token)
    }

    /// Zen mode and Settings, from the bar.
    @Test func zenModeAndSettings() {
        let browser = browser(with: ["a"])
        defer { reset(browser) }
        type("zen mode", on: tab("a", in: browser), in: browser)
        #expect(browser.isZenMode)
        #expect(browser.barActions(for: nil).contains(.exitZenMode))
        type("exit zen mode", on: tab("a", in: browser), in: browser)
        #expect(!browser.isZenMode)

        type("settings", on: tab("a", in: browser), in: browser)
        #expect(browser.selectedTab?.url?.absoluteString.hasPrefix(Internal.settingsURL.absoluteString) == true)
    }

    /// Clear site data removes the site's cookies from the tab's own store, here a private one;
    /// the same cookie in the default store stays.
    @Test func clearSiteDataEmptiesTheTabsStore() async throws {
        let (listener, url) = try await LocalHTTP.serve(["/": ("Content-Type: text/html", "<p>shop</p>")])
        defer { listener.cancel() }
        let browser = browser(with: [])
        defer { reset(browser) }
        let tab = browser.newTab(url: url, privateStore: .nonPersistent())
        #expect(await poll(10) { tab.url?.host() == "127.0.0.1" })
        #expect(browser.barActions(for: tab).contains(.clearSiteData))
        let cookie = try #require(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "cart", .value: "1"]))
        await tab.dataStore.httpCookieStore.setCookie(cookie)
        let mine = WKWebsiteDataStore.default().httpCookieStore
        await mine.setCookie(cookie)

        await browser.clearSiteData(of: tab)?.value
        let left = await tab.dataStore.httpCookieStore.allCookies()
        #expect(!left.contains { $0.name == "cart" })
        #expect(await mine.allCookies().contains { $0.name == "cart" }, "the default store is untouched")
        await mine.deleteCookie(cookie)
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

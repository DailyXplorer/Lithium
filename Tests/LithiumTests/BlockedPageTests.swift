import Foundation
import Network
import Testing
import WebKit
@testable import Lithium

/// A page a filter list blocks: what blocked it, read from the lists' text, and the ways through.
struct BlockedPageFilterTests {
    @Test func adblockFiltersMatchTheAddressAsAPage() throws {
        let url = try #require(URL(string: "https://www.tlauncher.org/en/download?x=1"))
        #expect(BlockedPage.blocksPage("||tlauncher.org^$doc", url: url))
        #expect(BlockedPage.blocksPage("||tlauncher.org^", url: url))
        #expect(BlockedPage.blocksPage("||tlauncher.org/en/*$document,important", url: url))
        #expect(BlockedPage.blocksPage("||tlauncher.org^$all,~script", url: url))
        #expect(BlockedPage.blocksPage("*$doc,domain=tlauncher.org", url: url))
        #expect(BlockedPage.blocksPage(#"/^https:\/\/www\.tlauncher\.org\/en\//$doc"#, url: url))
        #expect(!BlockedPage.blocksPage("||tlauncher.org^$script", url: url), "other kinds of loads")
        #expect(!BlockedPage.blocksPage("||tlauncher.org^$3p", url: url), "a page is its own first party")
        #expect(!BlockedPage.blocksPage("||tlauncher.org^$doc,domain=~tlauncher.org", url: url))
        #expect(!BlockedPage.blocksPage("||tlauncher.org^$removeparam=x", url: url), "not a block")
        #expect(!BlockedPage.blocksPage("@@||tlauncher.org^$doc", url: url))
        #expect(!BlockedPage.blocksPage("tlauncher.org##.banner", url: url))
        #expect(!BlockedPage.blocksPage("||mytlauncher.org^", url: url))
        #expect(!BlockedPage.blocksPage("||tlauncher.org.evil^", url: url))
        #expect(!BlockedPage.blocksPage("|http://tlauncher.org/|", url: url))
    }

    /// Lists that warn of danger come first, and a filter for pages before a broader one. Only the
    /// groups holding a matching list are named, to be left off once the page is let through.
    @Test func findsTheListAndFilterThatBlockThePage() throws {
        let folder = try Self.filters([
            "ubo-badware": "! Title: Badware risks\n||other.example^$doc\n||tlauncher.org^$doc\ntlauncher.org##.ad\n@@||tlauncher.org/ok^",
            "easylist": "||tlauncher.org/ads/*$script\n||tlauncher.org^",
            "easyprivacy": "||tracker.example^",
        ], groups: ["security": ["ubo-badware"], "ads": ["easylist"], "privacy": ["easyprivacy"]])
        defer { try? FileManager.default.removeItem(at: folder) }

        let reason = BlockedPage.reason(for: try #require(URL(string: "https://tlauncher.org/en/")), in: folder)
        #expect(reason.list == "ubo-badware")
        #expect(reason.filter == "||tlauncher.org^$doc")
        #expect(reason.groups == ["security", "ads"])
        #expect(BlockedPage.kind(of: reason.list) == .badware)
        #expect(BlockedPage.title(of: "ubo-badware") == "uBlock filters – Badware risks")
    }

    /// No list spells the address out (a regular expression the search can't tell): letting the
    /// page through leaves every group off it.
    @Test func withNoFilterFoundEveryGroupIsNamed() throws {
        let folder = try Self.filters(["ubo-badware": "||other.example^$doc"], groups: ["security": ["ubo-badware"], "ads": []])
        defer { try? FileManager.default.removeItem(at: folder) }

        let reason = BlockedPage.reason(for: try #require(URL(string: "https://tlauncher.org/")), in: folder)
        #expect(reason.list == nil && reason.filter == nil)
        #expect(reason.groups == ["security", "ads"])
        #expect(BlockedPage.kind(of: nil) == .unknown)
    }

    /// The layout `FilterUpdater` writes: a manifest naming each group's lists, and their text.
    static func filters(_ lists: [String: String], groups: [String: [String]]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "blocked-filters-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appending(path: "lists"), withIntermediateDirectories: true)
        for (name, text) in lists {
            try text.write(to: folder.appending(path: "lists/\(name).txt"), atomically: true, encoding: .utf8)
        }
        let manifest = Manifest(format: Manifest.currentFormat, updated: "2026-10-01T00:00:00Z",
                                groups: groups.mapValues { Manifest.Group(lists: $0, webkitRules: 1) }, advancedRules: 0)
        try JSONEncoder().encode(manifest).write(to: folder.appending(path: "manifest.json"))
        return folder
    }
}

/// Loads in real tabs, with a "security" group blocking `/blocked` as a page and an "ads" group
/// blocking its script. A whole Browser keeps its data in the home folder, so this suite only runs
/// in a throwaway one: `scripts/test --filter BlockedPageTests`.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct BlockedPageTests {
    private final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]

        func record(_ path: String) { lock.withLock { counts[path, default: 0] += 1 } }
        subscript(path: String) -> Int { lock.withLock { counts[path] ?? 0 } }
    }

    private struct Setup {
        let browser: Browser
        let page: URL
        let requests: Requests
        let listener: NWListener
        let folder: URL
    }

    private func setUp() async throws -> Setup {
        let requests = Requests()
        let (listener, base) = try await LocalHTTP.serve([
            "/blocked": ("Content-Type: text/html", Data(#"<title>Blocked</title><script src="/ad.js"></script>"#.utf8)),
            "/ad.js": ("Content-Type: text/javascript", Data("document.title = 'Ad'".utf8)),
        ], requested: { requests.record($0) })
        let store = try #require(WKContentRuleListStore(url: FileManager.default.temporaryDirectory.appending(path: "blocked-rules-\(UUID().uuidString)")))
        let security = try #require(try await store.compileContentRuleList(forIdentifier: "lithium-security-1-p4", encodedContentRuleList:
            #"[{"trigger": {"url-filter": "/blocked", "resource-type": ["document"]}, "action": {"type": "block"}}]"#))
        let ads = try #require(try await store.compileContentRuleList(forIdentifier: "lithium-ads-1-p4", encodedContentRuleList:
            #"[{"trigger": {"url-filter": "ad\\.js"}, "action": {"type": "block"}}]"#))
        let folder = try BlockedPageFilterTests.filters(["ubo-badware": "||127.0.0.1^$doc", "easylist": "||ads.example^"],
                                                        groups: ["security": ["ubo-badware"], "ads": ["easylist"]])
        let browser = Browser()
        await browser.privacy.waitUntilReady()
        browser.privacy.ruleLists = [ads, security]
        browser.privacy.filtersFolder = folder
        return Setup(browser: browser, page: base.appending(path: "blocked"), requests: requests, listener: listener, folder: folder)
    }

    private func tearDown(_ setup: Setup) {
        setup.browser.tabs.forEach { setup.browser.close($0, remembering: false) }
        setup.listener.cancel()
        try? FileManager.default.removeItem(at: setup.folder)
    }

    /// Instead of WebKit's bare error: the list and the filter that blocked the page. The page's
    /// address was never asked of its server.
    @Test func aBlockedPageShowsWhatBlockedIt() async throws {
        let setup = try await setUp()
        defer { tearDown(setup) }
        let tab = setup.browser.newTab(url: setup.page)

        #expect(await waitUntil(15) { tab.blockedPage?.reason != nil })
        let reason = try #require(tab.blockedPage?.reason)
        #expect(tab.blockedPage?.url == setup.page)
        #expect(reason.list == "ubo-badware" && reason.filter == "||127.0.0.1^$doc")
        #expect(reason.groups == ["security"])
        #expect(setup.requests["/blocked"] == 0)
    }

    /// Open anyway loads the page once, its ads still blocked; loading it again blocks it again,
    /// and nothing is saved.
    @Test func openAnywayLoadsThePageOnce() async throws {
        let setup = try await setUp()
        defer { tearDown(setup) }
        let tab = setup.browser.newTab(url: setup.page)
        #expect(await waitUntil(15) { tab.blockedPage?.reason != nil })

        await tab.letBlockedPageThrough(always: false)
        #expect(await waitUntil(15) { tab.title == "Blocked" && !tab.isLoading })
        #expect(tab.blockedPage == nil)
        #expect(setup.requests["/blocked"] == 1)
        #expect(setup.requests["/ad.js"] == 0, "the ads group stays on")

        setup.browser.navigate(tab, .reload)
        #expect(await waitUntil(15) { tab.blockedPage?.reason != nil })
        #expect(setup.requests["/blocked"] == 1)
        #expect(setup.browser.privacy.allowedPages.isEmpty)
    }

    /// Always allow lets the site's pages through from then on, saved and listed in Settings, its
    /// ads still blocked; removed there, the page is blocked again.
    @Test func alwaysAllowIsSaved() async throws {
        let setup = try await setUp()
        defer { tearDown(setup) }
        let privacy = setup.browser.privacy
        defer { privacy.removeAllowedPages(host: "127.0.0.1") }
        let tab = setup.browser.newTab(url: setup.page)
        #expect(await waitUntil(15) { tab.blockedPage?.reason != nil })

        await tab.letBlockedPageThrough(always: true)
        #expect(await waitUntil(15) { tab.title == "Blocked" && !tab.isLoading })
        #expect(privacy.allowedPages == ["127.0.0.1": ["security"]])
        #expect(Privacy().allowedPages == ["127.0.0.1": ["security"]], "saved")

        setup.browser.navigate(tab, .reload)
        #expect(await waitUntil(15) { setup.requests["/blocked"] == 2 && !tab.isLoading })
        #expect(tab.blockedPage == nil)
        #expect(setup.requests["/ad.js"] == 0, "the ads group stays on")

        privacy.removeAllowedPages(host: "127.0.0.1")
        #expect(Privacy().allowedPages.isEmpty)
        setup.browser.navigate(tab, .reload)
        #expect(await waitUntil(15) { tab.blockedPage != nil })
        #expect(setup.requests["/blocked"] == 2)
    }

    /// In a private tab, Always allow holds for its private session only, in memory.
    @Test func privateTabsAllowForTheirSessionOnly() async throws {
        let setup = try await setUp()
        defer { tearDown(setup) }
        let privacy = setup.browser.privacy
        let tab = setup.browser.newTab(url: setup.page, privateStore: .nonPersistent())
        let session = try #require(tab.privateSession)
        #expect(await waitUntil(15) { tab.blockedPage?.reason != nil })

        await tab.letBlockedPageThrough(always: true)
        #expect(await waitUntil(15) { tab.title == "Blocked" && !tab.isLoading })
        #expect(privacy.allowedGroups(for: setup.page, privateSession: session) == ["security"])
        #expect(privacy.allowedPages.isEmpty)
        #expect(UserDefaults.standard.dictionary(forKey: "allowedBlockedPages")?["127.0.0.1"] == nil, "nothing written to disk")

        let normal = setup.browser.newTab(url: setup.page)
        #expect(await waitUntil(15) { normal.blockedPage != nil })

        setup.browser.close(tab, remembering: false)
        #expect(privacy.allowedGroups(for: setup.page, privateSession: session).isEmpty, "forgotten with its last tab")
    }

    /// A link's own window shows the page too, and lets it through.
    @Test func quickLinkWindowsShowIt() async throws {
        let setup = try await setUp()
        defer { tearDown(setup) }
        setup.browser.quickLinks.showWindow = { _, _ in nil }
        let tab = try #require(setup.browser.quickLinks.open(setup.page))
        defer { setup.browser.quickLinks.close(tab) }
        #expect(await waitUntil(15) { tab.blockedPage?.reason != nil })

        await tab.letBlockedPageThrough(always: false)
        #expect(await waitUntil(15) { tab.title == "Blocked" && !tab.isLoading })
        #expect(setup.requests["/ad.js"] == 0)
    }

    /// With Site Protections off for the site, nothing blocks the page or its ads.
    @Test func withProtectionsOffNothingIsBlocked() async throws {
        let setup = try await setUp()
        defer { tearDown(setup) }
        setup.browser.privacy.setEnabled(false, for: setup.page)
        defer { setup.browser.privacy.setEnabled(true, for: setup.page) }
        let tab = setup.browser.newTab(url: setup.page)

        #expect(await waitUntil(15) { tab.title == "Ad" && !tab.isLoading })
        #expect(tab.blockedPage == nil)
        #expect(setup.requests["/ad.js"] == 1)
    }

    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

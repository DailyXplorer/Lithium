import Foundation
import Network
import os
import SwiftUI
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

    /// Among filters of the same kind, one written for pages wins, then the narrower one.
    @Test func sameKindPrefersAPageFilterThenTheNarrowest() throws {
        let url = try #require(URL(string: "https://tlauncher.org/en/"))
        // The filter for pages is the shorter one: only the first rule picks it.
        let forPages = try Self.filters(["easylist": "||tlauncher.org^$important\n||tlauncher.org^$doc"], groups: ["ads": ["easylist"]])
        let narrower = try Self.filters(["easylist": "||tlauncher.org^\n||tlauncher.org/en/^"], groups: ["ads": ["easylist"]])
        defer { [forPages, narrower].forEach { try? FileManager.default.removeItem(at: $0) } }

        #expect(BlockedPage.reason(for: url, in: forPages).filter == "||tlauncher.org^$doc")
        #expect(BlockedPage.reason(for: url, in: narrower).filter == "||tlauncher.org/en/^")
    }

    /// A filter that doesn't spell the site as plain text (a regular expression's escaped dot, a
    /// capitalised domain) is still found, and only its group is named: ads and trackers stay on.
    @Test func filtersNotSpellingTheSiteAreFound() throws {
        let url = try #require(URL(string: "https://tlauncher.org/en/"))
        let escaped = try Self.filters(["ubo-badware": #"/^https:\/\/tlauncher\.org\//$doc"#, "easylist": "||ads.example^"],
                                       groups: ["security": ["ubo-badware"], "ads": ["easylist"]])
        let capitalised = try Self.filters(["urlhaus": "||TLauncher.org^", "easylist": "||ads.example^"],
                                           groups: ["security": ["urlhaus"], "ads": ["easylist"]])
        let broader = try Self.filters(["ubo-badware": #"/^https:\/\/[a-z]+\.org\/en\//$doc"#, "easylist": "||ads.example^"],
                                       groups: ["security": ["ubo-badware"], "ads": ["easylist"]])
        // Beside a filter spelling the site, the longer expression is found only by its escaped name.
        let besideLiteral = try Self.filters(["ubo-badware": "||tlauncher.org^$doc\n" + #"/^https:\/\/tlauncher\.org\/en\//$doc"#],
                                             groups: ["security": ["ubo-badware"]])
        defer { [escaped, capitalised, broader, besideLiteral].forEach { try? FileManager.default.removeItem(at: $0) } }

        let byRegex = BlockedPage.reason(for: url, in: escaped)
        #expect(byRegex.list == "ubo-badware" && byRegex.filter == #"/^https:\/\/tlauncher\.org\//$doc"#)
        #expect(byRegex.groups == ["security"])
        let byCapitals = BlockedPage.reason(for: url, in: capitalised)
        #expect(byCapitals.list == "urlhaus" && byCapitals.groups == ["security"])
        let byBroader = BlockedPage.reason(for: url, in: broader)
        #expect(byBroader.list == "ubo-badware" && byBroader.groups == ["security"])
        #expect(BlockedPage.reason(for: url, in: besideLiteral).filter == #"/^https:\/\/tlauncher\.org\/en\//$doc"#)
    }

    /// A search for a tab gone elsewhere stops: cancelled before it starts, it reads no list.
    @Test func aCancelledSearchStops() async throws {
        let folder = try Self.filters(["ubo-badware": "||tlauncher.org^$doc"], groups: ["security": ["ubo-badware"]])
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try #require(URL(string: "https://tlauncher.org/en/"))

        let reason = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return BlockedPage.reason(for: url, in: folder)
        }.value
        #expect(reason.list == nil && reason.groups.isEmpty)
    }

    /// One list spelling the site doesn't stop another, in another group, from being searched: its
    /// group blocks the page too, and letting the page through must leave both off.
    @Test func everyBlockingListIsFoundWhenOneSpellsTheSite() throws {
        let url = try #require(URL(string: "https://tlauncher.org/en/"))
        let regex = try Self.filters(["easylist": "||tlauncher.org^$doc", "ubo-badware": #"/^https?:\/\/[a-z]+\.org\/en\//$doc"#],
                                     groups: ["ads": ["easylist"], "security": ["ubo-badware"]])
        let capitals = try Self.filters(["easylist": "||tlauncher.org^$doc", "urlhaus": "||TLauncher.org^$doc"],
                                        groups: ["ads": ["easylist"], "security": ["urlhaus"]])
        defer { [regex, capitals].forEach { try? FileManager.default.removeItem(at: $0) } }

        let byRegex = BlockedPage.reason(for: url, in: regex)
        #expect(byRegex.list == "ubo-badware" && byRegex.groups == ["ads", "security"])
        let byCapitals = BlockedPage.reason(for: url, in: capitals)
        #expect(byCapitals.list == "urlhaus" && byCapitals.groups == ["ads", "security"])
    }

    /// A filter naming hundreds of sites is cut short: the page, buttons included, fits a small window.
    @MainActor @Test func aLongFilterKeepsTheButtonsInView() {
        let filter = "*$doc,domain=" + (1...400).map { "site\($0).example" }.joined(separator: "|") + "|tlauncher.org"
        let page = BlockedPage(url: URL(string: "https://tlauncher.org/en/")!, reason: BlockedPage.Reason(list: "ubo-badware", filter: filter, groups: ["security"]))
        let view = NSHostingView(rootView: BlockedPageView(page: page, isPrivate: false, onBack: {}, onOpen: { _ in }).frame(width: 760))
        #expect(view.fittingSize.height <= 520)
    }

    /// No filter in the lists' text blocks the address (a list changed since it was compiled, say):
    /// letting the page through leaves every group off it.
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

    private func setUp(delay: TimeInterval = 0) async throws -> Setup {
        let requests = Requests()
        let served = OSAllocatedUnfairLock<URL?>(initialState: nil)
        let (listener, base) = try await LocalHTTP.serve([
            "/blocked": ("Content-Type: text/html", Data(#"<title>Blocked</title><script src="/ad.js"></script>"#.utf8)),
            "/ad.js": ("Content-Type: text/javascript", Data("document.title = 'Ad'".utf8)),
            // Once in, asks for a script the group that blocked it blocks too.
            "/blocked-late": ("Content-Type: text/html", Data(#"""
                <title>Blocked</title><script>onload = () => { const s = document.createElement('script'); s.src = '/late.js';
                s.onerror = () => document.title = 'Late blocked'; document.head.append(s) }</script>
                """#.utf8)),
            "/late.js": ("Content-Type: text/javascript", Data("document.title = 'Late loaded'".utf8)),
            "/start": ("Content-Type: text/html", Data("<title>Start</title>".utf8)),
        ], delay: delay, requested: { requests.record($0) }, answer: { path in
            guard let base = served.withLock({ $0 }), let port = base.port else { return nil }
            switch path {
            // Sends its load on to another site (localhost), where the same group blocks the page.
            case "/blocked-elsewhere": return ("HTTP/1.1 302 Found\r\nLocation: http://localhost:\(port)/blocked", Data())
            // Sends it on within its own site.
            case "/blocked-moved": return ("HTTP/1.1 302 Found\r\nLocation: \(base.appending(path: "blocked").absoluteString)", Data())
            default: return nil
            }
        })
        served.withLock { $0 = base }
        let store = try #require(WKContentRuleListStore(url: FileManager.default.temporaryDirectory.appending(path: "blocked-rules-\(UUID().uuidString)")))
        let security = try #require(try await store.compileContentRuleList(forIdentifier: "lithium-security-1-p4", encodedContentRuleList:
            #"[{"trigger": {"url-filter": "/blocked", "resource-type": ["document"]}, "action": {"type": "block"}}, "#
            + #"{"trigger": {"url-filter": "late\\.js"}, "action": {"type": "block"}}]"#))
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

    /// Only the page itself goes without the group that blocked it: what the page loads later is
    /// blocked by that group again.
    @Test func openAnywayLetsOnlyThePageThrough() async throws {
        let setup = try await setUp()
        defer { tearDown(setup) }
        let tab = setup.browser.newTab(url: setup.page.deletingLastPathComponent().appending(path: "blocked-late"))
        #expect(await waitUntil(15) { tab.blockedPage?.reason != nil })

        await tab.letBlockedPageThrough(always: false)
        #expect(await waitUntil(15) { tab.title.hasPrefix("Late") })
        #expect(tab.title == "Late blocked")
        #expect(setup.requests["/blocked-late"] == 1)
        #expect(setup.requests["/late.js"] == 0)
    }

    /// Open anyway lets its own site through, not one it redirects to: that site's page is blocked
    /// by the same group, and its server never asked.
    @Test func openAnywayDoesNotLetARedirectElsewhereThrough() async throws {
        let setup = try await setUp()
        defer { tearDown(setup) }
        let tab = setup.browser.newTab(url: setup.page.deletingLastPathComponent().appending(path: "blocked-elsewhere"))
        #expect(await waitUntil(15) { tab.blockedPage?.reason != nil })

        await tab.letBlockedPageThrough(always: false)
        #expect(await waitUntil(15) { tab.blockedPage?.url.host() == "localhost" && !tab.isLoading })
        #expect(setup.requests["/blocked-elsewhere"] == 1)
        #expect(setup.requests["/blocked"] == 0)
    }

    /// A redirect within the site is part of the load Open anyway lets through (http to https, say,
    /// which the same filters block), its ads still blocked.
    @Test func openAnywayFollowsARedirectWithinTheSite() async throws {
        let setup = try await setUp()
        defer { tearDown(setup) }
        let tab = setup.browser.newTab(url: setup.page.deletingLastPathComponent().appending(path: "blocked-moved"))
        #expect(await waitUntil(15) { tab.blockedPage?.reason != nil })

        await tab.letBlockedPageThrough(always: false)
        #expect(await waitUntil(15) { tab.title == "Blocked" && !tab.isLoading })
        #expect(tab.blockedPage == nil)
        #expect(setup.requests["/blocked-moved"] == 1 && setup.requests["/blocked"] == 1)
        #expect(setup.requests["/ad.js"] == 0)
    }

    /// Open anyway stopped before the page shows brings the blocked page back, buttons and all, and
    /// lets nothing through later: going to it again blocks it again.
    @Test func openAnywayStoppedLetsNothingThrough() async throws {
        let setup = try await setUp(delay: 3)
        defer { tearDown(setup) }
        let tab = setup.browser.newTab(url: setup.page)
        #expect(await waitUntil(15) { tab.blockedPage?.reason != nil })

        await tab.letBlockedPageThrough(always: false)
        #expect(await waitUntil(15) { setup.requests["/blocked"] == 1 })
        let unshown = tab.unshownLoads
        setup.browser.navigate(tab, .stop)
        #expect(await waitUntil(15) { tab.unshownLoads > unshown && !tab.isLoading })
        #expect(await waitUntil(15) { tab.blockedPage?.reason?.list == "ubo-badware" && tab.isShowingError })
        #expect(tab.blockedPage?.url == setup.page)

        let blocked = tab.loadError
        setup.browser.navigate(tab, .open(setup.page))
        #expect(await waitUntil(15) { tab.loadError !== blocked && tab.blockedPage?.reason != nil })
        #expect(setup.requests["/blocked"] == 1)
    }

    /// The site sent to again while Open anyway is on its way: that new load is blocked, whenever
    /// WebKit reports the first one dropped.
    @Test func openAnywaySupersededLetsNothingThrough() async throws {
        let setup = try await setUp(delay: 3)
        defer { tearDown(setup) }
        let tab = setup.browser.newTab(url: setup.page)
        #expect(await waitUntil(15) { tab.blockedPage?.reason != nil })

        await tab.letBlockedPageThrough(always: false)
        #expect(await waitUntil(15) { setup.requests["/blocked"] == 1 })
        let blocked = tab.loadError
        setup.browser.navigate(tab, .open(setup.page))
        #expect(await waitUntil(15) { tab.loadError !== blocked && tab.blockedPage?.reason != nil })
        #expect(setup.requests["/blocked"] == 1)
    }

    /// Reload while Open anyway is on its way is another navigation: the page is blocked again. So
    /// is the reload after a crash. The tab has history, so it is WebKit's reload, not a new load.
    @Test(arguments: [false, true]) func reloadDuringOpenAnywayBlocksAgain(crashed: Bool) async throws {
        let setup = try await setUp(delay: 3)
        defer { tearDown(setup) }
        let tab = setup.browser.newTab(url: setup.page.deletingLastPathComponent().appending(path: "start"))
        #expect(await waitUntil(15) { tab.title == "Start" && !tab.isLoading })
        setup.browser.navigate(tab, .open(setup.page))
        #expect(await waitUntil(15) { tab.blockedPage?.reason != nil })

        await tab.letBlockedPageThrough(always: false)
        #expect(await waitUntil(15) { setup.requests["/blocked"] == 1 })
        #expect(tab.webView.backForwardList.currentItem != nil)
        let blocked = tab.loadError
        if crashed { tab.webViewWebContentProcessDidTerminate(tab.webView) } else { setup.browser.navigate(tab, .reload) }
        #expect(await waitUntil(15) { tab.loadError !== blocked && tab.blockedPage?.reason != nil })
        #expect(setup.requests["/blocked"] == 1)
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

        // The allowed group stays off for what the site's pages load too, not only the page itself.
        // In another tab, so `tab` stays on the page reloaded below.
        let late = setup.browser.newTab(url: setup.page.deletingLastPathComponent().appending(path: "blocked-late"))
        #expect(await waitUntil(15) { late.title.hasPrefix("Late") })
        #expect(late.title == "Late loaded")

        // Removed with its button in Settings, the way the user does.
        let settings = setup.browser.newTab(url: Internal.settingsURL)
        var listed: [String]?
        for _ in 0..<300 where listed == nil {
            listed = try? await settings.webView.callAsyncJavaScript(
                "return document.querySelector('#allowed-pages button') ? (await call('state')).protections.allowedPages : null",
                contentWorld: .page) as? [String]
            if listed == nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(listed == ["127.0.0.1"])
        _ = try await settings.webView.callAsyncJavaScript("document.querySelector('#allowed-pages button').click()", contentWorld: .page)
        #expect(await waitUntil(15) { privacy.allowedPages.isEmpty })
        #expect(Privacy().allowedPages.isEmpty)
        setup.browser.navigate(tab, .reload)
        #expect(await waitUntil(15) { tab.blockedPage != nil })
        #expect(setup.requests["/blocked"] == 2)
    }

    /// What blocked a page is kept for each page looked up, not only the last, and a private
    /// session's are forgotten with it. A search cut short isn't kept.
    @Test func lookupsAreKeptPerPage() async throws {
        let folder = try BlockedPageFilterTests.filters(["ubo-badware": "||a.example^$doc\n||b.example^$doc\n||c.example^$doc"],
                                                        groups: ["security": ["ubo-badware"]])
        defer { try? FileManager.default.removeItem(at: folder) }
        let privacy = Privacy()
        privacy.filtersFolder = folder
        let owner = NSObject(), session = ObjectIdentifier(owner)
        let a = try #require(URL(string: "https://a.example/")), b = try #require(URL(string: "https://b.example/"))
        let c = try #require(URL(string: "https://c.example/"))

        _ = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await privacy.blockReason(for: c)
        }.value
        #expect(await privacy.blockReason(for: c).list == "ubo-badware", "searched again")
        #expect(await privacy.blockReason(for: a).list == "ubo-badware")
        #expect(await privacy.blockReason(for: b, privateSession: session).list == "ubo-badware")

        try FileManager.default.removeItem(at: folder.appending(path: "lists"))
        #expect(await privacy.blockReason(for: a).list == "ubo-badware", "kept, though another page was looked up since")
        #expect(await privacy.blockReason(for: b, privateSession: session).list == "ubo-badware")
        privacy.forget(privateSession: session)
        #expect(await privacy.blockReason(for: b, privateSession: session).list == nil, "forgotten with its private session")
        #expect(await privacy.blockReason(for: a).list == "ubo-badware")

        // Other lists: what was kept for them isn't the answer any more.
        let other = try BlockedPageFilterTests.filters(["easylist": "||a.example^"], groups: ["ads": ["easylist"]])
        defer { try? FileManager.default.removeItem(at: other) }
        privacy.filtersFolder = other
        #expect(await privacy.blockReason(for: a).list == "easylist")
        withExtendedLifetime(owner) {}
    }

    /// A closed tab's search stops: a private one's would otherwise keep its address after the
    /// session is forgotten.
    @Test func closingATabStopsItsSearch() async throws {
        let setup = try await setUp()
        defer { tearDown(setup) }
        let tab = setup.browser.newTab(url: setup.page, privateStore: .nonPersistent())
        let session = try #require(tab.privateSession)
        #expect(await waitUntil(15) { tab.blockedPage != nil })
        let lookup = try #require(tab.blockLookup)

        setup.browser.close(tab, remembering: false)
        #expect(lookup.isCancelled)
        // Whenever the search ended, nothing is kept for the session: with the lists gone, a
        // lookup finds nothing rather than a kept answer. That a search cut short is never kept,
        // whatever the timing here, is `lookupsAreKeptPerPage`'s "searched again".
        _ = await lookup.value
        try FileManager.default.removeItem(at: setup.folder.appending(path: "lists"))
        #expect(await setup.browser.privacy.blockReason(for: setup.page, privateSession: session).list == nil)
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

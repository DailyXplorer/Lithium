import Foundation
import Network
import Testing
import WebKit
@testable import Lithium

/// Choosing filter lists and writing filters: what is built from the choice, and what it does to a real page.
@MainActor
struct FilterListsTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "filter-lists-\(UUID())")
    private var storage: FilterLists.Storage { FilterLists.Storage(folder: root.appending(path: "chosen")) }

    /// A shipped set: each group's lists in lists/, compiled JSON that blocks nothing, no advanced rules.
    private func shippedSet(_ groups: [String: [String: String]]) throws -> (folder: URL, manifest: Manifest) {
        let folder = root.appending(path: "shipped")
        try FileManager.default.createDirectory(at: folder.appending(path: "lists"), withIntermediateDirectories: true)
        var entries: [String: Manifest.Group] = [:]
        for (group, lists) in groups {
            for (name, text) in lists {
                try text.write(to: folder.appending(path: "lists/\(name).txt"), atomically: true, encoding: .utf8)
            }
            try #"[{"trigger":{"url-filter":"lithium-matches-nothing"},"action":{"type":"block"}}]"#
                .write(to: folder.appending(path: "\(group).json"), atomically: true, encoding: .utf8)
            entries[group] = Manifest.Group(lists: lists.keys.sorted(), webkitRules: 1)
        }
        try "\n".write(to: folder.appending(path: "advanced.txt"), atomically: true, encoding: .utf8)
        try "\n".write(to: folder.appending(path: "scriptlets.txt"), atomically: true, encoding: .utf8)
        return (folder, Manifest(format: Manifest.currentFormat, updated: "2026-10-01T00:00:00Z", groups: entries, advancedRules: 0))
    }

    private func build(_ set: (folder: URL, manifest: Manifest), _ choices: FilterChoices = FilterChoices()) async throws -> ChosenFilters {
        let storage = storage
        return try #require(await Task.detached { ChosenFilters.build(base: set.folder, manifest: set.manifest, choices: choices, storage: storage) }.value)
    }

    /// Loads `page` from a local server with the chosen set's rule lists and, for `script`, its in-page engine.
    private func load(_ page: String, routes: [String: String] = [:], with chosen: ChosenFilters, engine: Bool = false,
                      probe: String) async throws -> String? {
        let store = try #require(WKContentRuleListStore(url: root.appending(path: "store")))
        let groups = await Privacy.loadGroups(chosen.groups, into: store)
        #expect(groups.complete)
        var served: [String: (headers: String, body: String)] = ["/": ("Content-Type: text/html", page)]
        for (path, body) in routes { served[path] = ("Content-Type: text/javascript", body) }
        let (server, base) = try await LocalHTTP.serve(served)
        defer { server.cancel() }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        groups.lists.forEach(configuration.userContentController.add)
        if engine {
            let blocking = AdvancedBlocking(container: root.appending(path: "engine"))
            await blocking.load(folder: chosen.engineFolder, stamp: chosen.engineStamp)
            let source = try #require(blocking.script(for: base))
            configuration.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let loaded = PageLoad()
        webView.navigationDelegate = loaded
        webView.load(URLRequest(url: base))
        try await loaded.wait()
        // Extended CSS hides what it matches once the page is parsed.
        try await Task.sleep(for: .milliseconds(500))
        return try await webView.evaluateJavaScript(probe) as? String
    }

    /// Turning a shipped list off unblocks what only it blocked; a group none of whose lists
    /// changed keeps its converted and compiled list.
    @Test func togglingAListChangesBlocking() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let set = try shippedSet([
            "ads": ["one": "/one-ad.js", "two": "/two-ad.js"],
            "privacy": ["three": "||tracker.lithium.test^"],
        ])
        let page = #"<!doctype html><script src="/one-ad.js"></script><script src="/two-ad.js"></script>"#
        let routes = ["/one-ad.js": "window.one = 'loaded'", "/two-ad.js": "window.two = 'loaded'"]
        let probe = "JSON.stringify([String(window.one), String(window.two)])"

        let twoOff = try await build(set, FilterChoices(off: ["two"]))
        #expect(try await load(page, routes: routes, with: twoOff, probe: probe) == #"["undefined","loaded"]"#)
        let oneOff = try await build(set, FilterChoices(off: ["one"]))
        #expect(try await load(page, routes: routes, with: oneOff, probe: probe) == #"["loaded","undefined"]"#)

        let identifiers = { (chosen: ChosenFilters) in Dictionary(uniqueKeysWithValues: chosen.groups.map { ($0.name, $0.identifier) }) }
        #expect(identifiers(twoOff)["ads"] != identifiers(oneOff)["ads"])
        #expect(identifiers(twoOff)["privacy"] == identifiers(oneOff)["privacy"])
    }

    /// The user's own cosmetic filter hides its element, and their `+js()` filter runs uBO's scriptlet.
    @Test func myFiltersHideAnElementAndRunScriptlets() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let set = try shippedSet(["ads": ["one": "||ads.lithium.test^"]])
        try storage.writeMyFilters("! Mine\n127.0.0.1##.promo\n127.0.0.1##+js(set, lithiumProbe, 42)\n")
        let chosen = try await build(set)
        #expect(chosen.groups.map(\.name) == ["ads", FilterLists.myFiltersID])

        let result = try await load("""
            <!doctype html><div class="promo">promo</div><div id="content">article</div>
            """, with: chosen, engine: true, probe: """
            JSON.stringify([getComputedStyle(document.querySelector('.promo')).display,
                            getComputedStyle(document.getElementById('content')).display, String(window.lithiumProbe)])
            """)
        #expect(result == #"["none","block","42"]"#)
    }

    /// Adding lists or filters leaves the shipped groups as compiled: nothing of them is converted again.
    @Test func addedListsLeaveTheShippedGroupsAsCompiled() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(FilterChoices().isDefault)
        let set = try shippedSet(["ads": ["one": "||ads.lithium.test^"], "privacy": ["two": "||tracker.lithium.test^"]])
        try storage.writeMyFilters("example.com##.banner")
        let chosen = try await build(set)
        let shipped = FilterGroup.shipped(in: set.folder, manifest: set.manifest)
        #expect(Array(chosen.groups.prefix(2)).map(\.identifier) == shipped.map(\.identifier))
        #expect(chosen.groups.last?.name == FilterLists.myFiltersID)

        // Nor does turning a catalog list on.
        try storage.save(["||example.org^"], for: "hide-youtube-shorts")
        let catalog = try await build(set, FilterChoices(on: ["hide-youtube-shorts"]))
        #expect(Array(catalog.groups.prefix(2)).map(\.identifier) == shipped.map(\.identifier))
        #expect(catalog.groups.map(\.name).contains(FilterLists.extraGroup))

        // Empty filters remove the file, so the shipped set loads as it always did.
        try storage.writeMyFilters("  \n")
        #expect(!storage.hasMyFilters)
    }

    /// A set built before is found by its files' sizes and dates: no list is read again, so an
    /// unreadable one changes nothing. Rules over WebKit's limit are reported with it.
    @Test func anUnchangedSetReadsNoList() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let set = try shippedSet(["ads": ["one": "||ads.lithium.test^", "two": "||more.lithium.test^"]])
        try storage.save(["||example.org^"], for: "hide-youtube-shorts")
        let choices = FilterChoices(off: ["two"], on: ["hide-youtube-shorts"])
        let first = try await build(set, choices)
        #expect(first.discarded.isEmpty)
        let ads = try #require(first.groups.first { $0.name == "ads" })
        let converted = try FileManager.default.attributesOfItem(atPath: ads.file.path)[.modificationDate] as? Date

        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: set.folder.appending(path: "lists/one.txt").path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: set.folder.appending(path: "lists/one.txt").path) }
        // As if conversion had left rules out.
        let extra = try #require(first.groups.first { $0.name == FilterLists.extraGroup })
        try #"{"webkitRules":1,"discarded":7}"#.write(to: extra.file.deletingLastPathComponent().appending(path: "info.json"), atomically: true, encoding: .utf8)

        let again = try await build(set, choices)
        #expect(again.groups.map(\.identifier) == first.groups.map(\.identifier))
        #expect(again.engineStamp == first.engineStamp)
        #expect(try FileManager.default.attributesOfItem(atPath: ads.file.path)[.modificationDate] as? Date == converted)
        #expect(again.discarded == [FilterLists.extraGroup: 7])
    }

    /// A chosen group that fails to compile is left out, not replaced by the shipped group of the
    /// same name, which still holds the lists the user turned off.
    @Test func aFailedChosenGroupDoesntBringBackTheShippedOne() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let set = try shippedSet(["ads": ["one": "||ads.lithium.test^", "two": "||more.lithium.test^"]])
        let store = try #require(WKContentRuleListStore(url: root.appending(path: "store")))
        #expect(await Privacy.loadGroups(from: set.folder, manifest: set.manifest, into: store).lists.count == 1)

        let chosen = try #require(try await build(set, FilterChoices(off: ["two"])).groups.first)
        let broken = FilterGroup(name: chosen.name, identifier: chosen.identifier, file: root.appending(path: "missing.json"), webkitRules: 1)
        let loaded = await Privacy.loadGroups([broken], into: store)
        #expect(loaded.lists.isEmpty)
        #expect(!loaded.complete)
    }

    /// Settings' switches and My filters go through `Privacy`: the choice is saved for the next
    /// launch and applied at once. When it can't be built, what was loaded stays, with a message,
    /// instead of the whole shipped set; a save that fails says so.
    @Test func choicesAreSavedAndAFailureKeepsWhatWasLoaded() async throws {
        let key = "filterChoices"
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            try? FileManager.default.removeItem(at: root)
        }
        let set = try shippedSet(["ads": ["easylist": "||ads.lithium.test^", "ubo-filters": "||more.lithium.test^"],
                                  "privacy": ["easyprivacy": "||tracker.lithium.test^"]])
        let privacy = Privacy()
        privacy.filterStorage = storage
        privacy.filterSet = set
        privacy.ruleListStore = try #require(WKContentRuleListStore(url: root.appending(path: "store")))

        #expect(await privacy.setFilterList("easylist", enabled: false) == nil)
        #expect(privacy.filterChoices.off == ["easylist"])
        #expect(Privacy().filterChoices.off == ["easylist"], "saved")
        #expect(privacy.ruleLists.count == 2 && privacy.ruleLists.allSatisfy { $0.identifier.contains("-h") })
        #expect(await privacy.setMyFilters("example.com##.ad") == nil)
        #expect(storage.readMyFilters() == "example.com##.ad")
        #expect(privacy.ruleLists.last?.identifier.hasPrefix("lithium-my-filters-h") == true)

        // Nowhere to convert to.
        let loaded = privacy.ruleLists.map(\.identifier)
        try FileManager.default.removeItem(at: storage.built)
        try Data().write(to: storage.built)
        #expect(await privacy.setFilterList("easyprivacy", enabled: false) != nil)
        #expect(privacy.filterChoices.off == ["easylist", "easyprivacy"], "kept, to be tried again")
        #expect(privacy.ruleLists.map(\.identifier) == loaded)

        try FileManager.default.removeItem(at: storage.myFilters)
        try FileManager.default.createDirectory(at: storage.myFilters, withIntermediateDirectories: true)
        #expect(await privacy.setMyFilters("example.org##.ad")?.hasPrefix("Couldn’t save your filters") == true)
    }

    /// What the user types in My filters stays when a reply re-renders the page before they save,
    /// and "Saved" shows only when saving worked.
    @Test(.timeLimit(.minutes(1))) func unsavedFiltersStayAndFailedSavesSayso() async throws {
        let bridge = FakeFilterBridge()
        let configuration = WKWebViewConfiguration()
        InternalSchemeHandler.shared.install(on: configuration)
        configuration.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: InternalBridge.name)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 700), configuration: configuration)
        let loaded = PageLoad()
        webView.navigationDelegate = loaded
        webView.load(URLRequest(url: URL(string: "lithium://settings#filters")!))
        try await loaded.wait()
        let run: (String) async throws -> Any? = { try await webView.callAsyncJavaScript($0, contentWorld: .page) }
        let settled: () async throws -> Void = {
            for _ in 0..<100 {
                if try await run("return document.querySelector('#filter-sections input') ? !document.querySelector('#filter-sections input').disabled : false") as? Bool == true,
                   try await run("return document.getElementById('my-filters-save').disabled") as? Bool == false { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            Issue.record("The page didn't render the reply")
        }
        try await settled()
        #expect(try await run("return document.getElementById('my-filters').value") as? String == "saved##.x")

        _ = try await run("""
            const box = document.getElementById('my-filters');
            box.value = 'typed##.y'; box.dispatchEvent(new Event('input'));
            document.querySelector('#filter-sections input').click();
            """)
        try await settled()
        #expect(bridge.toggled)
        #expect(try await run("return document.getElementById('my-filters').value") as? String == "typed##.y")

        bridge.error = "Couldn’t save your filters: disk full"
        _ = try await run("document.getElementById('my-filters-save').click()")
        try await Task.sleep(for: .milliseconds(200))
        try await settled()
        #expect(try await run("return document.getElementById('my-filters-status').textContent") as? String == "")
        #expect(try await run("return document.getElementById('filter-error').textContent") as? String == bridge.error)
        #expect(try await run("return document.getElementById('my-filters').value") as? String == "typed##.y")
    }

    /// The Hide YouTube Shorts list, as turned on from the catalog, hides the Shorts shelf and
    /// Shorts among videos. The page is served locally, so its rules are scoped to the local host
    /// instead of youtube.com for the page check.
    @Test func youTubeShortsListHidesTheShortsShelf() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try #require(Bundle.module.url(forResource: "Fixtures/hide-yt-shorts", withExtension: "txt"))
        let lines = try String(contentsOf: fixture, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init).filter { !$0.hasPrefix("!") }
        let set = try shippedSet(["ads": ["one": "||ads.lithium.test^"]])
        let choices = FilterChoices(on: ["hide-youtube-shorts"])

        // As shipped: for YouTube only.
        try storage.save(lines, for: "hide-youtube-shorts")
        let youtube = try await build(set, choices)
        let extra = try #require(youtube.groups.first { $0.name == FilterLists.extraGroup })
        let rules = try String(contentsOf: extra.file, encoding: .utf8)
        #expect(rules.contains("ytd-reel-shelf-renderer") && rules.contains("youtube.com"))

        try storage.save(lines.map { $0.replacingOccurrences(of: "youtube.com", with: "127.0.0.1") }, for: "hide-youtube-shorts")
        let local = try await build(set, choices)
        let result = try await load("""
            <!doctype html>
            <ytd-reel-shelf-renderer id="shelf">Shorts</ytd-reel-shelf-renderer>
            <ytd-rich-section-renderer id="section"><div id="rich-shelf-header">Shorts</div></ytd-rich-section-renderer>
            <ytd-rich-item-renderer id="short"><span overlay-style="SHORTS"></span></ytd-rich-item-renderer>
            <ytd-rich-item-renderer id="video"><span overlay-style="DEFAULT"></span></ytd-rich-item-renderer>
            """, with: local, engine: true, probe: """
            JSON.stringify(['shelf', 'section', 'short', 'video'].map((id) => getComputedStyle(document.getElementById(id)).display))
            """)
        #expect(result == #"["none","none","none","inline"]"#)
    }

    /// Only http(s) addresses with a host are taken, and only a text list under the size cap is added.
    @Test func badAddressesAreRefused() async throws {
        for text in ["ftp://example.com/list.txt", "file:///etc/hosts", "javascript:alert(1)", "https://", "example.com/list.txt",
                     "https://user:secret@example.com/list.txt", "https://example.com/" + String(repeating: "a", count: 2100), ""] {
            #expect(FilterLists.validatedURL(text) == nil, "\(text)")
        }
        #expect(FilterLists.validatedURL("  https://example.com/list.txt ")?.absoluteString == "https://example.com/list.txt")
        #expect(FilterLists.id(of: URL(string: "https://example.com/ubo-filters.txt")!).hasPrefix("url-"))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubFilterList.self]
        let session = URLSession(configuration: configuration)
        let host = "https://\(UUID().uuidString.lowercased()).lists.test"
        let bodies: [String: Data?] = [
            "html": Data("<!doctype html><title>Sign in</title>".utf8),
            "binary": Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]),
            "huge": Data(String(repeating: "||a.example^\n", count: FilterUpdater.maximumListBytes / 13 + 1).utf8),
            "empty": Data("! Title: nothing\n".utf8),
            "missing": nil,
        ]
        for (name, body) in bodies {
            let url = URL(string: "\(host)/\(name).txt")!
            StubFilterList.serve(body, at: url)
            await #expect(throws: (any Error).self, "\(name)") { try await FilterLists.download(url, session: session) }
        }
        // The cap is for the list with everything it includes.
        let half = Data(String(repeating: "||b.example^\n", count: FilterUpdater.maximumListBytes / 13 / 2 + 1000).utf8)
        StubFilterList.serve(half, at: URL(string: "\(host)/part-a.txt")!)
        StubFilterList.serve(half, at: URL(string: "\(host)/part-b.txt")!)
        let parts = URL(string: "\(host)/parts.txt")!
        StubFilterList.serve(Data("!#include part-a.txt\n!#include part-b.txt\n".utf8), at: parts)
        await #expect(throws: (any Error).self, "parts") { try await FilterLists.download(parts, session: session) }

        let good = URL(string: "\(host)/good.txt")!
        StubFilterList.serve(Data("! Title: good\n||ads.example^\nexample.com##.ad\n".utf8), at: good)
        #expect(try await FilterLists.download(good, session: session) == ["||ads.example^", "example.com##.ad"])
    }

    /// Each line Lithium can't apply is reported with its number; comments and valid rules aren't.
    /// The user's own `+js()` filters are trusted like uBO's; an added list's aren't.
    @Test func myFiltersReportEachUnsupportedLine() {
        let problems = FilterLists.problems(in: """
            ! A comment
            example.com##.ad
            ||ads.example^

            example.com##+js(lithium-no-such-scriptlet)
            ||ads.example^$lithium-no-such-option
            example.org##+js(set, lithiumProbe, 1)
            example.org#@#+js()
            """)
        #expect(problems.map(\.line) == [5, 6])
        #expect(problems.first?.message == "Unknown scriptlet “lithium-no-such-scriptlet”.")
        #expect(FilterUpdater.isAllowed("example.org##+js(set, a, 1)", list: FilterLists.myFiltersID))
        #expect(!FilterUpdater.isAllowed("example.org##+js(set, a, 1)", list: FilterLists.id(of: URL(string: "https://example.com/l.txt")!)))
    }
}

/// The Filter lists page's calls, answered with one list and the saved filters.
@MainActor
private final class FakeFilterBridge: NSObject, WKScriptMessageHandlerWithReply {
    var saved = "saved##.x"
    var error: String?
    var toggled = false

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        let body = message.body as? [String: Any]
        switch body?["action"] as? String {
        case "filterLists": break
        case "setFilterList": toggled = true
        case "setMyFilters": if error == nil { saved = body?["value"] as? String ?? "" }
        default: return (nil, nil)
        }
        let list: [String: Any] = ["id": "easylist", "name": "EasyList", "summary": "Ads.", "homepage": "", "enabled": !toggled,
                                   "rules": 1, "updated": 0, "failed": false, "removable": false]
        return (["sections": [["title": "Ads", "lists": [list]]], "myFilters": saved, "problems": [], "error": error ?? ""], nil)
    }
}

/// Answers with the body served at a URL, or a 404 when there is none.
private final class StubFilterList: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bodies: [URL: Data] = [:]

    static func serve(_ body: Data?, at url: URL) {
        lock.withLock { bodies[url] = body }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let body = Self.lock.withLock { Self.bodies[url] }
        let response = HTTPURLResponse(url: url, statusCode: body == nil ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data("Not found".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

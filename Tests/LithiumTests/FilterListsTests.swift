import Foundation
import Network
import Testing
import WebKit
@testable import Lithium

/// Choosing filter lists and writing filters: what is built from the choice, and what it does to a real page.
/// Serialized: several tests save the choice under the same UserDefaults key.
@Suite(.serialized)
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

        // Filters that are only comments make no group; a rule after many of them is found.
        try storage.writeMyFilters("! Nothing yet\n  \n! Still nothing")
        #expect(try await build(set).groups.map(\.name) == ["ads", "privacy"])
        try storage.writeMyFilters(String(repeating: "! A comment\n", count: 8000) + "example.com##.late")
        #expect(ChosenFilters.hasRule(storage.myFilters))
        // One cut across two 64 KB reads; comments only past the first read have none.
        let comments = String(repeating: "! A comment\n", count: 5461)
        try storage.writeMyFilters(comments + "example.com##.edge")
        #expect(ChosenFilters.hasRule(storage.myFilters))
        try storage.writeMyFilters(comments + "! Still a comment")
        #expect(!ChosenFilters.hasRule(storage.myFilters))
        // Lines end where the build's reading ends them, at a vertical tab or line separator too.
        for text in ["! Title\u{0B}example.com##.ad", "! Title\u{2028}example.com##.ad"] {
            try storage.writeMyFilters(text)
            #expect(ChosenFilters.hasRule(storage.myFilters), "\(text.unicodeScalars.map(\.value))")
        }
        try storage.writeMyFilters("\u{0B}! A comment")
        #expect(!ChosenFilters.hasRule(storage.myFilters))

        // Empty filters remove the file, so the shipped set loads as it always did.
        try storage.writeMyFilters("  \n")
        #expect(!storage.hasMyFilters)
    }

    /// A set built before is found by its files' sizes and dates: no list is read again, so an
    /// unreadable one changes nothing. Rules over WebKit's limit are reported with it.
    @Test func anUnchangedSetReadsNoList() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let set = try shippedSet(["ads": ["one": "||ads.lithium.test^", "two": "||more.lithium.test^"]])
        // A whole second, so the date put back below is the same to the nanosecond.
        let one = set.folder.appending(path: "lists/one.txt")
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: one.path)
        try storage.save(["||example.org^"], for: "hide-youtube-shorts")
        let choices = FilterChoices(off: ["two"], on: ["hide-youtube-shorts"])
        let first = try await build(set, choices)
        #expect(first.discarded.isEmpty)
        let ads = try #require(first.groups.first { $0.name == "ads" })
        let converted = try FileManager.default.attributesOfItem(atPath: ads.file.path)[.modificationDate] as? Date

        // Other rules of the same size, with the date put back: only a build that read the list would see them.
        try "||adz.lithium.test^".write(to: one, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: one.path)
        // As if conversion had left rules out.
        let extra = try #require(first.groups.first { $0.name == FilterLists.extraGroup })
        try #"{"webkitRules":1,"discarded":7}"#.write(to: extra.file.deletingLastPathComponent().appending(path: "info.json"), atomically: true, encoding: .utf8)

        let again = try await build(set, choices)
        #expect(again.groups.map(\.identifier) == first.groups.map(\.identifier))
        #expect(again.engineStamp == first.engineStamp)
        #expect(try FileManager.default.attributesOfItem(atPath: ads.file.path)[.modificationDate] as? Date == converted)
        #expect(again.discarded == [FilterLists.extraGroup: 7])

        // Converted before the count was recorded: converted again, so rules left out are reported.
        let info = extra.file.deletingLastPathComponent().appending(path: "info.json")
        try #"{"webkitRules":1}"#.write(to: info, atomically: true, encoding: .utf8)
        #expect(try await build(set, choices).groups.map(\.identifier) == first.groups.map(\.identifier))
        #expect(try String(contentsOf: info, encoding: .utf8).contains("discarded"))

        // An edit that keeps the list's size is found by its date.
        try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(60)], ofItemAtPath: one.path)
        let edited = try await build(set, choices)
        #expect(edited.groups.first { $0.name == "ads" }?.identifier != ads.identifier)
    }

    /// A staging folder a build interrupted by quitting left behind goes with the next build, once
    /// untouched for a day; one of a build under way stays.
    @Test func anAbandonedStagingFolderIsRemoved() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let set = try shippedSet(["ads": ["one": "||ads.lithium.test^", "two": "||more.lithium.test^"]])
        let choices = FilterChoices(off: ["two"])
        _ = try await build(set, choices)
        let abandoned = storage.built.appending(path: ".staging-\(UUID().uuidString)")
        let current = storage.built.appending(path: ".staging-\(UUID().uuidString)")
        for folder in [abandoned, current] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "[]".write(to: folder.appending(path: "rules.json"), atomically: false, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 24 * 60 * 60)], ofItemAtPath: abandoned.path)

        _ = try await build(set, choices)
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(FileManager.default.fileExists(atPath: current.path))
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

        // The user's filters keep their last version: it never holds a list turned off.
        try storage.writeMyFilters("example.com##.ad")
        let mine = try #require(try await build(set).groups.last)
        #expect(await Privacy.loadGroups([mine], into: store).complete)
        let edited = FilterGroup(name: mine.name, identifier: "lithium-my-filters-h0123abcd-p\(FilterGroup.preparation)",
                                 file: root.appending(path: "missing.json"), webkitRules: 1)
        let kept = await Privacy.loadGroups([edited], into: store)
        #expect(kept.lists.map(\.identifier) == [mine.identifier])
        #expect(!kept.complete)
    }

    /// Settings' switches and My filters go through `Privacy`: the choice is saved for the next
    /// launch and applied at once. When it can't be built, only the shipped groups holding no list
    /// turned off load, with a message, and the in-page engine only if no list is off; a save that
    /// fails says so.
    @Test func choicesAreSavedAndAFailureNeverLoadsAListTurnedOff() async throws {
        let key = "filterChoices"
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            try? FileManager.default.removeItem(at: root)
        }
        let named = try shippedSet(["ads": ["easylist": "||ads.lithium.test^", "ubo-filters": "||more.lithium.test^"],
                                    "privacy": ["easyprivacy": "||tracker.lithium.test^"],
                                    "malware": ["urlhaus": "||malware.lithium.test^"]])
        // One in-page rule in the shipped engine, so the rule count shows whether it is counted.
        try #"example.net#%#//scriptlet("set-constant", "lithiumShipped", "1")"#.write(to: named.folder.appending(path: "advanced.txt"), atomically: true, encoding: .utf8)
        let set = (folder: named.folder, manifest: Manifest(format: named.manifest.format, updated: named.manifest.updated,
                                                             groups: named.manifest.groups, advancedRules: 1))
        let shipped = FilterGroup.shipped(in: set.folder, manifest: set.manifest).map(\.identifier)
        let malware = FilterGroup.shipped(in: set.folder, manifest: set.manifest).filter { $0.name == "malware" }.map(\.identifier)
        let privacy = Privacy()
        privacy.filterStorage = storage
        privacy.filterSet = set
        privacy.ruleListStore = try #require(WKContentRuleListStore(url: root.appending(path: "store")))
        let engines = root.appending(path: "engine")
        privacy.advanced = AdvancedBlocking(container: engines)
        let page = URL(string: "https://example.com/")!

        #expect(await privacy.setFilterList("easylist", enabled: false) == nil)
        #expect(privacy.filterChoices.off == ["easylist"])
        #expect(Privacy().filterChoices.off == ["easylist"], "saved")
        #expect(privacy.ruleLists.count == 3 && privacy.ruleLists.allSatisfy { $0.identifier.contains("-h") })
        let filters = "example.com##.ad\nexample.com##+js(set, lithiumProbe, 1)"
        #expect(await privacy.setMyFilters(filters) == nil)
        #expect(storage.readMyFilters() == filters)
        #expect(privacy.ruleLists.last?.identifier.hasPrefix("lithium-my-filters-h") == true)
        #expect(privacy.filterError == nil)
        #expect(privacy.scripts(true, for: page).count == 2, "farbling and the scriptlet")
        let counted = privacy.ruleCount

        // An engine that can't be built: the one before, which may run a list since turned off,
        // goes too, and the page says so. Moved, not deleted, so the engine open before still works.
        let moved = root.appending(path: "engine-moved")
        try FileManager.default.moveItem(at: engines, to: moved)
        try Data().write(to: engines)
        #expect(await privacy.setMyFilters(filters + "\nexample.com##+js(set, lithiumOther, 1)") == nil)
        #expect(privacy.scripts(true, for: page).count == 1, "farbling only")
        #expect(privacy.ruleCount == counted - 1, "without the scriptlet of the engine unloaded")
        #expect(privacy.filterError == "Lithium couldn’t build the in-page rules of your filter lists, so none apply until the next change or update.")
        try FileManager.default.removeItem(at: engines)
        try FileManager.default.moveItem(at: moved, to: engines)
        #expect(await privacy.setMyFilters(filters) == nil)
        #expect(privacy.scripts(true, for: page).count == 2)
        #expect(privacy.filterError == nil)

        // A group WebKit won't compile is reported, and the save itself still succeeded.
        let mine = try #require(try FileManager.default.contentsOfDirectory(at: storage.built, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix(FilterLists.myFiltersID + "-") })
        try "not rules".write(to: mine.appending(path: "rules.json"), atomically: true, encoding: .utf8)
        privacy.ruleListStore = try #require(WKContentRuleListStore(url: root.appending(path: "other-store")))
        #expect(await privacy.setMyFilters(filters) == nil)
        #expect(privacy.filterError == "Some of your filter lists or filters couldn’t be applied.")

        // So is an add, which leaves the set's problem as it was.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubFilterList.self]
        privacy.filterSession = URLSession(configuration: configuration)
        let url = URL(string: "https://\(UUID().uuidString.lowercased()).lists.test/list.txt")!
        StubFilterList.serve(Data("||one.lithium.test^\n".utf8), at: url)
        #expect(await privacy.addFilterList(url.absoluteString) == nil)
        #expect(privacy.filterChoices.added == [url])
        #expect(privacy.filterError == "Some of your filter lists or filters couldn’t be applied.")

        // Nowhere to convert to: the list just turned off stops blocking, as does the engine,
        // built from every shipped list; the group holding none of them stays. Groups are compiled
        // whole, so uBlock Origin filters, left on beside EasyList, stops too, as do the added list
        // and the user's filters, and the message names them all.
        try FileManager.default.removeItem(at: storage.built)
        try Data().write(to: storage.built)
        #expect(await privacy.setFilterList("easyprivacy", enabled: false) == nil)
        let failed = "Lithium couldn’t apply your filter lists. It will try again with the next change or update."
        let stopped = failed + " Until then, these aren’t applied: uBlock Origin filters, \(url.absoluteString), your filters, every list’s in-page rules."
        #expect(privacy.filterError == stopped)
        #expect(!privacy.filtersComplete, "so the update backs off")
        #expect(privacy.filterChoices.off == ["easylist", "easyprivacy"], "kept, to be tried again")
        #expect(privacy.ruleLists.map(\.identifier) == malware)
        #expect(privacy.ruleCount == 1, "the malware group's rule, none of the unloaded engine's")
        #expect(privacy.scripts(true, for: page).count == 1, "farbling only")

        // The same at launch; with no list off, the whole shipped set, still marked incomplete.
        let launched = Privacy()
        launched.filterStorage = storage
        launched.filterSet = set
        launched.ruleListStore = privacy.ruleListStore
        launched.advanced = AdvancedBlocking(container: engines)
        #expect(await launched.setMyFilters(filters) == nil)
        #expect(launched.ruleLists.map(\.identifier) == malware)
        #expect(launched.filterError == stopped)
        #expect(await launched.setFilterList("easylist", enabled: true) == nil)
        #expect(await launched.setFilterList("easyprivacy", enabled: true) == nil)
        #expect(launched.ruleLists.map(\.identifier) == shipped)
        #expect(launched.filterError == failed + " Until then, these aren’t applied: \(url.absoluteString), your filters.")
        #expect(launched.ruleCount == 4, "three groups' rules and the shipped engine's")
        #expect(launched.scripts(true, for: URL(string: "https://example.net/")!).count == 2, "farbling and the shipped scriptlet")
        #expect(!launched.filtersComplete)

        try FileManager.default.removeItem(at: storage.myFilters)
        try FileManager.default.createDirectory(at: storage.myFilters, withIntermediateDirectories: true)
        #expect(await privacy.setMyFilters("example.org##.ad")?.hasPrefix("Couldn’t save your filters") == true)
    }

    /// An engine that can't be built leaves the shipped one in place only for a set no one
    /// customized, as it holds exactly that set's lists. With the user's filters, the one kept may
    /// run a filter removed since, so it goes with a message, though no list is off.
    @Test func aFailedEngineBuildKeepsOnlyTheShippedEngine() async throws {
        let key = "filterChoices"
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            try? FileManager.default.removeItem(at: root)
        }
        let named = try shippedSet(["ads": ["easylist": "||ads.lithium.test^"]])
        try #"example.net#%#//scriptlet("set-constant", "lithiumShipped", "1")"#.write(to: named.folder.appending(path: "advanced.txt"), atomically: true, encoding: .utf8)
        let manifest = { (updated: String) in
            Manifest(format: named.manifest.format, updated: updated, groups: named.manifest.groups, advancedRules: 1)
        }
        let privacy = Privacy()
        privacy.filterStorage = storage
        privacy.filterSet = (named.folder, manifest(named.manifest.updated))
        privacy.ruleListStore = try #require(WKContentRuleListStore(url: root.appending(path: "store")))
        let engines = root.appending(path: "engine")
        privacy.advanced = AdvancedBlocking(container: engines)
        let page = URL(string: "https://example.net/")!

        #expect(await privacy.setFilterList("easylist", enabled: true) == nil)
        #expect(privacy.scripts(true, for: page).count == 2, "farbling and the shipped scriptlet")

        // A newer set whose engine can't be built, having nothing to build from: the shipped
        // engine before stays, silently.
        try FileManager.default.removeItem(at: named.folder.appending(path: "advanced.txt"))
        privacy.filterSet = (named.folder, manifest("2026-10-02T00:00:00Z"))
        #expect(await privacy.setFilterList("easylist", enabled: true) == nil)
        #expect(privacy.scripts(true, for: page).count == 2, "the shipped engine kept")
        #expect(privacy.filterError == nil)

        // The user's filters, with no list off: no engine runs, and the page says so.
        try FileManager.default.removeItem(at: engines)
        try Data().write(to: engines)
        #expect(await privacy.setMyFilters("example.org##+js(set, lithiumProbe, 1)") == nil)
        #expect(privacy.scripts(true, for: page).count == 1, "farbling only")
        #expect(privacy.filterError == "Lithium couldn’t build the in-page rules of your filter lists, so none apply until the next change or update.")
    }

    /// A set downloaded before its manifest named each group's lists can't be rebuilt, so a list
    /// turned off fails the build. The app's own grouping then tells which groups hold it: the
    /// others stay, and the lists left on beside it are named.
    @Test func aSetWithoutListNamesKeepsTheGroupsOfTheAppsGrouping() async throws {
        let key = "filterChoices"
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            try? FileManager.default.removeItem(at: root)
        }
        let grouping = try #require(FilterUpdater.bundled()?.sources.groups)
        let named = try shippedSet(grouping.mapValues { lists in Dictionary(uniqueKeysWithValues: lists.map { ($0, "||\($0).lithium.test^") }) })
        let set = (folder: named.folder, manifest: Manifest(format: named.manifest.format, updated: named.manifest.updated,
                                                             groups: named.manifest.groups.mapValues { Manifest.Group(webkitRules: $0.webkitRules) },
                                                             advancedRules: 0))
        let privacy = Privacy()
        privacy.filterStorage = storage
        privacy.filterSet = set
        privacy.ruleListStore = try #require(WKContentRuleListStore(url: root.appending(path: "store")))
        privacy.advanced = AdvancedBlocking(container: root.appending(path: "engine"))

        #expect(await privacy.setFilterList("easylist", enabled: false) == nil)
        // Filters that are only comments add nothing the failure stops, so they aren't named.
        #expect(await privacy.setMyFilters("! only a note") == nil)
        let kept = FilterGroup.shipped(in: set.folder, manifest: set.manifest)
            .filter { !(grouping[$0.name] ?? []).contains("easylist") }.map(\.identifier)
        #expect(!kept.isEmpty)
        #expect(privacy.ruleLists.map(\.identifier) == kept)
        #expect(privacy.filterError == "Lithium couldn’t apply your filter lists. It will try again with the next change or update."
            + " Until then, these aren’t applied: uBlock Origin filters, uBlock Origin quick fixes, every list’s in-page rules.")
    }

    /// An added list is refreshed with the daily update and keeps its copy when that fails; one
    /// removed while it downloads leaves no copy behind. Rules over WebKit's limit are the set's
    /// notice, not a failure of the save that reloaded them, and go with the list.
    @Test func addedListsUpdateAndReportWhatIsLeftOut() async throws {
        let key = "filterChoices"
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            try? FileManager.default.removeItem(at: root)
        }
        let set = try shippedSet(["ads": ["easylist": "||ads.lithium.test^"]])
        let privacy = Privacy()
        privacy.filterStorage = storage
        privacy.filterSet = set
        privacy.ruleListStore = try #require(WKContentRuleListStore(url: root.appending(path: "store")))
        // The added list builds an engine: not in the app's own folder.
        privacy.advanced = AdvancedBlocking(container: root.appending(path: "engine"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubFilterList.self]
        privacy.filterSession = URLSession(configuration: configuration)
        let url = URL(string: "https://\(UUID().uuidString.lowercased()).lists.test/list.txt")!
        let id = FilterLists.id(of: url)

        StubFilterList.serve(Data("||one.lithium.test^\n".utf8), at: url)
        #expect(await privacy.addFilterList(url.absoluteString) == nil)
        #expect(privacy.filterChoices.copies[id]?.rules == 1)
        #expect(privacy.filterError == nil)

        // As if conversion had left rules out.
        let extra = try #require(try FileManager.default.contentsOfDirectory(at: storage.built, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix(FilterLists.extraGroup + "-") })
        try #"{"webkitRules":1,"discarded":7}"#.write(to: extra.appending(path: "info.json"), atomically: true, encoding: .utf8)
        #expect(await privacy.setMyFilters("example.com##.ad") == nil)
        #expect(privacy.filterError == "Over WebKit’s limit: 7 rules of the lists you chose or your filters are left out.")

        StubFilterList.serve(Data("||one.lithium.test^\n||two.lithium.test^\n".utf8), at: url)
        await privacy.updateChosenLists()
        #expect(privacy.filterChoices.copies[id]?.rules == 2)
        StubFilterList.serve(nil, at: url)
        await privacy.updateChosenLists()
        #expect(privacy.filterChoices.copies[id]?.failed == true)
        #expect(privacy.filterChoices.copies[id]?.rules == 2)
        #expect(FileManager.default.fileExists(atPath: storage.copy(of: id).path))

        // Removed while the update downloads it.
        StubFilterList.serve(Data("||three.lithium.test^\n".utf8), at: url, after: 1)
        let update = Task { await privacy.updateChosenLists() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await privacy.setFilterList(id, enabled: false) == nil)
        await update.value
        #expect(privacy.filterChoices.copies[id] == nil)
        #expect(!FileManager.default.fileExists(atPath: storage.copy(of: id).path))
        #expect(privacy.filterError == nil)
    }

    /// A catalog list turned off while it downloads stays off, with no copy left behind, and an
    /// address added twice at once is added once.
    @Test func filterListChoicesMadeDuringADownloadStand() async throws {
        let key = "filterChoices"
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            try? FileManager.default.removeItem(at: root)
        }
        let privacy = Privacy()
        privacy.filterStorage = storage
        privacy.filterSet = try shippedSet(["ads": ["easylist": "||ads.lithium.test^"]])
        privacy.ruleListStore = try #require(WKContentRuleListStore(url: root.appending(path: "store")))
        privacy.advanced = AdvancedBlocking(container: root.appending(path: "engine"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubFilterList.self]
        privacy.filterSession = URLSession(configuration: configuration)

        let list = try #require(FilterLists.catalog.first { $0.url != nil })
        StubFilterList.serve(Data("||catalog.lithium.test^\n".utf8), at: try #require(list.url), after: 1)
        let on = Task { await privacy.setFilterList(list.id, enabled: true) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await privacy.setFilterList(list.id, enabled: false) == nil)
        #expect(await on.value == nil)
        #expect(!privacy.filterChoices.on.contains(list.id))
        #expect(privacy.filterChoices.copies[list.id] == nil)
        #expect(!FileManager.default.fileExists(atPath: storage.copy(of: list.id).path))

        let url = URL(string: "https://\(UUID().uuidString.lowercased()).lists.test/list.txt")!
        StubFilterList.serve(Data("||added.lithium.test^\n".utf8), at: url, after: 0.3)
        async let first = privacy.addFilterList(url.absoluteString)
        async let second = privacy.addFilterList(url.absoluteString)
        _ = await (first, second)
        #expect(privacy.filterChoices.added == [url])
    }

    /// A blocked page is searched for in the lists as chosen: an added list is, a list turned off
    /// isn't. Nothing found names the groups WebKit has, but not one whose lists are all off, nor
    /// one a failed build left out: "Always allow" would save it for the site.
    @Test func blockedPagesAreSearchedInTheListsAsChosen() async throws {
        let key = "filterChoices"
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            try? FileManager.default.removeItem(at: root)
        }
        let set = try shippedSet(["security": ["ubo-badware": "||blocked.lithium.test^$doc"],
                                  "ads": ["easylist": "||ads.lithium.test^", "ubo-filters": "||more.lithium.test^"],
                                  "malware": ["urlhaus": "||malware.lithium.test^"]])
        // The search reads the groups' lists from the folder's manifest.
        try JSONEncoder().encode(set.manifest).write(to: set.folder.appending(path: "manifest.json"))
        let privacy = Privacy()
        privacy.filterStorage = storage
        privacy.filterSet = set
        privacy.ruleListStore = try #require(WKContentRuleListStore(url: root.appending(path: "store")))
        privacy.advanced = AdvancedBlocking(container: root.appending(path: "engine"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubFilterList.self]
        privacy.filterSession = URLSession(configuration: configuration)
        let url = URL(string: "https://\(UUID().uuidString.lowercased()).lists.test/list.txt")!
        let id = FilterLists.id(of: url)
        StubFilterList.serve(Data("||added.lithium.test^\n".utf8), at: url)
        #expect(await privacy.addFilterList(url.absoluteString) == nil)
        #expect(await privacy.setFilterList("ubo-badware", enabled: false) == nil)
        let added = URL(string: "https://added.lithium.test/")!, blocked = URL(string: "https://blocked.lithium.test/")!

        let byAdded = await privacy.blockReason(for: added)
        #expect(byAdded.list == id && BlockedPage.title(of: id) == "a list you added")
        #expect(byAdded.groups == [FilterLists.extraGroup])
        let byOff = await privacy.blockReason(for: blocked)
        #expect(byOff.list == nil, "the list turned off isn't searched")
        #expect(byOff.groups == ["ads", "malware", FilterLists.extraGroup])

        // A failed build loads only the malware group: the others block nothing.
        try FileManager.default.removeItem(at: storage.built)
        try Data().write(to: storage.built)
        #expect(await privacy.setFilterList("easylist", enabled: false) == nil)
        #expect(privacy.filterError?.hasPrefix("Lithium couldn’t apply your filter lists.") == true)
        #expect(await privacy.blockReason(for: added).groups == ["malware"])
        #expect(await privacy.blockReason(for: blocked).groups == ["malware"])
    }

    /// The daily update reloads an added list it refreshed even when the shipped lists fail to
    /// download, and backs off after that failure.
    @Test(.timeLimit(.minutes(1))) func aFailedUpdateStillReloadsAddedListsAndBacksOff() async throws {
        let keys = ["filterChoices", "failedFilterUpdates", "nextFilterUpdate"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        keys.forEach(UserDefaults.standard.removeObject)
        defer {
            for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) }
            try? FileManager.default.removeItem(at: root)
        }
        let set = try shippedSet(["ads": ["easylist": "||ads.lithium.test^"]])
        let privacy = Privacy()
        privacy.filterStorage = storage
        privacy.filterSet = set
        privacy.ruleListStore = try #require(WKContentRuleListStore(url: root.appending(path: "store")))
        privacy.advanced = AdvancedBlocking(container: root.appending(path: "engine"))
        // Not the app's own folder, which the shipped lists' update writes to.
        privacy.filterDownloads = root.appending(path: "downloads/Filters")
        // Every other address, the shipped lists' included, answers 404: nothing is written.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubFilterList.self]
        privacy.filterSession = URLSession(configuration: configuration)
        let url = URL(string: "https://\(UUID().uuidString.lowercased()).lists.test/list.txt")!
        StubFilterList.serve(Data("||one.lithium.test^\n".utf8), at: url)
        #expect(await privacy.addFilterList(url.absoluteString) == nil)
        let loaded = privacy.ruleLists.map(\.identifier)

        StubFilterList.serve(Data("||one.lithium.test^\n||two.lithium.test^\n".utf8), at: url)
        privacy.updateFiltersNow()
        #expect(privacy.isUpdatingFilters)
        while privacy.isUpdatingFilters { try await Task.sleep(for: .milliseconds(50)) }
        #expect(privacy.filterChoices.copies[FilterLists.id(of: url)]?.rules == 2)
        #expect(privacy.ruleLists.map(\.identifier) != loaded, "reloaded")
        #expect(UserDefaults.standard.integer(forKey: "failedFilterUpdates") == 1)
        #expect(UserDefaults.standard.double(forKey: "nextFilterUpdate") > Date().timeIntervalSinceReferenceDate)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "downloads").path), "the update ran there")
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

        // Another list's problem shows, but this save and this address went through.
        bridge.error = nil
        bridge.notice = "Over WebKit’s limit: 7 rules of the lists you chose or your filters are left out."
        _ = try await run("document.getElementById('my-filters-save').click()")
        try await Task.sleep(for: .milliseconds(200))
        try await settled()
        #expect(try await run("return document.getElementById('my-filters-status').textContent") as? String == "Saved")
        #expect(try await run("return document.getElementById('filter-error').textContent") as? String == bridge.notice)
        _ = try await run("""
            document.getElementById('filter-url').value = 'https://example.com/list.txt';
            document.getElementById('filter-add-form').requestSubmit();
            """)
        try await Task.sleep(for: .milliseconds(200))
        try await settled()
        #expect(bridge.added)
        #expect(try await run("return document.getElementById('filter-url').value") as? String == "")

        // A failed add shows its message beside the set's notice, and keeps the address.
        bridge.error = "This list is already added."
        _ = try await run("""
            document.getElementById('filter-url').value = 'https://example.com/list.txt';
            document.getElementById('filter-add-form').requestSubmit();
            """)
        try await Task.sleep(for: .milliseconds(200))
        try await settled()
        #expect(try await run("return document.getElementById('filter-error').textContent") as? String == "This list is already added. \(bridge.notice!)")
        #expect(try await run("return document.getElementById('filter-url').value") as? String == "https://example.com/list.txt")
    }

    /// The app's own bridge puts a failed save in `failed`, which keeps the page from saying "Saved".
    /// A whole Browser keeps its data in the home folder, so this only runs in a throwaway one.
    @Test(.timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
    func theBridgeReportsAFailedSave() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let browser = Browser()
        browser.privacy.filterStorage = storage
        // Where the file goes, a folder: the save fails.
        try FileManager.default.createDirectory(at: storage.myFilters, withIntermediateDirectories: true)
        let configuration = WKWebViewConfiguration()
        InternalSchemeHandler.shared.install(on: configuration)
        configuration.userContentController.addScriptMessageHandler(browser.internalBridge, contentWorld: .page, name: InternalBridge.name)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 700), configuration: configuration)
        let loaded = PageLoad()
        webView.navigationDelegate = loaded
        webView.load(URLRequest(url: URL(string: "lithium://settings#filters")!))
        try await loaded.wait()
        let reply = try await webView.callAsyncJavaScript("""
            return await window.webkit.messageHandlers.lithium.postMessage({ action: 'setMyFilters', value: 'example.org##.ad' })
            """, contentWorld: .page) as? [String: Any]
        let failed = try #require(reply?["failed"] as? String)
        #expect(failed.hasPrefix("Couldn’t save your filters"))
        #expect((reply?["error"] as? String)?.hasPrefix(failed) == true)
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
        #expect(rules.contains("ytd-reel-shelf-renderer"))
        // Every compiled rule is scoped to YouTube, and the in-page ones run on youtube.com only.
        let compiled = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: extra.file)) as? [[String: Any]])
        #expect(!compiled.isEmpty && compiled.allSatisfy { rule in
            (rule["trigger"] as? [String: Any] ?? [:]).contains { key, value in
                key.hasPrefix("if-") && (value as? [String]).map { !$0.isEmpty && $0.allSatisfy { $0.contains("youtube") } } == true
            }
        })
        let engine = AdvancedBlocking(container: root.appending(path: "engine"))
        #expect(await engine.load(folder: youtube.engineFolder, stamp: youtube.engineStamp))
        #expect(engine.script(for: URL(string: "https://www.youtube.com/")!)?.contains("rich-shelf-header") == true)
        #expect(engine.script(for: URL(string: "https://example.com/")!) == nil)

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
    @Test(.timeLimit(.minutes(1))) func badAddressesAreRefused() async throws {
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

        // Taken in the chunks it arrives in: a rule cut across two stays whole, and a NUL byte in a
        // later chunk is still found.
        let chunked = URL(string: "\(host)/chunked.txt")!
        StubFilterList.serve(Data("||one.example^\n||two.example^\n".utf8), at: chunked, chunk: 5)
        #expect(try await FilterLists.download(chunked, session: session) == ["||one.example^", "||two.example^"])
        StubFilterList.serve(Data("||one.example^\n||two\u{0}example^\n".utf8), at: chunked, chunk: 5)
        await #expect(throws: (any Error).self, "chunked binary") { try await FilterLists.download(chunked, session: session) }
        // The cap counts every chunk so far, with no length announced: none of these is over it alone.
        StubFilterList.serve(bodies["huge"]!, at: chunked, chunk: 1 << 20)
        await #expect(throws: (any Error).self, "chunked huge") { try await FilterLists.download(chunked, session: session) }

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
            ! A note\u{2028}example.com##+js(lithium-no-such-scriptlet)
            """)
        #expect(problems.map(\.line) == [5, 6, 9])
        #expect(problems.first?.message == "Unknown scriptlet “lithium-no-such-scriptlet”.")
        #expect(FilterUpdater.isAllowed("example.org##+js(set, a, 1)", list: FilterLists.myFiltersID))
        #expect(!FilterUpdater.isAllowed("example.org##+js(set, a, 1)", list: FilterLists.id(of: URL(string: "https://example.com/l.txt")!)))
    }
}

/// The Filter lists page's calls, answered with one list and the saved filters. `error` fails the
/// call; `notice` is a problem of the whole set, as `Privacy.filterError`.
@MainActor
private final class FakeFilterBridge: NSObject, WKScriptMessageHandlerWithReply {
    var saved = "saved##.x"
    var error: String?
    var notice: String?
    var toggled = false
    var added = false

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        let body = message.body as? [String: Any]
        switch body?["action"] as? String {
        case "filterLists": break
        case "setFilterList": toggled = true
        case "setMyFilters": if error == nil { saved = body?["value"] as? String ?? "" }
        case "addFilterList": added = true
        default: return (nil, nil)
        }
        let list: [String: Any] = ["id": "easylist", "name": "EasyList", "summary": "Ads.", "homepage": "", "enabled": !toggled,
                                   "rules": 1, "updated": 0, "failed": false, "removable": false]
        var reply: [String: Any] = ["sections": [["title": "Ads", "lists": [list]]], "myFilters": saved, "problems": []]
        for (key, message) in InternalBridge.filterMessages(failed: error, notice: notice) { reply[key] = message }
        return (reply, nil)
    }
}

/// Answers with the body served at a URL, or a 404 when there is none, after the delay given,
/// in chunks of the size given.
private final class StubFilterList: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bodies: [URL: Data] = [:]
    nonisolated(unsafe) private static var delays: [URL: TimeInterval] = [:]
    nonisolated(unsafe) private static var chunks: [URL: Int] = [:]

    static func serve(_ body: Data?, at url: URL, after delay: TimeInterval = 0, chunk: Int = .max) {
        lock.withLock {
            bodies[url] = body
            delays[url] = delay
            chunks[url] = chunk
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let (body, delay, chunk) = Self.lock.withLock { (Self.bodies[url], Self.delays[url] ?? 0, Self.chunks[url] ?? .max) }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        let response = HTTPURLResponse(url: url, statusCode: body == nil ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let data = body ?? Data("Not found".utf8)
        for start in stride(from: 0, to: data.count, by: chunk) {
            client?.urlProtocol(self, didLoad: data.subdata(in: start..<min(start + chunk, data.count)))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

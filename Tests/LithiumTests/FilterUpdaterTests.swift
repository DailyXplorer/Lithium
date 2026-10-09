import CryptoKit
import Foundation
import Testing
import WebKit
@testable import Lithium

/// Downloads the real lists; run with LITHIUM_NETWORK_TESTS=1.
@Test(.enabled(if: ProcessInfo.processInfo.environment["LITHIUM_NETWORK_TESTS"] == "1"))
@MainActor
func downloadsAndCompilesTheRealLists() async throws {
    let updater = try #require(FilterUpdater.bundled())
    let destination = FileManager.default.temporaryDirectory.appending(path: "filters-\(UUID())")
    try await updater.update(into: destination)

    let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: destination.appending(path: "manifest.json")))
    #expect(manifest.format == Manifest.currentFormat)
    #expect(Set(manifest.groups.keys) == ["ads", "cookies", "privacy", "security"])
    #expect(manifest.groups.values.allSatisfy { $0.webkitRules > 10_000 })
    #expect((manifest.advancedRules ?? 0) > 1_000)
    #expect((manifest.scriptletRules ?? 0) > 5_000)
    print("updater:", manifest.groups.mapValues(\.webkitRules), "advanced:", manifest.advancedRules ?? 0, "scriptlets:", manifest.scriptletRules ?? 0)

    let blocking = AdvancedBlocking(container: destination.appending(path: "engine"))
    await blocking.load(folder: destination, stamp: UUID().uuidString)
    let youtube = try #require(blocking.script(for: URL(string: "https://www.youtube.com/watch?v=x")!))
    #expect(youtube.contains("function trustedJsonEditXhrRequest("))
}

/// Loads a real HTTPS page; run with LITHIUM_NETWORK_TESTS=1.
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["LITHIUM_NETWORK_TESTS"] == "1"))
func readsTheCertificateOfARealPage() async throws {
    let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    let loaded = PageLoad()
    webView.navigationDelegate = loaded
    webView.load(URLRequest(url: URL(string: "https://github.com/")!))
    try await loaded.wait()
    let info = SiteInfo(url: try #require(webView.url))
    await info.loadCertificate(trust: webView.serverTrust)
    print("certificate:", info.connection, info.certificate)
    #expect(info.connection == .secure)
    guard case .found(let certificate) = info.certificate else { Issue.record("no certificate"); return }
    #expect(certificate.subject == "github.com")
    #expect((certificate.validUntil ?? .distantPast) > Date())
}

struct CookieFiltersTests {
    @Test func bundledSourcesHaveACookiesGroup() throws {
        let sources = try #require(FilterUpdater.bundled()).sources
        #expect(sources.groups["cookies"] == ["ubo-cookies", "easylist-cookies", "ubo-unbreak"])
        #expect(sources.lists["ubo-cookies"]?.absoluteString == "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/annoyances-cookies.txt")
        #expect(sources.lists["easylist-cookies"]?.absoluteString == "https://secure.fanboy.co.nz/fanboy-cookiemonster.txt")
    }

    @Test func onlyUBOCookieFiltersRunAsUBOScriptlets() {
        let rule = "example.com##+js(trusted-click-element, #reject-all)"
        #expect(FilterUpdater.isUBOScriptlet(rule, list: "ubo-cookies"))
        #expect(!FilterUpdater.isUBOScriptlet(rule, list: "easylist-cookies"))
    }

    @Test func manifestMissingAGroupOrListWasNotBuiltFromTheSources() {
        let sources = FilterUpdater.Sources(
            lists: [:],
            groups: ["ads": ["easylist", "ubo-unbreak"], "cookies": ["ubo-cookies", "easylist-cookies", "ubo-unbreak"]],
            trueTokens: []
        )
        func manifest(_ groups: [String: [String]?]) -> Manifest {
            Manifest(updated: "2026-10-02T00:00:00Z", groups: groups.mapValues { Manifest.Group(lists: $0, webkitRules: 1) }, advancedRules: nil)
        }
        #expect(sources.built(manifest(["ads": ["easylist", "ubo-unbreak"], "cookies": ["ubo-cookies", "easylist-cookies", "ubo-unbreak"]])))
        #expect(!sources.built(manifest(["ads": ["easylist", "ubo-unbreak"]])))
        #expect(!sources.built(manifest(["ads": ["easylist", "ubo-unbreak"], "cookies": ["ubo-cookies", "ubo-unbreak"]])))
        #expect(!sources.built(manifest(["ads": nil, "cookies": ["ubo-cookies", "easylist-cookies", "ubo-unbreak"]])))
    }

    /// A list's new address or a changed token changes no group: the set built from the old
    /// FilterSources.json is refreshed all the same.
    @Test func aChangedSourcesFileIsNotBuiltFromTheSameSources() throws {
        let bundled = try #require(FilterUpdater.bundled()).sources
        let data = try Data(contentsOf: try #require(Resources.bundle.url(forResource: "FilterSources", withExtension: "json")))
        #expect(bundled.digest == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())

        let groups = ["ads": ["easylist"]]
        let sources = FilterUpdater.Sources(lists: [:], groups: groups, trueTokens: [], digest: "new")
        func manifest(_ digest: String?) -> Manifest {
            Manifest(updated: "2026-10-02T00:00:00Z", groups: groups.mapValues { Manifest.Group(lists: $0, webkitRules: 1) }, advancedRules: nil, sources: digest)
        }
        #expect(sources.built(manifest("new")))
        #expect(!sources.built(manifest("old")))
        #expect(!sources.built(manifest(nil)))
    }
}

/// Filter updates from lists served in the test, without the network.
struct FilterUpdateTests {
    private let host = "\(UUID().uuidString.lowercased()).lists.test"
    private let destination = FileManager.default.temporaryDirectory.appending(path: "filters-\(UUID())")

    private func url(_ list: String) -> URL { URL(string: "https://\(host)/\(list).txt")! }

    /// Lists of a rule or two pass with `minimumRules` at 1.
    private func updater(_ groups: [String: [String]], bundledFilters: URL? = nil, minimumRules: Int = 1) -> FilterUpdater {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubLists.self]
        let lists = Dictionary(uniqueKeysWithValues: Set(groups.values.joined()).map { ($0, url($0)) })
        return FilterUpdater(
            sources: .init(lists: lists, groups: groups, trueTokens: [], digest: "test-sources"), session: URLSession(configuration: configuration),
            bundledFilters: bundledFilters, minimumRules: minimumRules
        )
    }

    private func read(_ file: String) throws -> String {
        try String(contentsOf: destination.appending(path: file), encoding: .utf8)
    }

    private func manifest() throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: destination.appending(path: "manifest.json")))
    }

    /// The in-page engine can't tell which list a rule came from, so only uBO's lists may bring rules that run code.
    @Test func onlyUBOListsBringRulesThatRunCode() async throws {
        defer { try? FileManager.default.removeItem(at: destination) }
        StubLists.serve("""
            example.org##+js(set, uboProbe, 1)
            example.org#%#//scriptlet("set-constant", "uboAdguardProbe", "1")
            """, at: url("ubo-filters"))
        StubLists.serve("""
            example.org##+js(trusted-set, otherProbe, 1)
            example.org#%#//scriptlet("ubo-trusted-set-constant", "otherScriptlet", "1")
            example.org#%#window.otherScript = 1;
            example.org#@%#//scriptlet("set-constant", "uboAdguardProbe", "1")
            ||ads.example.org^
            """, at: url("easylist"))
        try await updater(["ads": ["ubo-filters", "easylist"]]).update(into: destination)

        let scriptlets = try read("scriptlets.txt")
        let advanced = try read("advanced.txt")
        #expect(scriptlets.contains("uboProbe") && !scriptlets.contains("otherProbe"))
        #expect(advanced.contains("uboAdguardProbe"))
        #expect(!advanced.contains("otherProbe") && !advanced.contains("otherScript") && !advanced.contains("#@%#"))
        #expect(try manifest().groups["ads"]?.webkitRules == 1)
        #expect(FilterUpdater.isAllowed("example.org##+js(trusted-click-element, #x)", list: "ubo-cookies"))
        #expect(!FilterUpdater.isAllowed("example.org#@#+js(set, a, 1)", list: "easylist-cookies"))
        #expect(FilterUpdater.isAllowed("example.org##.cookie-banner", list: "easylist-cookies"))
    }

    /// A dead or failing list keeps its last good copy, and the others still update.
    @Test func aFailingListKeepsItsLastGoodCopyWithoutHoldingBackTheOthers() async throws {
        let bundled = FileManager.default.temporaryDirectory.appending(path: "bundled-filters-\(UUID())")
        defer { try? FileManager.default.removeItem(at: destination); try? FileManager.default.removeItem(at: bundled) }
        let updater = updater(["ads": ["steady", "flaky", "dead"]], bundledFilters: bundled)
        StubLists.serve("||first-steady.example^", at: url("steady"))
        StubLists.serve("||first-flaky.example^", at: url("flaky"))

        // A failing list with no copy anywhere would lose its rules: nothing is written.
        await #expect(throws: (any Error).self) { try await updater.update(into: destination) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))

        // The first update after installing falls back to the bundled copy.
        try FileManager.default.createDirectory(at: bundled.appending(path: "lists"), withIntermediateDirectories: true)
        try "||bundled-dead.example^".write(to: bundled.appending(path: "lists/dead.txt"), atomically: false, encoding: .utf8)
        try await updater.update(into: destination)
        #expect(try manifest().failedLists == ["dead"])
        #expect(try read("ads.json").contains("bundled-dead"))

        StubLists.serve("||second-steady.example^", at: url("steady"))
        StubLists.serve(nil, at: url("flaky"))
        try await updater.update(into: destination)
        let rules = try read("ads.json")
        #expect(try manifest().failedLists == ["dead", "flaky"])
        #expect(rules.contains("second-steady") && rules.contains("first-flaky") && !rules.contains("first-steady"))

        // Every list failing leaves the folder as it was.
        StubLists.serve(nil, at: url("steady"))
        let before = try read("manifest.json")
        await #expect(throws: (any Error).self) { try await updater.update(into: destination) }
        #expect(try read("manifest.json") == before)
        #expect(try read("ads.json") == rules)
    }

    /// After an upgrade the bundled set can be newer than the downloaded one: a failing list then
    /// keeps the bundled copy, not the older download.
    @Test func aFailingListKeepsTheNewerCopy() async throws {
        let bundled = FileManager.default.temporaryDirectory.appending(path: "bundled-filters-\(UUID())")
        defer { try? FileManager.default.removeItem(at: destination); try? FileManager.default.removeItem(at: bundled) }
        let updater = updater(["ads": ["steady", "flaky"]], bundledFilters: bundled)
        StubLists.serve("||steady.example^", at: url("steady"))
        StubLists.serve("||downloaded-flaky.example^", at: url("flaky"))
        try await updater.update(into: destination)

        func write(_ updated: String, to folder: URL) throws {
            let manifest = Manifest(updated: updated, groups: [:], advancedRules: nil)
            try JSONEncoder().encode(manifest).write(to: folder.appending(path: "manifest.json"))
        }
        try write("2025-01-01T00:00:00Z", to: destination)
        try FileManager.default.createDirectory(at: bundled.appending(path: "lists"), withIntermediateDirectories: true)
        try "||bundled-flaky.example^".write(to: bundled.appending(path: "lists/flaky.txt"), atomically: false, encoding: .utf8)
        try write(ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60)), to: bundled)

        StubLists.serve(nil, at: url("flaky"))
        try await updater.update(into: destination)
        let rules = try read("ads.json")
        #expect(rules.contains("bundled-flaky") && !rules.contains("downloaded-flaky"))
    }

    /// A staging folder an update interrupted by quitting left behind goes with the next update,
    /// once untouched for a day; one of an update under way stays.
    @Test func anAbandonedStagingFolderIsRemoved() async throws {
        let parent = FileManager.default.temporaryDirectory.appending(path: "filters-parent-\(UUID())")
        defer { try? FileManager.default.removeItem(at: parent) }
        let abandoned = parent.appending(path: ".filters-\(UUID().uuidString)")
        let current = parent.appending(path: ".filters-\(UUID().uuidString)")
        for folder in [abandoned, current] {
            try FileManager.default.createDirectory(at: folder.appending(path: "lists"), withIntermediateDirectories: true)
        }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 24 * 60 * 60)], ofItemAtPath: abandoned.path)

        StubLists.serve("||steady.example^", at: url("steady"))
        try await updater(["ads": ["steady"]]).update(into: parent.appending(path: "filters"))
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(FileManager.default.fileExists(atPath: current.path))
        #expect(FileManager.default.fileExists(atPath: parent.appending(path: "filters/manifest.json").path))
    }

    /// A set dated in the future (built with the clock set ahead) neither outranks the sets built
    /// after it nor stops the automatic updates.
    @MainActor
    @Test func aSetDatedInTheFutureIsUpdated() throws {
        let now = Date()
        let folder = FileManager.default.temporaryDirectory.appending(path: "dated-filters-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let (future, past) = (folder.appending(path: "future"), folder.appending(path: "past"))
        for (set, date) in [(future, now.addingTimeInterval(30 * 24 * 60 * 60)), (past, now.addingTimeInterval(-60))] {
            try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
            let manifest = Manifest(updated: ISO8601DateFormatter().string(from: date), groups: [:], advancedRules: nil)
            try JSONEncoder().encode(manifest).write(to: set.appending(path: "manifest.json"))
        }
        #expect(FilterUpdater.newestFirst([future, past], now: now) == [past, future])

        let ahead = now.addingTimeInterval(60 * 60)
        #expect(Privacy.needsUpdate(updated: ahead, matchesSources: true, complete: true, notBefore: .distantPast, now: now))
        #expect(!Privacy.needsUpdate(updated: ahead, matchesSources: true, complete: true, notBefore: now.addingTimeInterval(60), now: now))
    }

    /// A 200 answer that isn't a filter list (empty, an HTML page, a handful of lines) counts as
    /// failed and keeps the last good copy, so the next update retries it soon.
    @Test func aBodyThatIsNotAListKeepsTheLastGoodCopy() async throws {
        defer { try? FileManager.default.removeItem(at: destination) }
        let updater = updater(["ads": ["steady", "flaky"]], minimumRules: 10)
        func list(_ prefix: String) -> String { (1...12).map { "||\(prefix)-\($0).example^" }.joined(separator: "\n") }
        StubLists.serve(list("steady"), at: url("steady"))
        StubLists.serve(list("good"), at: url("flaky"))
        try await updater.update(into: destination)
        #expect(try manifest().failedLists == nil)
        let goodCopy = try read("lists/flaky.txt")

        for body in ["", "\n  \n! Title: empty\n", "\u{FEFF}  <!DOCTYPE html>\n<html><body>Sign in</body></html>", "||few-1.example^\n||few-2.example^"] {
            StubLists.serve(body, at: url("flaky"))
            try await updater.update(into: destination)
            #expect(try manifest().failedLists == ["flaky"])
            #expect(try read("lists/flaky.txt") == goodCopy)
            let rules = try read("ads.json")
            #expect(rules.contains("good-12") && rules.contains("steady-12") && !rules.contains("few-1") && !rules.contains("Sign in"))
        }

        // An HTML page behind an include fails the list too.
        StubLists.serve("!#include \(url("portal").absoluteString)\n" + list("included"), at: url("flaky"))
        StubLists.serve("<html><body>Sign in</body></html>", at: url("portal"))
        try await updater.update(into: destination)
        #expect(try manifest().failedLists == ["flaky"])
        #expect(try read("lists/flaky.txt") == goodCopy)
    }

    /// An include is followed only on the list's own server: another site's, or a file on the
    /// Mac, is skipped. The set names the FilterSources.json it was built from.
    @Test func includesComeOnlyFromTheListsOwnServer() async throws {
        defer { try? FileManager.default.removeItem(at: destination) }
        let other = URL(string: "https://other-\(host)/extra.txt")!
        StubLists.serve("||elsewhere-rule.example^", at: other)
        StubLists.serve("||same-server-rule.example^", at: url("same"))
        StubLists.serve("""
            !#include \(other.absoluteString)
            !#include file:///etc/hosts
            !#include same.txt
            ||own-list-rule.example^
            """, at: url("easylist"))
        try await updater(["ads": ["easylist"]]).update(into: destination)

        let rules = try read("ads.json")
        #expect(rules.contains("own-list-rule") && rules.contains("same-server-rule"))
        #expect(!rules.contains("elsewhere-rule"))
        #expect(try manifest().failedLists == nil)
        #expect(try manifest().sources == "test-sources")
    }

    /// A condition nested thousands deep is false, and doesn't overflow the updater's stack.
    @Test func aDeeplyNestedConditionIsFalse() {
        let tokens: Set<String> = ["env_safari"]
        #expect(FilterUpdater.evaluate("env_safari && !(ext_ubol || cap_x)", trueTokens: tokens))
        #expect(!FilterUpdater.evaluate("!env_safari", trueTokens: tokens))
        #expect(FilterUpdater.evaluate(String(repeating: "(", count: 20) + "env_safari", trueTokens: tokens))
        #expect(FilterUpdater.evaluate(String(repeating: "!", count: 20) + "env_safari", trueTokens: tokens))
        for prefix in ["(", "!", "!(", "!!"] {
            #expect(!FilterUpdater.evaluate(String(repeating: prefix, count: 100_000) + "env_safari", trueTokens: tokens))
        }
    }

    /// An endless chain of includes on the list's own server ends: the list fails and keeps its
    /// last good copy.
    @Test func anEndlessChainOfIncludesFailsTheList() async throws {
        defer { try? FileManager.default.removeItem(at: destination) }
        let updater = updater(["ads": ["chain"]])
        StubLists.serve("||good.example^", at: url("chain"))
        try await updater.update(into: destination)
        let goodCopy = try read("lists/chain.txt")

        StubLists.serve("!#include chain-1.txt\n||first.example^", at: url("chain"))
        let last = FilterUpdater.maximumListFiles + 8
        for link in 1...last {
            StubLists.serve((link < last ? "!#include chain-\(link + 1).txt\n" : "") + "||link-\(link).example^", at: url("chain-\(link)"))
        }
        await #expect(throws: (any Error).self) { try await updater.update(into: destination) }
        #expect(try read("lists/chain.txt") == goodCopy)

        // A few includes are fine.
        StubLists.serve("!#include chain-\(last - 2).txt\n||first.example^", at: url("chain"))
        try await updater.update(into: destination)
        #expect(try read("lists/chain.txt").contains("link-\(last).example"))
    }

    /// Automatic updates after a failure wait longer each time, up to a day, instead of fetching every list each hour.
    @MainActor
    @Test func failedUpdatesAreRetriedWithABackoff() {
        let now = Date()
        #expect(Privacy.retryDelay(afterFailures: 1) == 60 * 60)
        #expect(Privacy.retryDelay(afterFailures: 3) == 4 * 60 * 60)
        #expect(Privacy.retryDelay(afterFailures: 50) == 24 * 60 * 60)

        let recent = now.addingTimeInterval(-60)
        #expect(!Privacy.needsUpdate(updated: recent, matchesSources: true, complete: true, notBefore: .distantPast, now: now))
        #expect(Privacy.needsUpdate(updated: recent, matchesSources: true, complete: false, notBefore: .distantPast, now: now))
        #expect(!Privacy.needsUpdate(updated: recent, matchesSources: true, complete: false, notBefore: now.addingTimeInterval(60), now: now))
        #expect(!Privacy.needsUpdate(updated: .distantPast, matchesSources: true, complete: true, notBefore: now.addingTimeInterval(60), now: now))
        #expect(Privacy.needsUpdate(updated: .distantPast, matchesSources: true, complete: true, notBefore: now.addingTimeInterval(-1), now: now))
    }

    /// The backoff outlives a relaunch: a list that stays down doesn't bring a full update at every launch.
    @MainActor
    @Test func theBackoffSurvivesARelaunch() throws {
        let suite = "filter-backoff-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        #expect(Privacy.savedBackoff(in: defaults, now: now).notBefore == .distantPast)

        _ = Privacy.saveBackoff(afterFailures: 3, in: defaults, now: now)
        let relaunched = Privacy.savedBackoff(in: defaults, now: now.addingTimeInterval(60))
        #expect(relaunched.failures == 3)
        #expect(relaunched.notBefore == now.addingTimeInterval(4 * 60 * 60))
        #expect(!Privacy.needsUpdate(updated: now, matchesSources: true, complete: false, notBefore: relaunched.notBefore, now: now.addingTimeInterval(60)))

        // A clock turned back doesn't hold updates off for more than a day.
        #expect(Privacy.savedBackoff(in: defaults, now: now.addingTimeInterval(-7 * 24 * 60 * 60)).notBefore
            == now.addingTimeInterval(-6 * 24 * 60 * 60))

        _ = Privacy.saveBackoff(afterFailures: 0, in: defaults, now: now)
        let succeeded = Privacy.savedBackoff(in: defaults, now: now)
        #expect(succeeded.failures == 0 && succeeded.notBefore == .distantPast)
    }

    /// scripts/update-filters.py fails a list the app's updater would refuse, so the app never
    /// ships an HTML page or an empty file as the copy it falls back to.
    @Test func updateScriptRefusesWhatTheUpdaterRefuses() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "update-script-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func list(_ prefix: String) -> String { (1...12).map { "||\(prefix)-\($0).example^" }.joined(separator: "\n") }
        let bodies = [
            "good": list("good"),
            "empty": "\n  \n! Title: empty\n",
            "html": "\u{FEFF}  <!DOCTYPE html>\n<html><body>Sign in</body></html>",
            "few": "||few-1.example^\n||few-2.example^",
            "portal": "!#include html.txt\n" + list("included"),
        ]
        for (name, body) in bodies {
            try body.write(to: folder.appending(path: "\(name).txt"), atomically: false, encoding: .utf8)
        }
        // Loads the script as a module and downloads each list from a file URL.
        let check = """
            import importlib.util, pathlib, sys
            spec = importlib.util.spec_from_file_location("update_filters", sys.argv[1])
            script = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(script)
            folder = pathlib.Path(sys.argv[2])
            script.LISTS = {path.stem: path.as_uri() for path in folder.glob("*.txt")}
            for name in sorted(script.LISTS):
                try:
                    print(name, len(script.download(name)))
                except SystemExit:
                    print(name, "failed")
            """
        let script = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../scripts/update-filters.py").standardized
        let python = Process()
        python.executableURL = URL(filePath: "/usr/bin/python3")
        python.arguments = ["-I", "-c", check, script.path, folder.path]
        let output = Pipe()
        python.standardOutput = output
        try python.run()
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        python.waitUntilExit()
        #expect(python.terminationStatus == 0)
        #expect(printed == "empty failed\nfew failed\ngood 12\nhtml failed\nportal failed\n")
    }

    /// scripts/update-filters.py reads a malformed `!#if` as false without stopping or hanging the
    /// build, follows an include only on the list's own server, and `--check` sees a set built
    /// from another FilterSources.json as one to build again.
    @Test func updateScriptKeepsToItsListsAndSources() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "update-script-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let check = """
            import importlib.util, json, pathlib, sys
            spec = importlib.util.spec_from_file_location("update_filters", sys.argv[1])
            script = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(script)
            folder = pathlib.Path(sys.argv[2])
            for condition in ["env_safari", "!env_safari", "foo()", "1/0", "9**9**9", "env_safari && ("]:
                print(condition, script.eval_condition(condition))
            (folder / "main.txt").write_text("!#include https://example.invalid/list.txt\\n!#include neighbour.txt\\n||main.example^\\n")
            (folder / "neighbour.txt").write_text("||neighbour.example^\\n")
            print(*script.expand((folder / "main.txt").as_uri(), set()))
            built = folder / "set"
            (built / "lists").mkdir(parents=True)
            for name in ["ads.json", "advanced.txt", "scriptlets.txt", "lists/main.txt"]:
                (built / name).write_text("")
            script.GROUPS = {"ads": ["main"]}
            for sources, converter in [(script.SOURCES_DIGEST, script.CONVERTER_TAG), ("older", script.CONVERTER_TAG),
                                       (None, script.CONVERTER_TAG), (script.SOURCES_DIGEST, "v0.0.1"), (script.SOURCES_DIGEST, None)]:
                manifest = {"format": script.FORMAT, "groups": {"ads": {"lists": ["main"]}}}
                if sources:
                    manifest["sources"] = sources
                if converter:
                    manifest["converter"] = converter
                (built / "manifest.json").write_text(json.dumps(manifest))
                print("complete", script.complete(built))
            """
        let script = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../scripts/update-filters.py").standardized
        let python = Process()
        python.executableURL = URL(filePath: "/usr/bin/python3")
        python.arguments = ["-I", "-c", check, script.path, folder.path]
        let output = Pipe()
        python.standardOutput = output
        try python.run()
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        python.waitUntilExit()
        #expect(python.terminationStatus == 0)
        #expect(printed == """
            env_safari True
            !env_safari False
            foo() False
            1/0 False
            9**9**9 False
            env_safari && ( False
            ||neighbour.example^ ||main.example^
            complete True
            complete False
            complete False
            complete False
            complete False

            """)
    }

    /// scripts/update-filters.py clones and builds the converter again when its clone is of
    /// another tag, so the bundled set is never built with an older converter than the app's.
    @Test func updateScriptRebuildsAConverterOfAnotherTag() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "update-script-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // git and swift stand-ins: a clone checks out CONVERTER_TAG, a build makes the binary.
        let check = """
            import importlib.util, pathlib, subprocess, sys
            spec = importlib.util.spec_from_file_location("update_filters", sys.argv[1])
            script = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(script)
            tools = pathlib.Path(sys.argv[2])
            script.TOOLS = tools
            script.CONVERTER_BIN = tools / "SafariConverterLib/.build/release/ConverterTool"
            repo = tools / "SafariConverterLib"
            tag = [""]
            calls = []
            def run(command, **options):
                if command[:2] == ["git", "-C"]:
                    return subprocess.CompletedProcess(command, 0 if tag[0] else 128, stdout=tag[0] + "\\n", stderr="")
                calls.append(command[1])
                if command[1] == "clone":
                    pathlib.Path(command[-1]).mkdir(parents=True)
                    tag[0] = script.CONVERTER_TAG
                else:
                    script.CONVERTER_BIN.parent.mkdir(parents=True, exist_ok=True)
                    script.CONVERTER_BIN.touch()
                return subprocess.CompletedProcess(command, 0)
            script.subprocess.run = run
            def step(name):
                calls.clear()
                script.ensure_converter()
                print(name, " ".join(calls) or "nothing")
            step("fresh")
            step("built")
            tag[0] = "v0.0.1"
            (repo / "old").touch()
            step("raised")
            print("old clone left", (repo / "old").exists())
            script.CONVERTER_BIN.unlink()
            step("unbuilt")
            """
        let script = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../scripts/update-filters.py").standardized
        let python = Process()
        python.executableURL = URL(filePath: "/usr/bin/python3")
        python.arguments = ["-I", "-c", check, script.path, folder.appending(path: "tools").path]
        let output = Pipe()
        python.standardOutput = output
        try python.run()
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        python.waitUntilExit()
        #expect(python.terminationStatus == 0)
        #expect(printed == "fresh clone build\nbuilt nothing\nraised clone build\nold clone left False\nunbuilt build\n")
    }
}

/// Answers with the body served at a URL, or a 404 when there is none.
private final class StubLists: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bodies: [URL: String] = [:]

    static func serve(_ body: String?, at url: URL) {
        lock.withLock { bodies[url] = body }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let body = Self.lock.withLock { Self.bodies[url] }
        let response = HTTPURLResponse(url: url, statusCode: body == nil ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((body ?? "Not found").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

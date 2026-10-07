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
            sources: .init(lists: lists, groups: groups, trueTokens: []), session: URLSession(configuration: configuration),
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

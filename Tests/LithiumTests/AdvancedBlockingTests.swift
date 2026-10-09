import Foundation
import Testing
import WebKit
@testable import Lithium

@MainActor
struct AdvancedBlockingTests {
    private func makeBlocking(rules: String = "", uboScriptlets: String = "") async throws -> AdvancedBlocking {
        let folder = FileManager.default.temporaryDirectory.appending(path: "advanced-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try rules.write(to: folder.appending(path: "advanced.txt"), atomically: true, encoding: .utf8)
        try uboScriptlets.write(to: folder.appending(path: "scriptlets.txt"), atomically: true, encoding: .utf8)
        let blocking = AdvancedBlocking(container: folder.appending(path: "engine"))
        await blocking.load(folder: folder, stamp: UUID().uuidString)
        return blocking
    }

    @Test func onlyMatchingSitesGetAScript() async throws {
        let blocking = try await makeBlocking(rules: #"example.org#%#//scriptlet("set-constant", "lithiumProbe", "42")"#)
        #expect(blocking.script(for: URL(string: "https://example.org/page")!) != nil)
        #expect(blocking.script(for: URL(string: "https://www.example.org/")!) != nil)
        #expect(blocking.script(for: URL(string: "https://example.com/")!) == nil)
    }

    /// Made at launch, it reads nothing: the scriptlet library is read by the first load, off the
    /// main thread, and serves every load after.
    @Test func theLibraryIsReadByTheFirstLoad() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "advanced-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try #"example.org#%#//scriptlet("set-constant", "lithiumProbe", "42")"#.write(to: folder.appending(path: "advanced.txt"), atomically: true, encoding: .utf8)
        let blocking = AdvancedBlocking(container: folder.appending(path: "engine"))
        #expect(!blocking.hasReadLibrary)
        #expect(blocking.script(for: URL(string: "https://example.org/")!) == nil)

        await blocking.load(folder: folder, stamp: "one")
        #expect(blocking.hasReadLibrary)
        #expect(blocking.script(for: URL(string: "https://example.org/")!)?.contains("lithiumProbe") == true)
        await blocking.load(folder: folder, stamp: "two")
        #expect(blocking.script(for: URL(string: "https://example.org/")!)?.contains("lithiumProbe") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "engine").path).allSatisfy { $0.hasPrefix("two") })
    }

    /// An engine built by an app whose rule conversion was older isn't kept for the same filter set:
    /// it is built again with this app's conversion.
    @Test func anEngineFromAnOlderConversionIsRebuilt() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "advanced-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try #"example.org#%#//scriptlet("set-constant", "lithiumProbe", "42")"#.write(to: folder.appending(path: "advanced.txt"), atomically: true, encoding: .utf8)
        // What the older app left for this filter set: an engine without the rule.
        let version = UBOScriptlets.bundled?.version ?? "none"
        let old = folder.appending(path: "engine/one-ubo-\(version)")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)

        let blocking = AdvancedBlocking(container: folder.appending(path: "engine"))
        await blocking.load(folder: folder, stamp: "one")
        #expect(blocking.script(for: URL(string: "https://example.org/")!)?.contains("lithiumProbe") == true)
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }

    @Test func bundledListsCarryYouTubeAdScriptlets() async throws {
        let folder = try #require(Resources.bundle.url(forResource: "Filters", withExtension: nil))
        let blocking = AdvancedBlocking(container: FileManager.default.temporaryDirectory.appending(path: "engine-\(UUID())"))
        await blocking.load(folder: folder, stamp: UUID().uuidString)
        let script = try #require(blocking.script(for: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!))
        #expect(script.contains("adPlacements"))
        // uBO-only scriptlets YouTube's ads are fought with; AdGuard's library has neither.
        #expect(script.contains("function trustedJsonEditXhrRequest("))
        #expect(script.contains("function trustedPreventDomBypass("))
        // The real lists run end to end: the page loads and the player answer comes back without its ads.
        let result = try #require(try await FakeYouTube.run(Self.playerProbe, script: script))
        #expect(result.hasPrefix(#"["undefined","#) && result.contains("videoDetails"))
        #expect(!result.contains("adPlacements") && !result.contains("adSlots"))
    }

    /// The daily filter update rebuilds the engine while pages keep opening; they must neither wait for it nor lose their rules.
    @Test func pagesOpenedDuringARebuildDontWaitForIt() async throws {
        let folder = try #require(Resources.bundle.url(forResource: "Filters", withExtension: nil))
        let blocking = AdvancedBlocking(container: FileManager.default.temporaryDirectory.appending(path: "engine-\(UUID())"))
        await blocking.load(folder: folder, stamp: UUID().uuidString)
        let url = URL(string: "https://www.youtube.com/watch?v=x")!

        var rebuilt = false
        let rebuild = Task {
            await blocking.load(folder: folder, stamp: UUID().uuidString)
            rebuilt = true
        }
        var slowest = Duration.zero
        while !rebuilt {
            try await Task.sleep(for: .milliseconds(10))
            let start = ContinuousClock.now
            #expect(blocking.script(for: url)?.contains("adPlacements") == true)
            slowest = max(slowest, ContinuousClock.now - start)
        }
        await rebuild.value
        #expect(slowest < .milliseconds(250))
        #expect(blocking.script(for: url)?.contains("adPlacements") == true)
    }

    /// A load clears out engines it no longer needs, but not the build another load is still running.
    @Test func aLoadLeavesAnotherLoadsBuildAlone() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "advanced-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let container = folder.appending(path: "engine")
        let building = container.appending(path: ".building-\(UUID().uuidString)")
        let old = container.appending(path: "old-engine")
        try FileManager.default.createDirectory(at: building, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try #"example.org#%#//scriptlet("set-constant", "lithiumProbe", "42")"#.write(to: folder.appending(path: "advanced.txt"), atomically: true, encoding: .utf8)

        let blocking = AdvancedBlocking(container: container)
        await blocking.load(folder: folder, stamp: UUID().uuidString)
        #expect(blocking.script(for: URL(string: "https://example.org/")!) != nil)
        #expect(FileManager.default.fileExists(atPath: building.path))
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }

    /// Rules for an embedded site (an ad, a consent prompt) run in its frames, looked up for
    /// its own host, and never in the page or in frames of other sites.
    @Test func frameRulesRunOnlyInFramesOfTheirOwnSite() async throws {
        let blocking = try await makeBlocking(rules: """
            ads.example.net#%#//scriptlet("ubo-set-constant.js", "lithiumProbe", "42")
            ads.example.net#$#.promo { display: none !important; }
            """)
        let page = URL(string: "https://example.org/")!
        #expect(blocking.script(for: page) == nil)
        #expect(blocking.script(for: page, inFrameOf: page) == nil)
        let source = try #require(blocking.script(for: URL(string: "https://ads.example.net/frame")!, inFrameOf: page))

        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(FramedPage(), forURLScheme: "lithium-test")
        configuration.userContentController.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
        )
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let loaded = PageLoad()
        webView.navigationDelegate = loaded
        // The page itself is on the frame's host: the script still leaves it alone.
        webView.load(URLRequest(url: URL(string: "lithium-test://ads.example.net/")!))
        try await loaded.wait()

        var reports: [String] = []
        for _ in 0..<50 where reports.count < 2 {
            reports = try await webView.evaluateJavaScript("reports") as? [String] ?? []
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(reports.sorted() == [#"["ads.example.net","42","none"]"#, #"["other.example.com","undefined","block"]"#])
        let top = try await webView.evaluateJavaScript("JSON.stringify([String(window.lithiumProbe), getComputedStyle(document.querySelector('.promo')).display])") as? String
        #expect(top == #"["undefined","block"]"#)
    }

    private static let playerProbe = """
        window.ytInitialPlayerResponse = { adPlacements: [1], videoDetails: { videoId: 'x' } };
        const response = await fetch('/youtubei/v1/player?key=1');
        return JSON.stringify([String(ytInitialPlayerResponse.adPlacements), Object.keys(await response.json())]);
        """

    @Test func uboFiltersKeepUBOArgumentSyntax() throws {
        let ubo = try #require(UBOScriptlets.bundled)
        let rules = ubo.adguardRules(fromUBO: [
            #"www.youtube.com##+js(trusted-replace-fetch-response, '"adSlots"', '"no_ads"', player?)"#,
            #"www.youtube.com##+js(trusted-json-edit-xhr-request, [?.context.client.userAgent*="yahi"]+={"params":"YAHI"}, propsToMatch, /player?)"#,
            #"www.youtube.com##+js(json-prune-fetch-response, adPlacements adSlots, , propsToMatch, /player?)"#,
            #"example.com,~sub.example.com##+js(nostif, ()\,a\,b);, 5000)"#,
            #"example.com#@#+js(set, a.b, false)"#,
            #"example.com##+js(no-such-scriptlet, 1)"#,
        ])
        #expect(rules == [
            #"www.youtube.com#%#//scriptlet("ubo-trusted-replace-fetch-response", "\"adSlots\"", "\"no_ads\"", "player?")"#,
            #"www.youtube.com#%#//scriptlet("ubo-trusted-json-edit-xhr-request", "[?.context.client.userAgent*=\"yahi\"]+={\"params\":\"YAHI\"}", "propsToMatch", "/player?")"#,
            #"www.youtube.com#%#//scriptlet("ubo-json-prune-fetch-response", "adPlacements adSlots", "", "propsToMatch", "/player?")"#,
            #"example.com,~sub.example.com#%#//scriptlet("ubo-prevent-setTimeout", "(),a,b);", "5000")"#,
            #"example.com#@%#//scriptlet("ubo-set-constant", "a.b", "false")"#,
        ])
    }

    /// uBO's rules through AdGuard's index and back: arguments arrive intact, exceptions still cancel.
    @Test func uboFiltersSurviveTheEngine() async throws {
        let blocking = try await makeBlocking(uboScriptlets: #"""
            www.youtube.com##+js(trusted-json-edit-xhr-request, [?.context.client.userAgent*="yahi"]+={"params":"YAHI"}, propsToMatch, /player?)
            youtube.com##+js(set, lithiumProbe, 1)
            music.youtube.com#@#+js(set, lithiumProbe, 1)
            """#)
        let watch = try #require(blocking.script(for: URL(string: "https://www.youtube.com/watch?v=x")!))
        #expect(watch.contains(#"trustedJsonEditXhrRequest("[?.context.client.userAgent*=\"yahi\"]+={\"params\":\"YAHI\"}","propsToMatch","/player?")"#))
        #expect(watch.contains(#"setConstant("lithiumProbe","1")"#))
        #expect(blocking.script(for: URL(string: "https://music.youtube.com/")!) == nil)
    }

    /// uBO's bare `site#@#+js()` turns off every scriptlet on the site, generic ones too, and no other site's.
    @Test func aBareExceptionTurnsOffEveryScriptletOnTheSite() async throws {
        let filters = """
            youtube.com##+js(set, lithiumProbe, 1)
            ##+js(set, lithiumGeneric, 1)
            example.org##+js(set, lithiumOther, 1)
            music.youtube.com#@#+js()
            """
        let ubo = try #require(UBOScriptlets.bundled)
        let rules = ubo.adguardRules(fromUBO: filters.split(separator: "\n").map(String.init))
        #expect(rules.filter { $0.hasPrefix("music.youtube.com#@%#") }.count == 2, "\(rules)")

        let blocking = try await makeBlocking(uboScriptlets: filters)
        let watch = try #require(blocking.script(for: URL(string: "https://www.youtube.com/watch?v=x")!))
        #expect(watch.contains(#"setConstant("lithiumProbe","1")"#) && watch.contains(#"setConstant("lithiumGeneric","1")"#))
        #expect(blocking.script(for: URL(string: "https://music.youtube.com/")!) == nil)
        #expect(try #require(blocking.script(for: URL(string: "https://example.org/")!)).contains(#"setConstant("lithiumOther","1")"#))
    }

    /// What YouTube does on every in-app navigation: fetch /youtubei/v1/player, whose answer carries the ads.
    @Test func uboScriptletsStripAdsFromYouTubePlayerResponses() async throws {
        let blocking = try await makeBlocking(uboScriptlets: """
            www.youtube.com##+js(set, ytInitialPlayerResponse.adPlacements, undefined)
            www.youtube.com##+js(json-prune-fetch-response, adPlacements adSlots playerResponse.adPlacements, , propsToMatch, /player?)
            """)
        let source = try #require(blocking.script(for: URL(string: "https://www.youtube.com/watch?v=x")!))
        #expect(try await FakeYouTube.run(Self.playerProbe, script: nil) == #"["1",["adPlacements","adSlots","videoDetails"]]"#)
        #expect(try await FakeYouTube.run(Self.playerProbe, script: source) == #"["undefined",["videoDetails"]]"#)
    }

    /// The whole chain: uBO-style rules, AdGuard's engine, the injected script, a real page.
    @Test func scriptletsAndCosmeticsRunInTheRealPage() async throws {
        let blocking = try await makeBlocking(rules: """
            example.org#%#//scriptlet("ubo-set-constant.js", "lithiumProbe", "42")
            example.org#$#.promo { display: none !important; }
            example.org#?#.card:has(> .sponsored)
            """)
        let source = try #require(blocking.script(for: URL(string: "https://example.org/")!))

        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
        )
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let loaded = PageLoad()
        webView.navigationDelegate = loaded
        webView.loadHTMLString("""
            <div class="promo">promo</div>
            <div class="card" id="ad"><span class="sponsored">ad</span></div>
            <div class="card" id="content"><span>article</span></div>
            """, baseURL: URL(string: "https://example.org/")!)
        try await loaded.wait()
        try await Task.sleep(for: .milliseconds(300))

        let result = try await webView.evaluateJavaScript("""
            JSON.stringify([
              String(window.lithiumProbe),
              getComputedStyle(document.querySelector('.promo')).display,
              getComputedStyle(document.getElementById('ad')).display,
              getComputedStyle(document.getElementById('content')).display,
            ])
            """) as? String
        #expect(result == #"["42","none","none","block"]"#)
    }
}

/// Serves a page with two frames, one on its own host and one on another, under a custom scheme.
/// Each frame reports back what the script did in it.
@MainActor
private final class FramedPage: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let url = task.request.url!
        let body = url.path() == "/frame" ? """
            <!doctype html><div class="promo">frame</div>
            <script>
              addEventListener('load', () => parent.postMessage(JSON.stringify([
                location.hostname, String(window.lithiumProbe), getComputedStyle(document.querySelector('.promo')).display,
              ]), '*'));
            </script>
            """ : """
            <!doctype html><div class="promo">page</div>
            <script>window.reports = []; addEventListener('message', (event) => reports.push(event.data));</script>
            <iframe src="lithium-test://ads.example.net/frame"></iframe>
            <iframe src="lithium-test://other.example.com/frame"></iframe>
            """
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"])!)
        task.didReceive(Data(body.utf8))
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// Serves a page and a player API answer under a custom scheme, so the test needs no network.
@MainActor
private final class FakeYouTube: NSObject, WKURLSchemeHandler {
    static func run(_ probe: String, script: String?) async throws -> String? {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(FakeYouTube(), forURLScheme: "lithium-test")
        if let script {
            configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let loaded = PageLoad()
        webView.navigationDelegate = loaded
        webView.load(URLRequest(url: URL(string: "lithium-test://www.youtube.com/watch")!))
        try await loaded.wait()
        return try await webView.callAsyncJavaScript(probe, contentWorld: .page) as? String
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let url = task.request.url!
        let isPlayer = url.path().hasSuffix("/player")
        let body = isPlayer ? #"{"adPlacements":[{"ad":1}],"adSlots":[],"videoDetails":{"videoId":"x"}}"# : "<!doctype html><title>YouTube</title>"
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": isPlayer ? "application/json" : "text/html",
        ])!)
        task.didReceive(Data(body.utf8))
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

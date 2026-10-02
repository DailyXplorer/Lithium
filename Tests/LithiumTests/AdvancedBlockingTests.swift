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

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
    final class Loaded: NSObject, WKNavigationDelegate {
        var continuation: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { continuation?.resume(); continuation = nil }
    }
    let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    let loaded = Loaded()
    webView.navigationDelegate = loaded
    await withCheckedContinuation { continuation in
        loaded.continuation = continuation
        webView.load(URLRequest(url: URL(string: "https://github.com/")!))
    }
    let info = SiteInfo(url: try #require(webView.url), trust: webView.serverTrust)
    print("certificate:", info.isSecure, info.certificate as Any)
    #expect(info.isSecure)
    #expect(info.certificate?.subject == "github.com")
    #expect((info.certificate?.validUntil ?? .distantPast) > Date())
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

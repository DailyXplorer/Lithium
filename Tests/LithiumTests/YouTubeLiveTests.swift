import Foundation
import Testing
import WebKit
@testable import Lithium

/// Real YouTube, over the network: `LITHIUM_LIVE_TESTS=1 swift test --filter YouTubeLiveTests`.
/// A video opened from inside YouTube gets its ads from a /youtubei/v1/player request, which is
/// where AdGuard's look-alike scriptlets let them through.
@MainActor
struct YouTubeLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHIUM_LIVE_TESTS"] == "1"))
    func noAdsAfterInAppNavigation() async throws {
        let url = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
        let folder = try #require(Resources.bundle.url(forResource: "Filters", withExtension: nil))
        let blocking = AdvancedBlocking(container: FileManager.default.temporaryDirectory.appending(path: "live-\(UUID())"))
        await blocking.load(folder: folder, stamp: UUID().uuidString)

        let control = try await adsAfterInAppNavigation(url, script: nil)
        #expect(control.contains("adShowing\":true") || control.contains("ads\":true"), "YouTube served no ads at all, so this run proves nothing: \(control)")
        let protected = try await adsAfterInAppNavigation(url, script: try #require(blocking.script(for: url)))
        #expect(protected.hasSuffix(#""ads":false,"adShowing":false}"#), "\(protected)")
    }

    private func adsAfterInAppNavigation(_ url: URL, script: String?) async throws -> String {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        if let script {
            configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
        webView.load(URLRequest(url: url))
        try await Task.sleep(for: .seconds(10))
        _ = try await webView.callAsyncJavaScript("""
            [...document.querySelectorAll('a[href^="/watch?v="]')].find(a => !a.href.includes('dQw4w9WgXcQ'))?.click();
            """, contentWorld: .page)
        try await Task.sleep(for: .seconds(8))
        let result = try await webView.callAsyncJavaScript("""
            const response = document.getElementById('movie_player')?.getPlayerResponse?.();
            return JSON.stringify({
              video: location.search,
              ads: !!(response?.adPlacements?.length || response?.adSlots?.length),
              adShowing: !!document.querySelector('.ad-showing'),
            });
            """, contentWorld: .page) as? String
        return try #require(result)
    }
}

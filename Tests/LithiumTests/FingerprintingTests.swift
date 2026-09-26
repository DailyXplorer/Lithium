import Foundation
import Testing
import WebKit
@testable import Lithium

@MainActor
struct FingerprintingTests {
    private static let probe = """
        (() => {
          const hash = (win) => {
            const c = win.document.createElement('canvas'); c.width = 200; c.height = 40;
            const x = c.getContext('2d'); x.font = '18px Arial'; x.fillStyle = '#f60'; x.fillRect(0, 0, 200, 40);
            x.fillStyle = '#069'; x.fillText('Lithium fp', 4, 26);
            let h = 0; const d = c.toDataURL(); for (let i = 0; i < d.length; i++) h = (Math.imul(h, 31) + d.charCodeAt(i)) | 0;
            return (h >>> 0).toString(16);
          };
          const frame = document.createElement('iframe');
          document.body.appendChild(frame);
          return JSON.stringify({ page: hash(window), frame: hash(frame.contentWindow),
            native: /\\[native code\\]/.test(frame.contentWindow.HTMLCanvasElement.prototype.toDataURL.toString()) });
        })()
        """

    private func run(withFarbling: Bool) async throws -> [String: AnyHashable] {
        let configuration = WKWebViewConfiguration()
        if withFarbling {
            let url = try #require(Resources.bundle.url(forResource: "farbling", withExtension: "js"))
            let source = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "__LITHIUM_SESSION_KEY__", with: "test-key")
            configuration.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let loaded = Loaded()
        webView.navigationDelegate = loaded
        webView.loadHTMLString("<body></body>", baseURL: URL(string: "https://example.com/")!)
        await loaded.wait()
        let json = try #require(try await webView.evaluateJavaScript(Self.probe) as? String)
        return try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: AnyHashable])
    }

    @Test func freshIframeCannotHandBackUnprotectedCanvas() async throws {
        let bare = try await run(withFarbling: false)
        let protected = try await run(withFarbling: true)

        #expect(bare["page"] == bare["frame"])
        #expect(protected["page"] != bare["page"])
        #expect(protected["frame"] == protected["page"])
        #expect(protected["native"] == AnyHashable(true))
    }
}

@MainActor
private final class Loaded: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var done = false
    func wait() async { if !done { await withCheckedContinuation { continuation = $0 } } }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true; continuation?.resume() }
}

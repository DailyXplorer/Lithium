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

    /// A frame that is still navigating to its srcdoc shows a blank window WebKit injects nothing into;
    /// only the insertion hooks protect it when the page reaches it through `frames`.
    private static let srcdocProbe = """
        (() => {
          const hash = (win) => {
            const c = win.document.createElement('canvas'); c.width = 200; c.height = 40;
            const x = c.getContext('2d'); x.fillStyle = '#f60'; x.fillRect(0, 0, 200, 40);
            let h = 0; const d = c.toDataURL(); for (let i = 0; i < d.length; i++) h = (Math.imul(h, 31) + d.charCodeAt(i)) | 0;
            return (h >>> 0).toString(16);
          };
          const frame = document.createElement('iframe');
          frame.srcdoc = '<p>frame</p>';
          document.body.appendChild(frame);
          return JSON.stringify({ page: hash(window), frame: hash(frames[frames.length - 1]) });
        })()
        """

    /// A popup the page opens is a blank window of its site until its first page loads, and
    /// WebKit injects nothing into it; the opener reaches it at once.
    private static let popupProbe = """
        (() => {
          const hash = (win) => {
            const c = win.document.createElement('canvas'); c.width = 200; c.height = 40;
            const x = c.getContext('2d'); x.fillStyle = '#f60'; x.fillRect(0, 0, 200, 40);
            let h = 0; const d = c.toDataURL(); for (let i = 0; i < d.length; i++) h = (Math.imul(h, 31) + d.charCodeAt(i)) | 0;
            return (h >>> 0).toString(16);
          };
          return JSON.stringify({ page: hash(window), popup: hash(open('')) });
        })()
        """

    /// The names the script adds to a page's window: its marker.
    private static let markerProbe = "JSON.stringify(Object.getOwnPropertyNames(window).filter((name) => name.startsWith('__')))"

    private static func farbling(session: String = "test-key", mark: String = "0123456789abcdef") throws -> String {
        let url = try #require(Resources.bundle.url(forResource: "farbling", withExtension: "js"))
        return try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "__LITHIUM_SESSION_KEY__", with: session)
            .replacingOccurrences(of: "__LITHIUM_MARK_KEY__", with: mark)
    }

    private func run(withFarbling: Bool, probe: String = Self.probe) async throws -> [String: AnyHashable] {
        let source = withFarbling ? try Self.farbling() : nil
        return try await run(probe, farbling: source)
    }

    private func run<Value>(_ probe: String, farbling source: String?, at base: String = "https://example.com/") async throws -> Value {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        if let source {
            configuration.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let loaded = PageLoad()
        let popups = Popups()
        webView.navigationDelegate = loaded
        webView.uiDelegate = popups
        webView.loadHTMLString("<body></body>", baseURL: URL(string: base)!)
        try await loaded.wait()
        let json = try #require(try await webView.evaluateJavaScript(probe) as? String)
        return try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? Value)
    }

    /// Opens popups as Lithium does (`Privacy.harden`): with a content controller of their own,
    /// which has no scripts until their first page.
    @MainActor
    private final class Popups: NSObject, WKUIDelegate {
        private var opened: [WKWebView] = []

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            configuration.userContentController = WKUserContentController()
            let popup = WKWebView(frame: .zero, configuration: configuration)
            opened.append(popup)
            return popup
        }
    }

    /// The marker every protected window carries is a keyed hash of its site under a key of its
    /// own: no identifier shared across sites, and nothing that leads back to the noise's seed.
    @Test func markerDiffersFromSiteToSiteAndIsIndependentOfTheSeed() async throws {
        let bare: [String] = try await run(Self.markerProbe, farbling: nil)
        let marker = { (source: String, base: String) async throws -> [String] in
            let names: [String] = try await self.run(Self.markerProbe, farbling: source, at: base)
            return names.filter { !bare.contains($0) }
        }
        let source = try Self.farbling()
        let first = try await marker(source, "https://news.example/")
        #expect(first.count == 1)
        #expect(try await marker(source, "https://news.example/") == first)
        #expect(try await marker(source, "https://shop.example.org/") != first)
        #expect(try await marker(Self.farbling(session: "another-key"), "https://news.example/") == first)
        #expect(try await marker(Self.farbling(mark: "fedcba9876543210"), "https://news.example/") != first)
    }

    /// Private tabs farble with keys of their own, so their marker isn't a normal tab's either.
    @Test func privateTabsGetTheirOwnKeys() async throws {
        let privacy = Privacy()
        let url = URL(string: "https://news.example/")!
        let normal = try #require(privacy.scripts(true, for: url).first?.source)
        let ephemeral = try #require(privacy.scripts(true, for: url, isPrivate: true).first?.source)
        #expect(!normal.contains("__LITHIUM_") && !ephemeral.contains("__LITHIUM_"))
        #expect(normal != ephemeral)
        let normalMarker: [String] = try await run(Self.markerProbe, farbling: normal, at: url.absoluteString)
        let privateMarker: [String] = try await run(Self.markerProbe, farbling: ephemeral, at: url.absoluteString)
        #expect(normalMarker != privateMarker)
    }

    /// Built-ins the page replaced before adding a frame don't keep the frame unprotected: a
    /// `call` that always answers true once made it look protected already.
    @Test func replacedBuiltInsDontUnprotectAFrame() async throws {
        let tamper = """
            Function.prototype.call = function () { return true; };
            Object.defineProperty = function (target) { return target; };
            Object.getOwnPropertyDescriptor = function () { return undefined; };
            """
        let bare: [String: AnyHashable] = try await run(tamper + Self.probe, farbling: nil)
        let protected: [String: AnyHashable] = try await run(tamper + Self.probe, farbling: Self.farbling())

        #expect(protected["page"] != bare["page"])
        #expect(protected["frame"] == protected["page"])
    }

    @Test func popupIsProtectedBeforeItsFirstPage() async throws {
        let bare: [String: AnyHashable] = try await run(Self.popupProbe, farbling: nil)
        let protected: [String: AnyHashable] = try await run(Self.popupProbe, farbling: Self.farbling())

        #expect(bare["page"] == bare["popup"])
        #expect(protected["page"] != bare["page"])
        #expect(protected["popup"] == protected["page"])
    }

    @Test func freshIframeCannotHandBackUnprotectedCanvas() async throws {
        let bare = try await run(withFarbling: false)
        let protected = try await run(withFarbling: true)

        #expect(bare["page"] == bare["frame"])
        #expect(protected["page"] != bare["page"])
        #expect(protected["frame"] == protected["page"])
        #expect(protected["native"] == AnyHashable(true))
    }

    @Test func frameStillNavigatingToItsSrcdocIsProtected() async throws {
        let bare = try await run(withFarbling: false, probe: Self.srcdocProbe)
        let protected = try await run(withFarbling: true, probe: Self.srcdocProbe)

        #expect(bare["page"] == bare["frame"])
        #expect(protected["page"] != bare["page"])
        #expect(protected["frame"] == protected["page"])
    }
}

import Foundation
import WebKit

/// Styles Lithium adds to every page, whatever the protection settings: no horizontal page
/// scrolling, and DM Sans instead of the site's fonts (a setting, always on for Brave Search,
/// Lithium's start page and search engine).
@MainActor
enum PageStyle {
    /// Wide layouts are clipped instead of making the whole page scroll sideways.
    /// Scrollable regions inside the page (tables, code blocks, carousels) keep working.
    private static let baseCSS = "html, body { overflow-x: clip !important; }"

    private static let baseScript = script(css: baseCSS)

    /// DM Sans travels inline, since web pages cannot reach the app bundle. Every page decodes
    /// it again, so it goes as WOFF2: the same font as DMSans.ttf, compressed to about a third
    /// (`scripts/make-web-font.py`).
    private static let fontBase64 = Resources.bundle.url(forResource: "DMSans", withExtension: "woff2")
        .flatMap { try? Data(contentsOf: $0) }?.base64EncodedString() ?? ""

    /// Declares "Lithium DM Sans" for pages Lithium renders itself.
    static let fontFace = """
        @font-face { font-family: "Lithium DM Sans"; font-weight: 100 1000; font-style: normal;
          src: local("DM Sans"), url(data:font/woff2;base64,\(fontBase64)) format("woff2"); }
        """

    static let fontScript: WKUserScript = {
        let source = Resources.bundle.url(forResource: "page-font", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return WKUserScript(
            source: source.replacingOccurrences(of: "__LITHIUM_FONT__", with: fontBase64),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .defaultClient
        )
    }()

    static var usesDMSansEverywhere: Bool {
        get { UserDefaults.standard.object(forKey: Preference.websiteFont) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Preference.websiteFont) }
    }

    static func scripts(for url: URL) -> [WKUserScript] {
        usesDMSans(url) ? [baseScript, fontScript] : [baseScript]
    }

    static func usesDMSans(_ url: URL) -> Bool {
        if usesDMSansEverywhere { return true }
        guard let host = url.host()?.lowercased() else { return false }
        return host == "search.brave.com" || host.hasSuffix(".search.brave.com")
    }

    private static func script(css: String) -> WKUserScript {
        let literal = (try? String(data: JSONEncoder().encode(css), encoding: .utf8)) ?? "\"\""
        let source = """
            (() => {
              const style = document.createElement('style');
              style.textContent = \(literal);
              const attach = () => (document.head || document.documentElement).appendChild(style);
              if (document.documentElement) { attach(); return; }
              new MutationObserver((_, observer) => {
                if (document.documentElement) { observer.disconnect(); attach(); }
              }).observe(document, { childList: true });
            })();
            """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient)
    }
}

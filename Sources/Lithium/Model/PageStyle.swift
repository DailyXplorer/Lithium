import AppKit
import WebKit

/// Styles Lithium adds to every page, whatever the protection settings: no horizontal page
/// scrolling, and the user's font (DM Sans unless they picked another) instead of the site's
/// (a setting, always on for Brave Search, Lithium's start page and search engine).
@MainActor
enum PageStyle {
    /// Wide layouts are clipped instead of making the whole page scroll sideways.
    /// Scrollable regions inside the page (tables, code blocks, carousels) keep working.
    private static let baseCSS = "html, body { overflow-x: clip !important; }"

    private static let baseScript = script(css: baseCSS)

    /// DM Sans travels inline, since web pages cannot reach the app bundle. Every page decodes
    /// it again, so it goes as WOFF2: the same font as DMSans.ttf, compressed to about a third
    /// (`scripts/make-web-font.py`).
    static let fontBase64 = Resources.bundle.url(forResource: "DMSans", withExtension: "woff2")
        .flatMap { try? Data(contentsOf: $0) }?.base64EncodedString() ?? ""

    /// Declares "Lithium DM Sans" for pages Lithium renders itself.
    static let fontFace = """
        @font-face { font-family: "Lithium DM Sans"; font-weight: 100 1000; font-style: normal;
          src: local("DM Sans"), url(data:font/woff2;base64,\(fontBase64)) format("woff2"); }
        """

    private static let fontSource = Resources.bundle.url(forResource: "page-font", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""

    /// The script for the website font the user picked, built again only when that changes.
    static var fontScript: WKUserScript { currentFont().script }

    /// The family websites get, DM Sans unless the user picked another.
    static var websiteFamily: String { currentFont().family }

    /// Run in an open page, turns its font script off; running the script again turns it back on.
    static let fontOffSource = "window.__lithiumFont?.stop();"

    private static var builtFont: (choice: String?, family: String, script: WKUserScript)?
    /// Fonts installed or removed while Lithium runs (Font Book): the font is checked again at
    /// its next use, so one no longer on the Mac gives way to DM Sans. Nothing is read meanwhile.
    private static var fontSetObserver: (any NSObjectProtocol)?

    private static func currentFont() -> (family: String, script: WKUserScript) {
        let choice = FontChoice.shared.website ?? FontChoice.shared.interface
        if let builtFont, builtFont.choice == choice { return (builtFont.family, builtFont.script) }
        if fontSetObserver == nil {
            fontSetObserver = NotificationCenter.default.addObserver(forName: NSFont.fontSetChangedNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { builtFont = nil }
            }
        }
        let family = FontChoice.shared.websiteFamily
        let script = fontScript(family: family)
        builtFont = (choice, family, script)
        return (family, script)
    }

    /// DM Sans travels in the script; any other family is installed on the Mac, where pages find
    /// it by name, so they decode nothing.
    static func fontScript(family: String) -> WKUserScript {
        let isBundled = family == FontChoice.dmSans
        let source = fontSource
            .replacingOccurrences(of: "__LITHIUM_FONT__", with: isBundled ? fontBase64 : "")
            .replacingOccurrences(of: "__LITHIUM_FAMILY__", with: literal(isBundled ? "Lithium DM Sans" : family))
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient)
    }

    static var usesFontEverywhere: Bool {
        get { UserDefaults.standard.object(forKey: Preference.websiteFont) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Preference.websiteFont) }
    }

    static func scripts(for url: URL, privateSession: ObjectIdentifier? = nil) -> [WKUserScript] {
        usesPageFont(url, privateSession: privateSession) ? [baseScript, fontScript] : [baseScript]
    }

    static func usesPageFont(_ url: URL, privateSession: ObjectIdentifier? = nil) -> Bool {
        guard let host = url.host()?.lowercased() else { return usesFontEverywhere }
        return choosesPageFont(host) && !keepsSiteFont(host, privateSession: privateSession)
    }

    /// Whether the site menu offers "Use this site's font": the website font would apply but for it.
    static func offersSiteFont(_ url: URL) -> Bool {
        guard url.scheme == "http" || url.scheme == "https", let host = url.host()?.lowercased() else { return false }
        return choosesPageFont(host)
    }

    /// Sites that keep their own font, by registrable domain.
    static var siteFontDomains: [String] {
        UserDefaults.standard.stringArray(forKey: siteFontKey) ?? []
    }

    /// Pages served from this Mac are a developer's own: they keep their font, whatever the list says.
    static func isLoopback(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) || host.hasSuffix(".localhost")
    }

    /// `privateSession` is set for a private tab: its session's own choice wins, then the saved one.
    static func keepsSiteFont(_ host: String, privateSession: ObjectIdentifier? = nil) -> Bool {
        if isLoopback(host) { return true }
        let domain = SiteInfo.registrable(host)
        if let privateSession, let keeps = privateSiteFonts[privateSession]?[domain] { return keeps }
        return siteFontDomains.contains(domain)
    }

    /// A private tab's choice stays in memory for its private session only: saved, it would
    /// record the site it visited.
    static func setKeepsSiteFont(_ keeps: Bool, for host: String, privateSession: ObjectIdentifier? = nil) {
        let domain = SiteInfo.registrable(host)
        if let privateSession {
            privateSiteFonts[privateSession, default: [:]][domain] = keeps
            return
        }
        var domains = Set(siteFontDomains)
        if keeps { domains.insert(domain) } else { domains.remove(domain) }
        UserDefaults.standard.set(domains.sorted(), forKey: siteFontKey)
    }

    /// The private session's last tab closed: its choices go with its cookies.
    static func forget(privateSession: ObjectIdentifier) {
        privateSiteFonts[privateSession] = nil
    }

    private static let siteFontKey = "siteFontDomains"
    /// Site fonts chosen in private tabs, by private session, then registrable domain; never saved.
    private static var privateSiteFonts: [ObjectIdentifier: [String: Bool]] = [:]

    private static func choosesPageFont(_ host: String) -> Bool {
        usesFontEverywhere || host == "search.brave.com" || host.hasSuffix(".search.brave.com")
    }

    /// A JavaScript string literal.
    private static func literal(_ text: String) -> String {
        (try? String(data: JSONEncoder().encode(text), encoding: .utf8)) ?? "\"\""
    }

    private static func script(css: String) -> WKUserScript {
        let literal = Self.literal(css)
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

import AppKit
import WebKit

/// Styles Lithium adds to every page: no horizontal page scrolling, and the user's font instead
/// of the site's (a setting, always on for Brave Search).
@MainActor
enum PageStyle {
    /// Scrollable regions inside the page (tables, code blocks, carousels) keep working. Only at
    /// desktop widths: a fixed-width layout in a split pane, a narrow window or zoomed in would lose
    /// its right side, with no way to scroll to it (zoom narrows the width in CSS pixels).
    private static let baseCSS = "@media (min-width: 1024px) { html, body { overflow-x: clip !important; } }"

    /// Only overflow about a scrollbar wide (a `100vw` banner) is clipped: a layout wider than the
    /// view keeps its sideways scrolling, or its right side couldn't be reached. Measured with the
    /// clip off, as body's clip hides its content's width, at load and when the view is resized.
    /// Also when body's size changes while clipping: content that gets wide after load (an app's
    /// table, a dashboard) usually makes the page taller too, and html's box never gets wider. Its
    /// callbacks already come once a frame, after layout.
    private static let baseScript = script(css: baseCSS, then: """
        const wide = matchMedia('(min-width: 1024px)');
        let pending = false;
        const check = () => {
          pending = false;
          const root = document.scrollingElement, sheet = style.sheet;
          if (!wide.matches || !root || !root.clientWidth || !sheet) return;
          sheet.disabled = true;
          sheet.disabled = root.scrollWidth - root.clientWidth > 32;
        };
        addEventListener('load', () => {
          check();
          if (document.body) new ResizeObserver(() => { if (!style.sheet?.disabled) check(); }).observe(document.body);
        }, { once: true });
        addEventListener('resize', () => { if (!pending) { pending = true; requestAnimationFrame(check); } });
        """)

    /// Inline, since web pages cannot reach the app bundle; as WOFF2, about a third of the TTF,
    /// since every page decodes it again (`scripts/make-web-font.py`).
    static let fontBase64 = Resources.bundle.url(forResource: "DMSans", withExtension: "woff2")
        .flatMap { try? Data(contentsOf: $0) }?.base64EncodedString() ?? ""

    /// Declares "Lithium DM Sans" for pages Lithium renders itself.
    static let fontFace = """
        @font-face { font-family: "Lithium DM Sans"; font-weight: 100 1000; font-style: normal;
          src: local("DM Sans"), url(data:font/woff2;base64,\(fontBase64)) format("woff2"); }
        """

    private static let fontSource = Resources.bundle.url(forResource: "page-font", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""

    /// Built again only when the choice changes.
    static var fontScript: WKUserScript { currentFont().script }

    static var websiteFamily: String { currentFont().family }

    /// Turns an open page's font script off; running the script again turns it back on.
    static let fontOffSource = "window.__lithiumFont?.stop();"

    private static var builtFont: (choice: String?, family: String, script: WKUserScript)?
    /// Fonts installed or removed while Lithium runs: the font is checked again at its next use.
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

    /// DM Sans travels in the script; any other family is installed, so pages find it by name.
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

    static func scripts(for url: URL, privateSession: ObjectIdentifier? = nil, space: Space.ID? = nil) -> [WKUserScript] {
        usesPageFont(url, privateSession: privateSession, space: space) ? [baseScript, fontScript] : [baseScript]
    }

    static func usesPageFont(_ url: URL, privateSession: ObjectIdentifier? = nil, space: Space.ID? = nil) -> Bool {
        guard let host = url.host()?.lowercased() else { return usesFontEverywhere }
        return choosesPageFont(host) && !keepsSiteFont(host, privateSession: privateSession, space: space)
    }

    /// Whether the site menu offers "Use this site's font": the website font would apply but for it.
    static func offersSiteFont(_ url: URL) -> Bool {
        guard url.scheme == "http" || url.scheme == "https", let host = url.host()?.lowercased() else { return false }
        return choosesPageFont(host)
    }

    static var siteFontDomains: [String] {
        UserDefaults.standard.stringArray(forKey: siteFontKey) ?? []
    }

    /// Pages served from this Mac are a developer's own: they keep their font, whatever the list says.
    static func isLoopback(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) || host.hasSuffix(".localhost")
    }

    /// A private session's or separate space's (`Tab.siteSpace`) own choice wins, then the saved one.
    static func keepsSiteFont(_ host: String, privateSession: ObjectIdentifier? = nil, space: Space.ID? = nil) -> Bool {
        if isLoopback(host) { return true }
        let domain = SiteInfo.registrable(host)
        if let privateSession, let keeps = privateSiteFonts[privateSession]?[domain] { return keeps }
        if let space, let keeps = spaceSiteFonts[space]?[domain] { return keeps }
        return siteFontDomains.contains(domain)
    }

    /// A private tab's choice stays in memory: saved, it would record the site it visited.
    static func setKeepsSiteFont(_ keeps: Bool, for host: String, privateSession: ObjectIdentifier? = nil, space: Space.ID? = nil) {
        let domain = SiteInfo.registrable(host)
        if let privateSession {
            privateSiteFonts[privateSession, default: [:]][domain] = keeps
            return
        }
        if let space {
            var choices = spaceSiteFonts
            choices[space, default: [:]][domain] = keeps
            UserDefaults.standard.set(Space.stored(choices), forKey: spaceSiteFontKey)
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

    static func forget(space: Space.ID) {
        var choices = spaceSiteFonts
        guard choices.removeValue(forKey: space) != nil else { return }
        UserDefaults.standard.set(Space.stored(choices), forKey: spaceSiteFontKey)
    }

    private static let siteFontKey = "siteFontDomains"
    private static let spaceSiteFontKey = "spaceSiteFontDomains"
    private static var spaceSiteFonts: [Space.ID: [String: Bool]] {
        Space.siteChoices(UserDefaults.standard.dictionary(forKey: spaceSiteFontKey))
    }
    /// Never saved.
    private static var privateSiteFonts: [ObjectIdentifier: [String: Bool]] = [:]

    private static func choosesPageFont(_ host: String) -> Bool {
        usesFontEverywhere || host == "search.brave.com" || host.hasSuffix(".search.brave.com")
    }

    private static func literal(_ text: String) -> String {
        (try? String(data: JSONEncoder().encode(text), encoding: .utf8)) ?? "\"\""
    }

    /// `then` runs once the style is made, with it as `style`.
    private static func script(css: String, then: String = "") -> WKUserScript {
        let literal = Self.literal(css)
        let source = """
            (() => {
              const style = document.createElement('style');
              style.textContent = \(literal);
              const attach = () => (document.head || document.documentElement).appendChild(style);
              if (document.documentElement) {
                attach();
              } else {
                new MutationObserver((_, observer) => {
                  if (document.documentElement) { observer.disconnect(); attach(); }
                }).observe(document, { childList: true });
              }
              \(then)
            })();
            """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient)
    }
}

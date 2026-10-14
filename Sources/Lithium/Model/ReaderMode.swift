import AppKit
import WebKit

/// The reader: a page's article alone (found by Mozilla Readability, which `reader.js` carries).
/// It takes the page's place in the same web view, so find, zoom, print and translation work on it,
/// and leaving puts the page back without a reload: the page waits behind it, hidden.
/// Scripts run on demand in Lithium's own world; only leaving touches the page's (`reader-sheets.js`).
@MainActor
enum ReaderMode {
    enum PageState: String {
        case none, article, reading
    }

    /// Not Markdown, which Lithium already shows as a document.
    static func handles(_ url: URL?) -> Bool {
        guard let url, ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { return false }
        return !MarkdownReader.handles(url)
    }

    /// The address bar's button; ⇧⌘R works without it.
    static var showsButton: Bool {
        get { UserDefaults.standard.object(forKey: Preference.readerButton) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Preference.readerButton) }
    }

    static func check(_ webView: WKWebView) async -> PageState {
        let result = try? await webView.callAsyncJavaScript(checkScript, contentWorld: .defaultClient)
        return (result as? String).flatMap(PageState.init(rawValue:)) ?? .none
    }

    static func enter(_ webView: WKWebView, style: ReaderStyle) async -> Bool {
        await run("enter", style: style, css: css, font: PageStyle.fontBase64, in: webView)
    }

    /// The sheets the page added while reading move back with their elements, and get new ones too.
    static func exit(_ webView: WKWebView) async {
        _ = try? await webView.callAsyncJavaScript(sheetsScript, contentWorld: .page)
        _ = await run("exit", style: .init(), in: webView)
    }

    static func apply(_ style: ReaderStyle, to webView: WKWebView) async {
        _ = await run("style", style: style, in: webView)
    }

    private static func run(_ action: String, style: ReaderStyle, css: String = "", font: String = "", in webView: WKWebView) async -> Bool {
        let arguments: [String: Any] = ["action": action, "style": style.arguments, "css": css, "font": font]
        let result = try? await webView.callAsyncJavaScript(script, arguments: arguments, contentWorld: .defaultClient)
        return result as? Bool ?? false
    }

    private static let checkScript = source("reader-check", "js")
    private static let script = source("reader", "js")
    /// The page's sheet objects, which its scripts may keep, are the page's world's alone.
    private static let sheetsScript = source("reader-sheets", "js")
    /// DM Sans travels apart, as bytes: pages can't reach the app bundle, and a strict CSP blocks a data: font.
    private static let css = source("reader", "css")

    private static func source(_ name: String, _ fileExtension: String) -> String {
        Resources.bundle.url(forResource: name, withExtension: fileExtension)
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }
}

/// How the reader looks, one choice for every site: saved, it records no site, private tabs' included.
struct ReaderStyle: Codable, Equatable {
    enum Theme: String, Codable, CaseIterable, Identifiable {
        case auto, light, sepia, dark
        var id: Self { self }
        var label: String {
            switch self {
            case .auto: "Match system"
            case .light: "Light"
            case .sepia: "Sepia"
            case .dark: "Dark"
            }
        }
    }

    enum Font: String, Codable, CaseIterable, Identifiable {
        case sans, serif
        var id: Self { self }
        var label: String { self == .sans ? "Sans" : "Serif" }
    }

    var size = 19
    var theme = Theme.auto
    var font = Font.sans

    static let sizes = 13...31
    static let sizeStep = 2

    var arguments: [String: Any] { ["size": size, "theme": theme.rawValue, "font": font.rawValue] }

    static var saved: ReaderStyle {
        get {
            UserDefaults.standard.data(forKey: Preference.readerStyle)
                .flatMap { try? JSONDecoder().decode(ReaderStyle.self, from: $0) } ?? ReaderStyle()
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: Preference.readerStyle) }
    }
}

extension Browser {
    func toggleReader(_ tab: Tab?) {
        guard let tab, tab.canRead else { return }
        Task { if await !tab.toggleReader() { NSSound.beep() } }
    }

    func setReaderStyle(_ style: ReaderStyle) {
        ReaderStyle.saved = style
        for tab in tabs where tab.isReading {
            guard let webView = tab.loadedWebView else { continue }
            Task { await ReaderMode.apply(style, to: webView) }
        }
    }

    func setReaderButton(_ shown: Bool) {
        ReaderMode.showsButton = shown
        tabs.forEach { $0.readerButtonChanged() }
        if shown {
            for window in windows {
                window.selectedTab?.checkReader()
                window.shownPartner?.checkReader()
            }
        }
    }
}

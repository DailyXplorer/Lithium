import AppKit
import WebKit

/// The reader: a page's article alone, in a clean view the user sizes and colors. It takes the
/// page's place in the same web view (`reader.js`), so find, zoom, print, translation and summaries
/// all work on what is read, and leaving it puts the page back as it was, without a reload. Its
/// frames alone load again: detached, a frame loses its document.
/// Nothing is added to pages: the scripts run on demand, in Lithium's own content world, but for
/// the address bar's button, which asks once per page shown, and not at all once turned off. Opening
/// the reader alone touches the page's world (`reader-sheets.js`), so the sheets it holds stay live.
/// The article is found by Mozilla Readability, Firefox's reader, which `reader.js` carries: it
/// reaches a page only when the reader opens there.
@MainActor
enum ReaderMode {
    enum PageState: String {
        case none, article, reading
    }

    /// Websites and local files. Not Lithium's own pages, an extension's, nor Markdown, which
    /// Lithium already shows as a document.
    static func handles(_ url: URL?) -> Bool {
        guard let url, ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { return false }
        return !MarkdownReader.handles(url)
    }

    /// The address bar's button, on pages that look like articles. ⇧⌘R works without it.
    static var showsButton: Bool {
        get { UserDefaults.standard.object(forKey: Preference.readerButton) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Preference.readerButton) }
    }

    static func check(_ webView: WKWebView) async -> PageState {
        let result = try? await webView.callAsyncJavaScript(checkScript, contentWorld: .defaultClient)
        return (result as? String).flatMap(PageState.init(rawValue:)) ?? .none
    }

    /// False when the page has no article to show.
    static func enter(_ webView: WKWebView, style: ReaderStyle) async -> Bool {
        _ = try? await webView.callAsyncJavaScript(sheetsScript, contentWorld: .page)
        return await run("enter", style: style, css: css, font: PageStyle.fontBase64, in: webView)
    }

    static func exit(_ webView: WKWebView) async {
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
    /// DM Sans travels apart, as bytes (`reader.js`): pages can't reach the app bundle, and a strict
    /// Content-Security-Policy blocks a data: font.
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
    /// The reader for the tab in front, or the page again; a beep when it has no article to show.
    func toggleReader(_ tab: Tab?) {
        guard let tab, tab.canRead else { return }
        Task { if await !tab.toggleReader() { NSSound.beep() } }
    }

    /// Saved, and shown at once by every tab in the reader.
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
            selectedTab?.checkReader()
            shownPartner?.checkReader()
        }
    }
}

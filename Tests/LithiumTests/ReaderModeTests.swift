import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import Lithium

/// An article between the clutter around it, with things that must not reach the reader.
private enum ReaderPages {
    static let paragraphs = (1...6).map { index in
        "Paragraph \(index) of the field notes: lithium, the lightest metal, floats on oil, burns crimson, "
            + "and keeps phones, laptops and cars running, which is why its mines, brines and refineries matter so much."
    }

    static let article = """
        <!doctype html><html lang="en"><head><title>Lithium field notes | Example</title>
        <meta property="og:site_name" content="Example Times"><meta name="author" content="A. Writer">
        <style>body { font: 16px serif; }</style></head>
        <body>
        <nav><a href="/">Home page</a> <a href="/news">News desk</a></nav>
        <header><h1>Lithium field notes</h1></header>
        <main><div class="story">
        \(paragraphs.map { "<p>\($0)</p>" }.joined(separator: "\n"))
        <p>Read <a href="/more">the next part</a> or <a href="javascript:window.ran = 'link'">this one</a>, with enough words to count.</p>
        <div class="share-bar">Share this on Mastodon</div>
        <img src="x-broken:image" onerror="window.ran = 'onerror'">
        <script>window.inArticle = true;</script>
        <iframe src="about:blank"></iframe>
        <p onclick="window.ran = 'click'" id="clicky">A paragraph with a click handler that the reader should leave behind, long enough to stay.</p>
        </div></main>
        <aside>Related stories you might like</aside>
        <footer>Copyright footer</footer>
        <script>window.pageState = 42; document.querySelector('nav').dataset.live = 'yes';</script>
        </body></html>
        """

    static let short = "<!doctype html><title>Home</title><body><p>Hello.</p><a href='/a'>A</a></body>"
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ReaderModeTests {
    private func load(_ html: String, configuration: WKWebViewConfiguration = WKWebViewConfiguration()) async throws -> WKWebView {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        let loaded = PageLoad()
        webView.navigationDelegate = loaded
        webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/notes/")!)
        try await loaded.wait()
        return webView
    }

    private func value(_ script: String, in webView: WKWebView) async throws -> String? {
        try await webView.evaluateJavaScript(script) as? String
    }

    @Test func tellsArticlesFromOtherPages() async throws {
        #expect(await ReaderMode.check(try await load(ReaderPages.article)) == .article)
        #expect(await ReaderMode.check(try await load(ReaderPages.short)) == .none)
    }

    @Test func showsTheArticleAlone() async throws {
        let webView = try await load(ReaderPages.article)
        #expect(await ReaderMode.enter(webView, style: ReaderStyle()))
        #expect(await ReaderMode.check(webView) == .reading)
        #expect(try await value("document.querySelector('article header h1').textContent", in: webView) == "Lithium field notes")
        #expect(try await value("document.querySelector('.site').textContent", in: webView) == "Example Times · 1 min read")
        #expect(try await value("document.querySelector('.byline').textContent", in: webView) == "A. Writer")
        let text = try #require(try await value("document.body.innerText", in: webView))
        #expect(text.contains("Paragraph 1 of the field notes") && text.contains("Paragraph 6"))
        for clutter in ["Home page", "Share this on", "Related stories", "Copyright footer"] {
            #expect(!text.contains(clutter), "\(clutter)")
        }
        // The tab, the history and extensions keep the page's own title.
        #expect(try await value("document.title", in: webView) == "Lithium field notes | Example")
        #expect(try await value("document.querySelector('a').href", in: webView) == "https://example.com/more")
    }

    @Test func carriesNoScriptsOrHandlers() async throws {
        let webView = try await load(ReaderPages.article)
        // The page's own broken image already ran its handler.
        _ = try await webView.evaluateJavaScript("delete window.ran; 0")
        #expect(await ReaderMode.enter(webView, style: ReaderStyle()))
        #expect(try await value("String(document.querySelectorAll('script, iframe, img, body style, link').length)", in: webView) == "0")
        #expect(try await value("String([...document.querySelectorAll('*')].some((e) => [...e.attributes].some((a) => a.name.startsWith('on'))))", in: webView) == "false")
        #expect(try await value("String(document.querySelectorAll('a[href^=javascript]').length)", in: webView) == "0")
        _ = try await webView.evaluateJavaScript("document.querySelectorAll('a:not([href]), p').forEach((e) => e.click()); 0")
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await value("String(window.ran)", in: webView) == "undefined")
        #expect(webView.url?.absoluteString == "https://example.com/notes/")
    }

    @Test func leavesThePageAsItWas() async throws {
        let webView = try await load(ReaderPages.article)
        let before = try await value("String(document.querySelectorAll('*').length)", in: webView)
        #expect(await ReaderMode.enter(webView, style: ReaderStyle()))
        await ReaderMode.exit(webView)
        #expect(await ReaderMode.check(webView) == .article)
        // The same live document, not a reload: what the page's scripts set is still there.
        #expect(try await value("document.querySelector('nav').dataset.live", in: webView) == "yes")
        #expect(try await value("String(window.pageState)", in: webView) == "42")
        #expect(try await value("String(document.querySelectorAll('*').length)", in: webView) == before)
        #expect(try await value("String(document.styleSheets.length)", in: webView) == "1")
    }

    @Test func leavesPagesWithoutAnArticleAlone() async throws {
        let webView = try await load(ReaderPages.short)
        #expect(await !ReaderMode.enter(webView, style: ReaderStyle()))
        #expect(await ReaderMode.check(webView) == .none)
        #expect(try await value("document.body.innerText", in: webView)?.contains("Hello.") == true)
    }

    @Test func appliesTheStyle() async throws {
        let webView = try await load(ReaderPages.article)
        #expect(await ReaderMode.enter(webView, style: ReaderStyle(size: 23, theme: .sepia, font: .serif)))
        #expect(try await value("document.documentElement.dataset.theme", in: webView) == "sepia")
        #expect(try await value("document.documentElement.dataset.font", in: webView) == "serif")
        #expect(try await value("getComputedStyle(document.querySelector('article')).fontSize", in: webView) == "23px")
        await ReaderMode.apply(ReaderStyle(size: 15, theme: .dark, font: .sans), to: webView)
        #expect(try await value("document.documentElement.dataset.theme", in: webView) == "dark")
        #expect(try await value("getComputedStyle(document.querySelector('article')).fontSize", in: webView) == "15px")
    }

    /// With DM Sans on websites (the default), the page's font script leaves the reader's font
    /// alone, and gives the page DM Sans again once the reader is left.
    @Test func keepsItsFontWithDMSansOnWebsites() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(PageStyle.fontScript)
        let webView = try await load(ReaderPages.article, configuration: configuration)
        let font = "getComputedStyle(document.querySelector('p')).fontFamily.split(',')[0].replace(/\"/g, '').trim()"
        try await Task.sleep(for: .milliseconds(400))
        #expect(try await value(font, in: webView) == "Lithium DM Sans")
        #expect(await ReaderMode.enter(webView, style: ReaderStyle(font: .serif)))
        try await Task.sleep(for: .milliseconds(400))
        #expect(try await value(font, in: webView) == "ui-serif")
        await ReaderMode.exit(webView)
        try await Task.sleep(for: .milliseconds(400))
        #expect(try await value(font, in: webView) == "Lithium DM Sans")
    }

    @Test func savesOneStyleForEverySite() {
        let saved = UserDefaults.standard.data(forKey: Preference.readerStyle)
        defer { UserDefaults.standard.set(saved, forKey: Preference.readerStyle) }
        ReaderStyle.saved = ReaderStyle(size: 25, theme: .dark, font: .serif)
        #expect(ReaderStyle.saved == ReaderStyle(size: 25, theme: .dark, font: .serif))
        UserDefaults.standard.removeObject(forKey: Preference.readerStyle)
        #expect(ReaderStyle.saved == ReaderStyle())
    }

    @Test func handlesWebPagesAndFilesOnly() {
        #expect(ReaderMode.handles(URL(string: "https://example.com/a")))
        #expect(ReaderMode.handles(URL(filePath: "/tmp/page.html")))
        #expect(!ReaderMode.handles(URL(filePath: "/tmp/notes.md")))
        #expect(!ReaderMode.handles(URL(string: "lithium://settings")))
        #expect(!ReaderMode.handles(nil))
    }

    /// Summaries read what the reader shows: the article, without what sat in it.
    @Test func summariesReadTheArticle() async throws {
        let webView = try await load(ReaderPages.article)
        #expect(await PageReader.read(webView)?.text.contains("Share this on") == true)
        #expect(await ReaderMode.enter(webView, style: ReaderStyle()))
        let content = try #require(await PageReader.read(webView))
        #expect(content.title == "Lithium field notes | Example")
        #expect(content.text.contains("Paragraph 3 of the field notes"))
        #expect(!content.text.contains("Share this on"))
    }

    /// The context menu's Translate still learns the selection in the reader.
    @Test func translationStillHearsTheMenu() async throws {
        let configuration = WKWebViewConfiguration()
        let menu = MenuMessages()
        configuration.userContentController.addUserScript(PageTranslation.script)
        configuration.userContentController.add(menu, contentWorld: .defaultClient, name: PageTranslation.name)
        let webView = try await load(ReaderPages.article, configuration: configuration)
        #expect(await ReaderMode.enter(webView, style: ReaderStyle()))
        _ = try await webView.evaluateJavaScript("""
            getSelection().selectAllChildren(document.querySelector('article header h1'));
            document.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true })); 0
            """)
        for _ in 0..<30 where menu.texts.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        #expect(menu.texts == ["Lithium field notes"])
    }
}

@MainActor
private final class MenuMessages: NSObject, WKScriptMessageHandler {
    var texts: [String] = []

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let text = message.body as? String { texts.append(text) }
    }
}

/// A tab's reader: the button, the shortcut's toggle, Esc and leaving the page. A whole Browser
/// keeps its data in the home folder, so this suite only runs in a throwaway one (`scripts/test`).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct ReaderTabTests {
    private func pages() throws -> (article: URL, other: URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let article = folder.appending(path: "article.html"), other = folder.appending(path: "other.html")
        try ReaderPages.article.write(to: article, atomically: true, encoding: .utf8)
        try ReaderPages.short.write(to: other, atomically: true, encoding: .utf8)
        return (article, other)
    }

    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private func inReader(_ tab: Lithium.Tab) async -> Bool {
        (try? await tab.webView.evaluateJavaScript("String(document.querySelectorAll('article header h1').length)") as? String) == "1"
    }

    @Test func offersTheReaderOnArticlesAndLeavesItWithTheirPage() async throws {
        let (article, other) = try pages()
        let browser = Browser()
        browser.newTab(url: article)
        let tab = try #require(browser.selectedTab)
        #expect(await waitUntil(10) { tab.isReaderAvailable })
        #expect(!tab.isReading)

        #expect(await tab.toggleReader())
        #expect(tab.isReading)
        #expect(await inReader(tab))
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                   characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        tab.webView.keyDown(with: escape)
        #expect(await waitUntil(5) { !tab.isReading })
        try await Task.sleep(for: .milliseconds(200))
        #expect(await !inReader(tab))
        #expect(tab.isReaderAvailable)

        #expect(await tab.toggleReader())
        let commits = tab.commits
        tab.load(other)
        #expect(!tab.isReading)
        #expect(await waitUntil(10) { tab.commits > commits && !tab.isLoading })
        try await Task.sleep(for: .milliseconds(300))
        #expect(!tab.isReaderAvailable)
        #expect(!tab.isReading)
        #expect(await !tab.toggleReader())
    }

    /// A page that moves on by itself (pushState) is asked again for its new address.
    @Test func asksAgainWhenThePageMovesOnByItself() async throws {
        let (article, _) = try pages()
        let browser = Browser()
        browser.newTab(url: article)
        let tab = try #require(browser.selectedTab)
        #expect(await waitUntil(10) { tab.isReaderAvailable })
        let commits = tab.commits
        _ = try await tab.webView.evaluateJavaScript("""
            window.article = document.body.innerHTML;
            history.pushState(null, '', '?page=index');
            document.body.innerHTML = '<p>Hello.</p>'; 0
            """)
        #expect(await waitUntil(3) { !tab.isReaderAvailable })
        try await Task.sleep(for: .milliseconds(1500))
        #expect(!tab.isReaderAvailable)
        _ = try await tab.webView.evaluateJavaScript("""
            history.pushState(null, '', '?page=article');
            document.body.innerHTML = window.article; 0
            """)
        #expect(await waitUntil(5) { tab.isReaderAvailable })
        #expect(tab.commits == commits)
    }

    /// Turned off, the button asks pages nothing; the shortcut still opens the reader.
    @Test func buttonTurnedOffAsksNothing() async throws {
        let (article, _) = try pages()
        let browser = Browser()
        browser.setReaderButton(false)
        defer { browser.setReaderButton(true) }
        browser.newTab(url: article)
        let tab = try #require(browser.selectedTab)
        #expect(await waitUntil(10) { tab.commits > 0 && !tab.isLoading })
        try await Task.sleep(for: .milliseconds(300))
        #expect(!tab.isReaderAvailable)

        #expect(await tab.toggleReader())
        #expect(tab.isReading)
        #expect(await tab.toggleReader())
        #expect(!tab.isReading)
        #expect(!tab.isReaderAvailable)
        browser.setReaderButton(true)
        #expect(await waitUntil(5) { tab.isReaderAvailable })
    }
}

/// `LITHIUM_SNAPSHOT_DIR=/tmp/shots ./scripts/test --filter ReaderSnapshotTests`.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["LITHIUM_SNAPSHOT_DIR"] != nil, "Writes PNGs only when LITHIUM_SNAPSHOT_DIR is set"))
struct ReaderSnapshotTests {
    private let directory = URL(filePath: ProcessInfo.processInfo.environment["LITHIUM_SNAPSHOT_DIR"] ?? "/tmp")

    @Test func buttonAndStyleSnapshots() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Theme.registerFonts()
        for isDark in [false, true] {
            let palette = SidebarPalette(style: .solid, colorHex: Theme.defaultSidebarHex, scheme: isDark ? .dark : .light)
            let name = isDark ? "dark" : "light"
            for isReading in [false, true] {
                let bar = HStack(spacing: 4) {
                    Icon(.lock, size: 15).opacity(0.6).frame(width: 22, height: 22)
                    Text("example.com").frame(maxWidth: .infinity)
                    if isReading { ReaderButtonLabel(icon: .readerStyle, isOn: false) }
                    ReaderButtonLabel(icon: .reader, isOn: isReading)
                }
                .font(Theme.font(13))
                .padding(.leading, 4)
                .padding(.trailing, 10)
                .frame(width: 420, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.field))
                .padding(12)
                .environment(\.sidebarPalette, palette)
                try render(bar, isDark: isDark).write(to: directory.appending(path: "reader-button-\(isReading ? "on" : "off")-\(name).png"))
            }
            let style = ReaderStyleView(style: .constant(ReaderStyle(size: 19, theme: .sepia, font: .serif)))
                .environment(\.sidebarPalette, palette)
            try render(style, isDark: isDark).write(to: directory.appending(path: "reader-style-\(name).png"))
        }
    }

    @Test func pageSnapshots() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let window = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        defer { window.contentView = nil }
        let loaded = PageLoad()
        webView.navigationDelegate = loaded
        webView.loadHTMLString(ReaderPages.article, baseURL: URL(string: "https://example.com/notes/")!)
        try await loaded.wait()
        #expect(await ReaderMode.enter(webView, style: ReaderStyle()))
        for (name, theme, isDark) in [("light", ReaderStyle.Theme.auto, false), ("dark", .auto, true), ("sepia", .sepia, false)] {
            window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
            await ReaderMode.apply(ReaderStyle(theme: theme), to: webView)
            try await Task.sleep(for: .milliseconds(400))
            let image = try await webView.takeSnapshot(configuration: nil)
            let png = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]))
            try png.write(to: directory.appending(path: "reader-page-\(name).png"))
        }
    }

    /// Through an off-screen window, so AppKit controls such as the segmented picker draw as in the app.
    private func render(_ view: some View, isDark: Bool) throws -> Data {
        let hosting = NSHostingView(rootView: view.background(isDark ? Color(white: 0.17) : Color(white: 0.97)))
        hosting.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let window = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: hosting.frame.width, height: hosting.frame.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        defer { window.contentView = nil }
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        bitmap.size = hosting.bounds.size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}

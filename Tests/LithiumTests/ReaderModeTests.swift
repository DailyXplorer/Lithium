import AppKit
import Foundation
import Network
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

    /// No inline style nor data: font, as on GitHub and Google's sites: a <style> element or an
    /// @font-face the reader added would be blocked.
    static let strictPolicy = "Content-Type: text/html; charset=utf-8\r\nContent-Security-Policy: style-src 'self'; font-src 'self'"

    /// Google's kind: nonces for its own scripts and styles, Trusted Types, fonts from its host alone.
    static let googlePolicy = "Content-Type: text/html; charset=utf-8\r\nContent-Security-Policy: default-src 'self'; "
        + "script-src 'nonce-corpus' 'strict-dynamic' 'unsafe-eval'; style-src 'nonce-corpus'; font-src https://fonts.gstatic.com; "
        + "img-src 'self' data:; object-src 'none'; base-uri 'self'; require-trusted-types-for 'script'"

    /// GitHub's: inline styles allowed, but nothing from anywhere but its own hosts, fonts included.
    static let githubPolicy = "Content-Type: text/html; charset=utf-8\r\nContent-Security-Policy: default-src 'none'; base-uri 'self'; "
        + "font-src github.githubassets.com; img-src 'self' data: github.githubassets.com; script-src github.githubassets.com; "
        + "style-src 'unsafe-inline' github.githubassets.com"

    static func fixture(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "html"))
        return try String(contentsOf: url, encoding: .utf8)
    }
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

    private func fixture(_ name: String) throws -> String {
        try ReaderPages.fixture(name)
    }

    /// A synthetic page with a structure that cut real articles short: every paragraph, numbered
    /// "Paragraph 01" on, reaches the reader, and none of what sat around them does.
    @discardableResult
    private func expectWholeArticle(_ name: String, paragraphs: Int, without clutter: [String]) async throws -> WKWebView {
        let webView = try await load(try fixture(name))
        #expect(await ReaderMode.check(webView) == .article)
        #expect(await ReaderMode.enter(webView, style: ReaderStyle()))
        let text = try #require(try await value("document.body.innerText", in: webView))
        for index in 1...paragraphs {
            #expect(text.contains(String(format: "Paragraph %02d", index)), "paragraph \(index) of \(name)")
        }
        for leftover in clutter {
            #expect(!text.contains(leftover), "\(leftover) in \(name)")
        }
        return webView
    }

    @Test func tellsArticlesFromOtherPages() async throws {
        #expect(await ReaderMode.check(try await load(ReaderPages.article)) == .article)
        #expect(await ReaderMode.check(try await load(ReaderPages.short)) == .none)
    }

    /// The check waits for the page to be idle before it reads the page: the button costs a page
    /// nothing while it is busy, whether or not the reader is ever opened.
    @Test func checksOnceThePageIsIdle() async throws {
        let webView = try await load(ReaderPages.article)
        // The check's world asks for an idle moment; this one says when it was asked, and holds it back.
        _ = try await webView.callAsyncJavaScript("""
            window.idleAsked = false;
            window.requestIdleCallback = (callback) => { window.idleAsked = true; window.giveIdle = callback; };
            """, contentWorld: .defaultClient)
        let check = Task { await ReaderMode.check(webView) }
        var asked = false
        for _ in 0..<50 where !asked {
            asked = try await webView.callAsyncJavaScript("return idleAsked", contentWorld: .defaultClient) as? Bool == true
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(asked)
        _ = try await webView.callAsyncJavaScript("giveIdle()", contentWorld: .defaultClient)
        #expect(await check.value == .article)
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

    /// `reader-page-styles`, under a strict policy, with its linked sheets fetched again each time.
    private func loadStyledPage() async throws -> (WKWebView, NWListener) {
        let policy = "Content-Type: text/html; charset=utf-8\r\nContent-Security-Policy: default-src 'self'; "
            + "script-src 'nonce-fixture'; style-src 'self' 'nonce-fixture'; font-src 'self'"
        let css = "Content-Type: text/css\r\nCache-Control: no-store"
        let (listener, base) = try await LocalHTTP.serve([
            "/": (policy, try fixture("reader-page-styles")),
            "/page.css": (css, "@import url(/imported.css); .from-link { color: rgb(17, 18, 19); }"),
            "/imported.css": (css, ".from-import { color: rgb(24, 25, 26); }"),
            "/theme.css": (css, ".from-theme-link { color: rgb(21, 22, 23); }"),
        ])
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let loaded = PageLoad()
        webView.navigationDelegate = loaded
        webView.load(URLRequest(url: base))
        try await loaded.wait()
        return (webView, listener)
    }

    /// Each swatch's look, in the document and in the shadow root, once the linked sheets are back.
    private func swatches(in webView: WKWebView) async throws -> [String: String] {
        let result = try await webView.callAsyncJavaScript("""
            await Promise.all([...document.querySelectorAll('link')].map((link) => link.sheet ? null : new Promise((done) => {
              link.addEventListener('load', done, { once: true });
              link.addEventListener('error', done, { once: true });
            })));
            // A web view out of a window draws no frames: a moment instead.
            await new Promise((later) => setTimeout(later, 50));
            const shadow = document.getElementById('host').shadowRoot;
            const elements = [...document.querySelectorAll('.swatches span'), ...shadow.querySelectorAll('p')];
            return Object.fromEntries(elements.map((element) => {
              const style = getComputedStyle(element);
              return [element.className, [style.color, style.backgroundColor, style.fontFamily].join(' / ')];
            }));
            """, contentWorld: .page)
        return result as? [String: String] ?? [:]
    }

    /// Linked, imported and inline sheets, rules the page's scripts added, sheets it turned off,
    /// adopted sheets on the document and in a shadow root, its FontFace font and its root's theme
    /// class all come back: every element looks as it did.
    @Test func givesThePageBackItsStyles() async throws {
        let (webView, listener) = try await loadStyledPage()
        defer { listener.cancel() }
        let before = try await swatches(in: webView)
        #expect(before["from-js"]?.hasPrefix("rgb(1, 2, 3)") == true)
        #expect(before["from-link-js"]?.hasPrefix("rgb(27, 28, 29)") == true)
        #expect(before["from-import"]?.hasPrefix("rgb(24, 25, 26)") == true)
        #expect(before["themed"]?.contains("rgb(40, 50, 60)") == true)
        #expect(before["inner-js"]?.hasPrefix("rgb(11, 12, 13)") == true)
        #expect(before["switched-off"]?.hasPrefix("rgb(255, 0, 0)") == false)
        #expect(before["from-theme-link"]?.hasPrefix("rgb(21, 22, 23)") == false)
        let fixtureFace = "String([...document.fonts].some((face) => face.family.replace(/\"/g, '') === 'Fixture Face'))"
        #expect(try await value(fixtureFace, in: webView) == "true")

        #expect(await ReaderMode.enter(webView, style: ReaderStyle()))
        #expect(try await value("String(document.styleSheets.length)", in: webView) == "0")
        await ReaderMode.exit(webView)
        #expect(try await swatches(in: webView) == before)
        // The page's FontFace font stays; the reader's DM Sans joins it, as the page font script's does.
        #expect(try await value(fixtureFace, in: webView) == "true")
        #expect(try await value("document.documentElement.className + ' ' + document.documentElement.dataset.mode", in: webView) == "theme-night compact")
        #expect(try await value("String(document.adoptedStyleSheets.length)", in: webView) == "1")
        // And again: what came back is the page's own, kept for the next time.
        #expect(await ReaderMode.enter(webView, style: ReaderStyle()))
        await ReaderMode.exit(webView)
        #expect(try await swatches(in: webView) == before)
    }

    /// The page's scripts run on in the reader, and write to its document: a class on the root,
    /// a style in the head, an adopted sheet, a rule in the sheet they keep, a dialog in the body,
    /// a new title. All of it reaches the page when the reader is left.
    @Test func keepsWhatThePageWroteWhileReading() async throws {
        let (webView, listener) = try await loadStyledPage()
        defer { listener.cancel() }
        let before = try await swatches(in: webView)
        #expect(await ReaderMode.enter(webView, style: ReaderStyle()))
        _ = try await webView.evaluateJavaScript("""
            document.documentElement.classList.add('fonts-loaded');
            document.body.dataset.ready = 'yes';
            const late = document.createElement('style');
            late.nonce = 'fixture';
            late.textContent = '.late-style { color: rgb(31, 32, 33); }';
            document.head.append(late);
            const lateSheet = new CSSStyleSheet();
            lateSheet.replaceSync('.late-adopted { color: rgb(34, 35, 36); }');
            document.adoptedStyleSheets = [...document.adoptedStyleSheets, lateSheet];
            cssInJs.insertRule('.late-js { color: rgb(37, 38, 39); }', cssInJs.cssRules.length);
            const portal = document.createElement('div');
            portal.id = 'portal';
            document.body.append(portal);
            document.title = 'Styles that come back (1)'; 0
            """)
        await ReaderMode.exit(webView)
        let after = try await swatches(in: webView)
        #expect(after["late-class"]?.hasPrefix("rgb(70, 80, 90)") == true)
        #expect(after["late-style"]?.hasPrefix("rgb(31, 32, 33)") == true)
        #expect(after["late-adopted"]?.hasPrefix("rgb(34, 35, 36)") == true)
        #expect(after["late-js"]?.hasPrefix("rgb(37, 38, 39)") == true)
        let late: Set = ["late-class", "late-style", "late-adopted", "late-js"]
        #expect(after.filter { !late.contains($0.key) } == before.filter { !late.contains($0.key) })
        #expect(try await value("document.documentElement.className", in: webView) == "theme-night fonts-loaded")
        #expect(try await value("document.body.dataset.ready", in: webView) == "yes")
        #expect(try await value("String(document.body.lastElementChild.id)", in: webView) == "portal")
        #expect(try await value("document.title", in: webView) == "Styles that come back (1)")
        // The page's sheet and the one it added; the reader's left with it.
        #expect(try await value("String(document.adoptedStyleSheets.length)", in: webView) == "2")
    }

    /// A CSS-in-JS library that writes text (goober, Emotion and styled-components out of
    /// production) adds to its <style> while the reader is open: the page keeps all of it.
    @Test func keepsTextThePageAddedToItsStyles() async throws {
        let (webView, listener) = try await loadStyledPage()
        defer { listener.cancel() }
        _ = try await webView.evaluateJavaScript("window.textStyle = document.querySelector('style'); 0")
        #expect(await ReaderMode.enter(webView, style: ReaderStyle()))
        _ = try await webView.evaluateJavaScript("textStyle.append('.late-text { color: rgb(41, 42, 43); }'); 0")
        await ReaderMode.exit(webView)
        let after = try await swatches(in: webView)
        #expect(after["late-text"]?.hasPrefix("rgb(41, 42, 43)") == true)
        #expect(after["from-style"]?.hasPrefix("rgb(10, 20, 30)") == true)
    }

    /// A CSS-in-JS library keeps the sheet it was given (styled-components does, for good): what
    /// it writes there once the reader is left, or while it is open a second time, styles the page.
    @Test func keepsStylingThroughTheSheetThePageHolds() async throws {
        let (webView, listener) = try await loadStyledPage()
        defer { listener.cancel() }
        #expect(await ReaderMode.enter(webView, style: ReaderStyle()))
        await ReaderMode.exit(webView)
        _ = try await webView.evaluateJavaScript("cssInJs.insertRule('.after-exit { color: rgb(44, 45, 46); }', cssInJs.cssRules.length); 0")
        #expect(try await swatches(in: webView)["after-exit"]?.hasPrefix("rgb(44, 45, 46)") == true)
        #expect(await ReaderMode.enter(webView, style: ReaderStyle()))
        _ = try await webView.evaluateJavaScript("cssInJs.insertRule('.late-js { color: rgb(37, 38, 39); }', cssInJs.cssRules.length); 0")
        await ReaderMode.exit(webView)
        let after = try await swatches(in: webView)
        #expect(after["from-js"]?.hasPrefix("rgb(1, 2, 3)") == true)
        #expect(after["after-exit"]?.hasPrefix("rgb(44, 45, 46)") == true)
        #expect(after["late-js"]?.hasPrefix("rgb(37, 38, 39)") == true)
    }

    /// Each paragraph in its own section, custom element and div, as on some company blogs.
    @Test func keepsParagraphsSplitAcrossSections() async throws {
        try await expectWholeArticle("reader-split-sections", paragraphs: 9, without: ["Listen to article", "Products", "Related stories", "Copyright footer"])
    }

    /// A story cut into wrapped chunks by ads, photos, a pull quote, a sign-up box and links to
    /// other stories, with an offer the page keeps hidden.
    @Test func keepsStoriesCutByFiguresAndAsides() async throws {
        try await expectWholeArticle("reader-figures-asides", paragraphs: 8, without: [
            "Front page", "Advertisement", "Read more", "Get the morning briefing", "Subscribe now", "Copyright footer", "Most read",
        ])
    }

    /// A long read in chapters, each wrapped twice, none holding most of the text.
    @Test func keepsLongReadsInChapters() async throws {
        let webView = try await expectWholeArticle("reader-long-sections", paragraphs: 8, without: ["Issues"])
        #expect(try await value("[...document.querySelectorAll('article h2')].map((h) => h.textContent).join('|')", in: webView)
            == "I. A stone that burned red|II. Grease, glass and mood|III. The bomb and the battery|IV. The rush")
    }

    /// Text broken by blank lines instead of paragraphs, in an old table layout: the button
    /// offers the reader there too.
    @Test func readsTextBrokenByBlankLines() async throws {
        try await expectWholeArticle("reader-line-breaks", paragraphs: 4, without: [])
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

    /// Served with a Content-Security-Policy that blocks inline styles and data: fonts, the page
    /// still gets the reader's look: its column, size, DM Sans, and tables scrolling inside it.
    @Test func stylesPagesUnderAStrictPolicy() async throws {
        let (listener, base) = try await LocalHTTP.serve(["/": (ReaderPages.strictPolicy, try fixture("reader-carousel"))])
        defer { listener.cancel() }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let loaded = PageLoad()
        webView.navigationDelegate = loaded
        webView.load(URLRequest(url: base))
        try await loaded.wait()
        // The policy bites: the page's own inline style (17px) is blocked.
        #expect(try await value("getComputedStyle(document.body).fontSize", in: webView) == "16px")
        _ = try await webView.evaluateJavaScript("""
            const pageSheet = new CSSStyleSheet();
            pageSheet.replaceSync('.page-sheet {}');
            document.adoptedStyleSheets = [pageSheet]; 0
            """)

        #expect(await ReaderMode.enter(webView, style: ReaderStyle()))
        let article = "getComputedStyle(document.querySelector('article'))"
        #expect(try await value("\(article).fontSize", in: webView) == "19px")
        #expect(try await value("\(article).maxWidth", in: webView) != "none")
        #expect(try await value("\(article).fontFamily.split(',')[0].replace(/\"/g, '')", in: webView) == "Lithium DM Sans")
        let fontLoaded = try await webView.callAsyncJavaScript("""
            await document.fonts.ready;
            return [...document.fonts].some((face) => face.family.replace(/"/g, '') === 'Lithium DM Sans' && face.status === 'loaded');
            """, contentWorld: .page)
        #expect(fontLoaded as? Bool == true)
        #expect(try await value("""
            (() => {
              const table = document.querySelector('table'), article = document.querySelector('article');
              const right = article.getBoundingClientRect().right - parseFloat(getComputedStyle(article).paddingRight);
              return String(table.getBoundingClientRect().right <= right + 0.5 && table.scrollWidth > table.clientWidth);
            })()
            """, in: webView) == "true")

        await ReaderMode.apply(ReaderStyle(size: 23, theme: .dark, font: .sans), to: webView)
        #expect(try await value("\(article).fontSize", in: webView) == "23px")
        // The reader's sheet leaves with it, and the page's own comes back.
        await ReaderMode.exit(webView)
        #expect(try await value("document.adoptedStyleSheets.map((sheet) => sheet.cssRules[0].selectorText).join()", in: webView) == ".page-sheet")
    }

    /// Carousels with their "Slide 1 of 3" labels, tabs, a screen reader's label and a lone
    /// counter stay out; counts within the text stay in.
    @Test func leavesCarouselsAndLabelsOut() async throws {
        let webView = try await expectWholeArticle("reader-carousel", paragraphs: 6, without: [
            "Slide 1 of 3", "coating line, where", "Cylindrical cells", "Opens a glossary", "4 of 12",
        ])
        let text = try #require(try await value("document.body.innerText", in: webView))
        #expect(text.contains("1/2 part binder to 3 of 4 parts"))
        #expect(text.contains("Step 2 of 3") && text.contains("learn more about the plant"))
        #expect(text.contains("the formation hall find out more"))
    }

    /// A product's landing page isn't offered the reader, while an article whose page calls itself
    /// a website still is; forced, the landing page's reader leaves the carousel out.
    @Test func offersNoReaderOnLandingPages() async throws {
        let webView = try await load(try fixture("reader-landing-page"))
        #expect(await ReaderMode.check(webView) == .none)
        #expect(await ReaderMode.enter(webView, style: ReaderStyle()))
        let text = try #require(try await value("document.body.innerText", in: webView))
        #expect(text.contains("It thinks through problems") && text.contains("Our most capable model yet"))
        #expect(!text.contains("Slide 1 of") && !text.contains("See what it can build") && !text.contains("Learn more"))

        let website = ReaderPages.article.replacingOccurrences(of: "<title>", with: "<meta property=\"og:type\" content=\"website\"><title>")
        #expect(await ReaderMode.check(try await load(website)) == .article)
    }

    /// Pages modeled on the reported one and on other strict-policy sites, each served with its
    /// site's kind of policy: the button comes on the articles alone, and the reader, even forced,
    /// is styled in its loaded font and has no slide labels nor "Learn more" links, even beside another.
    @Test(arguments: [
        ("reader-corpus-deepmind", ReaderPages.googlePolicy, "none", "It thinks through hard problems"),
        ("reader-corpus-github", ReaderPages.githubPolicy, "article", "Paragraph 05: contributions are welcome"),
        ("reader-corpus-google-blog", ReaderPages.googlePolicy, "article", "Paragraph 05: everything the lab learns"),
    ])
    func readsStrictPolicySites(name: String, policy: String, state: String, kept: String) async throws {
        let (listener, base) = try await LocalHTTP.serve(["/": (policy, try fixture(name))])
        defer { listener.cancel() }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let loaded = PageLoad()
        webView.navigationDelegate = loaded
        webView.load(URLRequest(url: base))
        try await loaded.wait()
        #expect(await ReaderMode.check(webView).rawValue == state, "\(name)")
        #expect(await ReaderMode.enter(webView, style: ReaderStyle()), "\(name)")
        let article = "getComputedStyle(document.querySelector('article'))"
        #expect(try await value("\(article).fontSize", in: webView) == "19px", "\(name)")
        #expect(try await value("\(article).maxWidth", in: webView) != "none", "\(name)")
        #expect(try await value("\(article).fontFamily.split(',')[0].replace(/\"/g, '')", in: webView) == "Lithium DM Sans", "\(name)")
        let fontLoaded = try await webView.callAsyncJavaScript("""
            await document.fonts.ready;
            return [...document.fonts].some((face) => face.family.replace(/"/g, '') === 'Lithium DM Sans' && face.status === 'loaded');
            """, contentWorld: .page)
        #expect(fontLoaded as? Bool == true, "\(name)")
        let text = try #require(try await value("document.body.innerText", in: webView))
        #expect(text.contains(kept), "\(name)")
        #expect(text.range(of: #"Slide \d+ of \d+"#, options: .regularExpression) == nil, "\(name)")
        #expect(!text.contains("Learn more"), "\(name)")
    }

    /// Documentation whose page calls itself something else (GitHub says "object"), its paragraphs
    /// under one heading cut by code: none of them is a card's blurb, so the button is offered.
    @Test func offersTheReaderOnDocsCutByCode() async throws {
        let sentence = "This guide explains how the build cache works, when it is safe to share between machines, and what to clear when a build goes wrong after an upgrade. "
        let blocks = (1...4).map { "<p>\(String(repeating: sentence, count: 3))</p><pre>swift build --cache-path .cache/\($0)</pre>" }
        let page = """
            <!doctype html><html><head><meta property="og:type" content="object"><title>Build cache</title></head><body>
            <main><h1>Build cache</h1><h2>Usage</h2>\(blocks.joined())</main></body></html>
            """
        #expect(await ReaderMode.check(try await load(page)) == .article)
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

    /// An article with a carousel and a wide table, served with a strict Content-Security-Policy.
    @Test func strictPolicyPageSnapshots() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (listener, base) = try await LocalHTTP.serve(["/": (ReaderPages.strictPolicy, try ReaderPages.fixture("reader-carousel"))])
        defer { listener.cancel() }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 1100))
        let window = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: 900, height: 1100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        defer { window.contentView = nil }
        let loaded = PageLoad()
        webView.navigationDelegate = loaded
        webView.load(URLRequest(url: base))
        try await loaded.wait()
        #expect(await ReaderMode.enter(webView, style: ReaderStyle()))
        for (name, isDark) in [("light", false), ("dark", true)] {
            window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
            try await Task.sleep(for: .milliseconds(400))
            let image = try await webView.takeSnapshot(configuration: nil)
            let png = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]))
            try png.write(to: directory.appending(path: "reader-strict-policy-\(name).png"))
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

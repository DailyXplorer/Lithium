import AppKit
import Network
import Testing
@preconcurrency import Translation
import WebKit
@testable import Lithium

struct TranslationTargetTests {
    @Test func chosenLanguageWins() {
        let target = PageTranslation.target(for: "The weather is lovely today, let's go for a walk.", chosen: "fr", preferred: ["en-US", "fr-US"], supported: [])
        #expect(target?.languageCode == "fr")
    }

    @Test func textAlreadyInTheChosenLanguageGoesToTheNextOne() {
        let target = PageTranslation.target(for: "Il fait très beau aujourd'hui, allons nous promener.", chosen: "fr", preferred: ["en-US", "fr-US"], supported: [])
        #expect(target?.languageCode == "en")
    }

    @Test func languagesTranslationLacksAreSkipped() {
        let supported = ["en", "en-GB", "fr", "es"].map(Locale.Language.init(identifier:))
        let target = PageTranslation.target(for: "The weather is lovely today, let's go for a walk.", chosen: "sv", preferred: ["en-US", "fr-US"], supported: supported)
        #expect(target?.languageCode == "fr")
    }

    @Test func noLanguageLeftKeepsWebKitsTranslate() {
        let supported = ["en", "en-GB", "fr", "es"].map(Locale.Language.init(identifier:))
        #expect(PageTranslation.target(for: "The weather is lovely today, let's go for a walk.", chosen: nil, preferred: ["cs-CZ"], supported: supported) == nil)
        #expect(PageTranslation.target(for: "Il fait très beau aujourd'hui, allons nous promener.", chosen: nil, preferred: ["fr-FR"], supported: supported) == nil)
    }

    @Test func withoutAChoiceThePreferredLanguagesDecide() {
        #expect(PageTranslation.target(for: "The weather is lovely today, let's go for a walk.", chosen: nil, preferred: ["en-US", "fr-US"], supported: [])?.languageCode == "fr")
        #expect(PageTranslation.target(for: "Hace muy buen tiempo hoy, vamos a pasear.", chosen: nil, preferred: ["en-US", "fr-US"], supported: [])?.languageCode == "en")
    }
}

/// The script in a real WebKit page, with a synthetic right-click.
@MainActor
@Suite(.serialized)
struct PageTranslationMenuTests {
    private static let page = """
        <p id="text">The weather is lovely today, let's go for a walk.</p>
        <textarea id="field">The weather is lovely today.</textarea>
        """

    private func loadedPage() async throws -> (PageWebView, PageTranslation, NSWindow) {
        let translation = PageTranslation(summaries: PageSummaries())
        let configuration = WKWebViewConfiguration()
        translation.install(on: configuration)
        configuration.userContentController.addUserScript(PageTranslation.script)
        let webView = PageWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        webView.translation = translation
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderFrontRegardless()
        let loaded = PageLoad()
        webView.navigationDelegate = loaded
        webView.loadHTMLString(Self.page, baseURL: URL(string: "https://example.com/")!)
        try await loaded.wait()
        return (webView, translation, window)
    }

    /// Selects as the page script says, then right-clicks, and opens a menu holding WebKit's Translate.
    private func rightClick(_ select: String, in webView: PageWebView) async throws -> NSMenuItem {
        _ = try await webView.callAsyncJavaScript(
            select + "; document.getElementById('text').dispatchEvent(new MouseEvent('contextmenu', { bubbles: true }));",
            contentWorld: .page
        )
        // The script's message arrives before WebKit's menu, as it does after a real right-click.
        _ = try await webView.callAsyncJavaScript("return 1", contentWorld: .page)
        let item = NSMenuItem(title: "Translate", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierTranslate")
        let menu = NSMenu()
        menu.addItem(item)
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: NSPoint(x: 20, y: 580), modifierFlags: [], timestamp: 0,
            windowNumber: webView.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        webView.willOpenMenu(menu, with: event)
        return item
    }

    @Test func selectedTextGetsLithiumsTranslate() async throws {
        let (webView, translation, window) = try await loadedPage()
        defer { window.orderOut(nil) }
        let item = try await rightClick("getSelection().selectAllChildren(document.getElementById('text'))", in: webView)
        #expect(item.target === translation)
        #expect(webView.menuSelection.isEmpty, "used by one menu only")
    }

    @Test func textFieldsKeepWebKitsTranslate() async throws {
        let (webView, _, window) = try await loadedPage()
        defer { window.orderOut(nil) }
        let item = try await rightClick("const field = document.getElementById('field'); field.focus(); field.select()", in: webView)
        #expect(item.target == nil)
        #expect(item.action == #selector(NSText.copy(_:)))
    }

    /// A selection too long to copy to the app before the menu shows keeps WebKit's Translate.
    @Test func veryLongSelectionsKeepWebKitsTranslate() async throws {
        let (webView, _, window) = try await loadedPage()
        defer { window.orderOut(nil) }
        let item = try await rightClick("""
            const text = document.getElementById('text');
            text.textContent = 'The weather is lovely today. '.repeat(\(PageTranslation.maximumLength / 20));
            getSelection().selectAllChildren(text)
            """, in: webView)
        #expect(item.target == nil)
        #expect(item.action == #selector(NSText.copy(_:)))
    }

    @Test func pagesCantReachTheHandler() async throws {
        let (webView, _, window) = try await loadedPage()
        defer { window.orderOut(nil) }
        let reachable = try await webView.callAsyncJavaScript("return typeof window.webkit?.messageHandlers?.lithiumTranslate", contentWorld: .page) as? String
        #expect(reachable == "undefined")
    }
}

struct PageLanguageTests {
    @Test func readsTheTextBeforeTheDeclaredLanguage() {
        #expect(PageTranslator.language(of: "Le lithium flotte sur l’huile et brûle d’une flamme rouge.", declared: "en")?.languageCode == "fr")
        #expect(PageTranslator.language(of: "OK", declared: "de-DE")?.languageCode == "de", "too little text to tell")
        #expect(PageTranslator.language(of: "", declared: " ") == nil)
    }

    @Test func offersOnlyPagesInNoneOfTheUsersLanguages() {
        let french = Locale.Language(identifier: "fr")
        #expect(PageTranslator.offer(from: french, chosen: nil, preferred: ["en-US"], supported: [])?.languageCode == "en")
        #expect(PageTranslator.offer(from: french, chosen: nil, preferred: ["en-US", "fr-FR"], supported: []) == nil)
        #expect(PageTranslator.offer(from: french, chosen: "fr", preferred: ["en-US"], supported: []) == nil, "the summary language is the user's too")
        #expect(PageTranslator.offer(from: french, chosen: "es", preferred: ["en-US"], supported: [])?.languageCode == "es")
        let supported = ["en", "fr", "es"].map(Locale.Language.init(identifier:))
        #expect(PageTranslator.offer(from: Locale.Language(identifier: "cy"), chosen: nil, preferred: ["en-US"], supported: supported) == nil,
                "a language Translation can't read")
    }
}

/// Stands in for Apple's Translation: "EN(text)", so what was translated, and what wasn't, shows.
@MainActor
final class StandInTranslation: TranslationEngine {
    var availability = LanguageAvailability.Status.installed
    var refusesDownload = false
    /// The download waits for `finishDownload()`, as macOS's prompt waits for the user.
    var holdsDownload = false
    private var download: CheckedContinuation<Void, Never>?
    private(set) var calls: [(texts: [String], preparing: Bool)] = []

    func status(from source: Locale.Language, to target: Locale.Language) async -> LanguageAvailability.Status { availability }

    func finishDownload() {
        download?.resume()
        download = nil
    }

    func translate(_ texts: [String], from source: Locale.Language, to target: Locale.Language, preparing: Bool) async throws -> [String?] {
        calls.append((texts, preparing))
        if preparing, holdsDownload { await withCheckedContinuation { download = $0 } }
        if preparing, refusesDownload { throw CancellationError() }
        return texts.map { "EN(\($0))" }
    }
}

/// Whole pages, in a tab of a real browser, translated by the stand-in.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct PageTranslatorTests {
    private let engine = StandInTranslation()

    private func makeBrowser() -> Browser {
        for key in [PageTranslator.offerKey, PageTranslator.languagesKey, PageTranslator.sitesKey] { UserDefaults.standard.removeObject(forKey: key) }
        let browser = Browser()
        browser.translator.engine = engine
        browser.translator.preferredLanguages = { ["en-US"] }
        return browser
    }

    private func serve() async throws -> (NWListener, URL) {
        let french = try fixture("translate-fr"), english = try fixture("translate-en")
        let html = "Content-Type: text/html; charset=utf-8"
        return try await LocalHTTP.serve(["/fr": (html, french), "/fr2": (html, french.replacingOccurrences(of: "Le lithium, le plus", with: "Le sodium, presque le plus")),
                                          "/fr-low": (html, french.replacingOccurrences(of: "<article>", with: "<div style=\"height: 6000px\"></div><article>")),
                                          "/en": (html, english)])
    }

    private func fixture(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "html"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// In a window far off screen: the page draws, so what is in view can be told from what isn't.
    private func open(_ url: URL, in browser: Browser, privateStore: WKWebsiteDataStore? = nil) async throws -> (Lithium.Tab, NSWindow) {
        let tab = browser.newTab(url: url, privateStore: privateStore)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.webView
        window.orderFrontRegardless()
        #expect(await waitUntil(10) { tab.commits > 0 && !tab.isLoading })
        return (tab, window)
    }

    private func close(_ tab: Lithium.Tab, _ window: NSWindow, in browser: Browser) {
        window.orderOut(nil)
        window.contentView = nil
        browser.close(tab, remembering: false)
    }

    private func waitUntil(_ seconds: Double, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await condition()
    }

    private func page(_ script: String, in tab: Lithium.Tab, world: WKContentWorld = .page) async -> String? {
        try? await tab.webView.callAsyncJavaScript(script, contentWorld: world) as? String
    }

    private func text(_ id: String, in tab: Lithium.Tab) async -> String? {
        await page("return document.getElementById('\(id)').textContent", in: tab)
    }

    @Test func translatesWhatIsInViewAndRestoresThePageExactly() async throws {
        let browser = makeBrowser()
        let (listener, server) = try await serve()
        defer { listener.cancel() }
        let (tab, window) = try await open(server.appending(path: "fr"), in: browser)
        defer { close(tab, window, in: browser) }
        #expect(await waitUntil(10) { tab.pageTranslation != nil })
        #expect(tab.pageTranslation?.source.languageCode == "fr")
        #expect(tab.pageTranslation?.target.languageCode == "en")
        #expect(tab.pageTranslation?.status == .offered)
        #expect(browser.commandWindow.barActions(for: tab).contains(.translatePage))
        // Offered from the one-shot check alone: no handler, script or observer yet.
        #expect(await page("return typeof webkit.messageHandlers.lithiumPageTranslate + ' ' + typeof window.__lithiumPageTranslation", in: tab, world: .defaultClient)
                == "undefined undefined")
        let before = await page("return document.body.innerHTML", in: tab)

        await browser.translator.translate(tab)
        #expect(tab.pageTranslation?.status == .translated)
        #expect(await text("title", in: tab) == "EN(Le lithium, le plus léger des métaux)")
        #expect(await page("return document.getElementById('intro').firstChild.data", in: tab) == "EN(Le lithium flotte sur l’huile et brûle d’une flamme rouge.) ")
        #expect(await text("bold", in: tab) == "EN(Il fait tourner)")
        #expect(await page("return document.getElementById('photo').alt", in: tab) == "EN(Une mine de lithium au Chili)")
        #expect(await page("return document.getElementById('tip').title", in: tab) == "EN(Une note utile)")
        #expect(await page("return document.getElementById('field').placeholder", in: tab) == "EN(Votre adresse e-mail)")
        // Code, fields, what the user types and what the page marks keep their text.
        #expect(await page("return document.getElementById('field').value", in: tab) == "Bonjour tout le monde")
        #expect(await page("return document.getElementById('notes').value", in: tab) == "Mes notes restent en français.")
        #expect(await text("code", in: tab) == "const texte = \"Ne pas traduire\";")
        #expect(await text("inline", in: tab) == "bonjour()")
        #expect(await text("kept", in: tab) == "Ce nom de marque reste tel quel.")
        #expect(await text("kept-class", in: tab) == "Cette phrase reste aussi.")
        #expect(await text("editor", in: tab) == "Je tape ici mon brouillon.")
        // Far below the window: translated once it scrolls into view.
        #expect(await text("far", in: tab) == "Ce paragraphe attend tout en bas de la page.")
        _ = await page("scrollTo(0, document.body.scrollHeight); return ''", in: tab)
        #expect(await waitUntil(5) { await text("far", in: tab) == "EN(Ce paragraphe attend tout en bas de la page.)" })
        #expect(browser.commandWindow.barActions(for: tab).contains(.showOriginal))

        browser.translator.showOriginal(tab)
        #expect(tab.pageTranslation?.status == .offered)
        #expect(await waitUntil(5) { await page("return document.body.innerHTML", in: tab) == before })
        #expect(await page("return typeof window.__lithiumPageTranslation", in: tab, world: .defaultClient) == "undefined")
    }

    /// Content added later (a feed, a web app) is translated while the page is, and only then.
    @Test func translatesWhatThePageAddsWhileTranslated() async throws {
        let browser = makeBrowser()
        let (listener, server) = try await serve()
        defer { listener.cancel() }
        let (tab, window) = try await open(server.appending(path: "fr"), in: browser)
        defer { close(tab, window, in: browser) }
        #expect(await waitUntil(10) { tab.pageTranslation != nil })
        await browser.translator.translate(tab)
        _ = await page("""
            document.querySelector('article').insertAdjacentHTML('afterbegin', '<p id="late">Un paragraphe arrivé plus tard.</p><p id="late-kept" translate="no">Un nom propre.</p>');
            document.getElementById('title').firstChild.data = 'Un nouveau titre pour la page';
            return ''
            """, in: tab)
        #expect(await waitUntil(5) { await text("late", in: tab) == "EN(Un paragraphe arrivé plus tard.)" })
        #expect(await waitUntil(5) { await text("title", in: tab) == "EN(Un nouveau titre pour la page)" })
        #expect(await text("late-kept", in: tab) == "Un nom propre.")

        browser.translator.showOriginal(tab)
        #expect(await waitUntil(5) { await text("late", in: tab) == "Un paragraphe arrivé plus tard." })
        #expect(await text("title", in: tab) == "Un nouveau titre pour la page", "the page's own latest text")
        let calls = engine.calls.count
        _ = await page("document.querySelector('article').insertAdjacentHTML('afterbegin', '<p id=\"after\">Encore un paragraphe.</p>'); return ''", in: tab)
        try await Task.sleep(for: .milliseconds(800))
        #expect(await text("after", in: tab) == "Encore un paragraphe.")
        #expect(engine.calls.count == calls, "no observer once shown in the original")
    }

    /// What a single-page site takes away is let go while translated, not kept until Show Original;
    /// put back, it is translated again.
    @Test func letsGoOfWhatThePageRemoves() async throws {
        let browser = makeBrowser()
        let (listener, server) = try await serve()
        defer { listener.cancel() }
        let (tab, window) = try await open(server.appending(path: "fr"), in: browser)
        defer { close(tab, window, in: browser) }
        #expect(await waitUntil(10) { tab.pageTranslation != nil })
        await browser.translator.translate(tab)
        let held = "return String(window.__lithiumPageTranslation.held())"
        #expect(await page(held, in: tab, world: .defaultClient) != "0")

        // The paragraph far below still waits to come into view when it goes.
        _ = await page("window.far = document.getElementById('far'); document.body.replaceChildren(); return ''", in: tab)
        #expect(await waitUntil(5) { await page(held, in: tab, world: .defaultClient) == "0" })
        _ = await page("document.body.append(window.far); return ''", in: tab)
        #expect(await waitUntil(5) { await text("far", in: tab) == "EN(Ce paragraphe attend tout en bas de la page.)" })
    }

    /// Taken out and put back after it was let go (a tab panel, a view a web app reuses), translated
    /// content isn't sent again and Show Original still restores its text and attributes.
    @Test func showOriginalRestoresWhatThePagePutsBack() async throws {
        let browser = makeBrowser()
        let (listener, server) = try await serve()
        defer { listener.cancel() }
        let (tab, window) = try await open(server.appending(path: "fr"), in: browser)
        defer { close(tab, window, in: browser) }
        #expect(await waitUntil(10) { tab.pageTranslation != nil })
        let before = await page("return document.body.innerHTML", in: tab)
        await browser.translator.translate(tab)
        #expect(await text("title", in: tab) == "EN(Le lithium, le plus léger des métaux)")
        let held = "return String(window.__lithiumPageTranslation.held())"
        let translated = await page(held, in: tab, world: .defaultClient)

        _ = await page("window.view = document.querySelector('article'); window.spot = view.nextSibling; view.remove(); return ''", in: tab)
        #expect(await waitUntil(5) { await page(held, in: tab, world: .defaultClient) != translated })
        let calls = engine.calls.count
        _ = await page("document.body.insertBefore(view, spot); return ''", in: tab)
        try await Task.sleep(for: .milliseconds(800))
        #expect(engine.calls.count == calls, "already translated: not sent again")
        #expect(await text("title", in: tab) == "EN(Le lithium, le plus léger des métaux)")
        #expect(await page("return document.getElementById('tip').title", in: tab) == "EN(Une note utile)")

        browser.translator.showOriginal(tab)
        #expect(await waitUntil(5) { await page("return document.body.innerHTML", in: tab) == before })
    }

    @Test func alwaysAndNeverChoices() async throws {
        let browser = makeBrowser()
        let translator = browser.translator
        let (listener, server) = try await serve()
        defer { listener.cancel() }
        let french = Locale.Language(identifier: "fr")

        let (english, englishWindow) = try await open(server.appending(path: "en"), in: browser)
        try await Task.sleep(for: .seconds(1))
        #expect(english.pageTranslation == nil, "a page in the user's language")
        close(english, englishWindow, in: browser)

        translator.setAlwaysTranslates(true, french, privateSession: nil)
        #expect(translator.alwaysLanguages == ["fr"])
        let (always, alwaysWindow) = try await open(server.appending(path: "fr"), in: browser)
        #expect(await waitUntil(10) { always.pageTranslation?.status == .translated })
        #expect(await text("title", in: always) == "EN(Le lithium, le plus léger des métaux)")
        close(always, alwaysWindow, in: browser)
        translator.setAlwaysTranslates(false, french, privateSession: nil)

        let site = try #require(PageTranslator.site(of: server))
        translator.setNeverTranslates(true, site: site, privateSession: nil)
        #expect(translator.neverSites == [site])
        let (never, neverWindow) = try await open(server.appending(path: "fr"), in: browser)
        defer { close(never, neverWindow, in: browser) }
        try await Task.sleep(for: .seconds(1))
        #expect(never.pageTranslation == nil)
        // Translate Page from a menu still translates it.
        await translator.translatePage(never)
        #expect(never.pageTranslation?.status == .translated)
        translator.setNeverTranslates(false, site: site, privateSession: nil)
        #expect(translator.neverSites.isEmpty)
    }

    /// "Never translate this site" puts away the offer already showing on it.
    @Test func neverTranslatingASiteHidesItsOffer() async throws {
        let browser = makeBrowser()
        let (listener, server) = try await serve()
        defer { listener.cancel() }
        let (tab, window) = try await open(server.appending(path: "fr"), in: browser)
        defer { close(tab, window, in: browser) }
        #expect(await waitUntil(10) { tab.pageTranslation != nil })
        #expect(TranslateButton.isShown(for: tab))
        let site = try #require(PageTranslator.site(of: server))
        browser.translator.setNeverTranslates(true, site: site, privateSession: nil)
        defer { browser.translator.setNeverTranslates(false, site: site, privateSession: nil) }
        #expect(!TranslateButton.isShown(for: tab))
    }

    /// Like Chrome: once translated, the tab's next pages in that language are too, until Show Original.
    @Test func keepsTranslatingTheTabsNextPages() async throws {
        let browser = makeBrowser()
        let (listener, server) = try await serve()
        defer { listener.cancel() }
        let (tab, window) = try await open(server.appending(path: "fr"), in: browser)
        defer { close(tab, window, in: browser) }
        #expect(await waitUntil(10) { tab.pageTranslation != nil })
        await browser.translator.translate(tab)

        tab.load(server.appending(path: "fr2"))
        #expect(await waitUntil(10) { await text("title", in: tab) == "EN(Le sodium, presque le plus léger des métaux)" })
        #expect(tab.pageTranslation?.status == .translated)

        browser.translator.showOriginal(tab)
        let commits = tab.commits
        tab.load(server.appending(path: "fr"))
        #expect(await waitUntil(10) { tab.commits > commits && tab.pageTranslation != nil })
        try await Task.sleep(for: .milliseconds(500))
        #expect(tab.pageTranslation?.status == .offered)
        #expect(await text("title", in: tab) == "Le lithium, le plus léger des métaux")
    }

    /// With the offer off, no page is read until the user asks.
    @Test func offerOffChecksNoPage() async throws {
        let browser = makeBrowser()
        browser.translator.setOffers(false)
        defer { browser.translator.setOffers(true) }
        let (listener, server) = try await serve()
        defer { listener.cancel() }
        let (tab, window) = try await open(server.appending(path: "fr"), in: browser)
        defer { close(tab, window, in: browser) }
        try await Task.sleep(for: .milliseconds(1500))
        #expect(tab.pageTranslation == nil)
        #expect(!tab.languageChecked)

        await browser.translator.translatePage(tab)
        #expect(tab.pageTranslation?.status == .translated)
        #expect(await text("title", in: tab) == "EN(Le lithium, le plus léger des métaux)")
    }

    /// With two windows, each window's session translates only its own tabs' texts; a closed
    /// window's texts go to a window still shown.
    @Test func eachWindowsSessionServesItsOwnTabs() async throws {
        let browser = makeBrowser()
        let translator = browser.translator
        translator.engine = nil
        let first = browser.windows[0], second = browser.openWindow()
        let french = Locale.Language(identifier: "fr"), english = Locale.Language(identifier: "en")
        let firstTexts = Task { try await translator.engineTranslate(["un"], from: french, to: english, preparing: false, window: first.id) }
        let secondTexts = Task { try await translator.engineTranslate(["deux"], from: french, to: english, preparing: false, window: second.id) }
        #expect(await waitUntil(5) { translator.configuration != nil })
        await Task.yield()

        var served: [String] = []
        let session = { (texts: [String], _: Bool) in
            served += texts
            return texts.map { "EN(\($0))" as String? }
        }
        await translator.serve(in: second.id, with: session)
        #expect(served == ["deux"], "the other window's texts wait for its own session")
        #expect(try await secondTexts.value == ["EN(deux)"])

        browser.windowWillClose(first)
        await translator.serve(in: second.id, with: session)
        #expect(served == ["deux", "un"])
        #expect(try await firstTexts.value == ["EN(un)"])
    }

    /// A language not on this Mac yet is downloaded first (macOS's prompt), and said so; refused, the page stays as it was.
    @Test func downloadsTheLanguageFirst() async throws {
        let browser = makeBrowser()
        engine.availability = .supported
        let (listener, server) = try await serve()
        defer { listener.cancel() }
        let (tab, window) = try await open(server.appending(path: "fr"), in: browser)
        defer { close(tab, window, in: browser) }
        #expect(await waitUntil(10) { tab.pageTranslation != nil })
        await browser.translator.translate(tab)
        #expect(tab.pageTranslation?.status == .translated)
        #expect(engine.calls.first?.preparing == true)
        #expect(engine.calls.dropFirst().allSatisfy { !$0.preparing })

        browser.translator.showOriginal(tab)
        #expect(await waitUntil(5) { await text("title", in: tab) == "Le lithium, le plus léger des métaux" })
        engine.refusesDownload = true
        await browser.translator.translate(tab)
        guard case .failed(let message) = tab.pageTranslation?.status else {
            Issue.record("not failed: \(String(describing: tab.pageTranslation?.status))")
            return
        }
        #expect(message.contains("French"))
        #expect(await waitUntil(5) { await text("title", in: tab) == "Le lithium, le plus léger des métaux" })
    }

    /// A download that outlasts the script's wait says so until it's done, then the page is translated.
    @Test func saysDownloadingUntilTheLanguageArrives() async throws {
        let browser = makeBrowser()
        engine.availability = .supported
        engine.holdsDownload = true
        let (listener, server) = try await serve()
        defer { listener.cancel() }
        let (tab, window) = try await open(server.appending(path: "fr"), in: browser)
        defer { close(tab, window, in: browser) }
        #expect(await waitUntil(10) { tab.pageTranslation != nil })
        await browser.translator.translate(tab)
        #expect(tab.pageTranslation?.status == .downloading)

        engine.finishDownload()
        #expect(await waitUntil(5) { tab.pageTranslation?.status == .translated })
        #expect(await text("title", in: tab) == "EN(Le lithium, le plus léger des métaux)")
    }

    /// Nothing in view to send yet: no download is under way, so the page doesn't say there is.
    @Test func saysDownloadingOnlyWhileALanguageDownloads() async throws {
        let browser = makeBrowser()
        engine.availability = .supported
        engine.holdsDownload = true
        let (listener, server) = try await serve()
        defer { listener.cancel() }
        let (tab, window) = try await open(server.appending(path: "fr-low"), in: browser)
        defer { close(tab, window, in: browser) }
        #expect(await waitUntil(10) { tab.pageTranslation != nil })
        await browser.translator.translate(tab)
        #expect(engine.calls.isEmpty)
        #expect(tab.pageTranslation?.status == .translated)

        engine.holdsDownload = false
        _ = await page("document.getElementById('title').scrollIntoView(); return ''", in: tab)
        #expect(await waitUntil(5) { await text("title", in: tab) == "EN(Le lithium, le plus léger des métaux)" })
        #expect(tab.pageTranslation?.status == .translated)
    }

    /// Back to a translated page from WebKit's cache: it went in with its own text, and is translated again.
    @Test func pagesBackFromTheCacheAreTranslatedAgain() async throws {
        let browser = makeBrowser()
        let (listener, server) = try await serve()
        defer { listener.cancel() }
        let (tab, window) = try await open(server.appending(path: "fr"), in: browser)
        defer { close(tab, window, in: browser) }
        #expect(await waitUntil(10) { tab.pageTranslation != nil })
        await browser.translator.translate(tab)
        _ = await page("window.stayed = 'cached'; return ''", in: tab)
        let calls = engine.calls.count

        var commits = tab.commits
        tab.load(server.appending(path: "en"))
        #expect(await waitUntil(10) { tab.commits > commits && !tab.isLoading })
        commits = tab.commits
        tab.goBack()
        #expect(await waitUntil(10) { tab.commits > commits && !tab.isLoading })
        #expect(await page("return window.stayed", in: tab) == "cached", "back from the cache, not loaded again")
        #expect(await waitUntil(10) { engine.calls.count > calls && tab.pageTranslation?.status == .translated })
        #expect(await text("title", in: tab) == "EN(Le lithium, le plus léger des métaux)")

        browser.translator.showOriginal(tab)
        #expect(await waitUntil(5) { await text("title", in: tab) == "Le lithium, le plus léger des métaux" })
    }

    /// Text the page adds that reads like one of our translations is the page's own, and stays.
    @Test func showOriginalKeepsThePagesOwnTextThatMatchesATranslation() async throws {
        let browser = makeBrowser()
        let (listener, server) = try await serve()
        defer { listener.cancel() }
        let (tab, window) = try await open(server.appending(path: "fr"), in: browser)
        defer { close(tab, window, in: browser) }
        #expect(await waitUntil(10) { tab.pageTranslation != nil })
        await browser.translator.translate(tab)
        #expect(await text("title", in: tab) == "EN(Le lithium, le plus léger des métaux)")
        _ = await page("""
            document.querySelector('article').insertAdjacentHTML('afterbegin', '<p id="echo" title="EN(Une note utile)">EN(Le lithium, le plus léger des métaux)</p>');
            return ''
            """, in: tab)
        #expect(await waitUntil(5) { await text("echo", in: tab) == "EN(EN(Le lithium, le plus léger des métaux))" })

        browser.translator.showOriginal(tab)
        #expect(await waitUntil(5) { await text("title", in: tab) == "Le lithium, le plus léger des métaux" })
        #expect(await text("echo", in: tab) == "EN(Le lithium, le plus léger des métaux)")
        #expect(await page("return document.getElementById('echo').title", in: tab) == "EN(Une note utile)")
    }

    /// The reader shows the page's translated text, and its original after Show Original.
    @Test func translatesTheReader() async throws {
        let browser = makeBrowser()
        let (listener, server) = try await serve()
        defer { listener.cancel() }
        let (tab, window) = try await open(server.appending(path: "fr"), in: browser)
        defer { close(tab, window, in: browser) }
        #expect(await waitUntil(10) { tab.pageTranslation != nil })
        await browser.translator.translate(tab)
        #expect(await tab.toggleReader())
        let reader = "return document.body.innerText"
        #expect(await waitUntil(5) { await page(reader, in: tab)?.contains("EN(Dans les déserts du Chili") == true })

        browser.translator.showOriginal(tab)
        #expect(await waitUntil(5) { await page(reader, in: tab)?.contains("Dans les déserts du Chili, l’eau salée") == true })
        let leftover = "const text = document.body.innerText; const at = text.indexOf('EN('); return at < 0 ? '' : text.slice(at, at + 80)"
        let left = await page(leftover, in: tab)
        #expect(left == "")
        #expect(await tab.toggleReader())
        #expect(await waitUntil(5) { await text("title", in: tab) == "Le lithium, le plus léger des métaux" })
    }

    /// A private tab's choices stay in memory, and go with its session.
    @Test func privateTabsRememberNothing() async throws {
        let browser = makeBrowser()
        let translator = browser.translator
        let secret = browser.newTab(url: URL(string: "https://example.com/")!, privateStore: .nonPersistent())
        let session = try #require(secret.privateSession)
        let french = Locale.Language(identifier: "fr")
        translator.setAlwaysTranslates(true, french, privateSession: session)
        translator.setNeverTranslates(true, site: "example.com", privateSession: session)
        #expect(translator.alwaysTranslates(french, privateSession: session))
        #expect(translator.neverTranslates(URL(string: "https://www.example.com/")!, privateSession: session))
        #expect(translator.alwaysLanguages.isEmpty)
        #expect(translator.neverSites.isEmpty)
        #expect(!translator.alwaysTranslates(french, privateSession: nil))

        browser.close(secret, remembering: false)
        #expect(!translator.alwaysTranslates(french, privateSession: session))
        #expect(!translator.neverTranslates(URL(string: "https://example.com/")!, privateSession: session))
    }
}

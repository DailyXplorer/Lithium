import AppKit
import Testing
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

    @Test func pagesCantReachTheHandler() async throws {
        let (webView, _, window) = try await loadedPage()
        defer { window.orderOut(nil) }
        let reachable = try await webView.callAsyncJavaScript("return typeof window.webkit?.messageHandlers?.lithiumTranslate", contentWorld: .page) as? String
        #expect(reachable == "undefined")
    }
}

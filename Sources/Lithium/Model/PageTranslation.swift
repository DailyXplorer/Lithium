import AppKit
import NaturalLanguage
import SwiftUI
@preconcurrency import Translation
import WebKit

/// A page's web view, which lets Lithium change its context menu.
final class PageWebView: WKWebView {
    /// The text selected when the page was last right-clicked, which `PageTranslation.script`
    /// reports just before WebKit opens the menu. Empty in a text field.
    var menuSelection = ""
    weak var translation: PageTranslation?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        translation?.adjust(menu, in: self, at: convert(event.locationInWindow, from: nil))
        menuSelection = ""
    }
}

/// The context menu's Translate. WebKit's own opens macOS's translation popover, which picks the
/// target language itself: Spanish, for an English page read on a Mac set to English then French.
/// Lithium's translates into the summary language, else the first preferred language the text
/// isn't already in. In a text field, or a frame the script can't reach, WebKit's stays, since
/// it can replace the field's text with its translation.
@MainActor
final class PageTranslation: NSObject, WKScriptMessageHandler {
    static let name = "lithiumTranslate"

    /// In Lithium's own content world, so a page can't pass other text off as its selection.
    static let script = WKUserScript(source: """
        addEventListener('contextmenu', () => {
          const field = document.activeElement;
          const selection = getSelection();
          const node = selection.anchorNode;
          const element = node && node.nodeType !== Node.ELEMENT_NODE ? node.parentElement : node;
          const editable = field?.matches?.('input, textarea') || element?.isContentEditable;
          webkit.messageHandlers.\(name).postMessage(editable ? '' : String(selection));
        }, true);
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient)

    private static let menuIdentifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierTranslate")

    private let summaries: PageSummaries
    private var popover: NSPopover?
    /// The languages Translation translates into, which the summary language may not be one of.
    private var supported: [Locale.Language] = []

    init(summaries: PageSummaries) {
        self.summaries = summaries
        super.init()
        Task { supported = await LanguageAvailability().supportedLanguages }
    }

    func install(on configuration: WKWebViewConfiguration) {
        configuration.userContentController.add(self, contentWorld: .defaultClient, name: Self.name)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = message.webView as? PageWebView, let text = message.body as? String else { return }
        webView.menuSelection = text
    }

    func adjust(_ menu: NSMenu, in webView: PageWebView, at point: NSPoint) {
        let text = webView.menuSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let item = menu.items.first(where: { $0.identifier == Self.menuIdentifier }) else { return }
        item.target = self
        item.action = #selector(translate(_:))
        item.representedObject = Request(text: text, webView: webView, point: point)
    }

    @objc private func translate(_ item: NSMenuItem) {
        guard let request = item.representedObject as? Request, let webView = request.webView, webView.window != nil else { return }
        popover?.close()
        let target = Self.target(for: request.text, chosen: summaries.language, supported: supported)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: TranslationPanel(text: request.text, target: target))
        popover.show(relativeTo: NSRect(origin: request.point, size: .zero).insetBy(dx: -1, dy: -1), of: webView, preferredEdge: .maxY)
        self.popover = popover
    }

    private final class Request {
        let text: String
        weak var webView: PageWebView?
        let point: NSPoint

        init(text: String, webView: PageWebView, point: NSPoint) {
            self.text = text
            self.webView = webView
            self.point = point
        }
    }

    /// The chosen language, then the preferred ones, skipping the one the text is written in and
    /// those Translation doesn't have (all are kept until it has said which it has).
    nonisolated static func target(
        for text: String, chosen: String?, preferred: [String] = Locale.preferredLanguages, supported: [Locale.Language]
    ) -> Locale.Language {
        let languages = ((chosen.map { [$0] } ?? []) + preferred).map(Locale.Language.init(identifier:))
            .filter { language in supported.isEmpty || supported.contains { $0.languageCode == language.languageCode } }
        let source = NLLanguageRecognizer.dominantLanguage(for: text).map { Locale.Language(identifier: $0.rawValue).languageCode }
        return languages.first { $0.languageCode != source } ?? languages.first ?? Locale.Language(identifier: "en")
    }
}

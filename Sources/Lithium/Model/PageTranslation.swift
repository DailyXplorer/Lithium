import AppKit
import NaturalLanguage
import SwiftUI
@preconcurrency import Translation
import WebKit

/// A page's web view, which lets Lithium change its context menu.
final class PageWebView: WKWebView {
    /// The selection at the last right click, from `PageTranslation.script`; empty in a text field.
    var menuSelection = ""
    weak var translation: PageTranslation?
    weak var tab: Tab?
    /// Icons `Favicons` is drawing in the page: those loads are Lithium's, kept out of its network log.
    var iconsDrawn: Set<URL> = []

    /// An agent's right click opens no menu until then: WebKit opens it once the page has
    /// handled `contextmenu`, which may be after the click returned.
    var agentMenuUntil: ContinuousClock.Instant?
    private(set) var agentMenusCancelled = 0
    /// The user's mouse button is down in the page: an agent action waits (`user_busy`). Checked against
    /// the real button: a link drag, `<select>` or menu tracks the press in its own loop, so no `mouseUp`.
    var isUserPressing: Bool {
        if userPressed, Self.pressedMouseButtons() & 1 == 0 { userPressed = false }
        return userPressed
    }
    private var userPressed = false
    static var pressedMouseButtons = { NSEvent.pressedMouseButtons }
    /// The last press in the page was `NativeInput`'s: only then is what the page opens an agent's.
    private(set) var agentPressedLast = false
    private var lastPress: ContinuousClock.Instant?
    /// A real press came just before: what a link does now is that press's, not a script's own
    /// `click()`, which WebKit reports as a link click too. A second, like WebKit's own user gesture.
    var pressedRecently: Bool {
        lastPress.map { .now - $0 < .seconds(1) } ?? false
    }

    /// Used up by the navigation it allowed: it can't also let the opened page, or a second download, through.
    func usePress() { lastPress = nil }

    /// WebKit records edits with the view's undo manager, else the window's, which is shared with the
    /// address bar and, in the stage, with every page an agent acts in.
    private let pageUndoManager = UndoManager()
    override var undoManager: UndoManager? { pageUndoManager }

    @objc func undo(_ sender: Any?) { pageUndoManager.undo() }
    @objc func redo(_ sender: Any?) { pageUndoManager.redo() }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            (item as? NSMenuItem)?.title = pageUndoManager.undoMenuItemTitle
            return pageUndoManager.canUndo
        case #selector(redo(_:)):
            (item as? NSMenuItem)?.title = pageUndoManager.redoMenuItemTitle
            return pageUndoManager.canRedo
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        if NativeInput.isAgents(event) || agentMenuUntil.map({ $0 > .now }) == true {
            agentMenuUntil = nil
            agentMenusCancelled += 1
            // A menu that comes anyway is closed once it tracks: cancelling before that is ignored,
            // and the menu would stay open, holding the main thread in its loop.
            NotificationCenter.default.addObserver(self, selector: #selector(agentMenuDidBeginTracking(_:)), name: NSMenu.didBeginTrackingNotification, object: menu)
            return
        }
        super.willOpenMenu(menu, with: event)
        translation?.adjust(menu, in: self, at: convert(event.locationInWindow, from: nil))
        PageOverrides.addForcePaste(to: menu, in: self)
        Passwords.addOpenPasswords(to: menu)
        menuSelection = ""
    }

    @objc private func agentMenuDidBeginTracking(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: NSMenu.didBeginTrackingNotification, object: notification.object)
        (notification.object as? NSMenu)?.cancelTrackingWithoutAnimation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if userWindow != nil { tab?.didComeIntoView() }
        tab?.webViewDidMove(self)
    }

    // User input wins (design section 2.7): input that `NativeInput` isn't delivering ends the
    // agent action running in the tab.
    override func mouseDown(with event: NSEvent) {
        if noteUser(event, pressing: true) { userPressed = true }
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        // The click comes on release, maybe long after the press.
        lastPress = .now
        if !NativeInput.isAgents(event) {
            if userPressed { tab?.noteUserActivation() }
            userPressed = false
        }
        super.mouseUp(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        if noteUser(event, pressing: true) { agentMenuUntil = nil }
        super.rightMouseDown(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        noteUser(event, pressing: true)
        super.otherMouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Esc leaves the reader, as in Safari: its article has no field the key could be meant for.
        if event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty, let tab, tab.isReading {
            Task { await tab.toggleReader() }
            return
        }
        // Only Enter, of the user's keys, takes a load back from the agent: Space activates
        // only a focused control, which the view can't tell before the page acts on it.
        if noteUser(event, pressing: true), [36, 76].contains(event.keyCode) || event.characters == "\r" { tab?.noteUserActivation() }
        super.keyDown(with: event)
    }

    /// Lithium's shortcuts before the page's (`Shortcuts`).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        Shortcuts.performInMenu(event, menu: Self.mainMenu()) || super.performKeyEquivalent(with: event)
    }

    /// The app's menu bar; a test's own menu stands in for it.
    static var mainMenu = { NSApp.mainMenu }

    override func scrollWheel(with event: NSEvent) {
        noteUser(event, pressing: false)
        super.scrollWheel(with: event)
    }

    @discardableResult
    private func noteUser(_ event: NSEvent, pressing: Bool) -> Bool {
        let agents = NativeInput.isAgents(event)
        if pressing {
            agentPressedLast = agents
            lastPress = .now
        }
        guard !agents else { return false }
        tab?.noteUserInput()
        return true
    }
}

/// The context menu's Translate. WebKit's own lets macOS's popover pick the target language;
/// Lithium's uses the summary language, else the first preferred one the text isn't in. WebKit's
/// stays in a text field (it can replace the text), and when no language fits or the selection is long.
@MainActor
final class PageTranslation: NSObject, WKScriptMessageHandler {
    static let name = "lithiumTranslate"
    static let maximumLength = 10_000

    /// In Lithium's own content world, so a page can't pass other text off as its selection.
    static let script = WKUserScript(source: """
        addEventListener('contextmenu', () => {
          const field = document.activeElement;
          const selection = getSelection();
          const node = selection.anchorNode;
          const element = node && node.nodeType !== Node.ELEMENT_NODE ? node.parentElement : node;
          const editable = field?.matches?.('input, textarea') || element?.isContentEditable;
          const text = editable ? '' : String(selection);
          // A whole page selected isn't copied to the app and scanned there before the menu
          // shows; WebKit's Translate takes it.
          webkit.messageHandlers.\(name).postMessage(text.length > \(maximumLength) ? '' : text);
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
        guard !text.isEmpty, let item = menu.items.first(where: { $0.identifier == Self.menuIdentifier }),
              let target = Self.target(for: text, chosen: summaries.language, supported: supported) else { return }
        item.target = self
        item.action = #selector(translate(_:))
        item.representedObject = Request(text: text, target: target, webView: webView, point: point)
    }

    @objc private func translate(_ item: NSMenuItem) {
        guard let request = item.representedObject as? Request, let webView = request.webView, webView.window != nil else { return }
        popover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: TranslationPanel(text: request.text, target: request.target))
        popover.show(relativeTo: NSRect(origin: request.point, size: .zero).insetBy(dx: -1, dy: -1), of: webView, preferredEdge: .maxY)
        self.popover = popover
    }

    private final class Request {
        let text: String
        let target: Locale.Language
        weak var webView: PageWebView?
        let point: NSPoint

        init(text: String, target: Locale.Language, webView: PageWebView, point: NSPoint) {
            self.text = text
            self.target = target
            self.webView = webView
            self.point = point
        }
    }

    /// The chosen language, then the preferred ones, skipping the text's own and those Translation
    /// doesn't have. Nil when none is left, and WebKit's Translate stays.
    nonisolated static func target(
        for text: String, chosen: String?, preferred: [String] = Locale.preferredLanguages, supported: [Locale.Language]
    ) -> Locale.Language? {
        let languages = ((chosen.map { [$0] } ?? []) + preferred).map(Locale.Language.init(identifier:))
            .filter { language in supported.isEmpty || supported.contains { $0.languageCode == language.languageCode } }
        let source = NLLanguageRecognizer.dominantLanguage(for: text).map { Locale.Language(identifier: $0.rawValue).languageCode }
        return languages.first { $0.languageCode != source }
    }
}

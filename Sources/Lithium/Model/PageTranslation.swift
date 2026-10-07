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
    /// The tab showing this page, for the messages it sends.
    weak var tab: Tab?
    /// Icons `Favicons` is drawing in the page: the load each starts is Lithium's, not the page's,
    /// and stays out of its network log.
    var iconsDrawn: Set<URL> = []

    /// An agent's right click opens no menu until then: WebKit opens it once the page has
    /// handled `contextmenu`, which may be after the click returned.
    var agentMenuUntil: ContinuousClock.Instant?
    private(set) var agentMenusCancelled = 0
    /// The user's mouse button is down in the page: an agent action waits (`user_busy`). The
    /// button as it really is decides: a drag of a link, a native `<select>` or a context menu
    /// tracks the press in its own loop, and the view never gets its `mouseUp`.
    var isUserPressing: Bool {
        if userPressed, Self.pressedMouseButtons() & 1 == 0 { userPressed = false }
        return userPressed
    }
    private var userPressed = false
    static var pressedMouseButtons = { NSEvent.pressedMouseButtons }
    /// The last button or key pressed in the page was `NativeInput`'s: what the page opens
    /// is an agent's only then, never on the user's own click during an agent's action.
    private(set) var agentPressedLast = false
    /// When a button or key was last pressed or released in the page, by the user or `NativeInput`.
    private var lastPress: ContinuousClock.Instant?
    /// A real press came just before: what a link does now is that press's, not a script's own
    /// `click()`, which WebKit reports as a link click too. A second, like WebKit's own user gesture.
    var pressedRecently: Bool {
        lastPress.map { .now - $0 < .seconds(1) } ?? false
    }

    /// The page's own undo stack. WebKit records its edits with the view's undo manager, else
    /// the window's: shared with the address bar, and in the stage with every page an agent
    /// acts in, where one page's Undo would undo another's typing.
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
            // `agent.js` prevents the page's default, so WebKit asks for no menu. One that comes
            // anyway (the page stopped the event before Lithium's listener) is closed as soon as
            // it tracks: cancelling before that is ignored, and the menu would stay open on the
            // user's screen, holding the main thread in its loop.
            NotificationCenter.default.addObserver(self, selector: #selector(agentMenuDidBeginTracking(_:)), name: NSMenu.didBeginTrackingNotification, object: menu)
            return
        }
        super.willOpenMenu(menu, with: event)
        translation?.adjust(menu, in: self, at: convert(event.locationInWindow, from: nil))
        PageOverrides.addForcePaste(to: menu, in: self)
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
        // Only Enter, of the user's keys, takes a load back from the agent: Space activates
        // only a focused control, which the view can't tell before the page acts on it.
        if noteUser(event, pressing: true), [36, 76].contains(event.keyCode) || event.characters == "\r" { tab?.noteUserActivation() }
        super.keyDown(with: event)
    }

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

/// The context menu's Translate. WebKit's own opens macOS's translation popover, which picks the
/// target language itself: Spanish, for an English page read on a Mac set to English then French.
/// Lithium's translates into the summary language, else the first preferred language the text
/// isn't already in. In a text field WebKit's stays, since it can replace the field's text with its
/// translation; so it does when no language fits, or the script couldn't read the selection.
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

    /// The chosen language, then the preferred ones, skipping the one the text is written in and
    /// those Translation doesn't have (all are kept until it has said which it has). Nil when none
    /// is left, and WebKit's Translate, which lets the reader pick, stays.
    nonisolated static func target(
        for text: String, chosen: String?, preferred: [String] = Locale.preferredLanguages, supported: [Locale.Language]
    ) -> Locale.Language? {
        let languages = ((chosen.map { [$0] } ?? []) + preferred).map(Locale.Language.init(identifier:))
            .filter { language in supported.isEmpty || supported.contains { $0.languageCode == language.languageCode } }
        let source = NLLanguageRecognizer.dominantLanguage(for: text).map { Locale.Language(identifier: $0.rawValue).languageCode }
        return languages.first { $0.languageCode != source }
    }
}

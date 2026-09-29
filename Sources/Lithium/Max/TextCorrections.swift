import Foundation
import WebKit

/// Max feature: a button in the text field being written in, and ⌥⌘K, that fix its spelling and
/// grammar with Apple's on-device model. `text-correction.js` shows the button, sends the
/// field's text here, and makes the changes it gets back, word by word, as if typed.
@MainActor
final class TextCorrections: NSObject, WKScriptMessageHandlerWithReply {
    static let preferenceKey = "correctText"
    static let name = "lithiumCorrect"

    /// In Lithium's own content world, which pages can't reach: a page can't ask for corrections,
    /// nor read or fake the button.
    static let script: WKUserScript = {
        let source = Resources.bundle.url(forResource: "text-correction", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: .defaultClient)
    }()

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.preferenceKey) }
    }

    /// Pages get the button only when the model can answer.
    var isAvailable: Bool {
        guard isEnabled else { return false }
        if correct != nil { return true }
        guard #available(macOS 26.0, *), let model = model as? ModelCorrections else { return false }
        return model.isAvailable
    }

    typealias Corrector = @MainActor (String) async -> CorrectionOutcome

    private let model: AnyObject?
    /// Stands in for the model in tests.
    private let correct: Corrector?

    init(corrector: Corrector? = nil) {
        isEnabled = UserDefaults.standard.object(forKey: Self.preferenceKey) as? Bool ?? true
        correct = corrector
        if #available(macOS 26.0, *), corrector == nil {
            model = ModelCorrections()
        } else {
            model = nil
        }
        super.init()
    }

    func install(on configuration: WKWebViewConfiguration) {
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .defaultClient, name: Self.name)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let body = message.body as? [String: Any] else { return (nil, "Not allowed") }
        if let undo = body["undo"] as? String {
            guard let webView = message.webView else { return (false, nil) }
            if undo == "begin" { return (beginUndoGroup(in: webView), nil) }
            endUndoGroup(in: webView)
            return (true, nil)
        }
        guard let text = body["text"] as? String else { return (nil, "Not allowed") }
        guard isAvailable else { return (["error": "Spelling correction is off."], nil) }
        guard text.count <= CorrectionText.maximumLength else { return (["error": "Too long to correct at once."], nil) }
        switch await run(text) {
        case .corrected(let corrected):
            let edits = CorrectionText.edits(from: text, to: corrected)
            return (["edits": edits.map { [$0.from, $0.to, $0.text] as [Any] }], nil)
        case .declined:
            return (["error": "Apple Intelligence can’t correct this text."], nil)
        case .failed:
            return (["error": "The correction didn’t work this time."], nil)
        }
    }

    /// A rich text editor gets each change as typed text, which WebKit registers as one undo
    /// step per change; grouped, a single ⌘Z brings back what the person wrote.
    private var undoGroups: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// False when another frame's corrections hold the tab's group: this frame's go ungrouped
    /// rather than close that group early.
    private func beginUndoGroup(in webView: WKWebView) -> Bool {
        guard let manager = webView.undoManager, undoGroups[ObjectIdentifier(webView)] == nil else { return false }
        manager.beginUndoGrouping()
        // A page that leaves before saying it's done mustn't keep the group open.
        undoGroups[ObjectIdentifier(webView)] = Task { [weak self, weak webView] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, let webView else { return }
            self.endUndoGroup(in: webView)
        }
        return true
    }

    private func endUndoGroup(in webView: WKWebView) {
        guard let timeout = undoGroups.removeValue(forKey: ObjectIdentifier(webView)) else { return }
        timeout.cancel()
        // An undo meanwhile closes the group itself; closing it again would raise.
        guard let manager = webView.undoManager, manager.groupingLevel > 0 else { return }
        manager.endUndoGrouping()
    }

    private func run(_ text: String) async -> CorrectionOutcome {
        if let correct { return await correct(text) }
        guard #available(macOS 26.0, *), let model = model as? ModelCorrections else { return .failed }
        return await model.correct(text)
    }
}

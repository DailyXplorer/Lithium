import Observation
import WebKit

/// What find-in-page searches: a web page, or a PDF in Lithium's viewer.
@MainActor
protocol FindTarget: AnyObject {
    func countMatches(of query: String) async -> Int
    /// Shows the next or previous match, wrapping around.
    func showNextMatch(of query: String, forward: Bool) async -> FindStep
    func selectedText() async -> String?
    func clearMatches()
}

enum FindStep: Equatable {
    case none
    /// The match's place among them, from 1, when the target knows it (a web page doesn't).
    case shown(position: Int?)
}

/// Find-in-page state. WKWebView's own find panel needs private container APIs, so Lithium
/// drives `WKWebView.find` itself and counts matches in the page text.
@MainActor
@Observable
final class FindInPage {
    var isVisible = false
    private(set) var query = ""
    private(set) var matchCount = 0
    private(set) var currentMatch = 0
    private(set) var focusToken = 0
    /// What the last search highlighted, cleared when the search moves elsewhere or the bar closes.
    @ObservationIgnored private weak var target: FindTarget?
    /// Only the newest search sets the count: an older one may finish later, even for the same text.
    @ObservationIgnored private var search = 0

    func show() {
        isVisible = true
        focusToken &+= 1
    }

    func hide() {
        isVisible = false
        // A search still running must not show a match once the bar is closed.
        search += 1
        target?.clearMatches()
        target = nil
    }

    func update(query newQuery: String, in target: FindTarget) async {
        if self.target !== target { self.target?.clearMatches() }
        self.target = target
        search += 1
        let current = search
        query = newQuery
        currentMatch = 0
        guard !newQuery.isEmpty else {
            matchCount = 0
            target.clearMatches()
            return
        }
        let count = await target.countMatches(of: newQuery)
        guard current == search else { return }
        matchCount = count
        await step(forward: true, in: target)
    }

    func step(forward: Bool, in target: FindTarget) async {
        guard !query.isEmpty else { return }
        let current = search
        let step = await target.showNextMatch(of: query, forward: forward)
        guard current == search else { return }
        guard case .shown(let position) = step else {
            currentMatch = 0
            return
        }
        if matchCount == 0 { matchCount = 1 }
        currentMatch = position ?? next(forward)
    }

    /// For a target that doesn't say which match it showed, counted here.
    private func next(_ forward: Bool) -> Int {
        guard currentMatch > 0 else { return forward ? 1 : matchCount }
        return forward ? currentMatch % matchCount + 1 : (currentMatch + matchCount - 2) % matchCount + 1
    }

    func useSelection(in target: FindTarget) async {
        guard let text = await target.selectedText(), !text.isEmpty else { return }
        show()
        await update(query: text, in: target)
    }
}

extension WKWebView: FindTarget {
    private static let countScript = """
        const text = (document.body && document.body.innerText || '').toLocaleLowerCase();
        const needle = query.toLocaleLowerCase();
        let count = 0;
        for (let i = text.indexOf(needle); i !== -1; i = text.indexOf(needle, i + needle.length)) count++;
        return count;
        """

    func countMatches(of query: String) async -> Int {
        let count = try? await callAsyncJavaScript(Self.countScript, arguments: ["query": query], contentWorld: .defaultClient)
        return (count as? Int) ?? 0
    }

    func showNextMatch(of query: String, forward: Bool) async -> FindStep {
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.wraps = true
        let found = (try? await find(query, configuration: configuration))?.matchFound == true
        return found ? .shown(position: nil) : .none
    }

    func selectedText() async -> String? {
        try? await callAsyncJavaScript("return String(getSelection());", contentWorld: .defaultClient) as? String
    }

    /// WebKit clears its own highlight on the next search or click.
    func clearMatches() {}
}

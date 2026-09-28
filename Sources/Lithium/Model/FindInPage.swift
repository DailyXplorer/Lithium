import Observation
import WebKit

/// What find-in-page searches: a web page, or a PDF in Lithium's viewer.
@MainActor
protocol FindTarget: AnyObject {
    func countMatches(of query: String) async -> Int
    /// Shows the next or previous match, wrapping around. False when there is none.
    func showNextMatch(of query: String, forward: Bool) async -> Bool
    func selectedText() async -> String?
    func clearMatches()
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
        target?.clearMatches()
        target = nil
    }

    func update(query newQuery: String, in tab: Tab) async {
        let target = tab.findTarget
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
        await step(forward: true, in: tab)
    }

    func step(forward: Bool, in tab: Tab) async {
        guard !query.isEmpty else { return }
        guard await tab.findTarget.showNextMatch(of: query, forward: forward) else {
            currentMatch = 0
            return
        }
        if matchCount == 0 { matchCount = 1 }
        currentMatch = next(forward)
    }

    private func next(_ forward: Bool) -> Int {
        forward ? currentMatch % matchCount + 1 : (currentMatch + matchCount - 2) % matchCount + 1
    }

    func useSelection(in tab: Tab) async {
        guard let text = await tab.findTarget.selectedText(), !text.isEmpty else { return }
        show()
        await update(query: text, in: tab)
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

    func showNextMatch(of query: String, forward: Bool) async -> Bool {
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.wraps = true
        return (try? await find(query, configuration: configuration))?.matchFound == true
    }

    func selectedText() async -> String? {
        try? await callAsyncJavaScript("return String(getSelection());", contentWorld: .defaultClient) as? String
    }

    /// WebKit clears its own highlight on the next search or click.
    func clearMatches() {}
}

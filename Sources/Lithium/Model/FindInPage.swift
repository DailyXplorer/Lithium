import Observation
import WebKit

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

    private static let countScript = """
        const text = (document.body && document.body.innerText || '').toLocaleLowerCase();
        const needle = query.toLocaleLowerCase();
        let count = 0;
        for (let i = text.indexOf(needle); i !== -1; i = text.indexOf(needle, i + needle.length)) count++;
        return count;
        """

    func show() {
        isVisible = true
        focusToken &+= 1
    }

    func hide() {
        isVisible = false
    }

    func update(query newQuery: String, in webView: WKWebView) async {
        query = newQuery
        currentMatch = 0
        guard !newQuery.isEmpty else {
            matchCount = 0
            return
        }
        let count = try? await webView.callAsyncJavaScript(Self.countScript, arguments: ["query": newQuery], contentWorld: .defaultClient)
        guard newQuery == query else { return }
        matchCount = (count as? Int) ?? 0
        await step(forward: true, in: webView)
    }

    func step(forward: Bool, in webView: WKWebView) async {
        guard !query.isEmpty else { return }
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.wraps = true
        guard let result = try? await webView.find(query, configuration: configuration), result.matchFound else {
            currentMatch = 0
            return
        }
        if matchCount == 0 { matchCount = 1 }
        currentMatch = forward ? currentMatch % matchCount + 1 : (currentMatch + matchCount - 2) % matchCount + 1
    }

    func useSelection(in webView: WKWebView) async {
        let selection = try? await webView.callAsyncJavaScript("return String(getSelection());", contentWorld: .defaultClient)
        guard let text = selection as? String, !text.isEmpty else { return }
        show()
        await update(query: text, in: webView)
    }
}

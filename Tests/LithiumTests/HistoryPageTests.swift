import Testing
import WebKit
@testable import Lithium

/// The History page, with visits from a bridge standing in for Lithium's.
@MainActor
struct HistoryPageTests {
    /// 600 visits a minute apart, ids counting down with time, sent a page at a time as `InternalBridge` does.
    @MainActor
    private final class Visits: NSObject, WKScriptMessageHandlerWithReply {
        var asked: [Any] = []
        let newest = Date().timeIntervalSince1970 * 1000

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
            let body = message.body as? [String: Any]
            guard body?["action"] as? String == "history" else { return (nil, nil) }
            asked.append(body?["value"] ?? NSNull())
            let before = (body?["value"] as? [String: Any])?["before"] as? Int
            let start = before.map { $0 - 1 } ?? 600
            let ids = stride(from: start, to: max(start - InternalBridge.historyPageLength, 0), by: -1)
            let newest = newest
            return (ids.map { id -> [String: Any] in
                ["id": id, "url": "https://example.com/\(id)", "title": "Visit \(id)", "time": newest - Double(600 - id) * 60_000]
            }, nil)
        }
    }

    /// Only the newest 500 visits showed. The next page goes on from the last visit shown, under
    /// the same day heading, and the page stops asking once a page comes back short.
    @Test(.timeLimit(.minutes(1))) func olderVisitsLoadAfterTheFirstPage() async throws {
        let visits = Visits()
        let configuration = WKWebViewConfiguration()
        InternalSchemeHandler.shared.install(on: configuration)
        configuration.userContentController.addScriptMessageHandler(visits, contentWorld: .page, name: InternalBridge.name)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 700), configuration: configuration)
        let loaded = PageLoad()
        webView.navigationDelegate = loaded
        webView.load(URLRequest(url: URL(string: "lithium://history")!))
        try await loaded.wait()

        func rows(_ count: Int) async throws -> Bool {
            for _ in 0..<100 {
                let shown = try await webView.callAsyncJavaScript("return document.querySelectorAll('.visit').length", contentWorld: .page) as? Int
                if shown == count { return true }
                try await Task.sleep(for: .milliseconds(50))
            }
            return false
        }

        #expect(try await rows(500))
        // What the end of the list coming into view runs.
        _ = try await webView.callAsyncJavaScript("more()", contentWorld: .page)
        #expect(try await rows(600))
        let next = try #require(visits.asked.last as? [String: Any])
        #expect(next["before"] as? Int == 101 && next["query"] as? String == "")

        let headings = try await webView.callAsyncJavaScript(
            "const labels = [...document.querySelectorAll('.day h3')].map((h) => h.textContent); return labels.length === new Set(labels).size",
            contentWorld: .page
        ) as? Bool
        #expect(headings == true)
        let asked = visits.asked.count
        // Messages arrive in order: once the second is answered, any page the first asked for is counted.
        _ = try await webView.callAsyncJavaScript("more(); await call('ping')", contentWorld: .page)
        #expect(visits.asked.count == asked)
    }

    /// Show All History with the History tab already in front: a visit made meanwhile in a tab
    /// never selected (an agent's, a background link) is listed, though the page was never hidden.
    @Test(.timeLimit(.minutes(1))) func showingHistoryAgainListsANewVisit() async throws {
        let browser = Browser()
        browser.openHistory()
        let tab = try #require(browser.selectedTab)
        defer { browser.close(tab) }
        let marker = "history-refresh-\(UUID().uuidString)"
        let url = try #require(URL(string: "https://example.com/?\(marker)"))
        defer { browser.history.visits(matching: marker).forEach { browser.history.delete($0) } }

        // Polls until the marker's row shows; nil until the list has rendered at all.
        func listed() async -> Bool? {
            var answer: Bool?
            for _ in 0..<100 {
                try? await Task.sleep(for: .milliseconds(50))
                answer = try? await tab.webView.callAsyncJavaScript(
                    "return document.querySelector('#list .visit, #list .empty') ? [...document.querySelectorAll('#list .visit')].some((a) => a.href.includes(marker)) : null",
                    arguments: ["marker": marker], contentWorld: .page
                ) as? Bool
                if answer == true { return true }
            }
            return answer
        }
        #expect(await listed() == false)

        browser.history.record(url, title: "")
        browser.openHistory()
        #expect(browser.selectedTab === tab)
        #expect(await listed() == true)
    }
}

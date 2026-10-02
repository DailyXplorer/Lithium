import Foundation
import WebKit

/// A web view's navigation delegate that waits for its page to load, and never waits forever:
/// a load that fails, a web process that dies or a page that never finishes ends the wait with
/// an error, so the test fails at once instead of holding up the whole run.
@MainActor
final class PageLoad: NSObject, WKNavigationDelegate {
    struct TimedOut: Error {}
    struct ProcessTerminated: Error {}

    private var outcome: Result<Void, any Error>?
    private var continuation: CheckedContinuation<Void, any Error>?

    /// Waits for the first page the web view finishes, or returns at once if it already did.
    func wait(timeout: Duration = .seconds(30)) async throws {
        if outcome == nil {
            let timer = Task {
                try await Task.sleep(for: timeout)
                self.end(.failure(TimedOut()))
            }
            defer { timer.cancel() }
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
        try outcome?.get()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        end(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        fail(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        fail(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        end(.failure(ProcessTerminated()))
    }

    /// A navigation replaced by another one isn't the page failing.
    private func fail(_ error: any Error) {
        let error = error as NSError
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return }
        end(.failure(error))
    }

    private func end(_ result: Result<Void, any Error>) {
        guard outcome == nil else { return }
        outcome = result
        continuation?.resume(with: result)
        continuation = nil
    }
}

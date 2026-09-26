import Foundation
import Testing
import WebKit
@testable import Lithium

@MainActor
struct MarkdownReaderTests {
    private static let document = """
        # Lithium notes

        Some **bold** text and `code`.

        | Key | Value |
        | --- | ----- |
        | a   | 1     |

        - [x] done

        ## Lithium notes

        <img src="missing.png" onerror="window.ran = 'onerror'">
        <a id="bad" href="javascript:window.ran = 'link'">bad</a>
        <meta http-equiv="refresh" content="0; url=https://example.com/">
        """

    private func load(_ text: String, named name: String) async throws -> WKWebView {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: name)
        try text.write(to: file, atomically: true, encoding: .utf8)

        let configuration = WKWebViewConfiguration()
        if MarkdownReader.handles(file) { configuration.userContentController.addUserScript(MarkdownReader.script) }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let loaded = Loaded()
        webView.navigationDelegate = loaded
        webView.loadFileURL(file, allowingReadAccessTo: folder)
        await loaded.wait()
        return webView
    }

    private func value(_ script: String, in webView: WKWebView) async throws -> String? {
        try await webView.evaluateJavaScript(script) as? String
    }

    @Test func rendersMarkdownFiles() async throws {
        let webView = try await load(Self.document, named: "NOTES.md")
        #expect(try await value("document.title", in: webView) == "Lithium notes")
        #expect(try await value("document.querySelector('article h1').id", in: webView) == "lithium-notes")
        #expect(try await value("document.querySelectorAll('article h2')[0].id", in: webView) == "lithium-notes-1")
        #expect(try await value("document.querySelector('strong').textContent", in: webView) == "bold")
        #expect(try await value("document.querySelector('td').textContent", in: webView) == "a")
        #expect(try await value("String(document.querySelector('input[type=checkbox]').disabled)", in: webView) == "true")
    }

    @Test func renderedHTMLCannotRunScripts() async throws {
        let webView = try await load(Self.document, named: "NOTES.md")
        _ = try? await webView.evaluateJavaScript("document.getElementById('bad').click()")
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await value("String(window.ran)", in: webView) == "undefined")
        #expect(try await value("String(document.querySelector('article meta'))", in: webView) == "null")
        #expect(webView.url?.lastPathComponent == "NOTES.md")
    }

    @Test func leavesOtherTextFilesAlone() async throws {
        let webView = try await load("# Not markdown", named: "notes.txt")
        #expect(try await value("String(document.querySelector('article'))", in: webView) == "null")
        #expect(try await value("document.body.textContent", in: webView) == "# Not markdown")
    }

    @Test func leavesHTMLPagesWithMarkdownAddressesAlone() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(MarkdownReader.script)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let loaded = Loaded()
        webView.navigationDelegate = loaded
        webView.loadHTMLString("<title>Repo</title><h1>README.md</h1>", baseURL: URL(string: "https://example.com/blob/README.md")!)
        await loaded.wait()
        #expect(try await value("document.title", in: webView) == "Repo")
        #expect(try await value("String(document.querySelector('article'))", in: webView) == "null")
    }
}

@MainActor
private final class Loaded: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var done = false
    func wait() async { if !done { await withCheckedContinuation { continuation = $0 } } }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true; continuation?.resume() }
}

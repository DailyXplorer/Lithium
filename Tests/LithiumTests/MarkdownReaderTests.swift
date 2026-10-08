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
        let loaded = PageLoad()
        webView.navigationDelegate = loaded
        webView.loadFileURL(file, allowingReadAccessTo: folder)
        try await loaded.wait()
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

    /// A link keeps a bare `%` as it is (`100%.md`), which doesn't decode: the name is the title as written.
    @Test func titlesAFileWithABarePercentSign() async throws {
        let webView = try await load("# Start", named: "start.md")
        let folder = try #require(webView.url).deletingLastPathComponent()
        try "No heading here".write(to: folder.appending(path: "100%.md"), atomically: true, encoding: .utf8)
        let loaded = PageLoad()
        webView.navigationDelegate = loaded
        _ = try await webView.evaluateJavaScript("location.href = '100%.md#a%'")
        try await loaded.wait()
        #expect(try await value("location.pathname", in: webView)?.hasSuffix("/100%.md") == true)
        #expect(try await value("document.title", in: webView) == "100%.md")
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
        let loaded = PageLoad()
        webView.navigationDelegate = loaded
        webView.loadHTMLString("<title>Repo</title><h1>README.md</h1>", baseURL: URL(string: "https://example.com/blob/README.md")!)
        try await loaded.wait()
        #expect(try await value("document.title", in: webView) == "Repo")
        #expect(try await value("String(document.querySelector('article'))", in: webView) == "null")
    }
}

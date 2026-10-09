import Foundation
import WebKit

/// Renders Markdown files as documents: the file loads as usual, then a script swaps the raw
/// text for the rendered document.
@MainActor
enum MarkdownReader {
    private static let extensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn"]

    static func handles(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    /// Runs in Lithium's own content world, where the page cannot reach the parser.
    static let script: WKUserScript = {
        let marked = source("marked.min", "js")
        let css = PageStyle.fontFace + source("markdown", "css")
        let literal = (try? String(data: JSONEncoder().encode(css), encoding: .utf8)) ?? "\"\""
        let reader = source("markdown-reader", "js").replacingOccurrences(of: "__LITHIUM_MARKDOWN_CSS__", with: literal)
        return WKUserScript(source: marked + "\n" + reader, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)
    }()

    private static func source(_ name: String, _ fileExtension: String) -> String {
        Resources.bundle.url(forResource: name, withExtension: fileExtension)
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }
}

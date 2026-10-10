import Foundation
import WebKit

/// `unsaved-input.js` reports unsaved work, so idle sleep passes the tab by. Any page script can post this,
/// which only keeps its own tab awake, as playing sound would.
@MainActor
final class UnsavedInput: NSObject, WKScriptMessageHandler {
    static let shared = UnsavedInput()
    static let name = "lithiumUnsavedInput"

    /// In the page's world, where its `beforeunload` handlers are added.
    static let script = WKUserScript(
        source: Resources.bundle.url(forResource: "unsaved-input", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "",
        injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page
    )

    private let channels = NSHashTable<WKUserContentController>.weakObjects()

    /// Gives the controller the script before each page, and the channel once.
    func install(on controller: WKUserContentController) {
        if !channels.contains(controller) {
            controller.add(self, contentWorld: .page, name: Self.name)
            channels.add(controller)
        }
        controller.addUserScript(Self.script)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = message.webView as? PageWebView else { return }
        switch message.body as? String {
        case "uploading": webView.tab?.noteUpload(true, from: webView)
        case "uploaded": webView.tab?.noteUpload(false, from: webView)
        default: webView.tab?.noteUnsavedInput(from: webView)
        }
    }
}

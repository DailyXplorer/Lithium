import WebKit

/// Web Inspector for every page: Inspect Element in its menu and View › Developer. Settings ›
/// Advanced turns it off; WebKit only starts the inspector once one is opened.
@MainActor
enum DeveloperTools {
    enum Panel { case inspector, console }

    /// `isInspectable` lists the page in Safari's Develop menu; Inspect Element and the local
    /// inspector also need WebKit's developer extras, a private preference.
    static func apply(_ enabled: Bool, to webView: WKWebView) {
        webView.isInspectable = enabled
        let preferences = webView.configuration.preferences
        if preferences.responds(to: Selector(("_setDeveloperExtrasEnabled:"))) {
            preferences.setValue(enabled, forKey: "developerExtrasEnabled")
        }
        if !enabled { inspector(of: webView)?.perform(Selector(("close"))) }
    }

    static func show(_ panel: Panel, in webView: WKWebView) {
        let selector = Selector(panel == .console ? "showConsole" : "show")
        guard let inspector = inspector(of: webView), inspector.responds(to: selector) else { return }
        inspector.perform(selector)
    }

    private static func inspector(of webView: WKWebView) -> NSObject? {
        let selector = Selector(("_inspector"))
        guard webView.responds(to: selector) else { return nil }
        return webView.perform(selector)?.takeUnretainedValue() as? NSObject
    }
}

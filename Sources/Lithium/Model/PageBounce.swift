import WebKit

/// WebKit bounces the whole page under the trackpad even when the page can't scroll: a chat whose
/// own message list is at its end lifts with its sidebar and message box. Only a page that scrolls
/// vertically bounces vertically in Lithium, as in Chrome, checked as each swipe begins. Private
/// WebKit (`_pinnedState`, `_rubberBandingEnabled`), skipped by a WebKit without it.
@MainActor
enum PageBounce {
    /// `_WKRectEdge`'s top and bottom.
    static let vertical: UInt = 1 << 1 | 1 << 3

    private static let pinnedState = Selector(("_pinnedState"))
    private static let bouncing = Selector(("_rubberBandingEnabled"))
    private static let setBouncing = Selector(("_setRubberBandingEnabled:"))
    private static let isAvailable = [pinnedState, bouncing, setBouncing].allSatisfy(WKWebView.instancesRespond(to:))

    /// A page pinned at its top and bottom at once fits the window.
    static func edges(bouncing: UInt, pinned: UInt) -> UInt {
        pinned & vertical == vertical ? bouncing & ~vertical : bouncing | vertical
    }

    static func update(_ webView: WKWebView) {
        guard isAvailable else { return }
        typealias Getter = @convention(c) (AnyObject, Selector) -> UInt
        typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
        let pinned = unsafeBitCast(webView.method(for: pinnedState), to: Getter.self)(webView, pinnedState)
        let current = unsafeBitCast(webView.method(for: bouncing), to: Getter.self)(webView, bouncing)
        let wanted = edges(bouncing: current, pinned: pinned)
        if wanted != current { unsafeBitCast(webView.method(for: setBouncing), to: Setter.self)(webView, setBouncing, wanted) }
    }
}

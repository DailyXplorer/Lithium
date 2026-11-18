import AppKit
import Foundation
import Testing
import WebKit
@testable import Lithium

/// A page that can't scroll stays put under the trackpad, as in Chrome: WebKit bounced the whole
/// page, sidebar and message box included, when a chat's own list was already at its end.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PageBounceTests {
    /// A chat app's layout: the page fits the window and only its message list scrolls.
    static let chat = """
    <style>html,body{margin:0}#app{height:100vh;display:flex}#list{flex:1;overflow:auto}#list div{height:3000px}</style>
    <div id=app><div id=list><div></div></div></div>
    """
    static let article = """
    <style>html,body{margin:0}</style><div style="height:3000px"></div>
    """

    /// The page's scroll position after a two-finger swipe down, started at `start`.
    func scrollAfterSwipe(_ html: String, start: String) async throws -> Double {
        let window = OffscreenWindow(contentRect: NSRect(x: -30000, y: -30000, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let webView = PageWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: WKWebViewConfiguration())
        window.contentView = webView
        defer { window.contentView = nil }
        webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/"))
        for _ in 0..<100 where webView.isLoading { try await Task.sleep(for: .milliseconds(50)) }
        _ = try await webView.evaluateJavaScript(start)
        try await Task.sleep(for: .milliseconds(300))

        // Phases as a trackpad sends them, with no may-begin first, as a Magic Mouse does.
        let phases: [(dy: Double, phase: Int64)] = [(20, 1)] + Array(repeating: (40, 2), count: 15) + [(0, 4)]
        for event in phases {
            let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(-event.dy), wheel2: 0, wheel3: 0))
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: event.phase)
            let location = webView.convert(CGPoint(x: 200, y: 150), to: nil)
            cg.location = CGPoint(x: location.x, y: (NSScreen.screens.first?.frame.height ?? 0) - location.y)
            webView.scrollWheel(with: try #require(NSEvent(cgEvent: cg)))
            try await Task.sleep(for: .milliseconds(16))
        }
        try await Task.sleep(for: .milliseconds(200))
        return try #require(try await webView.evaluateJavaScript("scrollY") as? Double)
    }

    @Test func aPageThatFitsTheWindowDoesNotBounce() async throws {
        #expect(try await scrollAfterSwipe(Self.chat, start: "list.scrollTop = 1e6") == 0)
    }

    /// A page that scrolls still bounces at its end, as WebKit's own does.
    @Test func aPageThatScrollsStillBouncesAtItsEnd() async throws {
        #expect(try await scrollAfterSwipe(Self.article, start: "scrollTo(0, 1e6)") > 2700)
    }
}

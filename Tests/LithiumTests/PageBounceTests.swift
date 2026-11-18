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

    /// Loads `html` in a desktop-width web view with `PageStyle`'s sideways-overflow script.
    private func desktopPage(_ html: String) async throws -> (PageWebView, NSWindow) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // A loopback address keeps its own font: only the sideways-overflow script runs.
        PageStyle.scripts(for: URL(string: "http://127.0.0.1/")!).forEach(configuration.userContentController.addUserScript)
        let frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let window = OffscreenWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let webView = PageWebView(frame: frame, configuration: configuration)
        window.contentView = webView
        let occlusion = Selector(("_setWindowOcclusionDetectionEnabled:"))
        if webView.responds(to: occlusion) {
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(webView.method(for: occlusion), to: Setter.self)(webView, occlusion, false)
        }
        window.orderFrontRegardless()
        let loaded = PageLoad()
        webView.navigationDelegate = loaded
        webView.loadHTMLString("<!doctype html>" + html, baseURL: URL(string: "https://example.com/"))
        try await loaded.wait()
        try await Task.sleep(for: .milliseconds(150))
        return (webView, window)
    }

    private func swipe(_ webView: PageWebView, dx: Int32 = 0, dy: Int32 = 0, steps: Int = 10) async throws -> (peakX: Double, endX: Double, peakY: Double, endY: Double) {
        let phases: [(dx: Int32, dy: Int32, phase: Int64)] = [(0, 0, 32), (dx / 2, dy / 2, 1)]
            + Array(repeating: (dx, dy, 2), count: steps) + [(0, 0, 4)]
        var peakX = 0.0, peakY = 0.0
        for event in phases {
            let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -event.dy, wheel2: -event.dx, wheel3: 0))
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: event.phase)
            let location = webView.convert(CGPoint(x: 600, y: 400), to: nil)
            cg.location = CGPoint(x: location.x, y: (NSScreen.screens.first?.frame.height ?? 0) - location.y)
            webView.scrollWheel(with: try #require(NSEvent(cgEvent: cg)))
            try await Task.sleep(for: .milliseconds(16))
            if let position = try? await webView.evaluateJavaScript("[scrollX, scrollY]") as? [Double], position.count == 2 {
                if abs(position[0]) > abs(peakX) { peakX = position[0] }
                if abs(position[1]) > abs(peakY) { peakY = position[1] }
            }
        }
        try await Task.sleep(for: .milliseconds(250))
        let end = try #require(try await webView.evaluateJavaScript("[scrollX, scrollY]") as? [Double])
        return (peakX, end[0], peakY, end[1])
    }

    /// `overflow-x: clip` on `html` stops `body`'s overflow from propagating to the viewport, so a
    /// `body { overflow: hidden }` app shell with offscreen content below `100vh` (an overlay or
    /// even a 1 px visually-hidden announcer) scrolled and bounced the whole page up.
    @Test func bodyOverflowHiddenStillLocksTheViewportAtDesktopWidths() async throws {
        for (name, html) in [
            ("overflow: hidden + 56px offscreen overlay", """
                <style>html{height:100%}body{margin:0;height:100%;overflow:hidden}#app{height:100vh}#tip{position:absolute;top:100vh;height:56px;width:10px}</style>
                <div id=app></div><div id=tip></div>
                """),
            ("overflow: hidden + 1px announcer + inner list", """
                <style>html{height:100%}body{margin:0;height:100%;overflow:hidden}#app{height:100vh;display:flex}#list{flex:1;overflow-y:auto}#list div{height:3000px}#sr{position:absolute;top:100vh;height:1px;width:1px;overflow:hidden}</style>
                <div id=app><div id=list><div></div></div></div><div id=sr>a</div>
                """),
            ("overflow-y: hidden + tall child", """
                <style>body{margin:0;overflow-y:hidden}#app{height:calc(100vh + 56px)}</style>
                <div id=app></div>
                """),
            ("overflow: clip + tall child", """
                <style>body{margin:0;overflow:clip}#app{height:calc(100vh + 56px)}</style>
                <div id=app></div>
                """),
        ] {
            let (webView, window) = try await desktopPage(html)
            defer { window.orderOut(nil); window.contentView = nil }
            _ = try? await webView.evaluateJavaScript("const l = document.getElementById('list'); if (l) l.scrollTop = 1e6;")
            try await Task.sleep(for: .milliseconds(100))
            // Two swipes so an inner list at its end chains to the viewport on the second.
            let first = try await swipe(webView, dy: 40)
            let second = try await swipe(webView, dy: 40)
            #expect(first.peakY == 0 && first.endY == 0 && second.peakY == 0 && second.endY == 0, "\(name)")
        }
    }

    /// Modal scroll-locks (`body.style.overflow = 'hidden'`) and `body { height: 100%; overflow-y: auto }`
    /// keep propagating to the viewport at desktop widths.
    @Test func bodyModalLockAndBodyScrollPropagateToViewport() async throws {
        let (modal, modalWindow) = try await desktopPage("<style>body{margin:0}</style><div style='height:3000px'></div>")
        defer { modalWindow.orderOut(nil); modalWindow.contentView = nil }
        _ = try await modal.evaluateJavaScript("document.body.style.overflow = 'hidden'")
        let locked = try await swipe(modal, dy: 40)
        #expect(locked.peakY == 0 && locked.endY == 0)
        _ = try await modal.evaluateJavaScript("document.body.style.overflow = ''")
        let unlocked = try await swipe(modal, dy: 40)
        #expect(unlocked.endY > 100)

        let (bodyScroll, scrollWindow) = try await desktopPage("<style>html{height:100%}body{margin:0;height:100%;overflow-y:auto}</style><div style='height:3000px'></div>")
        defer { scrollWindow.orderOut(nil); scrollWindow.contentView = nil }
        let scrolled = try await swipe(bodyScroll, dy: 40)
        let bodyTop = try #require(try await bodyScroll.evaluateJavaScript("document.body.scrollTop") as? Double)
        #expect(scrolled.endY > 100 && bodyTop == 0)
    }

    private func waitHtmlOverflowX(_ webView: PageWebView, is expected: String) async -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if (try? await webView.evaluateJavaScript("getComputedStyle(document.documentElement).overflowX") as? String) == expected { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return (try? await webView.evaluateJavaScript("getComputedStyle(document.documentElement).overflowX") as? String) == expected
    }

    /// Small horizontal overflow stays unscrollable, both when `html` propagates `body` and when
    /// `html` sets its own overflow (`overflow-y: scroll` / `clip`), including when `html`'s
    /// overflow toggles, while a genuinely wide layout still scrolls sideways.
    @Test func smallSidewaysOverflowStaysClippedWithAndWithoutHtmlOverflow() async throws {
        // Positive control: a layout wider than `clientWidth + 32` still scrolls under horizontal swipe.
        let (wide, wideWindow) = try await desktopPage("<style>body{margin:0}</style><div style='width:1500px;height:50px'></div>")
        defer { wideWindow.orderOut(nil); wideWindow.contentView = nil }
        #expect(try await swipe(wide, dx: 40).endX > 100)

        for (name, html) in [
            ("100vw + 16px in body", "<style>body{margin:0}</style><div style='width:calc(100vw + 16px);height:2000px'></div>"),
            ("default body margin + 100vw", "<div style='width:100vw;height:2000px'></div>"),
            ("absolute 100vw + 16px with html visible", "<style>body{margin:0}</style><div style='position:absolute;left:0;width:calc(100vw + 16px);height:50px'></div>"),
            ("html overflow-y: scroll + absolute 100vw + 16px", "<style>html{overflow-y:scroll}body{margin:0}</style><div style='position:absolute;left:0;width:calc(100vw + 16px);height:50px'></div>"),
            ("html overflow-y: clip + absolute 100vw + 16px", "<style>html{overflow-y:clip}body{margin:0}</style><div style='position:absolute;left:0;width:calc(100vw + 16px);height:50px'></div>"),
        ] {
            let (webView, window) = try await desktopPage(html)
            defer { window.orderOut(nil); window.contentView = nil }
            let result = try await swipe(webView, dx: 40)
            #expect(result.peakX == 0 && result.endX == 0, "\(name)")
        }

        // Removing `html`'s own overflow hands viewport propagation back to `body`; adding it clips `html`.
        let (webView, window) = try await desktopPage("""
            <style id='root-of'>html{overflow-y:scroll}body{margin:0;height:100%;overflow:hidden}</style>
            <div style='height:100vh'></div><div style='position:absolute;top:100vh;height:56px;width:10px'></div>
            """)
        defer { window.orderOut(nil); window.contentView = nil }
        #expect(await waitHtmlOverflowX(webView, is: "hidden"))
        _ = try await webView.evaluateJavaScript("document.getElementById('root-of').textContent = 'html{height:100%}body{margin:0;height:100%;overflow:hidden}'")
        #expect(await waitHtmlOverflowX(webView, is: "visible"))
        let result = try await swipe(webView, dy: 40)
        #expect(result.peakY == 0 && result.endY == 0)

        let (dynamicHtml, dynamicWindow) = try await desktopPage("<style>body{margin:0}</style><div style='position:absolute;left:0;width:calc(100vw + 16px);height:50px'></div>")
        defer { dynamicWindow.orderOut(nil); dynamicWindow.contentView = nil }
        _ = try await dynamicHtml.evaluateJavaScript("document.documentElement.style.overflowY = 'scroll'")
        #expect(await waitHtmlOverflowX(dynamicHtml, is: "hidden"))
        let sideways = try await swipe(dynamicHtml, dx: 40)
        #expect(sideways.peakX == 0 && sideways.endX == 0)
        _ = try await dynamicHtml.evaluateJavaScript("document.documentElement.style.overflowY = ''")
        #expect(await waitHtmlOverflowX(dynamicHtml, is: "visible"))
    }
}

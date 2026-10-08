import AppKit
import Testing
import WebKit
@testable import Lithium

@MainActor
struct WebContainerTests {
    /// YouTube seeks on ← and → without calling preventDefault, so WebKit hands the key back
    /// to AppKit as unhandled. It must stop at the container instead of reaching the window,
    /// which plays the system alert sound.
    @Test func keysThePageLeavesUnhandledDoNotBeep() async throws {
        let window = BeepCountingWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let container = WebContainerView(frame: window.contentLayoutRect)
        window.contentView = container
        let webView = WKWebView(frame: container.bounds, configuration: WKWebViewConfiguration())
        container.addSubview(webView)
        let loaded = PageLoad()
        webView.navigationDelegate = loaded
        webView.loadHTMLString("""
            <p style="height: 3000px">video</p>
            <script>window.seeks = 0; addEventListener('keydown', (event) => { if (event.key === 'ArrowRight') seeks += 1; });</script>
            """, baseURL: URL(string: "https://example.com/")!)
        try await loaded.wait()
        // Off screen, WebKit never returns keys to AppKit.
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(webView)

        for type in [NSEvent.EventType.keyDown, .keyUp] {
            window.sendEvent(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [.function, .numericPad], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}",
                isARepeat: false, keyCode: 124)!)
        }
        try await Task.sleep(for: .milliseconds(500))

        #expect(try await webView.callAsyncJavaScript("return seeks", contentWorld: .page) as? Int == 1)
        #expect(window.unhandledKeyDowns == 0)
        window.orderOut(nil)
    }

    /// Swapping pages takes the keyboard away with the outgoing one; the incoming page gets it back.
    @Test func switchingPagesHandsTheKeyboardToTheNewPage() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let container = WebContainerView(frame: window.contentLayoutRect)
        window.contentView = container
        let outgoing = WKWebView(frame: container.bounds, configuration: WKWebViewConfiguration())
        let incoming = WKWebView(frame: container.bounds, configuration: WKWebViewConfiguration())
        container.addSubview(outgoing)
        window.makeFirstResponder(outgoing)

        outgoing.removeFromSuperview()
        container.addSubview(incoming)
        #expect(window.firstResponder === window)

        focusPage(incoming)
        #expect(window.firstResponder === incoming)
    }

    /// The address bar focused with ⌘L, or a tab being renamed, keeps the keyboard.
    @Test func aFieldBeingEditedKeepsTheKeyboard() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let container = WebContainerView(frame: window.contentLayoutRect)
        window.contentView = container
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 500), configuration: WKWebViewConfiguration())
        let field = NSTextField(frame: NSRect(x: 0, y: 520, width: 300, height: 24))
        container.addSubview(page)
        container.addSubview(field)
        window.makeFirstResponder(field)

        focusPage(page)
        #expect((window.firstResponder as? NSTextView)?.delegate === field)
        // A locked PDF's password prompt, coming up meanwhile, leaves it there too.
        #expect(isEditingText(in: window))

        window.makeFirstResponder(page)
        #expect(!isEditingText(in: window))
        #expect(!isEditingText(in: nil))
    }
}

private final class BeepCountingWindow: NSWindow {
    var unhandledKeyDowns = 0

    override func noResponder(for eventSelector: Selector) {
        if eventSelector == #selector(NSResponder.keyDown(with:)) { unhandledKeyDowns += 1 }
    }
}

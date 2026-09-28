import AppKit
import SwiftUI
import Testing
import WebKit
@testable import Lithium

/// The whole window, off screen. It builds a Browser, which keeps its data in the home folder,
/// so this suite only runs in a throwaway one:
/// `CFFIXED_USER_HOME=$(mktemp -d) swift test --filter PageLayersTests`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct PageLayersTests {
    /// A shadow on a layer that holds the web view made a playing video flash black each time
    /// the pointer moved, with the sidebar hidden.
    @Test(arguments: [true, false]) func nothingAboveThePageCastsAShadow(sidebarVisible: Bool) async throws {
        let browser = Browser()
        browser.isSidebarVisible = sidebarVisible
        let webView = browser.newTab(url: URL(string: "about:blank")!).webView
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1280, height: 820),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: BrowserView().environment(browser))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(500))

        var shadowed: [String] = []
        var layer = webView.layer
        while let current = layer {
            if current.shadowOpacity > 0 { shadowed.append(String(describing: current.delegate.map { type(of: $0) })) }
            layer = current.superlayer
        }
        #expect(webView.window === window)
        #expect(shadowed == [])
    }
}

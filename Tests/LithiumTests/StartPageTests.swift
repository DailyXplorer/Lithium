import AppKit
import SwiftUI
import Testing
@testable import Lithium

/// The whole window, off screen. It builds a Browser, which keeps its data in the home folder,
/// so this suite only runs in a throwaway one:
/// `CFFIXED_USER_HOME=$(mktemp -d) swift test --filter StartPageTests`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct StartPageTests {
    /// A new tab shows the start page with the keyboard in the address bar, and nothing on the
    /// page takes it back, as Brave Search's own field did once it loaded.
    @Test func newTabKeepsTheKeyboardInTheAddressBar() async throws {
        let browser = Browser()
        browser.newTab(url: URL(string: "about:blank")!)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1280, height: 820),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: BrowserView().environment(browser))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(300))

        browser.newTabFocusingAddress()
        var editing = false
        for _ in 0..<50 where !editing {
            try await Task.sleep(for: .milliseconds(20))
            editing = (window.firstResponder as? NSTextView)?.delegate is URLTextField
        }
        #expect(editing)
        #expect(browser.selectedTab == nil)
        try await Task.sleep(for: .seconds(1))
        #expect((window.firstResponder as? NSTextView)?.delegate is URLTextField)
    }
}

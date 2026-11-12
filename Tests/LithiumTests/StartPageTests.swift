import AppKit
import SwiftUI
import Testing
import WebKit
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
        let window = OffscreenWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1280, height: 820),
                                     styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: BrowserView().environment(browser).environment(browser.windows[0]))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(300))

        browser.commandWindow.newTabFocusingAddress()
        var editing = false
        for _ in 0..<50 where !editing {
            try await Task.sleep(for: .milliseconds(20))
            editing = (window.firstResponder as? NSTextView)?.delegate is URLTextField
        }
        #expect(editing)
        #expect(browser.commandWindow.selectedTab == nil)
        try await Task.sleep(for: .seconds(1))
        #expect((window.firstResponder as? NSTextView)?.delegate is URLTextField)
    }

    /// The decoded picture is let go once Settings switches the start page to something else.
    @Test func switchingAwayFromAPictureReleasesIt() async throws {
        let picture = URL(fileURLWithPath: "/System/Library/Desktop Pictures/iMac Blue.heic")
        #expect(await StartPictures.load(picture) != nil)
        #expect(StartPictures.cached(picture) != nil)

        let browser = Browser()
        let settings = browser.newTab(url: Internal.settingsURL)
        var ready = false
        for _ in 0..<100 where !ready {
            try await Task.sleep(for: .milliseconds(50))
            ready = (try? await settings.webView.evaluateJavaScript("!!document.querySelector('#start-kind button.on')")) as? Bool == true
        }
        #expect(ready)
        _ = try await settings.webView.evaluateJavaScript("document.querySelector('#start-kind button[data-value=color]').click()")
        var released = false
        for _ in 0..<50 where !released {
            try await Task.sleep(for: .milliseconds(20))
            released = StartPictures.cached(picture) == nil
        }
        #expect(released)
        #expect(UserDefaults.standard.string(forKey: Preference.startBackground) == "color")
    }
}

import AppKit
import SwiftUI
import Testing
@testable import Lithium

/// The capture's crosshair only while capturing, in the browser window off screen. Runs a whole
/// Browser, so only in a throwaway home folder (see `BrowserTests`).
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct CapturePointerTests {
    /// No capture view sits in the window until a capture starts, and when it ends the pointer
    /// left as the crosshair goes back to the arrow.
    @Test func crosshairGoesWithTheCapture() async throws {
        let browser = Browser()
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1024, height: 700),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: BrowserView().environment(browser).environment(browser.windows[0]))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(captureViews(in: window).isEmpty)

        browser.commandWindow.capture.begin()
        #expect(await waitUntil(5) { captureViews(in: window).count == 1 })

        NSCursor.crosshair.set()
        #expect(NSCursor.current == NSCursor.crosshair)
        browser.commandWindow.capture.finish()
        #expect(await waitUntil(5) { captureViews(in: window).isEmpty })
        #expect(NSCursor.current == NSCursor.arrow)
    }

    private func captureViews(in window: NSWindow) -> [PointerReset.ResetView] {
        func find(_ view: NSView) -> [PointerReset.ResetView] {
            ((view as? PointerReset.ResetView).map { [$0] } ?? []) + view.subviews.flatMap(find)
        }
        return window.contentView.map(find) ?? []
    }

    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

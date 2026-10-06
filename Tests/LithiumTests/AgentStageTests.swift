import AppKit
import Foundation
import Testing
import WebKit
@testable import Lithium
import LithiumTestGuard

/// The stage window, without a browser: it never shows on the user's screen, and leaves the
/// window list once nothing is staged.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AgentStageTests {
    @Test func theStageShowsNothingAndIsOrderedOutWhenEmpty() async throws {
        let stage = AgentStage()
        stage.releaseDelay = .milliseconds(100)
        defer { stage.releaseAll() }
        let size = CGSize(width: 1345, height: 805)
        let webView = WKWebView(frame: .zero)
        stage.host(webView, size: size)
        let window = try #require(stage.window)
        #expect(webView.window === window)
        #expect(window.isVisible)
        #expect(window.alphaValue == 0 && !window.isOpaque && window.backgroundColor == .clear)
        #expect(window.frame == CGRect(origin: AgentStage.origin, size: size))
        #expect(!NSScreen.screens.contains { $0.frame.intersects(window.frame) })

        // macOS moved it (kept off screen here); released, it leaves the window list.
        window.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
        #expect(await waitUntil(5) { webView.window == nil })
        #expect(!window.isVisible)
        #expect(!window.occlusionState.contains(.visible))

        // Staged again: back off every screen, behind everything.
        stage.host(webView, size: size)
        #expect(window.isVisible)
        #expect(window.frame.origin == AgentStage.origin)

        // The tab went to a window of the user's: nothing left staged, the stage leaves too.
        let other = NSWindow(contentRect: CGRect(origin: AgentStage.origin, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false
        other.contentView?.addSubview(webView)
        stage.didLeave(webView)
        #expect(stage.staged.isEmpty)
        #expect(!window.isVisible)
        #expect(!other.isVisible)
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

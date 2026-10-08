import AppKit
import SwiftUI
import Testing
@testable import Lithium

/// Where the pointer reveals what Zen mode hides, judged in the trackers' top-left coordinates.
struct PeekZoneTests {
    /// The traffic lights' corner wins over the top edge; past it, the edge peeks the top bar.
    @Test func topEdgeAndTrafficLightsCorner() {
        #expect(PeekZone.top(of: CGPoint(x: 20, y: 2)) == .corner)
        #expect(PeekZone.top(of: CGPoint(x: 77, y: 39)) == .corner)
        #expect(PeekZone.top(of: CGPoint(x: 78, y: 2)) == .edge)
        #expect(PeekZone.top(of: CGPoint(x: 600, y: 9)) == .edge)
        #expect(PeekZone.top(of: CGPoint(x: 600, y: 10)) == .near)
        #expect(PeekZone.top(of: CGPoint(x: 78, y: 30)) == .near)
    }

    /// The sidebar's edge starts where it is told: in Zen mode, below the traffic lights' corner.
    @Test func leftEdgeStartsBelowItsTop() {
        #expect(PeekZone.left(of: CGPoint(x: 4, y: 100), below: 88) == .edge)
        #expect(PeekZone.left(of: CGPoint(x: 4, y: 87), below: 88) == .near)
        #expect(PeekZone.left(of: CGPoint(x: 10, y: 100), below: 88) == .near)
    }
}

/// Zen mode in the browser window, off screen. Runs a whole Browser, so only in a throwaway home
/// folder (see `BrowserTests`).
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct ZenModeTests {
    init() {
        UserDefaults.standard.removeObject(forKey: Preference.zenMode)
        UserDefaults.standard.removeObject(forKey: Preference.sidebarVisible)
        UserDefaults.standard.removeObject(forKey: Preference.sidebarReveal)
    }

    /// Zen mode opens as the user left it, and leaves the sidebar's own setting alone; a passing
    /// change (the screenshot's other look) isn't remembered.
    @Test func zenModeSurvivesRelaunchApartFromTheSidebar() {
        defer { UserDefaults.standard.removeObject(forKey: Preference.zenMode) }
        let first = Browser()
        #expect(first.isZenMode == false)
        #expect(first.showsSidebar)

        first.toggleZenMode()
        #expect(first.isZenMode)
        #expect(first.isSidebarVisible)
        #expect(!first.showsSidebar)
        #expect(Browser().isZenMode)

        first.isZenMode = false
        #expect(Browser().isZenMode)

        first.isZenMode = true
        first.toggleZenMode()
        #expect(first.showsSidebar)
        #expect(Browser().isZenMode == false)
    }

    /// Show Sidebar (⌘B, the top bar's button) in Zen mode leaves it with the sidebar shown, even
    /// one hidden before.
    @Test func showingTheSidebarLeavesZenMode() {
        defer {
            UserDefaults.standard.removeObject(forKey: Preference.zenMode)
            UserDefaults.standard.removeObject(forKey: Preference.sidebarVisible)
        }
        let browser = Browser()
        browser.toggleSidebar()
        browser.toggleZenMode()
        #expect(!browser.showsSidebar)

        browser.toggleSidebar()
        #expect(browser.isZenMode == false)
        #expect(browser.showsSidebar)
        let relaunched = Browser()
        #expect(relaunched.isZenMode == false)
        #expect(relaunched.isSidebarVisible)
    }

    /// The top bar, its address bar with it, and the traffic lights go; out of Zen mode they're back.
    @Test func zenModeHidesTheTopBarAndTrafficLights() async throws {
        defer { UserDefaults.standard.removeObject(forKey: Preference.zenMode) }
        let (browser, _, window) = try await shownBrowser(zen: true)
        defer { window.orderOut(nil) }
        let close = try #require(window.standardWindowButton(.closeButton))
        #expect(addressField(in: window) == nil)
        #expect(close.isHidden)

        browser.toggleZenMode()
        #expect(await waitUntil(5) { addressField(in: window) != nil && !close.isHidden })
    }

    /// ⌘L in Zen mode brings the top bar and its field takes the keyboard; Escape (the field
    /// letting go) hands it back to the page and the bar goes.
    @Test func commandLBringsTheTopBarForTypingThenHidesIt() async throws {
        defer { UserDefaults.standard.removeObject(forKey: Preference.zenMode) }
        let (browser, tab, window) = try await shownBrowser(zen: true)
        defer { window.orderOut(nil) }
        let close = try #require(window.standardWindowButton(.closeButton))

        browser.requestAddressFocus()
        #expect(await waitUntil(5) { addressEditor(in: window) != nil })
        #expect(browser.isEditingAddress)
        #expect(!close.isHidden, "The traffic lights come with the bar")

        // Held while typing: past the close delay it is still there.
        try await Task.sleep(for: .milliseconds(900))
        #expect(addressEditor(in: window) != nil)

        window.makeFirstResponder(nil)
        #expect(await waitUntil(5) { window.firstResponder === tab.contentView }, "\(String(describing: window.firstResponder))")
        #expect(await waitUntil(5) { addressField(in: window) == nil && close.isHidden })
        #expect(!browser.isEditingAddress)
    }

    /// Entering Zen mode mid-edit ends the edit, rather than leaving the new bar held out for a
    /// field that is gone.
    @Test func enteringZenModeEndsAnEditInTheAddressBar() async throws {
        defer { UserDefaults.standard.removeObject(forKey: Preference.zenMode) }
        let (browser, _, window) = try await shownBrowser(zen: false)
        defer { window.orderOut(nil) }
        browser.requestAddressFocus()
        #expect(await waitUntil(5) { addressEditor(in: window) != nil })

        browser.toggleZenMode()
        #expect(!browser.isEditingAddress)
        #expect(await waitUntil(5) { addressField(in: window) == nil })
    }

    private func shownBrowser(zen: Bool) async throws -> (Browser, Lithium.Tab, NSWindow) {
        let browser = Browser()
        if zen { browser.toggleZenMode() }
        let tab = browser.newTab(url: URL(string: "data:text/html,page")!)
        // Titled with its buttons, so the traffic lights exist.
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: BrowserView().environment(browser))
        window.orderFrontRegardless()
        #expect(await waitUntil(60) { !tab.webView.isLoading && tab.webView.url != nil && tab.webView.window === window })
        try await Task.sleep(for: .milliseconds(300))
        return (browser, tab, window)
    }

    private func addressField(in window: NSWindow) -> URLTextField? {
        func find(_ view: NSView) -> URLTextField? {
            (view as? URLTextField) ?? view.subviews.lazy.compactMap(find).first
        }
        return window.contentView.flatMap(find)
    }

    /// The address bar's field editor, once it has the keyboard.
    private func addressEditor(in window: NSWindow) -> NSTextView? {
        (window.firstResponder as? NSTextView).flatMap { $0.isFieldEditor && $0.delegate is URLTextField ? $0 : nil }
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

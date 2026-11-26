import AppKit
import SwiftUI
import Testing
@testable import Lithium

/// Where the pointer reveals the hidden sidebar, judged in the tracker's top-left coordinates.
struct PeekZoneTests {
    @Test func leftEdgeTriggersPeekAcrossWindowHeight() {
        #expect(PeekZone.left(of: CGPoint(x: 0, y: 10)) == .edge)
        #expect(PeekZone.left(of: CGPoint(x: 9, y: 400)) == .edge)
        #expect(PeekZone.left(of: CGPoint(x: 10, y: 100)) == .near)
        #expect(PeekZone.left(of: CGPoint(x: 120, y: 100)) == .near)
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

    /// Zen mode opens as the user left it, saved with the session at quit, and leaves the sidebar's
    /// own setting alone; a passing change (the screenshot's other look) isn't what a new window
    /// opens with.
    @Test func zenModeSurvivesRelaunchApartFromTheSidebar() {
        defer { UserDefaults.standard.removeObject(forKey: Preference.zenMode) }
        SessionStore.save(Session())
        let first = Browser()
        #expect(first.commandWindow.isZenMode == false)
        #expect(first.commandWindow.showsSidebar)

        first.commandWindow.toggleZenMode()
        #expect(first.commandWindow.isZenMode)
        #expect(first.commandWindow.isSidebarVisible)
        #expect(!first.commandWindow.showsSidebar)
        first.saveNow()
        #expect(Browser().commandWindow.isZenMode)

        first.commandWindow.isZenMode = false
        #expect(UserDefaults.standard.bool(forKey: Preference.zenMode))
        #expect(Browser().commandWindow.isZenMode)

        first.commandWindow.isZenMode = true
        first.commandWindow.toggleZenMode()
        #expect(first.commandWindow.showsSidebar)
        first.saveNow()
        #expect(Browser().commandWindow.isZenMode == false)
    }

    /// Show Sidebar (⌘B, the top bar's button) in Zen mode leaves it with the sidebar shown, even
    /// one hidden before.
    @Test func showingTheSidebarLeavesZenMode() {
        defer {
            UserDefaults.standard.removeObject(forKey: Preference.zenMode)
            UserDefaults.standard.removeObject(forKey: Preference.sidebarVisible)
        }
        let browser = Browser()
        let window = browser.commandWindow
        if window.isZenMode { window.toggleZenMode() }
        if window.isSidebarVisible { window.toggleSidebar() }
        window.toggleZenMode()
        #expect(!window.showsSidebar)

        window.toggleSidebar()
        #expect(window.isZenMode == false)
        #expect(window.showsSidebar)
        browser.saveNow()
        let relaunched = Browser()
        #expect(relaunched.commandWindow.isZenMode == false)
        #expect(relaunched.commandWindow.isSidebarVisible)
    }

    /// The top bar, its address bar with it, and the traffic lights go; out of Zen mode they're back.
    @Test func zenModeHidesTheTopBarAndTrafficLights() async throws {
        defer { UserDefaults.standard.removeObject(forKey: Preference.zenMode) }
        let (browser, _, window) = try await shownBrowser(zen: true)
        defer { window.orderOut(nil) }
        let close = try #require(window.standardWindowButton(.closeButton))
        #expect(addressField(in: window) == nil)
        #expect(close.isHidden)

        browser.commandWindow.toggleZenMode()
        #expect(await waitUntil(5) { addressField(in: window) != nil && !close.isHidden })
    }

    /// ⌘L in Zen mode brings the top bar and its field takes the keyboard; Escape (the field
    /// letting go) hands it back to the page and the bar goes.
    @Test func commandLBringsTheTopBarForTypingThenHidesIt() async throws {
        defer { UserDefaults.standard.removeObject(forKey: Preference.zenMode) }
        let (browser, tab, window) = try await shownBrowser(zen: true)
        defer { window.orderOut(nil) }
        let close = try #require(window.standardWindowButton(.closeButton))

        browser.commandWindow.requestAddressFocus()
        #expect(await waitUntil(5) { addressEditor(in: window) != nil })
        #expect(browser.commandWindow.isEditingAddress)
        #expect(!close.isHidden, "The traffic lights come with the bar")

        // Held while typing: past the close delay it is still there.
        try await Task.sleep(for: .milliseconds(900))
        #expect(addressEditor(in: window) != nil)

        window.makeFirstResponder(nil)
        #expect(await waitUntil(5) { window.firstResponder === tab.contentView }, "\(String(describing: window.firstResponder))")
        #expect(await waitUntil(5) { addressField(in: window) == nil && close.isHidden })
        #expect(!browser.commandWindow.isEditingAddress)
    }

    /// Entering Zen mode mid-edit ends the edit, rather than leaving the new bar held out for a
    /// field that is gone.
    @Test func enteringZenModeEndsAnEditInTheAddressBar() async throws {
        defer { UserDefaults.standard.removeObject(forKey: Preference.zenMode) }
        let (browser, _, window) = try await shownBrowser(zen: false)
        defer { window.orderOut(nil) }
        browser.commandWindow.requestAddressFocus()
        #expect(await waitUntil(5) { addressEditor(in: window) != nil })

        browser.commandWindow.toggleZenMode()
        #expect(!browser.commandWindow.isEditingAddress)
        #expect(await waitUntil(5) { addressField(in: window) == nil })
    }

    /// Out of Zen mode too, Escape, Return and a click outside the address bar leave the keyboard
    /// on the page, not on the window where keys beep.
    @Test func endingAnAddressEditGivesTheKeyboardToThePage() async throws {
        let (browser, tab, window) = try await shownBrowser(zen: false)
        defer { window.orderOut(nil) }
        let url = try #require(tab.webView.url)

        for command in [#selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.insertNewline(_:))] {
            browser.commandWindow.requestAddressFocus()
            #expect(await waitUntil(5) { addressEditor(in: window) != nil })
            let editor = try #require(addressEditor(in: window))
            editor.string = url.absoluteString
            editor.doCommand(by: command)
            #expect(window.firstResponder === tab.contentView, "\(command): \(String(describing: window.firstResponder))")
        }

        browser.commandWindow.requestAddressFocus()
        #expect(await waitUntil(5) { addressEditor(in: window) != nil })
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 640, y: 300), modifierFlags: [],
                                                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                    eventNumber: 0, clickCount: 1, pressure: 1))
        browser.endEditingIfOutside(click)
        #expect(window.firstResponder === tab.contentView, "\(String(describing: window.firstResponder))")
        browser.tabs.forEach(browser.close)
    }

    /// ⇧⌘S in Zen mode brings the top bar, whose button the summary hangs from, and holds it while
    /// the summary is open. The summary is one page's: another tab shown, or the page moving on,
    /// closes it, even with no button there to see the change.
    @Test func theSummaryHoldsTheTopBarAndBelongsToOnePage() async throws {
        defer { UserDefaults.standard.removeObject(forKey: Preference.zenMode) }
        let (listener, base) = try await LocalHTTP.serve(["/a": ("Content-Type: text/html", "a"), "/b": ("Content-Type: text/html", "b")])
        defer { listener.cancel() }
        let (browser, _, window) = try await shownBrowser(zen: true)
        defer { window.orderOut(nil) }
        #expect(addressField(in: window) == nil)

        browser.commandWindow.isSummaryPresented = true
        #expect(await waitUntil(5) { addressField(in: window) != nil })
        // Past the close delay it is still there.
        try await Task.sleep(for: .milliseconds(900))
        #expect(addressField(in: window) != nil)

        let other = browser.newTab(url: base.appending(path: "a"))
        #expect(!browser.commandWindow.isSummaryPresented)
        #expect(await waitUntil(5) { addressField(in: window) == nil })

        #expect(await waitUntil(15) { !other.isLoading && other.webView.url != nil })
        browser.commandWindow.isSummaryPresented = true
        other.load(base.appending(path: "b"))
        #expect(!browser.commandWindow.isSummaryPresented)
        browser.tabs.forEach(browser.close)
    }

    /// The peek still out as Zen mode ends is not what Zen mode shows first when it is back.
    @Test func thePeekOutAsZenModeEndsIsGoneWhenItIsBack() async throws {
        defer { UserDefaults.standard.removeObject(forKey: Preference.zenMode) }
        let (browser, _, window) = try await shownBrowser(zen: true)
        defer { window.orderOut(nil) }
        let content = try #require(window.contentView)
        browser.commandWindow.requestAddressFocus()
        #expect(await waitUntil(5) { addressEditor(in: window) != nil })

        browser.commandWindow.toggleZenMode()
        #expect(await waitUntil(5) { peekTrackers(in: content).isEmpty }, "out of Zen mode, with its sidebar")
        browser.commandWindow.toggleZenMode()
        #expect(await waitUntil(5) { addressField(in: window) == nil })
    }

    /// The look is set, not toggled: the session an earlier test's browser saves a moment after
    /// its last change may still be landing as this one reads it.
    private func shownBrowser(zen: Bool) async throws -> (Browser, Lithium.Tab, NSWindow) {
        let browser = Browser()
        let first = browser.commandWindow
        if !first.isSidebarVisible { first.toggleSidebar() }
        if first.isZenMode != zen { first.toggleZenMode() }
        let tab = browser.newTab(url: URL(string: "data:text/html,page")!)
        // Titled with its buttons, so the traffic lights exist.
        let window = OffscreenWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1280, height: 820),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: BrowserView().environment(browser).environment(first))
        // What `BrowserNSWindow` tells the model as it opens.
        first.nsWindow = window
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

    /// Tells the peek trackers where the pointer rests, counted from the window's top left, as
    /// their tracking areas would: off screen there is no pointer to move.
    private func rest(pointerAt point: CGPoint, in window: NSWindow) throws {
        let content = try #require(window.contentView)
        let location = NSPoint(x: point.x, y: content.bounds.height - point.y)
        let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        for tracker in peekTrackers(in: content) {
            if tracker.bounds.contains(tracker.convert(location, from: nil)) {
                tracker.mouseMoved(with: event)
            } else {
                tracker.mouseExited(with: event)
            }
        }
    }

    private func peekTrackers(in view: NSView) -> [PeekTracker.TrackerView] {
        ((view as? PeekTracker.TrackerView).map { [$0] } ?? []) + view.subviews.flatMap(peekTrackers)
    }

    /// What the window draws at points counted from its top left, as red, green, blue and alpha.
    private func colors(at points: [CGPoint], in window: NSWindow) -> [[Int]] {
        guard let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return [] }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / content.bounds.width
        return points.map { point in
            var pixel = [Int](repeating: 0, count: 4)
            bitmap.getPixel(&pixel, atX: Int(point.x * scale), y: Int(point.y * scale))
            return pixel
        }
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

private extension [[Int]] {
    /// The same color everywhere, give or take what rounding leaves.
    var areAlike: Bool {
        guard let first else { return false }
        return allSatisfy { zip($0, first).allSatisfy { abs($0 - $1) <= 2 } }
    }
}

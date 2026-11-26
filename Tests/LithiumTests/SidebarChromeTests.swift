import AppKit
import SwiftUI
import Testing
@testable import Lithium

/// The sidebar chrome (nav row, address bar, tool row, and hidden-sidebar peek) in an off-screen
/// browser window. Runs a whole Browser, so only in a throwaway home folder.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct SidebarChromeTests {
    init() {
        UserDefaults.standard.removeObject(forKey: Preference.sidebarVisible)
        UserDefaults.standard.removeObject(forKey: Preference.sidebarReveal)
        UserDefaults.standard.removeObject(forKey: Preference.sidebarStyle)
        UserDefaults.standard.removeObject(forKey: Preference.agentAccess)
    }

    /// There is no top bar: the page card reaches the top margin, and the address bar lives inside
    /// the sidebar with its prompt and stripped host display.
    @Test func addressBarLivesInSidebarWithNoTopBar() async throws {
        let (listener, base) = try await LocalHTTP.serve(["/": ("Content-Type: text/html", "<p>hello</p>")])
        defer { listener.cancel() }
        let (browser, tab, window) = try await shownBrowser(sidebarVisible: true, url: base)
        defer {
            browser.tabs.forEach(browser.close)
            window.orderOut(nil)
        }
        let content = try #require(window.contentView)

        let field = try #require(addressField(in: window))
        let fieldRect = topLeftFrame(of: field, in: content)
        #expect((field.placeholderAttributedString?.string ?? field.placeholderString) == "Search or type a URL")
        #expect(fieldRect.minX >= 0 && fieldRect.maxX <= Layout.sidebarWidth, "address field sits inside the sidebar: \(fieldRect)")
        #expect(fieldRect.minY >= Layout.headerHeight && fieldRect.maxY < 100, "address field sits in row 2 of the sidebar: \(fieldRect)")
        #expect(field.stringValue == "127.0.0.1")

        let pageRect = topLeftFrame(of: tab.webView, in: content)
        #expect(abs(pageRect.minY - Layout.margin) <= 1, "no top bar above the page card: \(pageRect)")
        #expect(abs(pageRect.minX - Layout.sidebarWidth) <= 1, "page card starts beside the sidebar: \(pageRect)")
    }

    /// Hiding the sidebar hides the traffic lights and address bar; hovering the left edge slides
    /// out the full sidebar peek with traffic lights and address bar, and moving away hides it.
    @Test func hiddenSidebarPeeksOnLeftEdgeWithLightsAndAddressBar() async throws {
        let (browser, tab, window) = try await shownBrowser(sidebarVisible: false)
        defer {
            browser.tabs.forEach(browser.close)
            window.orderOut(nil)
        }
        let content = try #require(window.contentView)
        let close = try #require(window.standardWindowButton(.closeButton))

        let pageRect = topLeftFrame(of: tab.webView, in: content)
        #expect(abs(pageRect.minX - Layout.margin) <= 1, "page fills the window with margin when sidebar is hidden: \(pageRect)")
        #expect(abs(pageRect.minY - Layout.margin) <= 1, "no top bar when sidebar is hidden: \(pageRect)")
        #expect(addressField(in: window) == nil)
        #expect(close.isHidden)

        // The window margin far from any shadow carries the sidebar's background color.
        let frame = CGPoint(x: 1277, y: 400)
        let peekTop = CGPoint(x: 120, y: 12)
        try rest(pointerAt: CGPoint(x: 4, y: 300), in: window)
        #expect(await waitUntil(5) { addressField(in: window) != nil && !close.isHidden })
        #expect(await waitUntil(5) { colors(at: [frame, peekTop], in: window).areAlike }, "peek slides out with the sidebar background")

        try rest(pointerAt: CGPoint(x: 600, y: 300), in: window)
        #expect(await waitUntil(5) { addressField(in: window) == nil && close.isHidden })
    }

    /// ⌘L with the sidebar hidden brings the peek immediately with the address field active, holds
    /// it past the close delay while editing, and hides it again once editing ends.
    @Test func commandLOpensPeekFocusedAndHoldsWhileEditing() async throws {
        let (browser, tab, window) = try await shownBrowser(sidebarVisible: false)
        defer {
            browser.tabs.forEach(browser.close)
            window.orderOut(nil)
        }
        let close = try #require(window.standardWindowButton(.closeButton))
        #expect(addressField(in: window) == nil)
        #expect(close.isHidden)

        browser.commandWindow.requestAddressFocus()
        #expect(await waitUntil(5) { addressEditor(in: window) != nil })
        #expect(browser.commandWindow.isEditingAddress)
        #expect(!close.isHidden, "traffic lights come out with the peek")

        // Held while editing: past the close delay the peek is still there.
        try await Task.sleep(for: .milliseconds(900))
        #expect(addressEditor(in: window) != nil)

        window.makeFirstResponder(nil)
        #expect(await waitUntil(5) { window.firstResponder === tab.contentView }, "\(String(describing: window.firstResponder))")
        #expect(await waitUntil(5) { addressField(in: window) == nil && close.isHidden })
        #expect(!browser.commandWindow.isEditingAddress)
    }

    /// ⌘B while editing the address bar ends the edit rather than leaving the hidden sidebar's peek
    /// popped open for a field that moved.
    @Test func hidingSidebarEndsAddressEditing() async throws {
        let (browser, _, window) = try await shownBrowser(sidebarVisible: true)
        defer {
            browser.tabs.forEach(browser.close)
            window.orderOut(nil)
        }
        browser.commandWindow.requestAddressFocus()
        #expect(await waitUntil(5) { addressEditor(in: window) != nil })

        browser.commandWindow.toggleSidebar()
        #expect(!browser.commandWindow.isEditingAddress)
        #expect(await waitUntil(5) { addressField(in: window) == nil })
    }

    /// The sidebar's footer tool row orders its buttons as expected, shows the robot only when an
    /// agent connects, and clicking the sidebar's top-row toggle and footer Capture button works.
    @Test func sidebarContainsExpectedNavAndToolButtons() async throws {
        #expect(SidebarToolBar.items(hasExtensions: false, showsSummary: true, hasConnectedAgent: false)
                == [.downloads, .summary, .capture, .pageMenu])
        #expect(SidebarToolBar.items(hasExtensions: true, showsSummary: true, hasConnectedAgent: true)
                == [.downloads, .extensions, .summary, .capture, .agent, .pageMenu])
        #expect(SidebarToolBar.items(hasExtensions: false, showsSummary: false, hasConnectedAgent: false)
                == [.downloads, .capture, .pageMenu])

        let (browser, _, window) = try await shownBrowser(sidebarVisible: true)
        await browser.setAgentAccess(true)
        defer {
            Task { await browser.setAgentAccess(false) }
            browser.tabs.forEach(browser.close)
            window.orderOut(nil)
        }
        let content = try #require(window.contentView)
        // Footer tool row sits above the 28pt SpaceBar (+ 10pt bottom padding + 4pt spacing):
        // y ≈ 820 - 10 - 28 - 4 - 14 = 764.
        let toolRowY = content.bounds.height - 56
        // With Downloads (x=10..38), Summary (40..68), Capture (70..98), Agent appears at x=100..128.
        let agentSlot = CGRect(x: 100, y: toolRowY - 14, width: 28, height: 28)
        let beforeAgent = pixels(in: agentSlot, of: window)

        let client = try await AgentTabsTests.Client(browser: browser)
        _ = client
        #expect(await waitUntil(5) { browser.agent?.isConnected == true })
        #expect(await waitUntil(5) { pixels(in: agentSlot, of: window) != beforeAgent }, "Agent button draws in the sidebar footer once connected")

        // Clicking Capture in the sidebar footer enters capture selection mode.
        try await click(at: CGPoint(x: 84, y: toolRowY), in: window)
        #expect(await waitUntil(5) { browser.commandWindow.capture.isSelecting })
        browser.commandWindow.capture.finish()
        try await Task.sleep(for: .milliseconds(100))

        // Clicking SidebarToggle in row 1 (right after the traffic lights) hides the sidebar.
        try await click(at: CGPoint(x: Layout.trafficLightsWidth + 14, y: Layout.headerHeight / 2), in: window)
        #expect(await waitUntil(5) { !browser.commandWindow.showsSidebar })
        await browser.setAgentAccess(false)
    }

    private func shownBrowser(sidebarVisible: Bool, url: URL = URL(string: "data:text/html,page")!) async throws -> (Browser, Lithium.Tab, NSWindow) {
        let browser = Browser()
        let first = browser.commandWindow
        if first.isZenMode { first.toggleZenMode() }
        if first.isSidebarVisible != sidebarVisible { first.toggleSidebar() }
        let tab = browser.newTab(url: url)
        let window = OffscreenWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1280, height: 820),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = NSHostingView(rootView: BrowserView().environment(browser).environment(first))
        first.nsWindow = window
        window.orderFrontRegardless()
        #expect(await waitUntil(60) { !tab.webView.isLoading && tab.webView.url != nil && tab.webView.window === window })
        try await Task.sleep(for: .milliseconds(300))
        return (browser, tab, window)
    }

    private func topLeftFrame(of view: NSView, in content: NSView) -> CGRect {
        let rect = view.convert(view.bounds, to: content)
        return content.isFlipped ? rect : CGRect(x: rect.minX, y: content.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    private func allSubviews(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(allSubviews)
    }

    private func click(at point: CGPoint, in window: NSWindow) async throws {
        let content = try #require(window.contentView)
        let location = NSPoint(x: point.x, y: content.bounds.height - point.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            window.sendEvent(event)
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    private func pixels(in rect: CGRect, of window: NSWindow) -> [Int] {
        guard let content = window.contentView,
              let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return [] }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / content.bounds.width
        var out: [Int] = []
        for dy in stride(from: 2, to: Int(rect.height), by: 4) {
            for dx in stride(from: 2, to: Int(rect.width), by: 4) {
                var pixel = [Int](repeating: 0, count: 4)
                bitmap.getPixel(&pixel, atX: Int((rect.minX + CGFloat(dx)) * scale), y: Int((rect.minY + CGFloat(dy)) * scale))
                out.append(contentsOf: pixel)
            }
        }
        return out
    }

    private func addressField(in window: NSWindow) -> URLTextField? {
        window.contentView.flatMap { allSubviews(in: $0).compactMap { $0 as? URLTextField }.first }
    }

    private func addressEditor(in window: NSWindow) -> NSTextView? {
        (window.firstResponder as? NSTextView).flatMap { $0.isFieldEditor && ($0.delegate as AnyObject) is URLTextField ? $0 : nil }
    }

    private func rest(pointerAt point: CGPoint, in window: NSWindow) throws {
        let content = try #require(window.contentView)
        let location = NSPoint(x: point.x, y: content.bounds.height - point.y)
        let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        for tracker in allSubviews(in: content).compactMap({ $0 as? PeekTracker.TrackerView }) {
            if tracker.bounds.contains(tracker.convert(location, from: nil)) {
                tracker.mouseMoved(with: event)
            } else {
                tracker.mouseExited(with: event)
            }
        }
    }

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
    var areAlike: Bool {
        guard let first else { return false }
        return allSatisfy { zip($0, first).allSatisfy { abs($0 - $1) <= 2 } }
    }
}

import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import Lithium

private typealias Tab = Lithium.Tab

/// Two tabs side by side: pairing, closing, swapping, the session, and which side the address
/// bar acts on. A whole Browser keeps its data in the home folder, so this suite only runs in a
/// throwaway one: `./scripts/test --filter SplitViewTests`.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct SplitViewTests {
    private static let prefix = "data:text/html,"

    /// A browser whose tab list reads `names` top to bottom, and nothing else in it.
    private func browser(with names: [String]) -> Browser {
        let browser = Browser()
        browser.regularTabs.forEach(browser.close)
        for name in names.reversed() { browser.newTab(url: page(name)) }
        return browser
    }

    private func page(_ name: String) -> URL {
        URL(string: Self.prefix + name)!
    }

    private func name(_ tab: Tab?) -> String {
        String(tab?.url?.absoluteString.dropFirst(Self.prefix.count) ?? "")
    }

    private func tab(_ name: String, in browser: Browser) -> Tab {
        browser.tabs.first { $0.url == page(name) }!
    }

    /// The tab list as the sidebar shows it: a pair reads "a|c".
    private func rows(_ browser: Browser) -> [String] {
        browser.tabListEntries.map { entry in
            guard let split = entry.split else { return name(entry.tab) }
            return [split.first, split.second].map { id in name(browser.tabs.first { $0.id == id }) }.joined(separator: "|")
        }
    }

    /// Clicking the row of the pair shown keeps its focused side, as ⌘1…⌘9 does; from another
    /// tab, it shows the pair with its first side focused.
    @Test func theRowOfThePairShownKeepsItsFocusedSide() {
        let browser = browser(with: ["a", "b", "c"])
        browser.select(tab("a", in: browser))
        browser.openInSplit(tab("c", in: browser))
        #expect(rows(browser) == ["a|c", "b"])
        #expect(name(browser.selectedTab) == "c")

        browser.selectSplit(showing: tab("a", in: browser))
        #expect(name(browser.selectedTab) == "c")
        browser.select(tab("b", in: browser))
        browser.selectSplit(showing: tab("a", in: browser))
        #expect(name(browser.selectedTab) == "a")
        #expect(name(browser.shownPartner) == "c")
    }

    @Test func openInSplitViewPairsWithTheSelectedTabAndFocusesIt() {
        let browser = browser(with: ["a", "b", "c"])
        browser.select(tab("a", in: browser))
        browser.openInSplit(tab("c", in: browser))
        #expect(rows(browser) == ["a|c", "b"])
        #expect(name(browser.selectedTab) == "c")
        #expect(name(browser.shownPartner) == "a")

        // Another tab picked shows alone; either side of the pair brings both back.
        browser.select(tab("b", in: browser))
        #expect(browser.shownPartner == nil)
        browser.select(tab("a", in: browser))
        #expect(name(browser.shownPartner) == "c")
    }

    @Test func openInSplitViewOnTheSelectedTabTakesItsNeighbour() {
        let browser = browser(with: ["a", "b"])
        browser.select(tab("b", in: browser))
        browser.openInSplit(tab("b", in: browser))
        #expect(rows(browser) == ["a|b"])
        #expect(name(browser.selectedTab) == "b")

        let alone = self.browser(with: ["a"])
        #expect(alone.splitPartner(for: tab("a", in: alone)) == nil)
    }

    /// ⌘W closes the focused side; the other fills the window.
    @Test func closeTabClosesTheFocusedSideAndTheOtherFillsTheWindow() {
        let browser = browser(with: ["a", "b", "c"])
        browser.select(tab("a", in: browser))
        browser.openInSplit(tab("c", in: browser))
        browser.closeSelectedTab()
        #expect(rows(browser) == ["a", "b"])
        #expect(name(browser.selectedTab) == "a")
        #expect(browser.shownPartner == nil)

        browser.openInSplit(tab("b", in: browser))
        browser.close(tab("a", in: browser))
        #expect(rows(browser) == ["b"])
        #expect(name(browser.selectedTab) == "b")
    }

    @Test func swapStackResizeAndExit() throws {
        let browser = browser(with: ["a", "b"])
        browser.select(tab("a", in: browser))
        browser.openInSplit(tab("b", in: browser))
        let b = tab("b", in: browser)
        browser.swapSides(of: b)
        browser.toggleStacked(of: b)
        browser.resizeSplit(of: b, to: 0.9)
        let split = try #require(browser.split(of: b))
        #expect(rows(browser) == ["b|a"])
        #expect(split.isStacked && split.fraction == 0.75)
        browser.resizeSplit(of: b, to: 0.1)
        #expect(browser.split(of: b)?.fraction == 0.25)

        browser.exitSplit(of: b)
        #expect(rows(browser) == ["a", "b"])
        #expect(name(browser.selectedTab) == "b")
    }

    @Test func pinningASideEndsTheSplit() {
        let browser = browser(with: ["a", "b"])
        browser.select(tab("a", in: browser))
        browser.openInSplit(tab("b", in: browser))
        let b = tab("b", in: browser)
        browser.pin(b)
        defer { browser.pins.filter { $0.id == b.pinID }.forEach(browser.unpin) }
        #expect(browser.splits.pairs.isEmpty)
        #expect(rows(browser) == ["a"])
    }

    /// A tab dragged from the sidebar onto the left of the page opens there; the selected page
    /// moves right.
    @Test func droppingATabOnTheLeftOfThePageOpensItThere() {
        let browser = browser(with: ["a", "b", "c"])
        browser.select(tab("a", in: browser))
        let item = browser.startDragging(tab("c", in: browser))
        #expect(browser.splits.draggedTabID == tab("c", in: browser).id)
        #expect(browser.dropForSplit(item, on: .first))
        #expect(rows(browser) == ["c|a", "b"])
        #expect(name(browser.selectedTab) == "c")
        #expect(browser.splits.draggedTabID == nil)

        // Dropped on the right of the split, it takes the other side's place.
        browser.select(tab("a", in: browser))
        #expect(browser.dropForSplit(tab("b", in: browser).id.uuidString, on: .second))
        #expect(rows(browser) == ["a|b", "c"])
        // A tab can't go beside itself.
        #expect(!browser.dropForSplit(tab("b", in: browser).id.uuidString, on: .first))
    }

    /// A drag dropped off the page leaves the drop zone in the window until SwiftUI next draws;
    /// the click that ends the drag goes through it to the page.
    @Test func theClickAfterADragDroppedElsewhereReachesThePage() throws {
        let browser = browser(with: ["a", "b"])
        browser.select(tab("a", in: browser))
        let item = browser.startDragging(tab("b", in: browser))
        let zone = SplitDropZone.DropView()
        zone.isDragging = { browser.splits.draggedTabID != nil }
        zone.carries = { browser.carriesDraggedTab($0) }
        #expect(zone.takesMouse(buttons: 1, drag: item))

        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        browser.noteClick(event)
        #expect(!zone.takesMouse(buttons: 1, drag: item))
    }

    /// Side by side, the drop zone's sides are left and right; stacked (the new pair stays so),
    /// top and bottom, as the pair will show. The middle drops nothing either way.
    @Test func dropZoneSidesFollowTheSplitsOrientation() {
        let zone = SplitDropZone.DropView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        #expect(zone.side(at: NSPoint(x: 100, y: 500)) == .first)
        #expect(zone.side(at: NSPoint(x: 900, y: 100)) == .second)
        #expect(zone.side(at: NSPoint(x: 500, y: 550)) == nil)
        #expect(zone.frame(of: .second) == NSRect(x: 500, y: 0, width: 500, height: 600))

        zone.isStacked = true
        // Not flipped: the top is the high y.
        #expect(zone.side(at: NSPoint(x: 100, y: 550)) == .first)
        #expect(zone.side(at: NSPoint(x: 100, y: 50)) == .second)
        #expect(zone.side(at: NSPoint(x: 50, y: 300)) == nil)
        #expect(zone.frame(of: .first) == NSRect(x: 0, y: 300, width: 1000, height: 300))
        #expect(zone.frame(of: .second) == NSRect(x: 0, y: 0, width: 1000, height: 300))
    }

    /// A file or an image from another app carries no text, so the drop zone, registered for text
    /// only, never sees it enter: it stands down as the drag reaches it, and the page gets the drop.
    @Test func aFileDragFromAnotherAppAfterATabDragReachesThePage() {
        let browser = browser(with: ["a", "b"])
        browser.select(tab("a", in: browser))
        let item = browser.startDragging(tab("b", in: browser))
        let zone = SplitDropZone.DropView()
        zone.isDragging = { browser.splits.draggedTabID != nil }
        zone.carries = { browser.carriesDraggedTab($0) }
        #expect(zone.takesMouse(buttons: 1, drag: item))
        #expect(!zone.takesMouse(buttons: 0, drag: item))

        #expect(!zone.takesMouse(buttons: 1, drag: nil))
        #expect(browser.splits.draggedTabID == nil)
        #expect(!zone.takesMouse(buttons: 1, drag: item))
    }

    /// A tab dragged to the sidebar and a drag from another app, with no click in between: the
    /// drop zone stands down for the outside drag, which goes on to the page.
    @Test func aDragFromAnotherAppAfterATabDragReachesThePage() {
        let browser = browser(with: ["a", "b"])
        browser.select(tab("a", in: browser))
        let item = browser.startDragging(tab("b", in: browser))
        #expect(browser.carriesDraggedTab(item))
        #expect(browser.splits.draggedTabID != nil)

        #expect(!browser.carriesDraggedTab("https://example.com/"))
        #expect(browser.splits.draggedTabID == nil)
        #expect(!browser.carriesDraggedTab(nil))

        // Dropped in the sidebar, the tab's drag is over.
        _ = browser.startDragging(tab("b", in: browser))
        #expect(!browser.dropTab([item], on: .agentGroup))
        #expect(browser.splits.draggedTabID == nil)
    }

    /// The address bar, Reload and the rest act on the selected tab: in split view the focused
    /// side, which a click in the other side moves.
    @Test func addressBarActsOnTheFocusedSideAndAClickMovesIt() async throws {
        let (listener, base) = try await LocalHTTP.serve(["/typed": ("Content-Type: text/html", "<title>Typed</title>")])
        defer { listener.cancel() }
        let browser = browser(with: ["a", "b"])
        let a = tab("a", in: browser), b = tab("b", in: browser)
        browser.select(a)
        browser.openInSplit(b)

        let window = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: 800, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.contentView = nil }
        let content = NSView(frame: window.contentLayoutRect)
        window.contentView = content
        a.webView.frame = NSRect(x: 0, y: 0, width: 396, height: 400)
        b.webView.frame = NSRect(x: 404, y: 0, width: 396, height: 400)
        content.addSubview(a.webView)
        content.addSubview(b.webView)

        func click(atX x: CGFloat) throws {
            let event = try #require(NSEvent.mouseEvent(
                with: .leftMouseDown, location: NSPoint(x: x, y: 200), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            browser.noteClick(event)
        }
        try click(atX: 400)
        #expect(browser.selectedTab === b, "a click on the divider moves nothing")
        try click(atX: 100)
        #expect(browser.selectedTab === a)

        let typed = base.appending(path: "typed")
        browser.submitAddress(typed.absoluteString)
        #expect(a.url == typed)
        #expect(b.url == page("b"))

        try click(atX: 700)
        #expect(browser.selectedTab === b)
        browser.submitAddress(typed.absoluteString)
        #expect(b.url == typed)
        #expect(browser.split(of: a) != nil, "navigating keeps the pair")
    }

    /// ⌘1…⌘9 count the sidebar's rows: a pair is one, and its number shows the pair as it was.
    @Test func numberShortcutsCountAPairAsOneRow() {
        let browser = browser(with: ["a", "b", "c", "d"])
        browser.select(tab("a", in: browser))
        browser.openInSplit(tab("b", in: browser))
        #expect(rows(browser) == ["a|b", "c", "d"])
        let first = browser.pins.count

        browser.selectItem(at: first + 1)
        #expect(name(browser.selectedTab) == "c")
        browser.selectItem(at: first + 2)
        #expect(name(browser.selectedTab) == "d")
        browser.selectItem(at: first)
        #expect(name(browser.selectedTab) == "a")
        #expect(name(browser.shownPartner) == "b")

        browser.select(tab("b", in: browser))
        browser.selectItem(at: first)
        #expect(name(browser.selectedTab) == "b", "the focused side stays focused")
    }

    /// The other side's video popped out, its web view sits in the player: a click on the
    /// player's controls leaves the focus, and the video, where they are.
    @Test func aClickOnThePoppedOutPartnersPlayerKeepsItsVideoOut() throws {
        let browser = browser(with: ["a", "b"])
        let a = tab("a", in: browser), b = tab("b", in: browser)
        browser.select(a)
        browser.openInSplit(b)
        browser.videoPopout.adopt(a)
        defer { browser.videoPopout.discard(a) }
        #expect(browser.shownPartner === a)

        let window = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: 800, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.contentView = nil }
        let content = NSView(frame: window.contentLayoutRect)
        window.contentView = content
        b.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        a.webView.frame = NSRect(x: 560, y: 20, width: 220, height: 124)
        content.addSubview(b.webView)
        content.addSubview(a.webView)

        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 600, y: 60), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        browser.noteClick(event)
        #expect(browser.selectedTab === b)
        #expect(browser.videoPopout.tab === a)
    }

    /// The peeked sidebar lies over the left side: a right-click on its rows (the pair's among
    /// them) leaves the focus alone, or the sidebar would slide away under the menu (#105).
    /// A click on the page beside it still moves the focus.
    @Test func aClickOnThePeekedSidebarOverTheOtherSideKeepsTheFocus() throws {
        let browser = browser(with: ["a", "b"])
        let a = tab("a", in: browser), b = tab("b", in: browser)
        browser.select(a)
        browser.openInSplit(b)
        #expect(browser.shownPartner === a)

        let window = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: 800, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.contentView = nil }
        let content = NSView(frame: window.contentLayoutRect)
        window.contentView = content
        a.webView.frame = NSRect(x: 0, y: 0, width: 396, height: 400)
        b.webView.frame = NSRect(x: 404, y: 0, width: 396, height: 400)
        content.addSubview(a.webView)
        content.addSubview(b.webView)
        let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        content.addSubview(sidebar)

        func click(_ type: NSEvent.EventType, atX x: CGFloat) throws {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: x, y: 200), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            browser.noteClick(event)
        }
        let picks = browser.tabPickToken
        try click(.rightMouseDown, atX: 100)
        try click(.leftMouseDown, atX: 100)
        #expect(browser.selectedTab === b)
        #expect(browser.tabPickToken == picks, "the peeked sidebar slides away on a pick")

        try click(.leftMouseDown, atX: 300)
        #expect(browser.selectedTab === a)
    }

    /// The other side shows a PDF: a click on its viewer's own controls (the toolbar here), not
    /// only on its pages, focuses that side.
    @Test func aClickOnTheOtherSidesPDFToolbarFocusesIt() throws {
        let browser = browser(with: ["a", "b"])
        let a = tab("a", in: browser), b = tab("b", in: browser)
        browser.select(a)
        browser.openInSplit(b)
        #expect(browser.shownPartner === a)

        let window = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: 800, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.contentView = nil }
        let content = NSView(frame: window.contentLayoutRect)
        window.contentView = content
        a.webView.frame = NSRect(x: 0, y: 0, width: 396, height: 400)
        b.webView.frame = NSRect(x: 404, y: 0, width: 396, height: 400)
        content.addSubview(a.webView)
        content.addSubview(b.webView)
        let reader = PDFReader(url: URL(string: "https://example.com/report.pdf")!)
        let viewer = SplitPDFReader.Host(rootView: PDFReaderView(reader: reader, takesKeyboard: false))
        viewer.tabID = a.id
        viewer.frame = a.webView.frame
        content.addSubview(viewer)
        content.layoutSubtreeIfNeeded()

        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 200, y: 380), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let hit = try #require(content.hitTest(NSPoint(x: 200, y: 380)))
        #expect(!hit.isDescendant(of: a.webView), "the viewer lies over the page")
        browser.noteClick(event)
        #expect(browser.selectedTab === a)
    }

    /// In Zen mode the page reaches under the window's title bar: a split side's PDF viewer, in
    /// its own hosting view, ignores that inset like the rest of the window, so its toolbar stays
    /// at its top instead of under a blank strip.
    @Test func aSplitPDFViewerIgnoresTheTitleBarInset() {
        let window = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: 800, height: 400), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        defer { window.contentView = nil }
        let content = NSView(frame: NSRect(origin: .zero, size: window.frame.size))
        window.contentView = content
        let reader = PDFReader(url: URL(string: "https://example.com/report.pdf")!)
        let viewer = SplitPDFReader.Host(rootView: PDFReaderView(reader: reader, takesKeyboard: false))
        viewer.frame = NSRect(x: 8, y: 0, width: 784, height: content.bounds.height - 8)
        content.addSubview(viewer)
        content.layoutSubtreeIfNeeded()

        #expect(viewer.safeAreaInsets.top > 0, "the viewer lies under the title bar")
        #expect(viewer.safeAreaRegions.isEmpty)
    }

    /// Both sides are on screen: low memory puts other tabs to sleep, never the one beside the
    /// selected tab.
    @Test func theOtherSideNeverSleeps() async throws {
        let browser = browser(with: ["a", "b", "c"])
        browser.select(tab("a", in: browser))
        browser.openInSplit(tab("c", in: browser))
        browser.select(tab("a", in: browser))
        for name in ["b", "c"] {
            let page = tab(name, in: browser)
            for _ in 0..<500 where page.webView.isLoading || page.webView.url == nil {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        browser.relieveMemoryPressure(critical: true)
        #expect(tab("b", in: browser).isAsleep)
        #expect(!tab("c", in: browser).isAsleep)
    }

    /// Leaving a split, for another tab or the start page, its other side counts as used until
    /// then, like the selected side: it doesn't sleep at the next pass for time spent on screen.
    @Test func theOtherSideCountsAsUsedWhenLeft() async throws {
        let browser = browser(with: ["a", "b", "c"])
        browser.select(tab("a", in: browser))
        browser.openInSplit(tab("c", in: browser))
        browser.select(tab("a", in: browser))
        let c = tab("c", in: browser)
        #expect(browser.shownPartner === c)

        var shown = c.lastActive
        try await Task.sleep(for: .milliseconds(50))
        browser.select(tab("b", in: browser))
        #expect(c.lastActive > shown, "to another tab")

        browser.select(tab("a", in: browser))
        shown = c.lastActive
        try await Task.sleep(for: .milliseconds(50))
        browser.newTabFocusingAddress()
        #expect(c.lastActive > shown, "to the start page")

        browser.select(tab("a", in: browser))
        shown = c.lastActive
        try await Task.sleep(for: .milliseconds(50))
        #expect(browser.dropForSplit(tab("b", in: browser).id.uuidString, on: .second))
        #expect(c.lastActive > shown, "for another tab dropped beside the selected one")

        browser.select(tab("a", in: browser))
        let b = tab("b", in: browser)
        #expect(browser.shownPartner === b)
        shown = b.lastActive
        try await Task.sleep(for: .milliseconds(50))
        browser.exitSplit(of: tab("a", in: browser))
        #expect(b.lastActive > shown, "by Exit Split View")
    }

    /// From one split straight to another, the panes are reused and don't appear again: the new
    /// split's other side wakes as its first is selected.
    @Test func goingToAnotherSplitWakesItsOtherSide() async throws {
        let browser = browser(with: ["a", "b", "c", "d"])
        browser.select(tab("a", in: browser))
        browser.openInSplit(tab("b", in: browser))
        browser.select(tab("c", in: browser))
        browser.openInSplit(tab("d", in: browser))
        browser.select(tab("a", in: browser))
        let d = tab("d", in: browser)
        for _ in 0..<500 where d.webView.isLoading || d.webView.url == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        browser.relieveMemoryPressure(critical: true)
        try #require(d.isAsleep)

        browser.select(tab("c", in: browser))
        #expect(!d.isAsleep)
    }

    @Test func theSplitComesBackWithTheSession() async throws {
        let first = browser(with: ["a", "b", "c"])
        first.select(first.tabs.first { $0.url == page("a") }!)
        first.openInSplit(tab("c", in: first))
        first.toggleStacked(of: tab("c", in: first))
        first.resizeSplit(of: tab("c", in: first), to: 0.3)
        // The session is saved a moment after it changes.
        for _ in 0..<250 where SessionStore.load().splits?.first?.fraction != 0.3 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let saved = try #require(SessionStore.load().splits?.first)
        #expect(saved.isStacked && saved.fraction == 0.3)

        let restored = Browser()
        #expect(rows(restored) == ["a|c", "b"])
        let split = try #require(restored.split(of: tab("a", in: restored)))
        #expect(split.isStacked && split.fraction == 0.3)
        #expect(name(restored.selectedTab) == "c")
    }

    /// The tab list's drag source only runs when a drag starts: were it run as the list is
    /// drawn, the page's drop zones would cover it for good.
    @Test func drawingADraggableTabStartsNoDrag() throws {
        let browser = browser(with: ["a"])
        let row = NSHostingView(rootView: Text("a").frame(width: 240, height: 34).draggable(browser.startDragging(tab("a", in: browser))))
        row.frame = NSRect(x: 0, y: 0, width: 240, height: 34)
        row.layoutSubtreeIfNeeded()
        let bitmap = try #require(row.bitmapImageRepForCachingDisplay(in: row.bounds))
        row.cacheDisplay(in: row.bounds, to: bitmap)
        #expect(browser.splits.draggedTabID == nil)
    }
}

/// A split window, light and dark, with two fixture pages:
/// `LITHIUM_SNAPSHOT_DIR=/tmp/shots ./scripts/test --filter SplitViewSnapshots`.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["LITHIUM_SNAPSHOT_DIR"] != nil && ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct SplitViewSnapshots {
    private let directory = URL(filePath: ProcessInfo.processInfo.environment["LITHIUM_SNAPSHOT_DIR"] ?? "/tmp")

    private static func fixture(_ title: String, _ body: String) -> String {
        """
        <!doctype html><meta name="color-scheme" content="light dark"><title>\(title)</title>
        <style>body { font: 15px -apple-system; margin: 32px; } h1 { font-size: 24px; } p { line-height: 1.5; opacity: .8 }</style>
        <h1>\(title)</h1>\(body)
        """
    }

    @Test func splitWindowSnapshots() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Theme.registerFonts()
        let (listener, base) = try await LocalHTTP.serve([
            "/docs": ("Content-Type: text/html", Self.fixture("Release notes", "<p>Split view shows two tabs side by side.</p><p>Drag the divider to resize.</p>")),
            "/notes": ("Content-Type: text/html", Self.fixture("Notes", "<p>Click a side to focus it: the address bar acts on that side.</p>")),
        ])
        defer { listener.cancel() }

        let browser = Browser()
        browser.regularTabs.forEach(browser.close)
        let notes = browser.newTab(url: base.appending(path: "notes"))
        let docs = browser.newTab(url: base.appending(path: "docs"))
        browser.newTab(url: URL(string: "data:text/html,other")!).customTitle = "Inbox"
        docs.customTitle = "Release notes"
        notes.customTitle = "Notes"
        browser.select(docs)
        browser.openInSplit(notes)
        browser.select(docs)

        for isDark in [false, true] {
            let images = [try await image(of: docs, isDark: isDark), try await image(of: notes, isDark: isDark)]
            let split = try #require(browser.split(of: docs))
            let window = HStack(spacing: 0) {
                VStack(spacing: 2) {
                    ForEach(browser.tabListEntries) { entry in
                        if let split = entry.split { SplitTabRow(split: split) } else { SidebarRow(isSelected: false, action: {}) { Text(entry.tab.displayTitle) } }
                    }
                    Spacer()
                }
                .padding(10)
                .frame(width: 240)
                SplitLayout(isStacked: false, fraction: split.fraction, focused: .first, resize: { _ in }, menu: { EmptyView() },
                            first: { Image(nsImage: images[0]) }, second: { Image(nsImage: images[1]) })
                    .padding([.trailing, .bottom, .top], 8)
            }
            .frame(width: 1040, height: 420)
            .environment(browser)
            .environment(\.sidebarPalette, SidebarPalette(style: .solid, colorHex: Theme.defaultSidebarHex, scheme: isDark ? .dark : .light))
            .font(Theme.font(13))
            try render(window, isDark: isDark).write(to: directory.appending(path: "split-view-\(isDark ? "dark" : "light").png"))
        }
        browser.regularTabs.forEach(browser.close)
    }

    /// The page as WebKit draws it, at the size of one side.
    private func image(of tab: Tab, isDark: Bool) async throws -> NSImage {
        let webView = tab.webView
        let window = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: 392, height: 404), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        window.contentView = webView
        defer { window.contentView = nil }
        for _ in 0..<500 where webView.isLoading || webView.url == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try await webView.evaluateJavaScript("document.body.offsetHeight")
        return try await webView.takeSnapshot(configuration: nil)
    }

    private func render(_ view: some View, isDark: Bool) throws -> Data {
        let hosting = NSHostingView(rootView: view.background(isDark ? Color(white: 0.17) : Color(white: 0.93)))
        hosting.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let window = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: hosting.frame.width, height: hosting.frame.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        defer { window.contentView = nil }
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        bitmap.size = hosting.bounds.size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}

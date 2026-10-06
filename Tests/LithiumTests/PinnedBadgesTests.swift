import AppKit
import Foundation
import Network
import SwiftUI
import Testing
import WebKit
@testable import Lithium

/// Unread badges on pinned tabs. The suites below that run a whole Browser keep their favorites in
/// the home folder, so they only run in a throwaway one (`scripts/test` sets it).
@MainActor
@Suite(.serialized)
struct PinnedBadges {
    @Test(arguments: [
        ("(3) Inbox", 3),
        ("[12] Chat", 12),
        ("(99+) Messages", 100),
        ("Inbox (3) - someone@example.com - Gmail", 3),
        ("Inbox (1,234) - Gmail", 1234),
        ("Messages (5)", 5),
        ("Notifications [7]", 7),
        ("Windows (95) review", nil),
        ("Film (2024)", nil),
        ("(2024) Notes", 2024),
        ("(0) X", nil),
        ("X (0)", nil),
        ("99+", nil),
        ("3 new messages", nil),
        ("", nil),
        ("   ", nil),
        ("(-3) Inbox", nil),
    ] as [(String, Int?)])
    func titleCount(title: String, expected: Int?) {
        #expect(UnreadBadge.count(inTitle: title) == expected)
    }

    @Test func labels() {
        #expect(UnreadBadge.label(3) == "3")
        #expect(UnreadBadge.label(99) == "99")
        #expect(UnreadBadge.label(100) == "99+")
        #expect(UnreadBadge.accessibilityLabel(.count(3)) == "3 unread")
        #expect(UnreadBadge.accessibilityLabel(.count(250)) == "99+ unread")
        #expect(UnreadBadge.accessibilityLabel(.dot) == "Unread")
    }

    @Test func precedence() {
        var badge = UnreadBadge()
        #expect(badge.shown == nil)
        badge.setTitle("(4) Inbox")
        #expect(badge.shown == .count(4))
        badge.setAppBadge(2)
        #expect(badge.shown == .count(2))
        badge.setAppBadge(nil)
        #expect(badge.shown == .count(4))
        badge.setTitle("Inbox")
        #expect(badge.shown == .dot)
        badge.clearAppBadge()
        #expect(badge.shown == nil)
        badge.notify()
        #expect(badge.shown == .dot)
        badge.setTitle("(1) Inbox")
        #expect(badge.shown == .count(1))
        badge.setTitle("(0) Inbox")
        #expect(badge.shown == .dot)
        badge.open()
        #expect(badge.shown == nil)
        badge.setAppBadge(5)
        badge.setAppBadge(0)
        #expect(badge.shown == nil)
        badge.setAppBadge(5)
        badge.notify()
        badge.leaveSite()
        #expect(badge.shown == nil)
        #expect(badge == UnreadBadge())
    }

    @Test func hostileMessages() {
        typealias Signal = PinnedPages.Signal
        #expect(Signal(message: ["type": "badge", "count": 3]) == .badge(3))
        #expect(Signal(message: ["type": "badge", "count": 3.9]) == .badge(3))
        #expect(Signal(message: ["type": "badge"]) == .badge(nil))
        #expect(Signal(message: ["type": "badge", "count": NSNull()]) == .badge(nil))
        #expect(Signal(message: ["type": "badge", "count": 1e300]) == .badge(Signal.largestCount))
        #expect(Signal(message: ["type": "badge", "count": -1]) == nil)
        #expect(Signal(message: ["type": "badge", "count": Double.nan]) == nil)
        #expect(Signal(message: ["type": "badge", "count": Double.infinity]) == nil)
        #expect(Signal(message: ["type": "badge", "count": true]) == nil)
        #expect(Signal(message: ["type": "badge", "count": "3"]) == nil)
        #expect(Signal(message: ["type": "clearBadge"]) == .clearBadge)
        #expect(Signal(message: ["type": "notification", "title": "Hi"]) == .notification)
        #expect(Signal(message: ["type": "icon", "href": "https://example.com/a.png"]) == .icon(URL(string: "https://example.com/a.png")!))
        #expect(Signal(message: ["type": "icon", "href": "data:image/png;base64,AAAA"]) != nil)
        #expect(Signal(message: ["type": "icon", "href": "file:///etc/passwd"]) == nil)
        #expect(Signal(message: ["type": "icon", "href": "lithium://settings"]) == nil)
        #expect(Signal(message: ["type": "icon", "href": "data:" + String(repeating: "A", count: Signal.longestIcon)]) == nil)
        #expect(Signal(message: ["type": "icon"]) == nil)
        #expect(Signal(message: ["type": "other"]) == nil)
        #expect(Signal(message: "badge") == nil)
    }

    /// A page with a same-origin frame that posts to the channel itself, as an ad could.
    private static let page = """
        <!doctype html><title>Inbox</title>
        <iframe srcdoc="<script>function report() { webkit.messageHandlers.lithiumPinned.postMessage({ type: 'badge', count: 7 }) }</script>"></iframe>
        """

    private func browserWithPinnedPage() async throws -> (Browser, Lithium.Tab, NWListener) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pinned-badges-\(UUID().uuidString)")
        let browser = Browser(favicons: Favicons(folder: folder), notifications: NotificationCenter())
        browser.pins.forEach(browser.unpin)
        let (server, base) = try await LocalHTTP.serve(["/": ("Content-Type: text/html", Self.page)])
        let tab = browser.newTab(url: base, selecting: false)
        browser.pin(tab)
        let ready = await waitUntil(30) {
            try await tab.webView.evaluateJavaScript("document.readyState === 'complete' && typeof navigator.clearAppBadge === 'function' && typeof document.querySelector('iframe').contentWindow.report === 'function'") as? Bool == true
        }
        try #require(ready)
        return (browser, tab, server)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
    func pageSetsTheBadge() async throws {
        let (_, tab, server) = try await browserWithPinnedPage()
        defer { server.cancel() }
        #expect(tab.unread.shown == nil)

        _ = try await tab.webView.evaluateJavaScript("document.title = '(4) Inbox'")
        #expect(await waitUntil(5) { tab.unread.shown == .count(4) })

        _ = try await tab.webView.evaluateJavaScript("navigator.setAppBadge(2); 0")
        #expect(await waitUntil(5) { tab.unread.shown == .count(2) })

        // The frame's word comes first, the page's notification after it: once the dot is set,
        // the frame's message has been heard, and ignored.
        let isShim = try await tab.webView.evaluateJavaScript("Notification.permission === 'granted' && !String(Notification).includes('[native code]')") as? Bool
        try #require(isShim == true)
        _ = try await tab.webView.evaluateJavaScript("document.querySelector('iframe').contentWindow.report(); new Notification('New mail'); 0")
        #expect(await waitUntil(5) { tab.unread.isNotified })
        #expect(tab.unread.shown == .count(2))

        _ = try await tab.webView.evaluateJavaScript("navigator.clearAppBadge(); 0")
        #expect(await waitUntil(5) { tab.unread.shown == .count(4) })

        _ = try await tab.webView.evaluateJavaScript("document.title = '(0) Inbox'; navigator.setAppBadge(); 0")
        #expect(await waitUntil(5) { tab.unread.titleCount == nil && tab.unread.appBadge == .flag })
        #expect(tab.unread.shown == .dot)

        let rejected = try await tab.webView.callAsyncJavaScript(
            "try { await navigator.setAppBadge(-1); return false } catch (error) { return error instanceof TypeError }", contentWorld: .page
        ) as? Bool
        #expect(rejected == true)
        #expect(tab.unread.appBadge == .flag)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
    func notificationDotGoesWhenTheTabIsOpened() async throws {
        let (browser, tab, server) = try await browserWithPinnedPage()
        defer { server.cancel() }
        let pin = try #require(browser.pins.first { $0.id == tab.pinID })
        let other = browser.newTab()
        browser.newTab()
        #expect(browser.selectedTabID != tab.id)

        let granted = try await tab.webView.callAsyncJavaScript(
            "if (String(Notification).includes('[native code]')) return 'native'; return await Notification.requestPermission()", contentWorld: .page
        ) as? String
        try #require(granted == "granted")
        _ = try await tab.webView.evaluateJavaScript("new Notification('Reminder', { body: 'Standup' }); 0")
        #expect(await waitUntil(5) { tab.unread.shown == .dot })

        // Closing the selected tab moves the selection by itself: not the user opening this one.
        browser.closeSelectedTab()
        browser.close(other)
        #expect(tab.unread.shown == .dot)

        browser.activate(pin)
        #expect(browser.selectedTabID == tab.id)
        #expect(tab.unread.shown == nil)

        browser.unpin(pin)
        #expect(tab.unread == UnreadBadge())
    }

    /// A link opening in a new tab, as Gmail opens a message's link: the new tab's page has no
    /// say on the pinned page's channel.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
    func popupLeavesTheOpenersChannel() async throws {
        let (browser, tab, server) = try await browserWithPinnedPage()
        defer { server.cancel() }
        let count = browser.tabs.count
        _ = try await tab.webView.evaluateJavaScript("""
            const link = document.createElement('a');
            link.href = '/popup';
            link.target = '_blank';
            document.body.append(link);
            link.click();
            0
            """)
        #expect(await waitUntil(10) { browser.tabs.count == count + 1 })
        let popup = try #require(browser.tabs.first { $0 !== tab && $0.pinID == nil && $0.loadedWebView != nil })
        #expect(await waitUntil(10) { popup.url?.path() == "/popup" && !popup.isLoading })

        _ = try await tab.webView.evaluateJavaScript("navigator.setAppBadge(2); 0")
        #expect(await waitUntil(5) { tab.unread.shown == .count(2) })
    }

    /// Unpinned and pinned again without a reload, the page's script posts to the new channel.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
    func repinnedPageStillReports() async throws {
        let (browser, tab, server) = try await browserWithPinnedPage()
        defer { server.cancel() }
        let pin = try #require(browser.pins.first { $0.id == tab.pinID })
        browser.unpin(pin)
        #expect(tab.pinID == nil)
        browser.pin(tab)
        try #require(tab.pinID != nil)

        _ = try await tab.webView.evaluateJavaScript("navigator.setAppBadge(4); 0")
        #expect(await waitUntil(5) { tab.unread.shown == .count(4) })
    }

    /// Pictures of the badge on a stand-in pin tile, in light and dark:
    /// `LITHIUM_SNAPSHOT_DIR=/tmp/shots ./scripts/test --filter PinnedBadges`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHIUM_SNAPSHOT_DIR"] != nil, "Writes PNGs only when LITHIUM_SNAPSHOT_DIR is set"))
    func snapshots() throws {
        let directory = URL(filePath: ProcessInfo.processInfo.environment["LITHIUM_SNAPSHOT_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Theme.registerFonts()
        let badges: [(String, UnreadBadge.Shown?)] = [("none", nil), ("dot", .dot), ("3", .count(3)), ("99plus", .count(120))]
        for (name, badge) in badges {
            for isDark in [false, true] {
                let renderer = ImageRenderer(content: TileScene(badge: badge, isDark: isDark))
                renderer.scale = 2
                let image = try #require(renderer.nsImage)
                let png = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]))
                try png.write(to: directory.appending(path: "pinned-badge-\(name)-\(isDark ? "dark" : "light").png"))
            }
        }
    }

    private func waitUntil(_ seconds: Double, _ condition: () async throws -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if (try? await condition()) == true { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return (try? await condition()) == true
    }
}

/// Two favorites' tiles as the grid draws them, the second one selected.
private struct TileScene: View {
    let badge: UnreadBadge.Shown?
    let isDark: Bool

    private static let icon: NSImage = {
        let image = NSImage(size: NSSize(width: 64, height: 64))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 64, height: 64), xRadius: 14, yRadius: 14).fill()
        image.unlockFocus()
        return image
    }()

    var body: some View {
        let hex = isDark ? "#25272F" : Theme.defaultSidebarHex
        let palette = SidebarPalette(style: .solid, colorHex: hex, scheme: isDark ? .dark : .light)
        HStack(spacing: 8) {
            ForEach([false, true], id: \.self) { isSelected in
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(palette.tileFill(isSelected: isSelected, isHovered: false))
                    .frame(width: 66, height: 48)
                    .overlay { BadgedFavicon(image: Self.icon, fallback: "example.com", badge: badge) }
            }
        }
        .padding(12)
        .background(Color(hex: hex))
        .foregroundStyle(palette.ink)
        .environment(\.sidebarPalette, palette)
        .environment(\.colorScheme, isDark ? .dark : .light)
    }
}

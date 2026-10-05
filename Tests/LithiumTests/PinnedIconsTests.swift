import AppKit
import Foundation
import Network
import Testing
@testable import Lithium

/// Pinned tabs' icons follow their pages: a swapped `<link rel=icon>` while awake, a new day
/// while asleep. Favorites are kept in the home folder, so the suites building a Browser only run
/// in a throwaway one (`scripts/test` sets it); icons go to a temporary folder of their own.
@MainActor
@Suite(.serialized)
struct PinnedIcons {
    @Test func favoritesSavedBeforeIconURLsStillLoad() throws {
        let id = UUID()
        let old = Data(#"[{"id":"\#(id.uuidString)","url":"https://calendar.example.com/","title":"Calendar"}]"#.utf8)
        let pins = try JSONDecoder().decode([Pin].self, from: old)
        #expect(pins == [Pin(id: id, url: URL(string: "https://calendar.example.com/")!, title: "Calendar")])
        #expect(pins[0].iconURL == nil)

        var pin = pins[0]
        pin.iconURL = URL(string: "https://calendar.example.com/icon-28.png")
        let decoded = try JSONDecoder().decode(Pin.self, from: JSONEncoder().encode(pin))
        #expect(decoded.iconURL == pin.iconURL)
    }

    /// A square of one color, as a site's icon.
    private static func png(_ color: NSColor) -> Data {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        color.setFill()
        NSRect(x: 0, y: 0, width: 32, height: 32).fill()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])!
    }

    private static let red = png(.systemRed)
    private static let blue = png(.systemBlue)

    private static func favicons() -> Favicons {
        Favicons(folder: FileManager.default.temporaryDirectory.appending(path: "pinned-icons-\(UUID().uuidString)"))
    }

    /// Counts the requests for each path, from Network's queue.
    private final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]

        func record(_ path: String) { lock.withLock { counts[path, default: 0] += 1 } }
        subscript(path: String) -> Int { lock.withLock { counts[path] ?? 0 } }
    }

    private static func serveIcons(page: String = "", requests: Requests? = nil) async throws -> (NWListener, URL) {
        let routes: [String: (headers: String, body: Data)] = [
            "/": ("Content-Type: text/html", Data(page.utf8)),
            "/red.png": ("Content-Type: image/png", red),
            "/blue.png": ("Content-Type: image/png", blue),
        ]
        return try await LocalHTTP.serve(routes, requested: { requests?.record($0) })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
    func followsTheIconThePageSwaps() async throws {
        let (server, base) = try await Self.serveIcons(page: #"<!doctype html><title>Calendar</title><link rel="icon" href="/red.png">"#)
        defer { server.cancel() }
        let browser = Browser(favicons: Self.favicons(), notifications: NotificationCenter())
        browser.pins.forEach(browser.unpin)
        let tab = browser.newTab(url: base, selecting: false)
        browser.pin(tab)
        let red = try #require(Favicons.normalized(Self.red))
        let blue = try #require(Favicons.normalized(Self.blue))
        #expect(red != blue)
        let pin = { browser.pins.first { $0.id == tab.pinID } }

        #expect(await waitUntil(30) { tab.faviconData == red && pin()?.favicon == red })
        #expect(await waitUntil(5) { pin()?.iconURL == base.appending(path: "red.png") })

        _ = try await tab.webView.evaluateJavaScript("document.querySelector('link[rel=icon]').href = '/blue.png'; 0")
        #expect(await waitUntil(30) { tab.faviconData == blue && pin()?.favicon == blue })
        #expect(pin()?.iconURL == base.appending(path: "blue.png"))
        #expect(browser.icon(for: try #require(pin())) === tab.favicon)

        // A new link element, as some pages swap it.
        _ = try await tab.webView.evaluateJavaScript("""
            document.querySelector('link[rel=icon]').remove();
            const link = document.createElement('link');
            link.rel = 'shortcut icon';
            link.href = '/red.png';
            document.head.append(link);
            0
            """)
        #expect(await waitUntil(30) { tab.faviconData == red && pin()?.favicon == red })
    }

    /// Each favorite asleep or without a page fetches the icon its page last named, once, at the
    /// change of day; without it nothing is fetched, and no tab wakes.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
    func fetchesSleepingIconsWhenTheDayChanges() async throws {
        let requests = Requests()
        let (server, base) = try await Self.serveIcons(requests: requests)
        defer { server.cancel() }
        let red = try #require(Favicons.normalized(Self.red))
        let blue = try #require(Favicons.normalized(Self.blue))
        let calendar = Pin(id: UUID(), url: base.appending(path: "calendar"), title: "Calendar", favicon: red, iconURL: base.appending(path: "blue.png"))
        let mail = Pin(id: UUID(), url: base.appending(path: "mail"), title: "Mail", favicon: red, iconURL: base.appending(path: "blue.png"))
        let notes = Pin(id: UUID(), url: base.appending(path: "notes"), title: "Notes", favicon: red)
        PinStore.save([calendar, mail, notes])
        SessionStore.save(Session(tabs: [
            .init(url: calendar.url, title: "Calendar", pinID: calendar.id),
            .init(url: notes.url, title: "Notes", pinID: notes.id),
        ]))
        let center = NotificationCenter()
        let browser = Browser(favicons: Self.favicons(), notifications: center)
        let sleeping = try #require(browser.tabs.first { $0.pinID == calendar.id })
        #expect(sleeping.isAsleep && sleeping.loadedWebView == nil)
        #expect(browser.liveTab(for: mail) == nil)

        await Task.yield()
        #expect(browser.sleepingIconsRefresh == nil)
        #expect(requests["/blue.png"] == 0)

        center.post(name: .NSCalendarDayChanged, object: nil)
        await browser.sleepingIconsRefresh?.value
        #expect(requests["/blue.png"] == 2)
        #expect(requests["/"] == 0)
        #expect(browser.pins.map(\.favicon) == [blue, blue, red])
        #expect(sleeping.faviconData == blue)
        #expect(sleeping.isAsleep && sleeping.loadedWebView == nil)
        #expect(browser.tabs.allSatisfy { $0.loadedWebView == nil })

        PinStore.save([])
        SessionStore.save(Session())
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

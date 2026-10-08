import AppKit
import Foundation
import Network
import Testing
import WebKit
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
    /// The site's icon with its unread count drawn in.
    private static let badged = png(.systemGreen)

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
            "/badged.png": ("Content-Type: image/png", badged),
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

    /// Unpinned and pinned again without a reload, the page's next icon is still followed.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
    func repinnedPageStillReportsItsIcon() async throws {
        let (server, base) = try await Self.serveIcons(page: #"<!doctype html><title>Calendar</title><link rel="icon" href="/red.png">"#)
        defer { server.cancel() }
        let browser = Browser(favicons: Self.favicons(), notifications: NotificationCenter())
        browser.pins.forEach(browser.unpin)
        let tab = browser.newTab(url: base, selecting: false)
        browser.pin(tab)
        let red = try #require(Favicons.normalized(Self.red))
        let blue = try #require(Favicons.normalized(Self.blue))
        #expect(await waitUntil(30) { tab.faviconData == red })

        browser.unpin(try #require(browser.pins.first { $0.id == tab.pinID }))
        browser.pin(tab)
        let pin = { browser.pins.first { $0.id == tab.pinID } }
        _ = try await tab.webView.evaluateJavaScript("document.querySelector('link[rel=icon]').href = '/blue.png'; 0")
        #expect(await waitUntil(30) { tab.faviconData == blue && pin()?.iconURL == base.appending(path: "blue.png") })
    }

    /// Two quick swaps, the first icon slower to come: the second one stays, on the tab and the pin.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
    func slowerOlderIconDoesNotWin() async throws {
        let (server, base) = try await Self.serveIcons(page: "<!doctype html><title>Mail</title>")
        defer { server.cancel() }
        let requests = Requests()
        let (slow, slowBase) = try await LocalHTTP.serve(["/red.png": ("Content-Type: image/png", Self.red)], delay: 1, requested: { requests.record($0) })
        defer { slow.cancel() }
        let browser = Browser(favicons: Self.favicons(), notifications: NotificationCenter())
        browser.pins.forEach(browser.unpin)
        let tab = browser.newTab(url: base, selecting: false)
        browser.pin(tab)
        let blue = try #require(Favicons.normalized(Self.blue))
        let pin = { browser.pins.first { $0.id == tab.pinID } }
        #expect(await waitUntil(30) { tab.webView.url != nil && !tab.isLoading })

        let slowRed = slowBase.appending(path: "red.png").absoluteString
        _ = try await tab.webView.evaluateJavaScript("""
            const link = document.createElement('link');
            link.rel = 'icon';
            link.href = '\(slowRed)';
            document.head.append(link);
            0
            """)
        #expect(await waitUntil(10) { requests["/red.png"] == 1 })
        _ = try await tab.webView.evaluateJavaScript("document.querySelector('link[rel=icon]').href = '/blue.png'; 0")
        #expect(await waitUntil(30) { tab.faviconData == blue && pin()?.iconURL == base.appending(path: "blue.png") })

        // Past the slow answer, and the time to draw it.
        try await Task.sleep(for: .seconds(2))
        #expect(tab.faviconData == blue)
        #expect(pin()?.favicon == blue)
        #expect(pin()?.iconURL == base.appending(path: "blue.png"))
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

    /// A page's `<link>` can name anything: Lithium reads icons only from the web (or a `data:`
    /// address), never a file on the Mac, and never a body or image too big to be an icon.
    @Test func iconsComeOnlyFromTheWebAndStaySmall() async throws {
        // Trailing bytes don't stop a PNG from drawing: only the size limit refuses this one.
        let padded = Self.red + Data(count: Favicons.largestIcon)
        let (server, base) = try await LocalHTTP.serve([
            "/red.png": ("Content-Type: image/png", Self.red),
            "/padded.png": ("Content-Type: image/png", padded),
        ])
        defer { server.cancel() }
        let session = URLSession(configuration: .ephemeral)
        #expect(await Favicons.fetch(base.appending(path: "red.png"), with: session) != nil)
        #expect(await Favicons.fetch(base.appending(path: "padded.png"), with: session) == nil)
        #expect(Favicons.normalized(padded) != nil)

        let file = FileManager.default.temporaryDirectory.appending(path: "icon-\(UUID().uuidString).png")
        try Self.red.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(await Favicons.fetch(file, with: session) == nil)

        // A one-color image compresses to a few KB however many pixels it declares.
        func gray(_ side: Int) throws -> Data {
            let bitmap = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 1, samplesPerPixel: 1,
                hasAlpha: false, isPlanar: false, colorSpaceName: .deviceWhite, bytesPerRow: 0, bitsPerPixel: 0
            ))
            return try #require(bitmap.representation(using: .png, properties: [:]))
        }
        let huge = try gray(5000)
        #expect(huge.count < Favicons.largestIcon)
        #expect(Favicons.normalized(huge) == nil)
        #expect(Favicons.normalized(try gray(64)) != nil)
    }

    /// A page writes `sizes` itself: a negative or huge one counts as none or as the largest
    /// icon, never a size whose distance to 64 px overflows.
    @Test func sizesAPageWritesAreKeptInRange() {
        #expect(Favicons.size(sizes: "-9223372036854775808x-9223372036854775808", rel: "icon") == 32)
        #expect(Favicons.size(sizes: "-1x-1", rel: "apple-touch-icon") == 180)
        #expect(Favicons.size(sizes: "0x0", rel: "icon") == 32)
        #expect(Favicons.size(sizes: "9223372036854775807x9223372036854775807", rel: "icon") == 4096)
        #expect(Favicons.size(sizes: "-5x-5 16x16", rel: "icon") == 16)
        #expect(Favicons.size(sizes: "16x16 192x192", rel: "icon") == 192)
        #expect(Favicons.size(sizes: "any", rel: "icon") == 64)
    }

    /// Such a page used to crash Lithium as soon as it loaded, when its icon candidates were sorted.
    @Test func aPageWithHostileIconSizesStillGetsItsIcon() async throws {
        let page = """
            <!doctype html><title>Sizes</title>
            <link rel="icon" sizes="-9223372036854775807x-9223372036854775807" href="/red.png">
            <link rel="icon" sizes="9223372036854775807x9223372036854775807" href="/blue.png">
            """
        let (server, base) = try await Self.serveIcons(page: page)
        defer { server.cancel() }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        webView.load(URLRequest(url: base))
        #expect(await waitUntil(30) { !webView.isLoading && webView.url == base })

        let found = await Self.favicons().favicon(for: webView)
        let icons = [try #require(Favicons.normalized(Self.red)), try #require(Favicons.normalized(Self.blue))]
        #expect(found.map(icons.contains) == true)
    }

    /// A page animating its icon gets it fetched, and the favorite saved, at most every
    /// `Tab.iconInterval`, not at every frame; it ends on the icon named last.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
    func anAnimatedIconIsFetchedAtItsOwnPace() async throws {
        let requests = Requests()
        let (server, base) = try await Self.serveIcons(page: #"<!doctype html><title>Timer</title><link rel="icon" href="/red.png">"#, requests: requests)
        defer { server.cancel() }
        let browser = Browser(favicons: Self.favicons(), notifications: NotificationCenter())
        browser.pins.forEach(browser.unpin)
        let tab = browser.newTab(url: base, selecting: false)
        browser.pin(tab)
        defer { browser.pins.filter { $0.id == tab.pinID }.forEach(browser.unpin) }
        let red = try #require(Favicons.normalized(Self.red))
        let pin = { browser.pins.first { $0.id == tab.pinID } }
        #expect(await waitUntil(30) { tab.faviconData == red && pin()?.iconURL == base.appending(path: "red.png") })
        let before = requests["/red.png"] + requests["/blue.png"]

        // 60 swaps in 3 seconds, ending on blue.
        _ = try await tab.webView.evaluateJavaScript("""
            let swaps = 0;
            const timer = setInterval(() => {
                document.querySelector('link[rel=icon]').href = ++swaps % 2 ? '/blue.png' : '/red.png';
                if (swaps === 59) clearInterval(timer);
            }, 50);
            0
            """)
        try await Task.sleep(for: .seconds(3.5))
        #expect(requests["/red.png"] + requests["/blue.png"] - before <= 4)
        let blue = try #require(Favicons.normalized(Self.blue))
        #expect(await waitUntil(10) { tab.faviconData == blue && pin()?.iconURL == base.appending(path: "blue.png") })
    }

    /// A `data:` icon is shown and kept as the favorite's icon, but not as its address: only an
    /// http(s) one is fetched again, and a page redrawing its icon would rewrite the favorites.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
    func aDataIconIsNotSavedAsTheFavoritesAddress() async throws {
        let (server, base) = try await Self.serveIcons(page: #"<!doctype html><title>Calendar</title><link rel="icon" href="/red.png">"#)
        defer { server.cancel() }
        let browser = Browser(favicons: Self.favicons(), notifications: NotificationCenter())
        browser.pins.forEach(browser.unpin)
        let tab = browser.newTab(url: base, selecting: false)
        browser.pin(tab)
        defer { browser.pins.filter { $0.id == tab.pinID }.forEach(browser.unpin) }
        let blue = try #require(Favicons.normalized(Self.blue))
        let pin = { browser.pins.first { $0.id == tab.pinID } }
        #expect(await waitUntil(30) { pin()?.iconURL == base.appending(path: "red.png") })

        _ = try await tab.webView.evaluateJavaScript("document.querySelector('link[rel=icon]').href = 'data:image/png;base64,\(Self.blue.base64EncodedString())'; 0")
        #expect(await waitUntil(30) { tab.faviconData == blue && pin()?.favicon == blue })
        #expect(pin()?.iconURL == nil)
    }

    /// A page that draws its count into its icon too (Discord, Gmail): while the tile shows the
    /// count, the badged icon is neither fetched nor shown, so the count shows once, Lithium's.
    /// Once read, the page's next icon is followed again.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
    func aBadgedIconDoesNotShowTheCountTwice() async throws {
        let requests = Requests()
        let (server, base) = try await Self.serveIcons(page: #"<!doctype html><title>Chat</title><link rel="icon" href="/red.png">"#, requests: requests)
        defer { server.cancel() }
        let favicons = Self.favicons()
        let browser = Browser(favicons: favicons, notifications: NotificationCenter())
        browser.pins.forEach(browser.unpin)
        let tab = browser.newTab(url: base, selecting: false)
        browser.pin(tab)
        defer { browser.pins.filter { $0.id == tab.pinID }.forEach(browser.unpin) }
        let red = try #require(Favicons.normalized(Self.red))
        let blue = try #require(Favicons.normalized(Self.blue))
        let pin = { browser.pins.first { $0.id == tab.pinID } }
        #expect(await waitUntil(30) { tab.faviconData == red && pin()?.iconURL == base.appending(path: "red.png") })

        // As Discord does: the count goes in the title and the icon at once.
        _ = try await tab.webView.evaluateJavaScript("document.title = '(3) Chat'; document.querySelector('link[rel=icon]').href = '/badged.png'; 0")
        #expect(await waitUntil(10) { tab.unread.shown == .count(3) })
        // Past the time a fetch would take.
        try await Task.sleep(for: .seconds(1))
        #expect(requests["/badged.png"] == 0)
        #expect(tab.faviconData == red)
        #expect(pin()?.favicon == red)
        #expect(pin()?.iconURL == base.appending(path: "red.png"))
        #expect(favicons.cachedData(host: try #require(base.host())) == red)
        #expect(browser.icon(for: try #require(pin())) === tab.favicon)

        _ = try await tab.webView.evaluateJavaScript("document.title = 'Chat'; document.querySelector('link[rel=icon]').href = '/red.png'; 0")
        #expect(await waitUntil(10) { tab.unread.shown == nil })
        _ = try await tab.webView.evaluateJavaScript("document.querySelector('link[rel=icon]').href = '/blue.png'; 0")
        #expect(await waitUntil(30) { tab.faviconData == blue && pin()?.favicon == blue })
        #expect(requests["/badged.png"] == 0)
    }

    /// The badged icon named just before the count came in, still on its way then: it is not
    /// shown, saved with the favorite or kept as the site's icon.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
    func aBadgedIconNamedBeforeTheCountIsDropped() async throws {
        let (server, base) = try await Self.serveIcons(page: #"<!doctype html><title>Chat</title><link rel="icon" href="/red.png">"#)
        defer { server.cancel() }
        let requests = Requests()
        let (slow, slowBase) = try await LocalHTTP.serve(["/badged.png": ("Content-Type: image/png", Self.badged)], delay: 1, requested: { requests.record($0) })
        defer { slow.cancel() }
        let favicons = Self.favicons()
        let browser = Browser(favicons: favicons, notifications: NotificationCenter())
        browser.pins.forEach(browser.unpin)
        let tab = browser.newTab(url: base, selecting: false)
        browser.pin(tab)
        defer { browser.pins.filter { $0.id == tab.pinID }.forEach(browser.unpin) }
        let red = try #require(Favicons.normalized(Self.red))
        let pin = { browser.pins.first { $0.id == tab.pinID } }
        #expect(await waitUntil(30) { tab.faviconData == red && pin()?.iconURL == base.appending(path: "red.png") })
        // Past `Tab.iconInterval`, so the next icon is fetched at once.
        try await Task.sleep(for: Tab.iconInterval)

        let badged = slowBase.appending(path: "badged.png").absoluteString
        _ = try await tab.webView.evaluateJavaScript("document.querySelector('link[rel=icon]').href = '\(badged)'; 0")
        #expect(await waitUntil(10) { requests["/badged.png"] == 1 })
        _ = try await tab.webView.evaluateJavaScript("document.title = '(3) Chat'; 0")
        #expect(await waitUntil(10) { tab.unread.shown == .count(3) })

        // Past the slow answer, and the time to draw it.
        try await Task.sleep(for: .seconds(2))
        #expect(tab.faviconData == red)
        #expect(pin()?.favicon == red)
        #expect(pin()?.iconURL == base.appending(path: "red.png"))
        #expect(favicons.cachedData(host: try #require(base.host())) == red)
    }

    /// A site first opened while it shows a count, its icon not cached yet: its touch icon, which
    /// no site draws a count into, comes first, in a favorite and in a tab alike.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil), arguments: [true, false])
    func aSiteOpenedWithACountGetsItsTouchIcon(pinned: Bool) async throws {
        let requests = Requests()
        let page = #"<!doctype html><title>(3) Chat</title><link rel="icon" href="/badged.png"><link rel="apple-touch-icon" href="/red.png">"#
        let (server, base) = try await Self.serveIcons(page: page, requests: requests)
        defer { server.cancel() }
        let browser = Browser(favicons: Self.favicons(), notifications: NotificationCenter())
        browser.pins.forEach(browser.unpin)
        let tab = browser.newTab(url: base, selecting: false)
        if pinned { browser.pin(tab) }
        defer { browser.pins.filter { $0.id == tab.pinID }.forEach(browser.unpin) }
        let red = try #require(Favicons.normalized(Self.red))
        #expect(await waitUntil(30) { tab.faviconData == red })
        if pinned {
            #expect(tab.unread.shown == .count(3))
            #expect(await waitUntil(5) { browser.pins.first { $0.id == tab.pinID }?.favicon == red })
        }
        #expect(requests["/badged.png"] == 0)
    }

    /// The touch icon comes first only while the page counts something, in its title or through
    /// `setAppBadge`; otherwise the icon closest to the tile's size does, as before.
    @Test(arguments: [("(3) Chat", false), ("Chat", true), ("Chat", false)])
    func theTouchIconComesFirstWhileThePageCounts(title: String, counting: Bool) async throws {
        let page = #"<!doctype html><title>\#(title)</title><link rel="icon" href="/badged.png"><link rel="apple-touch-icon" href="/red.png">"#
        let (server, base) = try await Self.serveIcons(page: page)
        defer { server.cancel() }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        webView.load(URLRequest(url: base))
        #expect(await waitUntil(30) { !webView.isLoading && webView.url == base })

        let found = await Self.favicons().favicon(for: webView, counting: counting)
        let clean = title != "Chat" || counting
        #expect(found == Favicons.normalized(clean ? Self.red : Self.badged))
    }

    /// Clear History while an icon is still on its way: the late answer doesn't put the cleared
    /// host's icon back, on disk or in memory.
    @Test func clearingHistoryDropsAnIconStillOnItsWay() async throws {
        let requests = Requests()
        let (slow, base) = try await LocalHTTP.serve(["/red.png": ("Content-Type: image/png", Self.red)], delay: 1, requested: { requests.record($0) })
        defer { slow.cancel() }
        let folder = FileManager.default.temporaryDirectory.appending(path: "pinned-icons-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let favicons = Favicons(folder: folder)

        let fetch = Task { await favicons.refresh(host: "visited.example", from: base.appending(path: "red.png")) }
        #expect(await waitUntil(10) { requests["/red.png"] == 1 })
        await favicons.clear(keeping: [])
        #expect(await fetch.value != nil)
        #expect(favicons.cachedData(host: "visited.example") == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "visited.example.png").path))
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

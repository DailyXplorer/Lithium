import AppKit
import SwiftUI
import Testing
import WebKit
@testable import Lithium

/// The pictures of the README: Lithium's real window, drawn off screen in a throwaway home
/// folder, with real sites loaded in it. Nothing comes from anyone's browsing: the session is the
/// list below, and every page, title and icon is fetched from its site as the pictures are drawn.
/// Needs the network. `LITHIUM_SHOWCASE_DIR=docs/images ./scripts/test --filter ShowcaseShots`
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)), .enabled(if: ProcessInfo.processInfo.environment["LITHIUM_SHOWCASE_DIR"] != nil && ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct ShowcaseShots {
    private let directory = URL(filePath: ProcessInfo.processInfo.environment["LITHIUM_SHOWCASE_DIR"] ?? "/tmp")

    /// The favorites, by the name their tile answers to.
    private static let favorites = [
        ("GitHub", "https://github.com/"), ("YouTube", "https://www.youtube.com/"), ("Spotify", "https://open.spotify.com/"),
        ("Figma", "https://www.figma.com/"), ("Notion", "https://www.notion.com/"), ("Linear", "https://linear.app/"),
        ("Discord", "https://discord.com/"), ("Wikipedia", "https://www.wikipedia.org/"), ("Hacker News", "https://news.ycombinator.com/"),
    ]
    private static let article = "https://en.wikipedia.org/wiki/Lithium"
    private static let album = "https://c418.bandcamp.com/album/minecraft-volume-alpha"
    private static let essay = "https://hacks.mozilla.org/2017/08/inside-a-super-fast-css-engine-quantum-css-aka-stylo/"
    private static let trip = ["https://en.wikivoyage.org/wiki/Lisbon", "https://www.openstreetmap.org/#map=13/38.7223/-9.1393", "https://www.metrolisboa.pt/en/"]
    private static let others = ["https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_grid_layout", "https://webkit.org/blog/", "https://www.swift.org/documentation/"]

    @Test func pictures() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The badge of a screenshot draws the application's icon, and a test process has none.
        let appIcon = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Support/AppIcon.png").standardizedFileURL
        NSApplication.shared.applicationIconImage = try #require(NSImage(contentsOf: appIcon))
        Theme.registerFonts()
        // Sites answer in the language they are asked in: the pictures are the same from any Mac.
        UserDefaults.standard.set(["en-US"], forKey: "AppleLanguages")
        defer { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        SessionStore.save(Session())
        var pins: [Pin] = []
        for (name, address) in Self.favorites {
            let url = try #require(URL(string: address))
            let host = try #require(url.host())
            let icon = try #require(await Favicons.shared.icon(forHost: host), "no icon for \(name)")
            pins.append(Pin(id: UUID(), url: url, title: name, favicon: icon))
        }
        PinStore.save(pins)
        let browser = Browser()
        defer {
            browser.tabs.forEach { browser.close($0, remembering: false) }
            SessionStore.save(Session())
            PinStore.save([])
        }
        browser.commandWindow.regularTabs.forEach(browser.close)

        func opened(_ address: String, selecting: Bool = false) throws -> Lithium.Tab {
            let tab = browser.newTab(selecting: selecting)
            tab.load(try #require(URL(string: address)))
            return tab
        }
        let stops = try Self.trip.map { try opened($0) }
        let folder = browser.newFolder(with: stops[0])
        browser.renameFolder(folder.id, to: "Lisbon in May")
        stops.dropFirst().forEach { browser.moveTab($0, toFolder: folder.id) }
        let music = try opened(Self.album)
        let others = try Self.others.map { try opened($0) }
        let essay = try opened(Self.essay)
        let article = try opened(Self.article, selecting: true)

        let window = OffscreenWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1440, height: 900),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Said, not inherited: on a Mac in Dark Mode the light pictures would come out dark.
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(rootView: BrowserView().environment(browser).environment(browser.windows[0]))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        #expect(window.screen == nil, "the window must stay off screen")

        for tab in stops + others + [music, essay, article] { try await loaded(tab) }
        // Pictures, and what pages add once loaded.
        try await Task.sleep(for: .seconds(2))
        browser.nowPlaying.receive(try await song(playing: music), from: music)

        // An article, with the favorites, a folder of tabs and the player of the music tab.
        let first = try await picture(of: window)
        try save("window-light", first, isDark: false)
        try jpeg(try socialPreview(first)).write(to: directory.appending(path: "social-preview.jpg"))

        // An essay in the reader.
        browser.select(essay)
        #expect(await essay.toggleReader())
        try save("reader", try await picture(of: window), isDark: false)
        #expect(await essay.toggleReader())

        // Two tabs side by side: the essay and the documentation.
        browser.select(essay)
        browser.openInSplit(others[0])
        try save("split-view", try await picture(of: window), isDark: false)
        browser.exitSplit(of: essay)

        // At night, on a dark sidebar, with the badge of the app's own screenshots.
        defer { UserDefaults.standard.removeObject(forKey: Preference.sidebarColor) }
        UserDefaults.standard.set("#2B2D42", forKey: Preference.sidebarColor)
        window.appearance = NSAppearance(named: .darkAqua)
        browser.select(music)
        try save("window-dark", try await picture(of: window), isDark: true, badge: true)
    }

    /// A page that never paints anything fails the run: an empty one is a white sheet however long
    /// it is asked.
    @Test func aPageLeftBlankFailsTheRun() async throws {
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let window = OffscreenWindow(contentRect: NSRect(x: -30000, y: -30000, width: 320, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        defer { window.contentView = nil }
        page.loadHTMLString("<!doctype html><title>Nothing</title>", baseURL: nil)
        for _ in 0..<300 where page.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        await #expect(throws: BlankPage.self) { _ = try await painted(page) }
    }

    private struct BlankPage: Error {
        let host: String
    }

    /// Framed as the app frames its screenshots, at half the pixels (1632 wide is plenty for a
    /// README) and as a JPEG, a quarter of the PNG's weight with nothing to see of it at that size.
    private func save(_ name: String, _ window: CGImage, isDark: Bool, badge: Bool = false) throws {
        let image = try framed(window, isDark: isDark, badge: badge)
        try jpeg(try scaled(image, by: 0.5)).write(to: directory.appending(path: "\(name).jpg"))
    }

    /// The card GitHub shows where the repository's link is shared, 1280 by 640: the window on the
    /// gradient. Uploaded by hand in the repository's settings, which have no API for it.
    private func socialPreview(_ window: CGImage) throws -> CGImage {
        let size = CGSize(width: 1280, height: 640)
        let context = try #require(CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .high
        context.draw(try gradient(isDark: false), in: CGRect(origin: .zero, size: size))
        let height: CGFloat = 548
        let width = (height * CGFloat(window.width) / CGFloat(window.height)).rounded()
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: 36, color: CGColor(gray: 0, alpha: 0.3))
        context.draw(window, in: CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height))
        return try #require(context.makeImage())
    }

    // MARK: Invented content

    /// Waits for the page, its title and its icon: a tab drawn before them shows an address and a globe.
    private func loaded(_ tab: Lithium.Tab) async throws {
        for _ in 0..<1500 where tab.webView.isLoading || tab.webView.url == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!tab.webView.isLoading, "\(tab.url?.absoluteString ?? "a page") did not finish loading")
        for _ in 0..<250 where Favicons.shared.cached(host: tab.url?.host()) == nil { try await Task.sleep(for: .milliseconds(20)) }
        _ = try await tab.webView.evaluateJavaScript("document.body.offsetHeight")
    }

    /// What the album's page would report while its first track plays, read from the page: the
    /// track is never started, so nothing sounds while the pictures are drawn.
    private func song(playing tab: Lithium.Tab) async throws -> NowPlaying.Media {
        let read = """
        (() => {
          const album = JSON.parse(document.querySelector('script[type="application/ld+json"]').textContent);
          const track = album.track.itemListElement[0].item;
          const [, hours, minutes, seconds] = /P(\\d+)H(\\d+)M(\\d+)S/.exec(track.duration);
          return { title: track.name, artist: album.byArtist.name, cover: album.image, duration: hours * 3600 + minutes * 60 + +seconds };
        })()
        """
        let album = try #require(try await tab.webView.evaluateJavaScript(read) as? [String: Any])
        let cover = try await URLSession.shared.data(from: try #require((album["cover"] as? String).flatMap(URL.init(string:)))).0
        let duration = try #require(album["duration"] as? Double)
        let title = try #require(album["title"] as? String)
        let artist = try #require(album["artist"] as? String)
        return try #require(NowPlaying.Media(message: [
            "title": title, "artist": artist,
            "artwork": "data:image/jpeg;base64,\(cover.base64EncodedString())",
            // A rate close to none: the time shown is the same in every run.
            "paused": false, "audible": true, "time": (duration / 3).rounded(), "duration": duration, "rate": 0.000_001, "previous": true, "next": true,
        ], at: Date()))
    }

    // MARK: Drawing

    /// The window as it draws itself, then each page as WebKit draws it, laid over its place: a web
    /// view's pixels live in another process and `cacheDisplay` leaves them blank.
    private func picture(of window: NSWindow) async throws -> CGImage {
        // Pages lay out again after a resize or a change of appearance, and the sidebar animates.
        try await Task.sleep(for: .milliseconds(900))
        let frame = try #require(window.contentView?.superview)
        frame.layoutSubtreeIfNeeded()
        let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        for page in webViews(in: frame) where !page.isHiddenOrHasHiddenAncestor {
            let image = try await painted(page)
            var place = page.convert(page.bounds, to: frame)
            if frame.isFlipped { place.origin.y = frame.bounds.height - place.maxY }
            // Saved and restored on the bitmap's own context: the clip of one page must not stay for the next.
            NSGraphicsContext.current = context
            context.saveGraphicsState()
            NSBezierPath(roundedRect: place, xRadius: 9, yRadius: 9).addClip()
            image.draw(in: place)
            context.restoreGraphicsState()
        }
        // Off screen the window is never the one in front, and its three buttons draw as empty
        // rings: given the colors they have in a window being used.
        NSGraphicsContext.current = context
        for (kind, hex) in [(NSWindow.ButtonType.closeButton, "#FF5F57"), (.miniaturizeButton, "#FEBC2E"), (.zoomButton, "#28C840")] {
            guard let button = window.standardWindowButton(kind) else { continue }
            let place = button.convert(button.bounds, to: frame)
            let dot = NSBezierPath(ovalIn: NSRect(x: place.midX - 7, y: place.midY - 7, width: 14, height: 14))
            NSColor(Color(hex: hex)).setFill()
            dot.fill()
            NSColor.black.withAlphaComponent(0.12).setStroke()
            dot.lineWidth = 0.5
            dot.stroke()
        }
        return try rounded(try #require(bitmap.cgImage), radius: 16 * window.backingScaleFactor)
    }

    /// A window's corners: `cacheDisplay` draws the frame view square.
    private func rounded(_ image: CGImage, radius: CGFloat) throws -> CGImage {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
        context.draw(image, in: bounds)
        return try #require(context.makeImage())
    }

    private func scaled(_ image: CGImage, by factor: CGFloat) throws -> CGImage {
        let size = CGSize(width: (CGFloat(image.width) * factor).rounded(), height: (CGFloat(image.height) * factor).rounded())
        let context = try #require(CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return try #require(context.makeImage())
    }

    /// A page just put in the window answers its first snapshots with a blank sheet: asked again
    /// until it shows more than one color. One still blank after that fails the run, so a blank page
    /// never ends up in the README.
    private func painted(_ page: WKWebView) async throws -> NSImage {
        var image = try await page.takeSnapshot(configuration: nil)
        for _ in 0..<12 where isBlank(image) {
            try await Task.sleep(for: .milliseconds(250))
            image = try await page.takeSnapshot(configuration: nil)
        }
        guard !isBlank(image) else { throw BlankPage(host: page.url?.host() ?? "a page") }
        return image
    }

    private func isBlank(_ image: NSImage) -> Bool {
        guard let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil).map(NSBitmapImageRep.init(cgImage:)) else { return true }
        var colors: Set<[Int]> = []
        for x in stride(from: 8, to: bitmap.pixelsWide, by: max(bitmap.pixelsWide / 24, 1)) {
            for y in stride(from: 8, to: bitmap.pixelsHigh, by: max(bitmap.pixelsHigh / 24, 1)) {
                var pixel = [Int](repeating: 0, count: 4)
                bitmap.getPixel(&pixel, atX: x, y: y)
                colors.insert(pixel)
            }
        }
        return colors.count < 2
    }

    private func webViews(in view: NSView) -> [WKWebView] {
        if let page = view as? WKWebView { return [page] }
        return view.subviews.flatMap(webViews)
    }

    /// On Lithium's own gradient, with the shadow the app's screenshots have.
    private func framed(_ window: CGImage, isDark: Bool, badge: Bool) throws -> CGImage {
        let shot = Shot(content: .window(sidebarOpen: window, sidebarClosed: window), scale: 2, wallpaper: try gradient(isDark: isDark))
        return try #require(CaptureComposition.render(shot, CaptureStyle(backdrop: .wallpaper, showsBadge: badge, showsSidebar: true)))
    }

    /// The gradient of Lithium's start page.
    private func gradient(isDark: Bool) throws -> CGImage {
        let renderer = ImageRenderer(content: LithiumGradient().frame(width: 800, height: 520).environment(\.colorScheme, isDark ? .dark : .light))
        renderer.scale = 2
        return try #require(renderer.cgImage)
    }

    private func jpeg(_ image: CGImage) throws -> Data {
        try #require(NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.9]))
    }
}

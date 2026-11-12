import AppKit
import SwiftUI
import Testing
import WebKit
@testable import Lithium

/// The pictures of the README: Lithium's real window with an invented session, drawn off screen in
/// a throwaway home folder. Nothing comes from anyone's browsing, and every site, icon and song is
/// made up here or in `Fixtures/showcase`.
/// `LITHIUM_SHOWCASE_DIR=docs/images ./scripts/test --filter ShowcaseShots`
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: ProcessInfo.processInfo.environment["LITHIUM_SHOWCASE_DIR"] != nil && ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct ShowcaseShots {
    private let directory = URL(filePath: ProcessInfo.processInfo.environment["LITHIUM_SHOWCASE_DIR"] ?? "/tmp")

    /// An invented site: its host, the Phosphor glyph and colors of its icon.
    private struct Site {
        let host: String
        let title: String
        let glyph: String
        let colors: [String]

        var url: URL { URL(string: "https://\(host)/")! }

        static let mail = Site(host: "mail.example", title: "Inbox", glyph: "envelope-simple", colors: ["#4F8DF7", "#2B5FD9"])
        static let calendar = Site(host: "calendar.example", title: "Calendar", glyph: "calendar-blank", colors: ["#FF6B5E", "#E0423A"])
        static let tides = Site(host: "tides.example", title: "Harbor Lights · Tides", glyph: "waves", colors: ["#2FB8A6", "#126B78"])
        static let notes = Site(host: "notes.example", title: "Design notes", glyph: "notebook", colors: ["#FFC94A", "#F09A1A"])
        static let code = Site(host: "code.example", title: "Pull request 42 · orchard", glyph: "code", colors: ["#3A3F55", "#1E2133"])
        static let chat = Site(host: "chat.example", title: "Chat", glyph: "chats", colors: ["#48C774", "#1F9E57"])
        static let maps = Site(host: "maps.example", title: "Maps", glyph: "map-trifold", colors: ["#FF9F45", "#EC6B2D"])
        static let photos = Site(host: "photos.example", title: "Photos", glyph: "image", colors: ["#C86DD7", "#7A4BD6"])
        static let meridian = Site(host: "meridian.example", title: "The slow train to the coast", glyph: "compass", colors: ["#E0676A", "#7A3F8F"])
        static let rail = Site(host: "rail.example", title: "Night train timetable", glyph: "train-simple", colors: ["#5C6BC0", "#34408F"])
        static let stay = Site(host: "stay.example", title: "Harbor hotel, 2 nights", glyph: "house-line", colors: ["#26A69A", "#1B7F76"])
        static let weather = Site(host: "weather.example", title: "Weather · Coast", glyph: "cloud", colors: ["#64B5F6", "#3B82D6"])
        static let bakery = Site(host: "bakery.example", title: "Sourdough, step by step", glyph: "coffee", colors: ["#B9825A", "#7A4E2D"])

        static let reading = Site(host: "reading.example", title: "Reading list", glyph: "book-open", colors: ["#7C83F0", "#4A4FC4"])

        static let favorites = [mail, calendar, tides, notes, code, chat, maps, photos, reading]
        static let all = favorites + [meridian, rail, stay, weather, bakery]
    }

    @Test func pictures() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The badge of a screenshot draws the application's icon, and a test process has none.
        let appIcon = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Support/AppIcon.png").standardizedFileURL
        NSApplication.shared.applicationIconImage = try #require(NSImage(contentsOf: appIcon))
        Theme.registerFonts()
        try seedIcons()
        SessionStore.save(Session())
        PinStore.save(try Site.favorites.map { Pin(id: UUID(), url: $0.url, title: $0.title, favicon: try icon($0)) })
        let browser = Browser()
        defer {
            browser.tabs.forEach { browser.close($0, remembering: false) }
            SessionStore.save(Session())
            PinStore.save([])
        }
        browser.commandWindow.regularTabs.forEach(browser.close)

        func sleeping(_ site: Site) -> Lithium.Tab {
            let tab = browser.newTab(selecting: false)
            tab.restore(url: site.url, title: site.title)
            return tab
        }
        let trip = browser.newFolder(with: sleeping(.rail))
        browser.renameFolder(trip.id, to: "Trip to the coast")
        browser.moveTab(sleeping(.stay), toFolder: trip.id)
        browser.moveTab(sleeping(.weather), toFolder: trip.id)
        let music = browser.newTab(selecting: false)
        _ = sleeping(.bakery)
        _ = sleeping(.notes)
        let article = browser.newTab(selecting: true)

        let window = OffscreenWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1440, height: 900),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = NSHostingView(rootView: BrowserView().environment(browser).environment(browser.windows[0]))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        #expect(window.screen == nil, "the window must stay off screen")

        try await load("meridian", as: .meridian, in: article)
        try await load("tides", as: .tides, in: music)
        browser.nowPlaying.receive(try song(), from: music)

        // An article, with the favorites, a folder of tabs and the player of the music tab.
        let first = try await picture(of: window)
        try save("window-light", first, isDark: false)
        try jpeg(try socialPreview(first)).write(to: directory.appending(path: "social-preview.jpg"))

        // The same article in the reader.
        #expect(await article.toggleReader())
        try save("reader", try await picture(of: window), isDark: false)
        #expect(await article.toggleReader())

        // Two tabs side by side.
        browser.select(article)
        browser.openInSplit(music)
        try save("split-view", try await picture(of: window), isDark: false)
        browser.exitSplit(of: article)

        // The music tab at night, on a dark sidebar, with the badge of the app's own screenshots.
        defer { UserDefaults.standard.removeObject(forKey: Preference.sidebarColor) }
        UserDefaults.standard.set("#2B2D42", forKey: Preference.sidebarColor)
        window.appearance = NSAppearance(named: .darkAqua)
        browser.select(music)
        try save("window-dark", try await picture(of: window), isDark: true, badge: true)
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

    /// A site's icon: its glyph in white on a gradient tile, 64 pixels as `Favicons` keeps them.
    private func icon(_ site: Site) throws -> Data {
        let glyph = try #require(Resources.bundle.url(forResource: site.glyph, withExtension: "svg").flatMap(NSImage.init(contentsOf:)))
        glyph.isTemplate = true
        let tile = ZStack {
            LinearGradient(colors: site.colors.map { Color(hex: $0) }, startPoint: .top, endPoint: .bottom)
            Image(nsImage: glyph).resizable().renderingMode(.template).foregroundStyle(.white).frame(width: 20, height: 20)
        }
        .frame(width: 32, height: 32)
        let renderer = ImageRenderer(content: tile)
        renderer.scale = 2
        return try png(try #require(renderer.cgImage))
    }

    /// Where `Favicons` looks for a host's icon, so sleeping tabs show theirs without any request.
    private func seedIcons() throws {
        let folder = URL.applicationSupportDirectory.appending(path: "Lithium/Favicons")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for site in Site.all {
            try icon(site).write(to: folder.appending(path: "\(site.host).png"))
        }
    }

    /// What a page's Media Session would report, with a cover drawn here.
    private func song() throws -> NowPlaying.Media {
        let cover = ZStack {
            LinearGradient(colors: ["#0F2A44", "#1D5A73", "#F29E6B", "#FFD9A0"].map { Color(hex: $0) }, startPoint: .top, endPoint: .bottom)
            Circle().fill(Color(hex: "#FFE9C4")).frame(width: 44, height: 44).offset(y: 10)
            Rectangle().fill(Color(hex: "#0C2233").opacity(0.85)).frame(height: 44).offset(y: 38)
        }
        .frame(width: 120, height: 120)
        .clipped()
        let renderer = ImageRenderer(content: cover)
        renderer.scale = 2
        let art = try png(try #require(renderer.cgImage))
        return try #require(NowPlaying.Media(message: [
            "title": "Harbor Lights", "artist": "Paper Lanterns", "artwork": "data:image/png;base64,\(art.base64EncodedString())",
            // A rate close to none: the time shown is the same in every run.
            "paused": false, "audible": true, "time": 96, "duration": 252, "rate": 0.000_001, "previous": true, "next": true,
        ], at: Date()))
    }

    /// The fixture, as if `site` had served it: no request leaves, the address bar shows the site.
    private func load(_ fixture: String, as site: Site, in tab: Lithium.Tab) async throws {
        let file = try #require(Bundle.module.url(forResource: "Fixtures/showcase/\(fixture)", withExtension: "html"))
        let icon = "<link rel=\"icon\" href=\"data:image/png;base64,\(try icon(site).base64EncodedString())\">"
        let html = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "<title>", with: "\(icon)<title>")
        tab.webView.loadSimulatedRequest(URLRequest(url: site.url), responseHTML: html)
        for _ in 0..<500 where tab.webView.isLoading || tab.webView.url == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await tab.webView.evaluateJavaScript("document.body.offsetHeight")
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
    /// until it shows more than one color.
    private func painted(_ page: WKWebView) async throws -> NSImage {
        var image = try await page.takeSnapshot(configuration: nil)
        for _ in 0..<12 where isBlank(image) {
            try await Task.sleep(for: .milliseconds(250))
            image = try await page.takeSnapshot(configuration: nil)
        }
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

    private func png(_ image: CGImage) throws -> Data {
        try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }
}


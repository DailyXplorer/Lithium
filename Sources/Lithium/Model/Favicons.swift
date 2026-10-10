import AppKit
import ImageIO
import WebKit

/// Finds a site's icon and normalizes it to a 64 px PNG known to contain visible pixels.
/// Kept per host on disk, and in memory for the hosts last asked about.
@MainActor
final class Favicons {
    static let shared = Favicons()

    private var cache: [String: (data: Data, lastUse: Int)] = [:]
    private var uses = 0
    /// Hosts with no icon, not asked again this session.
    private(set) var missing: Set<String> = []
    /// Hosts whose open page was searched and has no icon. Apart from `missing`: history's lookup
    /// (no cookies, `https` only) fails for sites the page's own search finds an icon for.
    private(set) var iconless: Set<String> = []
    /// Hosts with no file kept: the address bar's rows ask at every keystroke, and would read the disk each time.
    private var unstored: Set<String> = []
    /// Decoded for those rows too, by host, with the bytes they came from.
    private var images: [String: (data: Data, image: NSImage)] = [:]
    private static let imagesLimit = 64
    /// Kept icons by the address they came from: pages of one host can name different icons
    /// (Docs, Sheets), so an open page is never given its host's icon blindly, nor refetches its own.
    private var byAddress: [URL: Data] = [:]
    private static let byAddressLimit = 256
    /// Addresses that answered with no icon (a 404, a login page): the `/favicon.ico` fallback ranks
    /// ahead of many declared icons, and would otherwise cost a request at each of the page's loads.
    /// Only the fetch skips them: the page may still draw one with its cookies.
    private var noIcon: Set<URL> = []
    private var inFlight: [String: Task<(png: Data?, allAnswered: Bool), Never>] = [:]
    /// When `refresh` last wrote each host's icon: an animated one changes every few seconds.
    private var refreshed: [String: ContinuousClock.Instant] = [:]
    private static let refreshStoreInterval = Duration.seconds(60)
    /// Raised by Clear History: a fetch that began before it must not store its host's icon again.
    private var generation = 0
    private let session: URLSession = {
        // A server that trickles its answer gives up the fetch long before the default week.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }()
    private let folder: URL
    private let cacheLimit: Int
    private let missingLimit: Int
    nonisolated private static let side = 64
    /// Icons are a few KB: a larger body is never one, and is not read past this.
    nonisolated static let largestIcon = 512 * 1024
    /// Past this many pixels an image is no icon, and decoding it would cost a lot of memory.
    nonisolated static let largestPixels = 4096 * 4096

    init(folder: URL = .applicationSupportDirectory.appending(path: "Lithium/Favicons"), cacheLimit: Int = 500, missingLimit: Int = 5000) {
        self.folder = folder
        self.cacheLimit = cacheLimit
        self.missingLimit = missingLimit
    }

    /// The title too: the tab may not have heard of it yet when its page finishes loading.
    private static let collectScript = """
        return { title: document.title, links: [...document.querySelectorAll('link[rel~="icon"], link[rel~="apple-touch-icon"], link[rel="apple-touch-icon-precomposed"]')]
            .map(link => [link.href, link.getAttribute('sizes') || '', link.rel, link.type || '']) };
        """

    /// The page's engine draws the icon: SVG favicons often style themselves with CSS, which AppKit
    /// ignores. In Lithium's isolated world, so the page's scripts (and our farbling) never touch it.
    private static let drawScript = """
        const image = new Image();
        image.crossOrigin = 'anonymous';
        image.src = href;
        await image.decode();
        const canvas = document.createElement('canvas');
        canvas.width = canvas.height = side;
        canvas.getContext('2d').drawImage(image, 0, 0, side, side);
        return canvas.toDataURL('image/png');
        """

    func cachedData(host: String) -> Data? {
        if let entry = cache[host] {
            uses += 1
            cache[host]?.lastUse = uses
            return entry.data
        }
        guard !unstored.contains(host) else { return nil }
        guard let data = try? Data(contentsOf: file(for: host)) else {
            if unstored.count >= missingLimit { unstored.removeAll(keepingCapacity: true) }
            unstored.insert(host)
            return nil
        }
        remember(data, for: host)
        return data
    }

    /// Drops the least recently used icon: a linear scan, but only on a miss over a few hundred entries.
    private func remember(_ data: Data, for host: String) {
        if cache[host] == nil, cache.count >= cacheLimit,
           let oldest = cache.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
            cache[oldest] = nil
        }
        uses += 1
        cache[host] = (data, uses)
    }

    func cached(host: String?) -> NSImage? {
        guard let host, let data = cachedData(host: host) else { return nil }
        if let entry = images[host], entry.data == data { return entry.image }
        guard let image = NSImage(data: data) else { return nil }
        if images.count >= Self.imagesLimit { images.removeAll(keepingCapacity: true) }
        images[host] = (data, image)
        return image
    }

    /// For pages not open in a tab (history): the stored icon, or one from well-known locations.
    /// The host is marked iconless only once every request got a real answer: a fetch that timed
    /// out or found no network leaves it to be asked again. `scheme` is for tests' local servers.
    func icon(forHost host: String, scheme: String = "https") async -> Data? {
        if let data = cachedData(host: host) { return data }
        guard !missing.contains(host), let site = URL(string: "\(scheme)://\(host)/") else { return nil }
        if let running = inFlight[host] { return await running.value.png }

        let generation = generation
        let session = session
        let task = Task<(png: Data?, allAnswered: Bool), Never> {
            var allAnswered = true
            var answered = false
            for path in ["/apple-touch-icon.png", "/favicon.ico", "/favicon.png"] {
                guard let url = URL(string: path, relativeTo: site) else { continue }
                if let png = await Self.fetch(url, with: session, answered: &answered) { return (png, true) }
                allAnswered = allAnswered && answered
            }
            // Some sites only declare their icons in the page, often on a CDN.
            guard let html = await Self.download(site, limit: 200_000, keepingPrefix: true, with: session, answered: &answered) else {
                return (nil, allAnswered && answered)
            }
            for url in Self.declaredIcons(in: String(decoding: html, as: UTF8.self), base: site) {
                if let png = await Self.fetch(url, with: session, answered: &answered) { return (png, true) }
                allAnswered = allAnswered && answered
            }
            return (nil, allAnswered)
        }
        inFlight[host] = task
        let result = await task.value
        // History was cleared meanwhile: `clear` already emptied `inFlight`, and the host is gone from the list.
        guard generation == self.generation else { return nil }
        inFlight[host] = nil
        if let png = result.png {
            store(png, for: host)
        } else if result.allAnswered {
            if missing.count >= missingLimit { missing.removeAll(keepingCapacity: true) }
            missing.insert(host)
        }
        return result.png
    }

    /// `<link rel="…icon…" href="…">` targets in a page, raster formats first.
    nonisolated static func declaredIcons(in html: String, base: URL) -> [URL] {
        let links = html.matches(of: /<link\b[^>]*>/.ignoresCase()).map { String($0.output) }
        let urls = links.compactMap { tag -> URL? in
            guard let rel = tag.firstMatch(of: /rel\s*=\s*["']([^"']+)["']/.ignoresCase())?.1,
                  rel.lowercased().contains("icon"),
                  let href = tag.firstMatch(of: /href\s*=\s*["']([^"']+)["']/.ignoresCase())?.1 else { return nil }
            return URL(string: String(href), relativeTo: base)?.absoluteURL
        }
        return urls.sorted { ($0.pathExtension.lowercased() == "svg" ? 1 : 0) < ($1.pathExtension.lowercased() == "svg" ? 1 : 0) }
    }

    private func file(for host: String) -> URL {
        let safe = host.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
        return folder.appending(path: "\(safe).png")
    }

    /// Clear History: kept icons would still list the hosts visited, so all go but `hosts`'
    /// (favorites, open tabs).
    func clear(keeping hosts: Set<String>) async {
        generation += 1
        for task in inFlight.values { task.cancel() }
        inFlight = [:]
        missing = []
        iconless = []
        refreshed = [:]
        byAddress = [:]
        noIcon = []
        cache = cache.filter { hosts.contains($0.key) }
        images = images.filter { hosts.contains($0.key) }
        let folder = folder
        let kept = Set(hosts.map { file(for: $0).lastPathComponent })
        await Task.detached(priority: .userInitiated) {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files where !kept.contains(file.lastPathComponent) { try? FileManager.default.removeItem(at: file) }
        }.value
    }

    /// `address` only for http(s): a `data:` icon costs no fetch, and its address may be large.
    private func store(_ png: Data, for host: String, from address: URL? = nil) {
        if let address, ["http", "https"].contains(address.scheme?.lowercased()) {
            if byAddress.count >= Self.byAddressLimit { byAddress.removeAll(keepingCapacity: true) }
            byAddress[address] = png
        }
        remember(png, for: host)
        missing.remove(host)
        iconless.remove(host)
        unstored.remove(host)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? png.write(to: file(for: host), options: .atomic)
    }

    /// With an unread count (in the title, or `counting` via `setAppBadge`) the touch icon comes first:
    /// sites draw the count into their favicon, never their touch icon. A favicon is then shown but
    /// not kept, as the count in it would stay. A site that has none isn't searched again this
    /// session: each of its pages would cost a script and every candidate's fetch.
    /// The page is always asked which icon it names, as pages of one host can name different ones;
    /// an icon already kept from that address is reused, not fetched again.
    func favicon(for webView: WKWebView, counting: Bool = false) async -> Data? {
        guard let page = webView.url, let host = page.host() else { return nil }
        guard !iconless.contains(host) else { return cachedData(host: host) }
        let generation = generation

        let found = (try? await webView.callAsyncJavaScript(Self.collectScript, contentWorld: .defaultClient)) as? [String: Any]
        // A page that can't be asked keeps its host's icon, as before.
        if found == nil, let cached = cachedData(host: host) { return cached }
        let links = found?["links"] as? [[String]] ?? []
        let preferringTouchIcon = counting || UnreadBadge.count(inTitle: found?["title"] as? String ?? "") != nil
        var candidates = links.compactMap { link -> Candidate? in
            guard link.count == 4, let url = URL(string: link[0]), Self.isFetchable(url) else { return nil }
            let isVector = link[3].contains("svg") || url.pathExtension.lowercased() == "svg"
            return Candidate(url: url, size: Self.size(sizes: link[1], rel: link[2]), isVector: isVector, isTouchIcon: link[2].contains("apple-touch-icon"))
        }
        if let fallback = URL(string: "/favicon.ico", relativeTo: page)?.absoluteURL {
            candidates.append(Candidate(url: fallback, size: 32, isVector: false, isTouchIcon: false))
        }

        let sorted = candidates.sorted(by: Candidate.preferred)
        var allAnswered = true
        for candidate in preferringTouchIcon ? sorted.filter(\.isTouchIcon) + sorted.filter { !$0.isTouchIcon } : sorted {
            // The tab moved on, and its next fetch took this one's place.
            if Task.isCancelled { return nil }
            if let kept = keptIcon(for: candidate, host: host, preferringTouchIcon: preferringTouchIcon) { return kept }
            guard !noIcon.contains(candidate.url) else { continue }
            var answered = false
            let png = await Self.fetch(candidate.url, with: session, answered: &answered)
            allAnswered = allAnswered && answered
            guard let png else {
                // `data:` icons cost no request, and their address may be large.
                if answered, generation == self.generation, ["http", "https"].contains(candidate.url.scheme?.lowercased()) {
                    if noIcon.count >= Self.byAddressLimit { noIcon.removeAll(keepingCapacity: true) }
                    noIcon.insert(candidate.url)
                }
                continue
            }
            if generation == self.generation, !preferringTouchIcon || candidate.isTouchIcon { store(png, for: host, from: candidate.url) }
            return png
        }

        for candidate in candidates {
            if Task.isCancelled { return nil }
            if let kept = keptIcon(for: candidate, host: host, preferringTouchIcon: preferringTouchIcon) { return kept }
            let page = webView as? PageWebView
            page?.iconsDrawn.insert(candidate.url)
            let result = try? await webView.callAsyncJavaScript(
                Self.drawScript, arguments: ["href": candidate.url.absoluteString, "side": Self.side], contentWorld: .defaultClient
            )
            page?.iconsDrawn.remove(candidate.url)
            guard let dataURL = result as? String,
                  let encoded = dataURL.split(separator: ",").last,
                  let data = Data(base64Encoded: String(encoded)),
                  let png = await Self.normalizedInBackground(data) else { continue }
            if generation == self.generation, !preferringTouchIcon || candidate.isTouchIcon { store(png, for: host, from: candidate.url) }
            return png
        }
        // Only once the page and every candidate's server answered and none had an icon: not for a
        // tab that moved on, nor a fetch that timed out or found no network.
        if found != nil, allAnswered, !Task.isCancelled, generation == self.generation {
            if iconless.count >= missingLimit { iconless.removeAll(keepingCapacity: true) }
            iconless.insert(host)
        }
        return nil
    }

    /// While the page counts, a favicon may have the count drawn in: the host's kept icon, clean,
    /// comes before it, as it did when every page of a host showed that one.
    private func keptIcon(for candidate: Candidate, host: String, preferringTouchIcon: Bool) -> Data? {
        if preferringTouchIcon, !candidate.isTouchIcon { return cachedData(host: host) }
        return byAddress[candidate.url]
    }

    /// Fetched past the cache: a calendar's icon changes with the date, even at the same address.
    /// Stored only when its pixels changed and `keeping` still holds once it came, and at most once
    /// a minute per host: an animated icon would rewrite the file every frame. Still returned, so
    /// the tile follows it.
    func refresh(host: String, from url: URL, keeping: () -> Bool = { true }) async -> Data? {
        let generation = generation
        guard Self.isFetchable(url), let png = await Self.fetch(url, with: session) else { return nil }
        let now = ContinuousClock.now
        if generation == self.generation, keeping(), cachedData(host: host) != png,
           refreshed[host].map({ now - $0 >= Self.refreshStoreInterval }) ?? true {
            refreshed[host] = now
            store(png, for: host)
        }
        return png
    }

    /// Never `file:` or another scheme that would have Lithium read something on the Mac for the page.
    nonisolated static func isFetchable(_ url: URL) -> Bool {
        ["http", "https", "data"].contains(url.scheme?.lowercased())
    }

    nonisolated static func fetch(_ url: URL, with session: URLSession) async -> Data? {
        var answered = false
        return await fetch(url, with: session, answered: &answered)
    }

    /// `answered` tells a real answer apart from a passing failure (offline, timed out, a server error),
    /// after which the site may still have an icon.
    nonisolated static func fetch(_ url: URL, with session: URLSession, answered: inout Bool) async -> Data? {
        guard isFetchable(url), let data = await download(url, limit: largestIcon, with: session, answered: &answered) else { return nil }
        return await normalizedInBackground(data)
    }

    nonisolated static func download(_ url: URL, limit: Int, keepingPrefix: Bool = false, with session: URLSession) async -> Data? {
        var answered = false
        return await download(url, limit: limit, keepingPrefix: keepingPrefix, with: session, answered: &answered)
    }

    /// Read as it comes and dropped (or cut) past `limit`, so a huge answer is never held whole in memory.
    nonisolated static func download(_ url: URL, limit: Int, keepingPrefix: Bool = false, with session: URLSession, answered: inout Bool) async -> Data? {
        answered = false
        guard let (bytes, response) = try? await session.bytes(from: url) else { return nil }
        defer { bytes.task.cancel() }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard status < 400 else {
            answered = status < 500
            return nil
        }
        if !keepingPrefix, response.expectedContentLength > limit {
            answered = true
            return nil
        }
        var data = Data()
        do {
            for try await byte in bytes {
                guard data.count < limit else {
                    answered = true
                    return keepingPrefix ? data : nil
                }
                data.append(byte)
            }
        } catch {
            return nil
        }
        answered = true
        return data
    }

    /// A large ICO or touch icon takes a few milliseconds to redraw: off the main thread.
    nonisolated private static func normalizedInBackground(_ data: Data) async -> Data? {
        await Task.detached(priority: .utility) { normalized(data) }.value
    }

    /// Redraws the icon at 64 px and rejects it when nothing visible was drawn.
    nonisolated static func normalized(_ data: Data) -> Data? {
        guard !isTooLarge(data), let image = NSImage(data: data), image.size.width > 0, image.size.height > 0,
              let bitmap = NSBitmapImageRep(
                  bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                  hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        guard let pixels = bitmap.bitmapData else { return nil }
        var visible = 0
        for index in stride(from: 3, to: side * side * 4, by: 4) where pixels[index] > 16 {
            visible += 1
        }
        guard visible > side * side / 50 else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// A small file can still declare a huge image (a PNG of one color compresses to almost
    /// nothing): the size each image in it declares is read before anything is decoded.
    nonisolated private static func isTooLarge(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return (0..<CGImageSourceGetCount(source)).contains { index in
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
            // In Double: a forged header's sizes would overflow an Int product.
            return Double(width) * Double(height) > Double(largestPixels)
        }
    }

    private struct Candidate {
        let url: URL
        let size: Int
        let isVector: Bool
        let isTouchIcon: Bool

        /// Raster icons first (AppKit draws them faithfully), closest to 64 px.
        static func preferred(_ a: Candidate, _ b: Candidate) -> Bool {
            if a.isVector != b.isVector { return !a.isVector }
            return abs(a.size - side) < abs(b.size - side)
        }
    }

    /// Page-written: only positive sizes up to `largestSide` count, so the distance to 64 px can't overflow.
    nonisolated static func size(sizes: String, rel: String) -> Int {
        if sizes.lowercased() == "any" { return 64 }
        let largest = sizes.split(separator: " ")
            .compactMap { $0.lowercased().split(separator: "x").first.flatMap { Int($0) } }
            .filter { $0 > 0 }
            .max()
        return largest.map { min($0, largestSide) } ?? (rel.contains("apple-touch-icon") ? 180 : 32)
    }

    nonisolated private static let largestSide = 4096
}

import AppKit
import ImageIO
import WebKit

/// Finds a site's icon and normalizes it to a 64 px PNG that is known to contain visible pixels.
/// Icons are kept per host on disk, so history and suggestions show them across launches, and in
/// memory for the hosts last asked about: the history page and suggestions go through thousands.
@MainActor
final class Favicons {
    static let shared = Favicons()

    private var cache: [String: (data: Data, lastUse: Int)] = [:]
    private var uses = 0
    /// Hosts with no icon, not asked again this session. Emptied past `missingLimit`: the
    /// history page goes through thousands of hosts.
    private(set) var missing: Set<String> = []
    private var inFlight: [String: Task<Data?, Never>] = [:]
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

    private static let collectScript = """
        return [...document.querySelectorAll('link[rel~="icon"], link[rel~="apple-touch-icon"], link[rel="apple-touch-icon-precomposed"]')]
            .map(link => [link.href, link.getAttribute('sizes') || '', link.rel, link.type || '']);
        """

    /// Lets the page's own engine draw an icon it references. SVG favicons often style
    /// themselves with CSS, which AppKit's SVG renderer ignores, leaving a blank image.
    /// Runs in Lithium's isolated world, so the page's scripts (and our farbling) never touch it.
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
        guard let data = try? Data(contentsOf: file(for: host)) else { return nil }
        remember(data, for: host)
        return data
    }

    /// Past the limit, drops only the least recently used icon. The scan is linear, but it only
    /// runs on a miss and the cache holds a few hundred entries.
    private func remember(_ data: Data, for host: String) {
        if cache[host] == nil, cache.count >= cacheLimit,
           let oldest = cache.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
            cache[oldest] = nil
        }
        uses += 1
        cache[host] = (data, uses)
    }

    func cached(host: String?) -> NSImage? {
        host.flatMap(cachedData(host:)).flatMap(NSImage.init(data:))
    }

    /// For pages not open in a tab (history): the stored icon, or one fetched from the site's
    /// well-known locations. Failures are remembered for the session to avoid refetching.
    func icon(forHost host: String) async -> Data? {
        if let data = cachedData(host: host) { return data }
        guard !missing.contains(host), let site = URL(string: "https://\(host)/") else { return nil }
        if let running = inFlight[host] { return await running.value }

        let session = session
        let task = Task<Data?, Never> {
            for path in ["/apple-touch-icon.png", "/favicon.ico", "/favicon.png"] {
                if let url = URL(string: path, relativeTo: site), let png = await Self.fetch(url, with: session) { return png }
            }
            // Some sites only declare their icons in the page, often on a CDN.
            guard let html = await Self.download(site, limit: 200_000, keepingPrefix: true, with: session) else { return nil }
            for url in Self.declaredIcons(in: String(decoding: html, as: UTF8.self), base: site) {
                if let png = await Self.fetch(url, with: session) { return png }
            }
            return nil
        }
        inFlight[host] = task
        let result = await task.value
        inFlight[host] = nil
        if let result {
            store(result, for: host)
        } else {
            if missing.count >= missingLimit { missing.removeAll(keepingCapacity: true) }
            missing.insert(host)
        }
        return result
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

    /// Clear History: the icon kept for every host visited would still list them, so they go too,
    /// but for `hosts` (favorites and open tabs, which show theirs). Files are removed off the main thread.
    func clear(keeping hosts: Set<String>) async {
        missing = []
        cache = cache.filter { hosts.contains($0.key) }
        let folder = folder
        let kept = Set(hosts.map { file(for: $0).lastPathComponent })
        await Task.detached(priority: .userInitiated) {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files where !kept.contains(file.lastPathComponent) { try? FileManager.default.removeItem(at: file) }
        }.value
    }

    private func store(_ png: Data, for host: String) {
        remember(png, for: host)
        missing.remove(host)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? png.write(to: file(for: host), options: .atomic)
    }

    func favicon(for webView: WKWebView) async -> Data? {
        guard let page = webView.url, let host = page.host() else { return nil }
        if let cached = cachedData(host: host) { return cached }

        let links = (try? await webView.callAsyncJavaScript(Self.collectScript, contentWorld: .defaultClient)) as? [[String]] ?? []
        var candidates = links.compactMap { link -> Candidate? in
            guard link.count == 4, let url = URL(string: link[0]), Self.isFetchable(url) else { return nil }
            let isVector = link[3].contains("svg") || url.pathExtension.lowercased() == "svg"
            return Candidate(url: url, size: Self.size(sizes: link[1], rel: link[2]), isVector: isVector)
        }
        if let fallback = URL(string: "/favicon.ico", relativeTo: page)?.absoluteURL {
            candidates.append(Candidate(url: fallback, size: 32, isVector: false))
        }

        for candidate in candidates.sorted(by: Candidate.preferred) {
            // The tab moved on, and its next fetch took this one's place.
            if Task.isCancelled { return nil }
            guard let png = await Self.fetch(candidate.url, with: session) else { continue }
            store(png, for: host)
            return png
        }

        for candidate in candidates {
            if Task.isCancelled { return nil }
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
            store(png, for: host)
            return png
        }
        return nil
    }

    /// The icon a page declares, fetched afresh past the cache: a calendar's changes with the
    /// date, at a new address or the same one. Stored for the host only when its pixels changed.
    func refresh(host: String, from url: URL) async -> Data? {
        guard Self.isFetchable(url), let png = await Self.fetch(url, with: session) else { return nil }
        if cachedData(host: host) != png { store(png, for: host) }
        return png
    }

    /// The addresses icons are fetched from, as a page's `<link>` names them: never `file:` or
    /// any other scheme that would have Lithium read something on the Mac for the page.
    nonisolated static func isFetchable(_ url: URL) -> Bool {
        ["http", "https", "data"].contains(url.scheme?.lowercased())
    }

    nonisolated static func fetch(_ url: URL, with session: URLSession) async -> Data? {
        guard isFetchable(url), let data = await download(url, limit: largestIcon, with: session) else { return nil }
        return await normalizedInBackground(data)
    }

    /// The body, read as it comes and dropped past `limit` (or cut there, for a page read only
    /// for its head), so a huge or endless answer is never held whole in Lithium's memory.
    nonisolated static func download(_ url: URL, limit: Int, keepingPrefix: Bool = false, with session: URLSession) async -> Data? {
        guard let (bytes, response) = try? await session.bytes(from: url),
              (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { return nil }
        defer { bytes.task.cancel() }
        if !keepingPrefix, response.expectedContentLength > limit { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                guard data.count < limit else { return keepingPrefix ? data : nil }
                data.append(byte)
            }
        } catch {
            return nil
        }
        return data
    }

    /// Decoding, redrawing and encoding a large ICO or touch icon takes a few milliseconds, so it
    /// runs off the main thread.
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

        /// Raster icons first (AppKit draws them faithfully), closest to 64 px.
        static func preferred(_ a: Candidate, _ b: Candidate) -> Bool {
            if a.isVector != b.isVector { return !a.isVector }
            return abs(a.size - side) < abs(b.size - side)
        }
    }

    /// The page writes `sizes`: a negative or huge value would overflow the distance to 64 px
    /// when candidates are sorted, so only positive sizes count, and none past `largestSide`.
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

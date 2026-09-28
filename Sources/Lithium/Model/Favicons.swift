import AppKit
import WebKit

/// Finds a site's icon and normalizes it to a 64 px PNG that is known to contain visible pixels.
/// Icons are kept per host in memory and on disk, so history and suggestions show them across launches.
@MainActor
final class Favicons {
    static let shared = Favicons()

    private var cache: [String: Data] = [:]
    private var missing: Set<String> = []
    private var inFlight: [String: Task<Data?, Never>] = [:]
    private let session = URLSession(configuration: .ephemeral)
    private let folder = URL.applicationSupportDirectory.appending(path: "Lithium/Favicons")
    nonisolated private static let side = 64

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
        if let data = cache[host] { return data }
        guard let data = try? Data(contentsOf: file(for: host)) else { return nil }
        cache[host] = data
        return data
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
            func fetchIcon(_ url: URL) async -> Data? {
                guard let (data, response) = try? await session.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { return nil }
                return await Self.normalizedInBackground(data)
            }
            for path in ["/apple-touch-icon.png", "/favicon.ico", "/favicon.png"] {
                if let url = URL(string: path, relativeTo: site), let png = await fetchIcon(url) { return png }
            }
            // Some sites only declare their icons in the page, often on a CDN.
            guard let (html, _) = try? await session.data(from: site) else { return nil }
            for url in Self.declaredIcons(in: String(decoding: html.prefix(200_000), as: UTF8.self), base: site) {
                if let png = await fetchIcon(url) { return png }
            }
            return nil
        }
        inFlight[host] = task
        let result = await task.value
        inFlight[host] = nil
        if let result { store(result, for: host) } else { missing.insert(host) }
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

    private func store(_ png: Data, for host: String) {
        cache[host] = png
        missing.remove(host)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? png.write(to: file(for: host), options: .atomic)
    }

    func favicon(for webView: WKWebView) async -> Data? {
        guard let page = webView.url, let host = page.host() else { return nil }
        if let cached = cachedData(host: host) { return cached }

        let links = (try? await webView.callAsyncJavaScript(Self.collectScript, contentWorld: .defaultClient)) as? [[String]] ?? []
        var candidates = links.compactMap { link -> Candidate? in
            guard link.count == 4, let url = URL(string: link[0]) else { return nil }
            let isVector = link[3].contains("svg") || url.pathExtension.lowercased() == "svg"
            return Candidate(url: url, size: Self.size(sizes: link[1], rel: link[2]), isVector: isVector)
        }
        if let fallback = URL(string: "/favicon.ico", relativeTo: page)?.absoluteURL {
            candidates.append(Candidate(url: fallback, size: 32, isVector: false))
        }

        for candidate in candidates.sorted(by: Candidate.preferred) {
            guard let (data, response) = try? await session.data(from: candidate.url),
                  (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
                  let png = await Self.normalizedInBackground(data) else { continue }
            store(png, for: host)
            return png
        }

        for candidate in candidates {
            let result = try? await webView.callAsyncJavaScript(
                Self.drawScript, arguments: ["href": candidate.url.absoluteString, "side": Self.side], contentWorld: .defaultClient
            )
            guard let dataURL = result as? String,
                  let encoded = dataURL.split(separator: ",").last,
                  let data = Data(base64Encoded: String(encoded)),
                  let png = await Self.normalizedInBackground(data) else { continue }
            store(png, for: host)
            return png
        }
        return nil
    }

    /// Decoding, redrawing and encoding a large ICO or touch icon takes a few milliseconds, so it
    /// runs off the main thread.
    nonisolated private static func normalizedInBackground(_ data: Data) async -> Data? {
        await Task.detached(priority: .utility) { normalized(data) }.value
    }

    /// Redraws the icon at 64 px and rejects it when nothing visible was drawn.
    nonisolated static func normalized(_ data: Data) -> Data? {
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0,
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

    private static func size(sizes: String, rel: String) -> Int {
        if sizes.lowercased() == "any" { return 64 }
        let largest = sizes.split(separator: " ")
            .compactMap { $0.lowercased().split(separator: "x").first.flatMap { Int($0) } }
            .max()
        return largest ?? (rel.contains("apple-touch-icon") ? 180 : 32)
    }
}

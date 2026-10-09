import AppKit
import WebKit

/// One frame's answer to `masks`: rects to paint over and where its frames sit, in its own viewport.
struct MaskReport: Decodable {
    let token: String
    var path: String?
    let viewport: PageViewport
    let rects: [[Double]]
    let frames: [FrameReport.Frame]
    var box: [Double]?
}

/// Where every frame of a page sits in the top-level viewport, from the frames' `masks` answers.
struct FrameLayout {
    struct Placement {
        var origin = CGPoint.zero
        var scale = 1.0
        var clip = CGRect.infinite

        func place(_ box: [Double]) -> CGRect {
            guard box.count >= 4 else { return .null }
            return CGRect(x: origin.x + box[0] * scale, y: origin.y + box[1] * scale, width: box[2] * scale, height: box[3] * scale)
        }
    }

    let main: MaskReport
    let children: [String: MaskReport]
    /// Frames in shadow roots (left out of `window.frames`) by parent path, and whether one had no path.
    private let unplaced: [String: Int]
    private let lost: Bool
    /// Payment providers' frames are painted over whole, whatever they show.
    private let providers: PaymentProviders

    init(main: MaskReport, children: [MaskReport], providers: PaymentProviders = .known) {
        self.main = main
        self.providers = providers
        var byPath: [String: MaskReport] = [:]
        var unplaced: [String: Int] = [:]
        var lost = false
        for child in children {
            guard let path = child.path else {
                lost = true
                continue
            }
            if path == "-1" || path.hasSuffix(".-1") {
                unplaced[path == "-1" ? "" : String(path.dropLast(3)), default: 0] += 1
            } else if byPath[path] == nil {
                byPath[path] = child
            }
        }
        self.children = byPath
        self.unplaced = unplaced
        self.lost = lost
    }

    /// In frame path order, not the dictionary's: two reads of an unchanged page then list the
    /// same masks in the same order, so they compare equal and `masking` pairs a field with itself.
    var reports: [MaskReport] { [main] + children.keys.sorted().map { children[$0]! } }

    /// Whether every frame `earlier` read sits at the same scroll here: masks read then still fit.
    func keepsScroll(of earlier: FrameLayout) -> Bool {
        let scrolls = Dictionary(reports.map { ($0.path ?? "", [$0.viewport.sx, $0.viewport.sy]) }) { first, _ in first }
        return earlier.reports.allSatisfy { scrolls[$0.path ?? ""] == [$0.viewport.sx, $0.viewport.sy] }
    }

    /// `path` is "" for the main frame, "0.2" for the third frame of the first.
    func placement(of path: String) -> Placement? {
        var placement = Placement()
        var report = main
        var prefix = ""
        for component in path.split(separator: ".") {
            guard let index = Int(component), let frame = report.frames.first(where: { $0.index == index }), frame.content.count == 5 else { return nil }
            let inner = placement.place(frame.content)
            placement = Placement(origin: inner.origin, scale: placement.scale * frame.content[4], clip: placement.clip.intersection(inner))
            prefix = prefix.isEmpty ? String(component) : "\(prefix).\(component)"
            guard let next = children[prefix] else { return nil }
            report = next
        }
        return placement
    }

    /// Inside a frame that answered nothing, and so painted over whole.
    private func isCovered(_ path: String) -> Bool {
        var report = main
        var prefix = ""
        for component in path.split(separator: ".") {
            guard let index = Int(component), report.frames.contains(where: { $0.index == index }) else { return false }
            prefix = prefix.isEmpty ? String(component) : "\(prefix).\(component)"
            guard let next = children[prefix] else { return true }
            report = next
        }
        return false
    }

    func placement(ofDocument token: String) -> Placement? {
        if token == main.token { return Placement() }
        guard let path = children.values.first(where: { $0.token == token })?.path else { return nil }
        return placement(of: path)
    }

    func box(of element: ElementAddress) -> [Double]? {
        reports.first { $0.token == element.document }?.box
    }

    /// Every rect to mask, in top-level CSS pixels; frames that didn't answer and payment frames are
    /// masked whole. Nil when a frame answered that can't be placed (shadow root, `<embed>`).
    var masks: [CGRect]? {
        if lost { return nil }
        var rects: [CGRect] = []
        for report in reports {
            let path = report.path ?? ""
            guard let placement = placement(of: path) else {
                if isCovered(path) { continue }
                return nil
            }
            if unplaced[path, default: 0] > report.frames.count(where: { $0.index < 0 }) { return nil }
            let unknown = report.frames.filter {
                $0.index < 0 || children[path.isEmpty ? "\($0.index)" : "\(path).\($0.index)"] == nil || providers.contains(address: $0.src)
            }
            rects += (report.rects + unknown.map(\.box)).map { placement.place($0).intersection(placement.clip) }
        }
        return (rects + alsoMasked).filter { !$0.isNull && !$0.isEmpty }
    }

    private var alsoMasked: [CGRect] = []

    /// Also paints over `later`'s masks: the picture was taken between the two reads, so a moving
    /// field may be anywhere between. The nth rects of each are unioned to cover its way.
    func masking(_ later: FrameLayout) -> FrameLayout {
        guard let own = masks else { return self }
        guard let other = later.masks else { return later }
        var both = self
        both.alsoMasked = other + (own.count == other.count ? zip(own, other).map { $0.union($1) } : [])
        return both
    }
}

/// Screenshots and PDFs of pages, with sensitive regions painted over.
@MainActor
enum AgentScreenshot {
    /// Neutral gray, so a masked field reads as covered rather than as an empty one.
    nonisolated static let maskColor = CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
    /// A full page longer than this many pixels is cut, and says so.
    nonisolated static let maxHeight = 16_384
    /// Pages longer than this (points) aren't flattened into a masked PDF.
    nonisolated static let maxPDFLength = 65_536.0
    nonisolated static let maxPDFPixelWidth = 4096.0

    /// Top-level CSS pixels to web view points: visual viewport offset and pinch scale, then pageZoom.
    static func viewRect(_ css: CGRect, viewport: PageViewport, zoom: Double) -> CGRect {
        let scale = viewport.vs * zoom
        return CGRect(x: (css.minX - viewport.vx) * scale, y: (css.minY - viewport.vy) * scale, width: css.width * scale, height: css.height * scale)
    }

    static func cgImage(_ image: NSImage) -> CGImage? {
        image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// `crop` and `masks` are in the image's pixels, before scaling to `maxWidth`.
    nonisolated static func render(_ image: CGImage, crop: CGRect? = nil, masks: [CGRect], maxWidth: Int) -> (image: CGImage, scale: Double, masks: [CGRect])? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let area = (crop ?? bounds).integral.intersection(bounds)
        guard !area.isEmpty else { return nil }
        let scale = min(1, Double(maxWidth) / area.width)
        let width = max(1, Int((area.width * scale).rounded()))
        let height = max(1, min(maxHeight, Int((area.height * scale).rounded())))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Image pixels run top down; the context's run bottom up.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -area.minX, y: -area.minY)
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: bounds)
        context.restoreGState()
        context.setFillColor(maskColor)
        var painted: [CGRect] = []
        for mask in masks {
            let visible = mask.intersection(area)
            guard !visible.isNull, !visible.isEmpty else { continue }
            context.fill(visible)
            painted.append(CGRect(x: (visible.minX - area.minX) * scale, y: (visible.minY - area.minY) * scale, width: visible.width * scale, height: visible.height * scale).integral)
        }
        guard let output = context.makeImage() else { return nil }
        return (output, scale, painted)
    }

    /// The part of a page's PDF in `area` (points from top left; nil for all) as an image, cut at
    /// `maxHeight` pixels. Only that part is drawn, so a far-down element needs no huge bitmap.
    nonisolated static func rasterize(_ data: Data, area: CGRect? = nil, scale: Double) -> (image: CGImage, area: CGRect, cut: Bool)? {
        guard let pdf = PagePDF(data) else { return nil }
        let rect = (area ?? CGRect(origin: .zero, size: pdf.size)).intersection(CGRect(origin: .zero, size: pdf.size))
        guard !rect.isNull, !rect.isEmpty else { return nil }
        let width = max(1, Int((rect.width * scale).rounded()))
        let full = Int((rect.height * scale).rounded())
        let height = max(1, min(full, maxHeight))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // The area's top goes to the image's top, also when the image is cut short.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -rect.minX, y: rect.minY)
        pdf.draw(in: context, from: rect.minY, to: rect.minY + Double(height) / scale)
        guard let image = context.makeImage() else { return nil }
        return (image, rect, full > height)
    }

    /// `rasterize` then `render`, off the main thread: a long page makes a large bitmap.
    nonisolated static func picture(ofPDF data: Data, area: CGRect?, scale: Double, masks: [CGRect], maxWidth: Int) async -> Picture? {
        await Task.detached(priority: .userInitiated) {
            guard let drawn = rasterize(data, area: area, scale: scale) else { return nil }
            let inPixels = masks.map { mask in
                CGRect(x: (mask.minX - drawn.area.minX) * scale, y: (mask.minY - drawn.area.minY) * scale, width: mask.width * scale, height: mask.height * scale)
            }
            guard let rendered = render(drawn.image, masks: inPixels, maxWidth: maxWidth) else { return nil }
            return Picture(image: rendered.image, scale: rendered.scale, masks: rendered.masks, cut: drawn.cut)
        }.value
    }

    /// `CGImage` is immutable, so handing it across threads is safe.
    struct Picture: @unchecked Sendable {
        let image: CGImage
        let scale: Double
        let masks: [CGRect]
        let cut: Bool
    }

    nonisolated static func pdfPageSize(_ data: Data) -> CGSize? {
        PagePDF(data)?.size
    }

    /// WebKit cuts a long page into several PDF pages (about 14,400 points each); this stacks them.
    private struct PagePDF {
        let document: CGPDFDocument
        let pages: [(page: CGPDFPage, box: CGRect, top: Double)]
        let size: CGSize

        init?(_ data: Data) {
            guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider), document.numberOfPages > 0 else { return nil }
            var pages: [(page: CGPDFPage, box: CGRect, top: Double)] = []
            var top = 0.0
            for index in 1...document.numberOfPages {
                guard let page = document.page(at: index) else { continue }
                let box = page.getBoxRect(.mediaBox)
                pages.append((page, box, top))
                top += box.height
            }
            guard let first = pages.first else { return nil }
            self.document = document
            self.pages = pages
            size = CGSize(width: first.box.width, height: top)
        }

        /// `context` is in points, y up, with the page's top left at the origin.
        func draw(in context: CGContext, from top: Double, to bottom: Double) {
            for (page, box, offset) in pages where offset < bottom && offset + box.height > top {
                context.saveGState()
                context.translateBy(x: -box.minX, y: -(box.maxY + offset))
                context.clip(to: box)
                context.drawPDFPage(page)
                context.restoreGState()
            }
        }
    }

    /// A page's PDF flattened to pixels with `masks` painted over: text under a mask would still be
    /// in a vector PDF. Sliced into pages of up to `slice` points to bound each bitmap.
    nonisolated static func maskedPDF(_ data: Data, masks: [CGRect], scale: Double = 2, slice: Double = 2048) -> (data: Data, pages: Int)? {
        guard let page = PagePDF(data) else { return nil }
        let box = CGRect(origin: .zero, size: page.size)
        let scale = min(scale, maxPDFPixelWidth / max(1, box.width))
        let output = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: box.width, height: min(box.height, slice))
        guard let consumer = CGDataConsumer(data: output), let pdf = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        var top = 0.0
        var pages = 0
        while top < box.height {
            let height = min(slice, box.height - top)
            let width = max(1, Int((box.width * scale).rounded()))
            guard let bitmap = CGContext(data: nil, width: width, height: max(1, Int((height * scale).rounded())), bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            bitmap.setFillColor(.white)
            bitmap.fill(CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
            // PDF space runs bottom up: the slice's bottom edge goes to the bitmap's.
            bitmap.scaleBy(x: scale, y: scale)
            bitmap.translateBy(x: 0, y: top + height)
            page.draw(in: bitmap, from: top, to: top + height)
            bitmap.setFillColor(maskColor)
            for mask in masks {
                bitmap.fill(CGRect(x: mask.minX, y: -mask.maxY, width: mask.width, height: mask.height))
            }
            guard let image = bitmap.makeImage() else { return nil }
            var bounds = CGRect(x: 0, y: 0, width: box.width, height: height)
            let pageBox = Data(bytes: &bounds, count: MemoryLayout<CGRect>.size)
            pdf.beginPDFPage([kCGPDFContextMediaBox as String: pageBox] as CFDictionary)
            pdf.draw(image, in: bounds)
            pdf.endPDFPage()
            top += height
            pages += 1
        }
        pdf.closePDF()
        return (output as Data, pages)
    }

    static func encode(_ image: CGImage, jpeg: Bool) async -> Data? {
        let box = UncheckedImage(image: image)
        return await Task.detached(priority: .userInitiated) {
            let rep = NSBitmapImageRep(cgImage: box.image)
            return rep.representation(using: jpeg ? .jpeg : .png, properties: jpeg ? [.compressionFactor: 0.8] : [:])
        }.value
    }

    /// `CGImage` is immutable, so handing it to the encoder's thread is safe.
    private struct UncheckedImage: @unchecked Sendable {
        let image: CGImage
    }
}

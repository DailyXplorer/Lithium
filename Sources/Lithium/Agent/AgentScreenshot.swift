import AppKit
import WebKit

/// One frame's answer to `masks`: rects to paint over (fields that were ever passwords, card
/// fields, extension UI), and where its frames sit, in its own viewport.
struct MaskReport: Decodable {
    let token: String
    var path: String?
    let viewport: PageViewport
    let rects: [[Double]]
    let frames: [FrameReport.Frame]
    /// The box of the element the layout was read for, from the frame it is in.
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
    /// Child frames that answered from a frame in a shadow root, which `window.frames` leaves
    /// out, by the path of the frame they are in; and whether one answered with no path at all.
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

    var reports: [MaskReport] { [main] + children.values }

    /// Whether every frame `earlier` read sits at the same scroll here: masks read then still fit.
    func keepsScroll(of earlier: FrameLayout) -> Bool {
        let scrolls = Dictionary(reports.map { ($0.path ?? "", [$0.viewport.sx, $0.viewport.sy]) }) { first, _ in first }
        return earlier.reports.allSatisfy { scrolls[$0.path ?? ""] == [$0.viewport.sx, $0.viewport.sy] }
    }

    /// The placement of the frame at `path` ("" for the main frame, "0.2" for the third frame of
    /// the first), composed down the content boxes of the frames above it; nil once one is gone.
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

    /// Whether the frame at `path` lies inside a frame on its way down that answered nothing, and
    /// so is painted over whole.
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

    /// The box, in its own frame's viewport, of the element this layout was read for; nil once it is gone.
    func box(of element: ElementAddress) -> [Double]? {
        reports.first { $0.token == element.document }?.box
    }

    /// Every rect to mask, in top-level viewport CSS pixels: the sensitive fields of the frames
    /// that answered, and the whole box of every payment provider's frame and of every frame that
    /// didn't answer (no hello: open before agent access was on; or too slow), since Lithium can't
    /// see what is in it. Nil when a frame
    /// answered that Lithium can't place (in a shadow root, an `<embed>`), so it can't tell where to paint.
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

    /// Rects painted over besides this read's own: another read's, taken around the same picture.
    private var alsoMasked: [CGRect] = []

    /// This layout painting over `later`'s masks too, a later read of the same scroll whose
    /// fields moved, showed or went: the picture was taken between the two, so a field was at
    /// one place, the other, or on its way. Read in document order, the nth rect of each is
    /// most likely one field, and the box spanning both covers its way.
    func masking(_ later: FrameLayout) -> FrameLayout {
        // Either one that can't place its masks is refused as such.
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
    static let maskColor = CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
    /// A full page longer than this many pixels is cut, and says so.
    static let maxHeight = 16_384

    /// Top-level viewport CSS pixels to the web view's points: the visual viewport's offset and
    /// scale (pinch magnification), then pageZoom. Verified at pageZoom 1.5 and magnification 2.
    static func viewRect(_ css: CGRect, viewport: PageViewport, zoom: Double) -> CGRect {
        let scale = viewport.vs * zoom
        return CGRect(x: (css.minX - viewport.vx) * scale, y: (css.minY - viewport.vy) * scale, width: css.width * scale, height: css.height * scale)
    }

    static func cgImage(_ image: NSImage) -> CGImage? {
        image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// The image redrawn at most `maxWidth` pixels wide, cropped to `crop` (in its pixels) when
    /// given, with `masks` (in its pixels, before scaling) painted over.
    static func render(_ image: CGImage, crop: CGRect? = nil, masks: [CGRect], maxWidth: Int) -> (image: CGImage, scale: Double, masks: [CGRect])? {
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

    /// The first page of a PDF as an image, `scale` pixels per PDF point, white behind.
    static func rasterize(_ data: Data, scale: Double) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider), let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        let width = max(1, Int((box.width * scale).rounded()))
        let height = max(1, min(Int((box.height * scale).rounded()), Int(Double(maxHeight) * 2)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // The page's top goes to the image's top, also when the image is cut short.
        context.translateBy(x: 0, y: CGFloat(height) - box.height * scale)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        return context.makeImage()
    }

    static func pdfPageSize(_ data: Data) -> CGSize? {
        guard let provider = CGDataProvider(data: data as CFData), let page = CGPDFDocument(provider)?.page(at: 1) else { return nil }
        return page.getBoxRect(.mediaBox).size
    }

    /// The first page of a PDF as pixels, `scale` per point, with `masks` (in points from the
    /// page's top left) painted over: a page with masked regions goes out as pixels, since text
    /// drawn under a mask would still be in the PDF. Cut into pages of up to `slice` points, so
    /// a page of any length keeps its proportions and its end within a bitmap's size.
    static func maskedPDF(_ data: Data, masks: [CGRect], scale: Double = 2, slice: Double = 2048) -> (data: Data, pages: Int)? {
        guard let provider = CGDataProvider(data: data as CFData), let page = CGPDFDocument(provider)?.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
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
            bitmap.translateBy(x: -box.minX, y: -(box.minY + box.height - top - height))
            bitmap.drawPDFPage(page)
            bitmap.setFillColor(maskColor)
            for mask in masks {
                bitmap.fill(CGRect(x: box.minX + mask.minX, y: box.minY + box.height - mask.maxY, width: mask.width, height: mask.height))
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

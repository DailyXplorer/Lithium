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

    init(main: MaskReport, children: [MaskReport]) {
        self.main = main
        var byPath: [String: MaskReport] = [:]
        for child in children {
            if let path = child.path, byPath[path] == nil { byPath[path] = child }
        }
        self.children = byPath
    }

    var reports: [MaskReport] { [main] + children.values }

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

    func placement(ofDocument token: String) -> Placement? {
        if token == main.token { return Placement() }
        guard let path = children.values.first(where: { $0.token == token })?.path else { return nil }
        return placement(of: path)
    }

    /// Every rect to mask, in top-level viewport CSS pixels.
    var masks: [CGRect] {
        reports.flatMap { report -> [CGRect] in
            guard let placement = placement(of: report.path ?? "") else { return [] }
            return report.rects.map { placement.place($0).intersection(placement.clip) }.filter { !$0.isNull && !$0.isEmpty }
        }
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

    /// A PDF of one page holding `image`, `size` points large: a page with masked regions goes
    /// out as pixels, since text drawn under a mask would still be in the PDF.
    static func pdf(of image: CGImage, size: CGSize) -> Data? {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        context.beginPDFPage(nil)
        context.draw(image, in: box)
        context.endPDFPage()
        context.closePDF()
        return data as Data
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

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// A black-on-white QR code, drawn module by module so its edges stay sharp at any size.
enum QRCode {
    /// The white margin around the code, in modules, that scanners need to find it.
    static let quietZone = 4

    /// `scale` pixels per module; nil for text too long for a QR code.
    static func image(for text: String, scale: Int = 8) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let modules = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        let side = (modules.width + 2 * quietZone) * scale
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .none
        let margin = quietZone * scale
        context.draw(modules, in: CGRect(x: margin, y: margin, width: modules.width * scale, height: modules.height * scale))
        return context.makeImage()
    }

    static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// "example.com QR code.png", for the save panel.
    static func fileName(for url: URL) -> String {
        "\(url.host(percentEncoded: false) ?? "Page") QR code.png"
    }
}

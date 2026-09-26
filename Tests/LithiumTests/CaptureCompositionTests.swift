import AppKit
import Testing
@testable import Lithium

@MainActor
struct CaptureCompositionTests {
    /// 100 × 50 points of one color at 2×.
    private static func image(red: CGFloat, blue: CGFloat) -> CGImage {
        let context = CGContext(
            data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: red, green: 0, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        return context.makeImage()!
    }

    private static let shot = Shot(content: .area(image(red: 1, blue: 0)), scale: 2, wallpaper: nil)

    private func hex(_ image: CGImage, x: Int, y: Int) -> String {
        var pixel = [Int](repeating: 0, count: 4)
        NSBitmapImageRep(cgImage: image).getPixel(&pixel, atX: x, y: y)
        return "#" + pixel.prefix(3).map { String(format: "%02X", $0) }.joined()
    }

    @Test func noBackgroundExportsTheBarePixels() throws {
        let image = try #require(CaptureComposition.render(Self.shot, CaptureStyle(backdrop: .none, showsBadge: true)))
        #expect(image.width == 200)
        #expect(image.height == 100)
        #expect(hex(image, x: 0, y: 0) == "#FF0000")
    }

    @Test func colorBackdropFramesTheShot() throws {
        let style = CaptureStyle(backdrop: .color("#1D1D1F"), showsBadge: false)
        let image = try #require(CaptureComposition.render(Self.shot, style))
        #expect(image.width == 328)
        #expect(image.height == 228)
        #expect(hex(image, x: 2, y: 2) == "#1D1D1F")
        #expect(hex(image, x: 164, y: 114) == "#FF0000")
    }

    @Test func windowShowsTheChosenSidebarLook() throws {
        let window = Shot(
            content: .window(sidebarOpen: Self.image(red: 1, blue: 0), sidebarClosed: Self.image(red: 0, blue: 1)),
            scale: 2, wallpaper: nil
        )
        let open = try #require(CaptureComposition.render(window, CaptureStyle(backdrop: .none, showsBadge: false, showsSidebar: true)))
        let closed = try #require(CaptureComposition.render(window, CaptureStyle(backdrop: .none, showsBadge: false, showsSidebar: false)))
        #expect(hex(open, x: 100, y: 50) == "#FF0000")
        #expect(hex(closed, x: 100, y: 50) == "#0000FF")
    }

    @Test func backdropSurvivesStorage() {
        #expect(CaptureBackdrop(rawValue: "wallpaper") == .wallpaper)
        #expect(CaptureBackdrop(rawValue: "none") == CaptureBackdrop.none)
        #expect(CaptureBackdrop(rawValue: "#CDE7D6") == .color("#CDE7D6"))
        #expect(CaptureBackdrop.color("#CDE7D6").rawValue == "#CDE7D6")
    }
}

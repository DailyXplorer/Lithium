import AppKit
import Testing
@testable import Lithium

@MainActor
struct CaptureCompositionTests {
    /// 100 × 50 points of one color at 2×.
    private static func image(red: CGFloat, blue: CGFloat, green: CGFloat = 0) -> CGImage {
        let context = CGContext(
            data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
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

    @Test func marksAreDrawnOnTheScreenshot() throws {
        let frame = Annotation(tool: .rectangle, colorHex: "#00FF00", lineWidth: 4, points: [CGPoint(x: 20, y: 10), CGPoint(x: 80, y: 40)])
        let bare = try #require(CaptureComposition.render(Self.shot, CaptureStyle(backdrop: .none, showsBadge: false, annotations: [frame])))
        #expect(hex(bare, x: 40, y: 50) == "#00FF00")
        #expect(hex(bare, x: 100, y: 50) == "#FF0000")

        // On a backdrop the marks move with the screenshot, 32 points in.
        let framed = try #require(CaptureComposition.render(Self.shot, CaptureStyle(backdrop: .color("#FFFFFF"), showsBadge: false, annotations: [frame])))
        #expect(hex(framed, x: 64 + 40, y: 64 + 50) == "#00FF00")
        #expect(hex(framed, x: 64 + 100, y: 64 + 50) == "#FF0000")
    }

    @Test func marksReachOntoTheBackdrop() throws {
        // Its left side is 20 points left of the screenshot, over the backdrop's 32-point margin.
        let frame = Annotation(tool: .rectangle, colorHex: "#00FF00", lineWidth: 4, points: [CGPoint(x: -20, y: -10), CGPoint(x: 50, y: 40)])
        let framed = try #require(CaptureComposition.render(Self.shot, CaptureStyle(backdrop: .color("#FFFFFF"), showsBadge: false, annotations: [frame])))
        #expect(hex(framed, x: 2 * 12, y: 2 * (32 + 20)) == "#00FF00")
        #expect(hex(framed, x: 2 * 4, y: 2 * (32 + 20)) == "#FFFFFF")
    }

    @Test func marksStayOnANarrowShotWidenedByTheBadge() throws {
        // 20 × 20 points at 2×: the badge is wider than the shot and its margins, which widens the image.
        let context = CGContext(
            data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        let narrow = Shot(content: .area(context.makeImage()!), scale: 2, wallpaper: nil)
        let dot = Annotation(tool: .pen, colorHex: "#00FF00", lineWidth: 6, points: [CGPoint(x: 10, y: 10)])
        let image = try #require(CaptureComposition.render(narrow, CaptureStyle(backdrop: .color("#FFFFFF"), showsBadge: true, annotations: [dot])))
        #expect(image.width > 2 * (20 + 2 * 32))
        #expect(hex(image, x: image.width / 2, y: image.height / 2) == "#00FF00")
    }

    @Test func highlightsKeepDarkPixelsDark() throws {
        let black = Shot(content: .area(Self.image(red: 0, blue: 0)), scale: 2, wallpaper: nil)
        let highlight = Annotation(tool: .highlighter, colorHex: Annotation.highlightHex, lineWidth: 16, points: [CGPoint(x: 10, y: 25), CGPoint(x: 90, y: 25)])
        let image = try #require(CaptureComposition.render(black, CaptureStyle(backdrop: .none, showsBadge: false, annotations: [highlight])))
        #expect(hex(image, x: 100, y: 50) == "#000000")
    }

    @Test func highlightsLookAsTheyDidWhileDrawn() throws {
        // The preview window showed #FFFF72 under a highlight being drawn over white, captured on a Display P3 screen.
        let white = Shot(content: .area(Self.image(red: 1, blue: 1, green: 1)), scale: 2, wallpaper: nil)
        let highlight = Annotation(tool: .highlighter, colorHex: Annotation.highlightHex, lineWidth: 16, points: [CGPoint(x: 10, y: 10), CGPoint(x: 90, y: 10)])
        let image = try #require(CaptureComposition.render(white, CaptureStyle(backdrop: .none, showsBadge: false, annotations: [highlight])))
        #expect(hex(image, x: 100, y: 20) == "#FFFF73")
        #expect(hex(image, x: 100, y: 80) == "#FFFFFF")
    }

    @Test func cornersResizeShapes() {
        var box = Annotation(tool: .rectangle, colorHex: "#FF3B30", lineWidth: 3, points: [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 30)])
        #expect(box.handles.map(\.1) == [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 10), CGPoint(x: 50, y: 30), CGPoint(x: 10, y: 30)])

        box.drag(.corner(x: 1, y: 0), to: CGPoint(x: 70, y: 0), constrained: false)
        #expect(box.points == [CGPoint(x: 10, y: 0), CGPoint(x: 70, y: 30)])

        // Shift keeps it square around the opposite corner, the bottom left one.
        box.drag(.corner(x: 1, y: 0), to: CGPoint(x: 60, y: 10), constrained: true)
        #expect(box.points == [CGPoint(x: 10, y: -20), CGPoint(x: 60, y: 30)])
    }

    @Test func shapesMoveWhole() {
        var arrow = Annotation(tool: .arrow, colorHex: "#FF3B30", lineWidth: 4, points: [.zero, CGPoint(x: 40, y: 0)])
        arrow.drag(.bend, to: CGPoint(x: 20, y: 15), constrained: false)
        arrow.move(by: CGSize(width: 5, height: -5))
        #expect(arrow.points == [CGPoint(x: 5, y: -5), CGPoint(x: 45, y: -5)])
        #expect(arrow.handles.first?.1 == CGPoint(x: 25, y: 10))
    }

    @Test func arrowsBendThroughTheirMiddleHandle() throws {
        var arrow = Annotation(tool: .arrow, colorHex: "#00FF00", lineWidth: 4, points: [CGPoint(x: 10, y: 10), CGPoint(x: 90, y: 10)])
        arrow.drag(.bend, to: CGPoint(x: 50, y: 40), constrained: false)
        #expect(arrow.handles.map(\.0) == [.bend, .corner(x: 0, y: 0), .corner(x: 1, y: 1)])

        let image = try #require(CaptureComposition.render(Self.shot, CaptureStyle(backdrop: .none, showsBadge: false, annotations: [arrow])))
        #expect(hex(image, x: 100, y: 80) == "#00FF00")
        #expect(hex(image, x: 100, y: 20) == "#FF0000")

        // Moving an end keeps the bend.
        arrow.drag(.corner(x: 1, y: 1), to: CGPoint(x: 90, y: 30), constrained: false)
        #expect(arrow.handles.first?.1 == CGPoint(x: 50, y: 50))
    }

    @Test func shiftSquaresShapesAndStraightensArrows() {
        var square = Annotation(tool: .rectangle, colorHex: "#FF3B30", lineWidth: 3, points: [.zero])
        square.extend(to: CGPoint(x: 40, y: -10), constrained: true)
        #expect(square.points == [.zero, CGPoint(x: 40, y: -40)])

        var arrow = Annotation(tool: .arrow, colorHex: "#FF3B30", lineWidth: 4, points: [.zero])
        arrow.extend(to: CGPoint(x: 50, y: 3), constrained: true)
        #expect(arrow.points.count == 2)
        #expect(abs(arrow.points[1].y) < 0.001)
        #expect(abs(arrow.points[1].x - hypot(50, 3)) < 0.001)
    }

    @Test func shiftMidStrokeKeepsTheCurveDrawnSoFar() {
        var line = Annotation(tool: .pen, colorHex: "#FF3B30", lineWidth: 3, points: [.zero])
        line.extend(to: CGPoint(x: 10, y: 5), constrained: false)
        line.extend(to: CGPoint(x: 20, y: 0), constrained: false)
        line.extend(to: CGPoint(x: 40, y: 2), constrained: true)
        line.extend(to: CGPoint(x: 60, y: 3), constrained: true)
        #expect(line.points == [.zero, CGPoint(x: 10, y: 5), CGPoint(x: 20, y: 0), CGPoint(x: 20 + hypot(CGFloat(40), 3), y: 0)])

        // Letting go of Shift goes on from the end of the straight segment.
        line.extend(to: CGPoint(x: 70, y: 10), constrained: false)
        #expect(line.points.count == 5)
        #expect(line.points[2] == CGPoint(x: 20, y: 0))
    }

    @Test func clicksLeaveDotsButNoShapes() {
        var dot = Annotation(tool: .pen, colorHex: "#FF3B30", lineWidth: 3, points: [CGPoint(x: 5, y: 5)])
        dot.extend(to: CGPoint(x: 5, y: 5), constrained: false)
        #expect(dot.points.count == 1)
        #expect(dot.isVisible)

        var box = Annotation(tool: .rectangle, colorHex: "#FF3B30", lineWidth: 3, points: [.zero])
        box.extend(to: CGPoint(x: 2, y: 2), constrained: false)
        #expect(!box.isVisible)
    }

    @Test func backdropSurvivesStorage() {
        #expect(CaptureBackdrop(rawValue: "wallpaper") == .wallpaper)
        #expect(CaptureBackdrop(rawValue: "none") == CaptureBackdrop.none)
        #expect(CaptureBackdrop(rawValue: "#CDE7D6") == .color("#CDE7D6"))
        #expect(CaptureBackdrop.color("#CDE7D6").rawValue == "#CDE7D6")
    }
}

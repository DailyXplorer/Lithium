import SwiftUI

/// The drawing tools of the screenshot preview.
enum AnnotationTool: String, CaseIterable, Identifiable {
    case pen, highlighter, arrow, rectangle, ellipse

    var id: Self { self }

    var label: String {
        switch self {
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        }
    }

    var icon: Phosphor {
        switch self {
        case .pen: .pen
        case .highlighter: .highlighter
        case .arrow: .arrow
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .pen: "p"
        case .highlighter: "h"
        case .arrow: "a"
        case .rectangle: "r"
        case .ellipse: "o"
        }
    }

    /// Keeps every point of the drag, rather than only where it started and ended.
    var isFreehand: Bool { self == .pen || self == .highlighter }

    /// Line width in points as seen in the preview; the mark is drawn that thick whatever the screenshot's size.
    var lineWidth: CGFloat {
        switch self {
        case .pen, .rectangle, .ellipse: 3
        case .arrow: 4
        case .highlighter: 16
        }
    }
}

/// A mark drawn over a screenshot, in the screenshot's points (top-left origin).
struct Annotation: Equatable {
    let tool: AnnotationTool
    let colorHex: String
    let lineWidth: CGFloat
    var points: [CGPoint]

    /// Adds where the drag is now. With `constrained` (Shift held), lines and arrows snap to
    /// multiples of 45° and shapes become squares and circles.
    mutating func extend(to point: CGPoint, constrained: Bool) {
        guard let start = points.first else {
            points = [point]
            return
        }
        if tool.isFreehand && !constrained {
            if let last = points.last, hypot(point.x - last.x, point.y - last.y) < lineWidth / 8 { return }
            points.append(point)
            return
        }
        var end = point
        if constrained {
            let dx = point.x - start.x, dy = point.y - start.y
            switch tool {
            case .rectangle, .ellipse:
                let side = max(abs(dx), abs(dy))
                end = CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
            case .pen, .highlighter, .arrow:
                let step = CGFloat.pi / 4
                let angle = (atan2(dy, dx) / step).rounded() * step
                let length = hypot(dx, dy)
                end = CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
            }
        }
        points = [start, end]
    }

    /// A click with a freehand tool leaves a dot; shapes and arrows need some size to be kept.
    var isVisible: Bool {
        guard let start = points.first, let end = points.last else { return false }
        return tool.isFreehand || hypot(end.x - start.x, end.y - start.y) >= lineWidth * 2
    }

    var path: Path {
        guard let start = points.first, let end = points.last else { return Path() }
        switch tool {
        case .pen, .highlighter: return Self.smoothLine(through: points)
        case .arrow: return Self.arrow(from: start, to: end, width: lineWidth)
        case .rectangle: return Path(Self.rect(start, end))
        case .ellipse: return Path(ellipseIn: Self.rect(start, end))
        }
    }

    func draw(in context: GraphicsContext) {
        var context = context
        let color = Color(hex: colorHex)
        let stroke = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        switch tool {
        case .arrow:
            // A thin outline in the same color rounds the arrow's corners.
            context.fill(path, with: .color(color))
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth / 2, lineJoin: .round))
        case .highlighter:
            context.opacity = 0.55
            context.stroke(path, with: .color(color), style: stroke)
        case .pen, .rectangle, .ellipse:
            context.stroke(path, with: .color(color), style: stroke)
        }
    }

    private static func rect(_ start: CGPoint, _ end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    /// Curves through the midpoints between the points, so a hand-drawn line has no corners.
    /// A single point makes a zero-length line, which round caps draw as a dot.
    private static func smoothLine(through points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first, let last = points.last else { return path }
        path.move(to: first)
        for (point, next) in zip(points.dropFirst(), points.dropFirst(2)) {
            path.addQuadCurve(to: CGPoint(x: (point.x + next.x) / 2, y: (point.y + next.y) / 2), control: point)
        }
        path.addLine(to: last)
        return path
    }

    /// A filled arrow: a shaft `width` thick, tapering toward its tail, ending in a head four times as wide.
    private static func arrow(from start: CGPoint, to end: CGPoint, width: CGFloat) -> Path {
        let length = hypot(end.x - start.x, end.y - start.y)
        guard length > 0 else { return Path() }
        let direction = CGPoint(x: (end.x - start.x) / length, y: (end.y - start.y) / length)
        let headLength = min(width * 4, length * 0.6)
        let base = CGPoint(x: end.x - direction.x * headLength, y: end.y - direction.y * headLength)
        func side(_ point: CGPoint, _ offset: CGFloat) -> CGPoint {
            CGPoint(x: point.x - direction.y * offset, y: point.y + direction.x * offset)
        }
        var path = Path()
        path.move(to: side(start, width * 0.2))
        path.addLine(to: side(base, width / 2))
        path.addLine(to: side(base, headLength / 2))
        path.addLine(to: end)
        path.addLine(to: side(base, -headLength / 2))
        path.addLine(to: side(base, -width / 2))
        path.addLine(to: side(start, -width * 0.2))
        path.closeSubpath()
        return path
    }
}

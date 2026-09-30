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

/// A point of a shape that can be dragged to reshape it.
enum AnnotationHandle: Hashable {
    /// Moves `points[x].x` and `points[y].y`: a corner of a rectangle or ellipse, or with `x == y` an end of an arrow.
    case corner(x: Int, y: Int)
    /// The middle of an arrow, which bends it.
    case bend
}

/// A mark drawn over a screenshot, in the screenshot's points (top-left origin).
struct Annotation: Equatable, Identifiable {
    /// The highlighter's one color, a fluorescent yellow.
    static let highlightHex = "#FFFF00"

    let id = UUID()
    let tool: AnnotationTool
    let colorHex: String
    let lineWidth: CGFloat
    var points: [CGPoint]
    /// While Shift is held in a freehand stroke, the index of the point its straight segment starts from.
    var straightFrom: Int?
    /// How far an arrow's middle is from halfway between its ends; zero draws it straight.
    var bend = CGVector.zero

    /// Adds where the drag is now. With `constrained` (Shift held), lines and arrows snap to
    /// multiples of 45° and shapes become squares and circles. A freehand stroke goes straight
    /// from where it was when Shift went down, keeping what was drawn before.
    mutating func extend(to point: CGPoint, constrained: Bool) {
        guard let start = points.first else {
            points = [point]
            return
        }
        if tool.isFreehand {
            if constrained {
                let anchor = straightFrom ?? points.count - 1
                straightFrom = anchor
                points = Array(points[...anchor]) + [Self.snapped(points[anchor], point)]
            } else {
                straightFrom = nil
                if let last = points.last, hypot(point.x - last.x, point.y - last.y) < lineWidth / 8 { return }
                points.append(point)
            }
            return
        }
        points = [start, constrained ? constrain(point, from: start) : point]
    }

    /// Where `point` goes when Shift is held and the shape is drawn from `anchor`: squares and
    /// circles, lines and arrows at multiples of 45°.
    private func constrain(_ point: CGPoint, from anchor: CGPoint) -> CGPoint {
        switch tool {
        case .rectangle, .ellipse:
            let dx = point.x - anchor.x, dy = point.y - anchor.y
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: anchor.x + (dx < 0 ? -side : side), y: anchor.y + (dy < 0 ? -side : side))
        case .pen, .highlighter, .arrow:
            return Self.snapped(anchor, point)
        }
    }

    /// Rectangles, ellipses and arrows can be moved and reshaped once drawn; hand-drawn lines can't.
    var isEditable: Bool { !tool.isFreehand }

    /// Where the handles of an editable shape are, bottom to top. An arrow's ends come after its
    /// middle, so on a short arrow, where the handles overlap, its ends can still be grabbed.
    var handles: [(AnnotationHandle, CGPoint)] {
        guard isEditable, points.count == 2 else { return [] }
        if tool == .arrow {
            return [(.bend, middle), (.corner(x: 0, y: 0), points[0]), (.corner(x: 1, y: 1), points[1])]
        }
        return [(0, 0), (1, 0), (1, 1), (0, 1)].map { x, y in
            (.corner(x: x, y: y), CGPoint(x: points[x].x, y: points[y].y))
        }
    }

    /// Drags `handle` to `point`. With `constrained` (Shift held), the shape stays a square or a
    /// circle, and an arrow's end turns in steps of 45° around its other end.
    mutating func drag(_ handle: AnnotationHandle, to point: CGPoint, constrained: Bool) {
        switch handle {
        case .bend:
            let halfway = chordMiddle(pulled: 0)
            bend = CGVector(dx: point.x - halfway.x, dy: point.y - halfway.y)
        case .corner(let x, let y):
            let anchor = CGPoint(x: points[1 - x].x, y: points[1 - y].y)
            let moved = constrained ? constrain(point, from: anchor) : point
            points[x].x = moved.x
            points[y].y = moved.y
        }
    }

    mutating func move(by offset: CGSize) {
        points = points.map { CGPoint(x: $0.x + offset.width, y: $0.y + offset.height) }
    }

    /// Where a shape can be grabbed: along its outline, `tolerance` either side of the line.
    func grabArea(tolerance: CGFloat) -> Path {
        let outline = tool == .arrow ? Self.curve(points[0], control, points[points.count - 1]) : path
        let width = tool == .arrow ? lineWidth * 4 : lineWidth
        return outline.strokedPath(StrokeStyle(lineWidth: width + tolerance * 2, lineCap: .round, lineJoin: .round))
    }

    /// The point halfway along an arrow, which its bend handle sits on.
    private var middle: CGPoint { chordMiddle(pulled: 1) }

    /// The control point of the curve from an arrow's start to its end that goes through `middle`.
    private var control: CGPoint { chordMiddle(pulled: 2) }

    private func chordMiddle(pulled: CGFloat) -> CGPoint {
        guard let start = points.first, let end = points.last else { return .zero }
        return CGPoint(x: (start.x + end.x) / 2 + bend.dx * pulled, y: (start.y + end.y) / 2 + bend.dy * pulled)
    }

    /// `end`, moved around `start` to the nearest multiple of 45°.
    private static func snapped(_ start: CGPoint, _ end: CGPoint) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        let step = CGFloat.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        let length = hypot(dx, dy)
        return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
    }

    /// Whether any of the mark, line width included, is drawn inside `rect`. Only what is drawn
    /// counts: a frame around `rect` doesn't touch it.
    func touches(_ rect: CGRect) -> Bool {
        // A click's dot is a line of no length, which a stroked outline may leave out: its round cap is a disc.
        if tool.isFreehand, let first = points.first, points.allSatisfy({ $0 == first }) {
            let radius = lineWidth / 2
            return Path(ellipseIn: CGRect(x: first.x - radius, y: first.y - radius, width: lineWidth, height: lineWidth))
                .cgPath.intersects(CGPath(rect: rect, transform: nil))
        }
        let drawn = tool == .arrow ? path : path.strokedPath(StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        return drawn.cgPath.intersects(CGPath(rect: rect, transform: nil))
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
        case .arrow: return Self.arrow(from: start, to: end, control: control, width: lineWidth)
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
            context.opacity = 0.7
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

    private static func curve(_ start: CGPoint, _ control: CGPoint, _ end: CGPoint) -> Path {
        var path = Path()
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
        return path
    }

    /// A filled arrow along the curve from `start` to `end` pulled toward `control`: a shaft `width`
    /// thick, tapering toward its tail, ending in a head four times as wide.
    private static func arrow(from start: CGPoint, to end: CGPoint, control: CGPoint, width: CGFloat) -> Path {
        let straight = abs((control.x - start.x) * (end.y - start.y) - (control.y - start.y) * (end.x - start.x)) < 0.001
        let count = straight ? 1 : 48
        let spine = (0...count).map { step in
            let t = CGFloat(step) / CGFloat(count), u = 1 - t
            return CGPoint(
                x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                y: u * u * start.y + 2 * u * t * control.y + t * t * end.y
            )
        }
        var distances: [CGFloat] = [0]
        for (point, next) in zip(spine, spine.dropFirst()) {
            distances.append(distances.last! + hypot(next.x - point.x, next.y - point.y))
        }
        let length = distances.last!
        guard length > 0 else { return Path() }
        let headLength = min(width * 4, length * 0.6)

        // The head points from where it starts on the curve to the tip.
        let shaftLength = length - headLength
        let index = distances.lastIndex { $0 <= shaftLength } ?? 0
        let span = distances[index + 1] - distances[index]
        let fraction = span > 0 ? (shaftLength - distances[index]) / span : 0
        let base = CGPoint(
            x: spine[index].x + (spine[index + 1].x - spine[index].x) * fraction,
            y: spine[index].y + (spine[index + 1].y - spine[index].y) * fraction
        )
        let reach = max(hypot(end.x - base.x, end.y - base.y), .ulpOfOne)
        let direction = CGPoint(x: (end.x - base.x) / reach, y: (end.y - base.y) / reach)

        // The shaft's sides, each point pushed out square to the curve by half the shaft's width there.
        let shaft = Array(zip(spine, distances).prefix(index + 1)) + [(base, shaftLength)]
        func side(_ offset: (CGFloat) -> CGFloat) -> [CGPoint] {
            shaft.indices.map { i in
                let (point, distance) = shaft[i]
                let along: CGPoint
                if i == shaft.count - 1 {
                    along = direction
                } else {
                    let next = shaft[i + 1].0, previous = shaft[max(i - 1, 0)].0
                    let dx = next.x - previous.x, dy = next.y - previous.y, norm = max(hypot(dx, dy), .ulpOfOne)
                    along = CGPoint(x: dx / norm, y: dy / norm)
                }
                let half = offset(width * (0.2 + 0.3 * distance / max(shaftLength, .ulpOfOne)))
                return CGPoint(x: point.x - along.y * half, y: point.y + along.x * half)
            }
        }
        func beside(_ point: CGPoint, _ offset: CGFloat) -> CGPoint {
            CGPoint(x: point.x - direction.y * offset, y: point.y + direction.x * offset)
        }
        var path = Path()
        path.addLines(side { $0 })
        path.addLine(to: beside(base, headLength / 2))
        path.addLine(to: end)
        path.addLine(to: beside(base, -headLength / 2))
        for point in side({ -$0 }).reversed() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }
}

import SwiftUI
import UniformTypeIdentifiers

struct CaptureButton: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        IconButton(icon: .screenshot, help: "Capture the window or an area") {
            browser.capture.begin()
        }
    }
}

/// Covers the window while picking what to capture: a click takes the whole window, a drag an area.
struct CaptureSelectionOverlay: View {
    @Environment(Browser.self) private var browser
    @State private var origin: CGPoint?
    @State private var corner: CGPoint?
    @State private var escapeMonitor: Any?

    private static let minimumSide: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let selection = selection
            ZStack {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: proxy.size))
                    if let selection { path.addRect(selection) }
                }
                .fill(Color.black.opacity(0.28), style: FillStyle(eoFill: true))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            origin = value.startLocation
                            corner = value.location
                        }
                        .onEnded { _ in capture(selection) }
                )

                if let selection {
                    Rectangle()
                        .path(in: selection)
                        .stroke(.white.opacity(0.9), lineWidth: 1)
                        .allowsHitTesting(false)
                    Text("\(Int(selection.width)) × \(Int(selection.height))")
                        .font(Theme.font(11, .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.black.opacity(0.6)))
                        .position(x: selection.midX, y: min(selection.maxY + 14, proxy.size.height - 12))
                        .allowsHitTesting(false)
                } else {
                    hint.position(x: proxy.size.width / 2, y: Layout.topBarHeight + 32)
                }
            }
        }
        .pointerStyle(.rectSelection)
        .onAppear {
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53 else { return event }
                browser.capture.finish()
                return nil
            }
        }
        .onDisappear {
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        }
    }

    private var hint: some View {
        HStack(spacing: 12) {
            Text("Click to capture the window, or drag to capture an area")
            Button("Cancel") { browser.capture.finish() }
                .buttonStyle(.plain)
                .font(Theme.font(13, .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Capsule().fill(.white.opacity(0.18)))
        }
        .font(Theme.font(13))
        .foregroundStyle(.white)
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Capsule().fill(.black.opacity(0.72)))
        .fixedSize()
    }

    private var selection: CGRect? {
        guard let origin, let corner else { return nil }
        let rect = CGRect(
            x: min(origin.x, corner.x), y: min(origin.y, corner.y),
            width: abs(corner.x - origin.x), height: abs(corner.y - origin.y)
        )
        return rect.width >= Self.minimumSide && rect.height >= Self.minimumSide ? rect : nil
    }

    private func capture(_ area: CGRect?) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        Task { await browser.capture.capture(area, of: window) }
    }
}

struct CaptureStyle: Equatable {
    var backdrop: CaptureBackdrop
    var showsBadge: Bool
    var showsSidebar = false
    var annotations: [Annotation] = []
}

/// The finished screenshot. Rendered once per style change, so the preview is the exported image.
struct CaptureComposition: View {
    let shot: Shot
    let style: CaptureStyle
    /// The screenshot with its marks drawn in.
    let screenshot: CGImage

    static func render(_ shot: Shot, _ style: CaptureStyle) -> CGImage? {
        let screenshot = marked(shot.image(showingSidebar: style.showsSidebar), scale: shot.scale, with: style.annotations)
        let renderer = ImageRenderer(content: CaptureComposition(shot: shot, style: style, screenshot: screenshot))
        renderer.scale = shot.scale
        return renderer.cgImage
    }

    /// Blend modes mix colors in the color space they draw into. The preview window blends the mark
    /// being drawn in the screen's Display P3, so the marks are drawn into the screenshot in Display P3
    /// too, and a highlight looks the same before and after the mouse is let go. The marked screenshot
    /// goes back to the screenshot's own color space, so the exported image is in the same format.
    private static func marked(_ screenshot: CGImage, scale: CGFloat, with annotations: [Annotation]) -> CGImage {
        let pixels = CGRect(x: 0, y: 0, width: screenshot.width, height: screenshot.height)
        func context(_ space: CGColorSpace, bits: Int) -> CGContext? {
            CGContext(
                data: nil, width: screenshot.width, height: screenshot.height, bitsPerComponent: bits, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        guard !annotations.isEmpty,
              let blending = context(CGColorSpace(name: CGColorSpace.displayP3)!, bits: 16),
              let output = context(screenshot.colorSpace ?? sRGB, bits: 8) ?? context(sRGB, bits: 8)
        else { return screenshot }
        blending.draw(screenshot, in: pixels)
        blending.scaleBy(x: scale, y: scale)
        ImageRenderer(content: AnnotationLayer(annotations: annotations).frame(width: pixels.width / scale, height: pixels.height / scale))
            .render { _, draw in draw(blending) }
        guard let blended = blending.makeImage() else { return screenshot }
        output.draw(blended, in: pixels)
        return output.makeImage() ?? screenshot
    }

    var body: some View {
        let image = Image(decorative: screenshot, scale: shot.scale)
        if style.backdrop == .none {
            image
        } else {
            let side = max(shot.size.width, shot.size.height)
            let padding = min(max((side * 0.07).rounded(), 32), 96)
            ZStack(alignment: .bottom) {
                image
                    .clipShape(RoundedRectangle(cornerRadius: shot.isWindow ? 0 : 10, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                    .shadow(color: .black.opacity(0.3), radius: padding * 0.35, y: padding * 0.12)
                    .padding(padding)
                if style.showsBadge {
                    CaptureBadge(size: min(max(side * 0.011, 11), 16), onDark: badgeOnDark)
                        .frame(height: padding)
                }
            }
            .background { backdrop }
            .clipped()
        }
    }

    private var badgeOnDark: Bool {
        if case .color(let hex) = style.backdrop { Color(hex: hex).luminance < 0.5 } else { true }
    }

    @ViewBuilder private var backdrop: some View {
        switch style.backdrop {
        case .wallpaper:
            if let wallpaper = shot.wallpaper {
                Image(decorative: wallpaper, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        case .color(let hex): Color(hex: hex)
        case .none: Color.clear
        }
    }
}

/// Marks over a screenshot. Highlights go under the ink and multiply with what they cover, like a
/// marker on paper: dark text stays dark. `transform` maps the screenshot's points to the layer's.
struct AnnotationLayer: View {
    let annotations: [Annotation]
    var transform = CGAffineTransform.identity
    var clip: CGRect?

    var body: some View {
        ZStack {
            canvas(annotations.filter { $0.tool == .highlighter })
                .blendMode(.multiply)
            canvas(annotations.filter { $0.tool != .highlighter })
        }
        .allowsHitTesting(false)
    }

    private func canvas(_ marks: [Annotation]) -> some View {
        Canvas { context, size in
            context.clip(to: Path(clip ?? CGRect(origin: .zero, size: size)))
            context.concatenate(transform)
            for mark in marks { mark.draw(in: context) }
        }
    }
}

private struct CaptureBadge: View {
    let size: CGFloat
    let onDark: Bool

    var body: some View {
        HStack(spacing: size * 0.4) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: size * 1.4, height: size * 1.4)
            Text("Made with Lithium")
                .font(Theme.font(size, .medium))
        }
        .foregroundStyle(onDark ? Color.white : Color.black.opacity(0.75))
        .padding(.leading, size * 0.4)
        .padding(.trailing, size * 0.8)
        .padding(.vertical, size * 0.3)
        .background(Capsule().fill(onDark ? Color.black.opacity(0.3) : Color.black.opacity(0.06)))
        .fixedSize()
    }
}

struct CapturePreview: View {
    let shot: Shot
    @Environment(Browser.self) private var browser
    @AppStorage(Preference.captureBackdrop) private var backdrop = CaptureBackdrop.wallpaper
    @AppStorage(Preference.captureBadge) private var showsBadge = true
    @AppStorage(Preference.captureSidebar) private var showsSidebar = false
    @AppStorage(Preference.captureTool) private var toolName = ""
    @AppStorage(Preference.captureInk) private var ink = "#FF3B30"
    @State private var rendered: CGImage?
    @State private var annotations: [Annotation] = []
    @State private var past: [[Annotation]] = []
    @State private var future: [[Annotation]] = []
    /// The mark being drawn, moved or reshaped, shown over the preview until the render that includes it replaces the preview.
    @State private var draft: Annotation?
    @State private var drag: Drag?
    /// The shape showing its handles.
    @State private var selection: Annotation.ID?
    /// Resets when a drag ends and also when it is cancelled (Cmd-Tab away mid-stroke), which skips `onEnded`.
    @GestureState private var isDragging = false

    static let colors: KeyValuePairs<String, String> = [
        "#FFFFFF": "White", "#E8E8ED": "Light Gray", "#1D1D1F": "Black",
        Theme.defaultSidebarHex: "Lavender", "#F4D9CD": "Peach", "#CDE7D6": "Mint",
    ]

    static let inks: KeyValuePairs<String, String> = [
        "#FF3B30": "Red", "#FF9500": "Orange", "#FFD60A": "Yellow", "#34C759": "Green",
        "#0A84FF": "Blue", "#1D1D1F": "Black", "#FFFFFF": "White",
    ]

    /// What the drag under way does.
    private enum Drag: Equatable {
        case drawing
        /// Moves `original`, or with a handle reshapes it. The preview leaves it out once `draft` differs from it.
        case editing(original: Annotation, handle: AnnotationHandle?)
    }

    private static let space = "preview"

    private var tool: AnnotationTool? { AnnotationTool(rawValue: toolName) }

    /// The shape being moved or reshaped, if it has changed yet.
    private var edited: Annotation.ID? {
        if case .editing(let original, _) = drag, draft != original { original.id } else { nil }
    }

    /// The highlighter only comes in fluorescent yellow; the other tools draw in the chosen ink.
    private var color: String { tool == .highlighter ? Annotation.highlightHex : ink }

    private var style: CaptureStyle {
        let fallback = CaptureBackdrop.color(Self.colors[1].key)
        return CaptureStyle(
            backdrop: backdrop == .wallpaper && shot.wallpaper == nil ? fallback : backdrop,
            showsBadge: showsBadge,
            showsSidebar: showsSidebar,
            annotations: annotations.filter { $0.id != edited }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            preview
                .frame(maxWidth: .infinity)
                .frame(height: 440)
                .padding([.horizontal, .top], 24)
            annotationBar
                .padding(.vertical, 12)
            Divider()
            HStack(spacing: 12) {
                BackdropPicker(selection: $backdrop, wallpaper: shot.wallpaper, colors: Self.colors)
                Spacer(minLength: 8)
                if shot.isWindow {
                    Toggle("Sidebar", isOn: $showsSidebar)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .fixedSize()
                }
                Toggle("Made with Lithium", isOn: $showsBadge)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(style.backdrop == .none)
                HStack(spacing: 8) {
                    Button { browser.capture.finish() } label: { Icon(.close, size: 15) }
                        .keyboardShortcut(.cancelAction)
                        .help("Cancel")
                        .accessibilityLabel("Cancel")
                    Button { save() } label: { Icon(.download, size: 15) }
                        .help("Save as PNG…")
                        .accessibilityLabel("Save as PNG…")
                    Button { copy() } label: { Icon(.copy, size: 15) }
                        .keyboardShortcut(.defaultAction)
                        .help("Copy")
                        .accessibilityLabel("Copy")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .font(Theme.font(13))
        .frame(width: 920)
        .onChange(of: style, initial: true) {
            rendered = CaptureComposition.render(shot, style)
            if drag == nil { draft = nil }
        }
        .onChange(of: toolName) {
            // Each tool has its own drawing surface: changing tools mid-drag removes the surface, which
            // cancels the drag without ending it, and the next surface only takes drags that start on it.
            drag = nil
            draft = nil
        }
        .onChange(of: isDragging) {
            // A drag that ended has already committed its mark or dropped it; this drops the mark of a cancelled one.
            if !isDragging {
                drag = nil
                draft = nil
            }
        }
    }

    @ViewBuilder private var preview: some View {
        if let rendered {
            Image(decorative: rendered, scale: shot.scale)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .overlay { drawingSurface(over: rendered) }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                .help("\(rendered.width) × \(rendered.height) pixels")
        }
    }

    /// Takes drags on the preview: on a shape or its handles they move or reshape it, elsewhere they
    /// draw with the picked tool. The preview is the whole finished image, scaled to fit, with the
    /// screenshot in its middle.
    private func drawingSurface(over rendered: CGImage) -> some View {
        GeometryReader { proxy in
            let scale = proxy.size.width * shot.scale / CGFloat(rendered.width)
            let frame = CGRect(
                x: (proxy.size.width - shot.size.width * scale) / 2,
                y: (proxy.size.height - shot.size.height * scale) / 2,
                width: shot.size.width * scale,
                height: shot.size.height * scale
            )
            let transform = CGAffineTransform(translationX: frame.minX, y: frame.minY).scaledBy(x: scale, y: scale)
            let inShot = { (location: CGPoint) in
                CGPoint(x: (location.x - frame.minX) / scale, y: (location.y - frame.minY) / scale)
            }
            ZStack {
                if let draft {
                    AnnotationLayer(annotations: [draft], transform: transform, clip: frame)
                }
                if let tool {
                    Color.clear
                        .contentShape(Rectangle())
                        .pointerStyle(.rectSelection)
                        .gesture(drawing(tool, scale: scale, inShot: inShot))
                        .id(tool)
                } else if selection != nil {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { selection = nil }
                }
                ForEach(annotations.filter(\.isEditable)) { mark in
                    Color.clear
                        .contentShape(mark.grabArea(tolerance: 5 / scale).applying(transform))
                        .pointerStyle(.grabIdle)
                        .gesture(editing(mark, handle: nil, scale: scale, inShot: inShot))
                }
                if let mark = drag == nil ? annotations.first(where: { $0.id == selection }) : draft, mark.id == selection {
                    ForEach(mark.handles, id: \.0) { handle, point in
                        HandleKnob()
                            .pointerStyle(pointer(for: handle, of: mark))
                            .gesture(editing(annotations.first { $0.id == mark.id } ?? mark, handle: handle, scale: scale, inShot: inShot))
                            .position(point.applying(transform))
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .coordinateSpace(.named(Self.space))
        }
    }

    /// `inShot` turns a place in the preview into the screenshot's points, `scale` preview points per screenshot point.
    private func drawing(_ tool: AnnotationTool, scale: CGFloat, inShot: @escaping (CGPoint) -> CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .updating($isDragging) { _, dragging, _ in dragging = true }
            .onChanged { value in
                if drag == nil {
                    drag = .drawing
                    selection = nil
                    draft = Annotation(tool: tool, colorHex: color, lineWidth: tool.lineWidth / scale, points: [inShot(value.startLocation)])
                }
                draft?.extend(to: inShot(value.location), constrained: NSEvent.modifierFlags.contains(.shift))
            }
            .onEnded { _ in
                drag = nil
                guard let mark = draft else { return }
                if mark.isVisible {
                    change { $0.append(mark) }
                    if mark.isEditable { selection = mark.id }
                } else {
                    draft = nil
                }
            }
    }

    /// Moves `mark` with the pointer, or with `handle` drags that handle. Grabbing a shape selects it.
    private func editing(_ mark: Annotation, handle: AnnotationHandle?, scale: CGFloat, inShot: @escaping (CGPoint) -> CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .updating($isDragging) { _, dragging, _ in dragging = true }
            .onChanged { value in
                if drag == nil {
                    drag = .editing(original: mark, handle: handle)
                    selection = mark.id
                    draft = mark
                }
                guard case .editing(let original, let handle) = drag else { return }
                let offset = CGSize(width: value.translation.width / scale, height: value.translation.height / scale)
                var changed = original
                if let handle, let (_, point) = original.handles.first(where: { $0.0 == handle }) {
                    let target = CGPoint(x: point.x + offset.width, y: point.y + offset.height)
                    changed.drag(handle, to: target, constrained: NSEvent.modifierFlags.contains(.shift))
                } else {
                    changed.move(by: offset)
                }
                draft = changed
            }
            .onEnded { _ in
                guard case .editing(let original, _) = drag, let changed = draft else { return }
                drag = nil
                if changed != original {
                    change { marks in
                        if let index = marks.firstIndex(where: { $0.id == original.id }) { marks[index] = changed }
                    }
                }
            }
    }

    /// Resize arrows on the corners of a frame, a hand on an arrow's ends and middle.
    private func pointer(for handle: AnnotationHandle, of mark: Annotation) -> PointerStyle {
        guard case .corner(let x, let y) = handle, mark.tool != .arrow else { return .grabIdle }
        let top = mark.points[y].y < mark.points[1 - y].y
        let leading = mark.points[x].x < mark.points[1 - x].x
        return .frameResize(position: top ? (leading ? .topLeading : .topTrailing) : (leading ? .bottomLeading : .bottomTrailing))
    }

    /// Undo, redo and erasing change the marks, which drops the one being drawn while the drag
    /// goes on and would start another from where it began: they wait for the drag to end.
    private var isDrawing: Bool { draft != nil }

    private var annotationBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                ForEach(AnnotationTool.allCases) { item in
                    ToolButton(icon: item.icon, isSelected: tool == item) {
                        toolName = tool == item ? "" : item.rawValue
                    }
                    .keyboardShortcut(item.shortcut, modifiers: [])
                    .help("\(item.label) (\(item.shortcut.character.uppercased()))")
                    .accessibilityLabel(item.label)
                }
            }
            Divider().frame(height: 18)
            HStack(spacing: 0) {
                ForEach(Self.inks, id: \.key) { hex, name in
                    Button { ink = hex } label: {
                        InkSwatch(hex: hex, isSelected: tool != .highlighter && ink == hex)
                    }
                    .buttonStyle(.plain)
                    .disabled(tool == .highlighter)
                    .help(name)
                    .accessibilityLabel(name)
                }
            }
            .opacity(tool == .highlighter ? 0.35 : 1)
            Divider().frame(height: 18)
            HStack(spacing: 2) {
                ToolButton(icon: .undo) { undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(past.isEmpty || isDrawing)
                    .help("Undo")
                    .accessibilityLabel("Undo")
                ToolButton(icon: .redo) { redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(future.isEmpty || isDrawing)
                    .help("Redo")
                    .accessibilityLabel("Redo")
                ToolButton(icon: .trash) { change { $0.removeAll() } }
                    .disabled(annotations.isEmpty || isDrawing)
                    .help("Erase All")
                    .accessibilityLabel("Erase All")
            }
        }
        .background {
            // ⌫ removes the selected shape. The button is only there for its shortcut; the key types
            // U+007F, which `KeyEquivalent.delete` (U+0008) doesn't match.
            Button("Delete Shape") { change { $0.removeAll { $0.id == selection } } }
                .keyboardShortcut(KeyEquivalent("\u{7F}"), modifiers: [])
                .disabled(!annotations.contains { $0.id == selection } || isDrawing)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private func change(_ update: (inout [Annotation]) -> Void) {
        past.append(annotations)
        future.removeAll()
        update(&annotations)
    }

    private func undo() {
        guard let previous = past.popLast() else { return }
        future.append(annotations)
        annotations = previous
    }

    private func redo() {
        guard let next = future.popLast() else { return }
        past.append(annotations)
        annotations = next
    }

    private func copy() {
        guard let rendered, let png = Self.png(rendered) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        browser.capture.finish()
    }

    private func save() {
        guard let rendered, let png = Self.png(rendered) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.directoryURL = .downloadsDirectory
        panel.nameFieldStringValue = "Lithium \(Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try png.write(to: url)
            browser.capture.finish()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

/// One row of round swatches: the wallpaper, preset colors, any color, and no background.
private struct BackdropPicker: View {
    @Binding var selection: CaptureBackdrop
    let wallpaper: CGImage?
    let colors: KeyValuePairs<String, String>
    @State private var colorPanel = ColorPanelTarget()

    var body: some View {
        HStack(spacing: 6) {
            if let wallpaper {
                swatch(.wallpaper, help: "Wallpaper") {
                    Image(decorative: wallpaper, scale: 1).resizable().aspectRatio(contentMode: .fill)
                }
            }
            ForEach(colors, id: \.key) { hex, name in
                swatch(.color(hex), help: name) { Color(hex: hex) }
            }
            customColor
            swatch(.none, help: "No background") {
                ZStack {
                    Color.white
                    Path { path in
                        path.move(to: CGPoint(x: 5, y: 21))
                        path.addLine(to: CGPoint(x: 21, y: 5))
                    }
                    .stroke(Color.red.opacity(0.8), lineWidth: 1.5)
                }
            }
        }
        .onDisappear { colorPanel.close() }
    }

    private var customHex: String? {
        if case .color(let hex) = selection, !colors.contains(where: { $0.key == hex }) { hex } else { nil }
    }

    private var customColor: some View {
        Button {
            colorPanel.show(initial: customHex.map { Color(hex: $0) } ?? .white) { selection = .color($0.hex) }
        } label: {
            SwatchLabel(isSelected: customHex != nil) {
                if let customHex {
                    Color(hex: customHex)
                } else {
                    AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Other color…")
    }

    private func swatch(_ backdrop: CaptureBackdrop, help: String, @ViewBuilder fill: () -> some View) -> some View {
        Button { selection = backdrop } label: {
            SwatchLabel(isSelected: selection == backdrop, fill: fill)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct ToolButton: View {
    let icon: Phosphor
    var isSelected = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Icon(icon, size: 16)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .frame(width: 30, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? Color.accentColor : isHovered && isEnabled ? Color.primary.opacity(0.08) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { isHovered = $0 }
    }
}

/// A handle of the selected shape: a white dot ringed in the accent color, easy to see on any screenshot.
private struct HandleKnob: View {
    var body: some View {
        Circle()
            .fill(.white)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
            .frame(width: 11, height: 11)
            .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
            .frame(width: 20, height: 20)
            .contentShape(Circle())
    }
}

private struct InkSwatch: View {
    let hex: String
    let isSelected: Bool

    var body: some View {
        Circle()
            .fill(Color(hex: hex))
            .overlay(Circle().strokeBorder(.black.opacity(0.15)))
            .frame(width: 18, height: 18)
            .padding(3)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0))
            .frame(width: 28, height: 28)
            .contentShape(Circle())
    }
}

private struct SwatchLabel<Fill: View>: View {
    let isSelected: Bool
    @ViewBuilder let fill: Fill

    var body: some View {
        fill
            .frame(width: 26, height: 26)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.black.opacity(0.12)))
            .padding(3)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0))
            .contentShape(Circle())
    }
}

/// NSColorPanel reports changes through target-action.
@MainActor
private final class ColorPanelTarget: NSObject {
    private var onChange: ((Color) -> Void)?

    func show(initial: Color, onChange: @escaping (Color) -> Void) {
        self.onChange = onChange
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = NSColor(initial)
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.orderFront(nil)
    }

    func close() {
        guard NSColorPanel.sharedColorPanelExists else { return }
        NSColorPanel.shared.setTarget(nil)
        NSColorPanel.shared.orderOut(nil)
    }

    @objc private func colorChanged(_ panel: NSColorPanel) {
        onChange?(Color(nsColor: panel.color))
    }
}

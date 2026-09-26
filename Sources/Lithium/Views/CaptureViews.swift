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
}

/// The finished screenshot. Rendered once per style change, so the preview is the exported image.
struct CaptureComposition: View {
    let shot: Shot
    let style: CaptureStyle

    static func render(_ shot: Shot, _ style: CaptureStyle) -> CGImage? {
        let renderer = ImageRenderer(content: CaptureComposition(shot: shot, style: style))
        renderer.scale = shot.scale
        return renderer.cgImage
    }

    var body: some View {
        let image = Image(decorative: shot.image(showingSidebar: style.showsSidebar), scale: shot.scale)
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
    @State private var rendered: CGImage?

    static let colors: KeyValuePairs<String, String> = [
        "#FFFFFF": "White", "#E8E8ED": "Light Gray", "#1D1D1F": "Black",
        Theme.defaultSidebarHex: "Lavender", "#F4D9CD": "Peach", "#CDE7D6": "Mint",
    ]

    private var style: CaptureStyle {
        let fallback = CaptureBackdrop.color(Self.colors[1].key)
        return CaptureStyle(
            backdrop: backdrop == .wallpaper && shot.wallpaper == nil ? fallback : backdrop,
            showsBadge: showsBadge,
            showsSidebar: showsSidebar
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            preview
                .frame(maxWidth: .infinity)
                .frame(height: 440)
                .padding(24)
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
        }
    }

    @ViewBuilder private var preview: some View {
        if let rendered {
            Image(decorative: rendered, scale: shot.scale)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                .help("\(rendered.width) × \(rendered.height) pixels")
        }
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

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The page's zoom in the address bar, shown only away from 100 %; opens − / + / Reset.
struct ZoomPill: View {
    let tab: Tab
    @Binding var isPresented: Bool

    /// It stays while its popover is open, so stepping through 100 % doesn't close it. PDFs
    /// have their own zoom.
    static func isShown(for tab: Tab, isPresented: Bool) -> Bool {
        tab.pdf == nil && (PageZoom.label(tab.zoom) != nil || isPresented)
    }

    var body: some View {
        Button { isPresented.toggle() } label: {
            ZoomPillLabel(text: PageZoom.label(tab.zoom) ?? "100%")
        }
        .buttonStyle(.plain)
        .help("Zoom")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ZoomView(
                zoom: tab.zoom,
                onZoomOut: { setZoom(PageZoom.stepped(tab.zoom, by: -PageZoom.step)) },
                onZoomIn: { setZoom(PageZoom.stepped(tab.zoom, by: PageZoom.step)) },
                onReset: { setZoom(1) }
            )
        }
    }

    private func setZoom(_ zoom: Double) {
        tab.webView.pageZoom = zoom
    }
}

struct ZoomPillLabel: View {
    let text: String
    @State private var isHovered = false

    var body: some View {
        Text(text)
            .font(Theme.font(11, .medium))
            .monospacedDigit()
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(Capsule().fill(.primary.opacity(isHovered ? 0.14 : 0.08)))
            .contentShape(Capsule())
            .onHover { isHovered = $0 }
    }
}

/// The zoom popover from plain values, so it also draws without a tab.
struct ZoomView: View {
    let zoom: Double
    var onZoomOut: () -> Void = {}
    var onZoomIn: () -> Void = {}
    var onReset: () -> Void = {}

    var body: some View {
        HStack(spacing: 2) {
            IconButton(icon: .minus, help: "Zoom out (⌘−)", isEnabled: zoom > PageZoom.range.lowerBound, action: onZoomOut)
            Text(PageZoom.label(zoom) ?? "100%")
                .font(Theme.font(13, .medium))
                .monospacedDigit()
                .frame(minWidth: 44)
            IconButton(icon: .plus, help: "Zoom in (⌘+)", isEnabled: zoom < PageZoom.range.upperBound, action: onZoomIn)
            Divider().frame(height: 16).padding(.horizontal, 6)
            Button("Reset", action: onReset)
                .buttonStyle(.plain)
                .font(Theme.font(13))
                .foregroundStyle(Color.accentColor)
                .disabled(PageZoom.label(zoom) == nil)
                .padding(.trailing, 6)
        }
        .padding(6)
    }
}

/// A QR code of the page's address, to open it on a phone.
struct QRCodeView: View {
    let url: URL
    /// One pixel per module.
    private let code: CGImage?
    @Environment(\.displayScale) private var displayScale

    private static let side: CGFloat = 200

    init(url: URL) {
        self.url = url
        code = QRCode.image(for: url.absoluteString, scale: 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("QR code").font(Theme.font(15, .semibold))
                Text(url.host(percentEncoded: false) ?? url.absoluteString)
                    .font(Theme.font(12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let code {
                // Drawn at the screen's own pixels, whole points per module: nothing scales it, so
                // every module stays square and sharp.
                let pixelsPerPoint = Int(displayScale.rounded(.up))
                let perModule = max(1, Int(Self.side) / code.width)
                Image(decorative: QRCode.image(for: url.absoluteString, scale: perModule * pixelsPerPoint) ?? code, scale: CGFloat(pixelsPerPoint))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("QR code for \(url.absoluteString)")
            } else {
                Text("This address is too long for a QR code.")
                    .font(Theme.font(12))
                    .foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button { copyImage() } label: {
                    Label { Text("Copy image") } icon: { Icon(.copy, size: 14) }
                }
                Spacer(minLength: 8)
                Button { save() } label: {
                    Label { Text("Save…") } icon: { Icon(.download, size: 14) }
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .font(Theme.font(12))
            .disabled(code == nil)
        }
        .font(Theme.font(13))
        .padding(16)
        .frame(width: Self.side + 32)
    }

    private var png: Data? {
        QRCode.image(for: url.absoluteString, scale: 10).flatMap(QRCode.png)
    }

    private func copyImage() {
        guard let png else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        // Some apps only paste TIFF.
        if let tiff = NSImage(data: png)?.tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
    }

    private func save() {
        guard let png else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = QRCode.fileName(for: url)
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            try? png.write(to: destination, options: .atomic)
        }
    }
}

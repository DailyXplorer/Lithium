import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Lithium

/// A sidebar the tests paint on. Translucent has no color of its own: the light and dark
/// stand-ins are close to what the sidebar material shows over a plain desktop.
private struct Backdrop {
    let name: String
    let style: SidebarStyle
    let hex: String
    let scheme: ColorScheme

    var palette: SidebarPalette { SidebarPalette(style: style, colorHex: hex, scheme: scheme) }

    static let all = [
        Backdrop(name: "default", style: .solid, hex: Theme.defaultSidebarHex, scheme: .light),
        Backdrop(name: "lavender", style: .solid, hex: "#D9DCF2", scheme: .light),
        Backdrop(name: "red", style: .solid, hex: "#C0392B", scheme: .light),
        Backdrop(name: "very-dark", style: .solid, hex: "#1E1E24", scheme: .dark),
        Backdrop(name: "translucent-light", style: .translucent, hex: "#E7E5EA", scheme: .light),
        Backdrop(name: "translucent-dark", style: .translucent, hex: "#2C2B30", scheme: .dark),
    ]
}

private func rgba(_ color: Color) -> (r: Double, g: Double, b: Double, a: Double) {
    let c = NSColor(color).usingColorSpace(.sRGB)!
    return (c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
}

/// `surface` drawn over `hex`, as the screen shows it.
private func composite(_ surface: Color, over hex: String) -> (r: Double, g: Double, b: Double) {
    let s = rgba(surface), bg = rgba(Color(hex: hex))
    return (s.r * s.a + bg.r * (1 - s.a), s.g * s.a + bg.g * (1 - s.a), s.b * s.a + bg.b * (1 - s.a))
}

private func luminance(_ c: (r: Double, g: Double, b: Double)) -> Double {
    0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
}

@MainActor
struct SidebarPaletteTests {
    /// Same hue, darker: every channel shrinks by the same factor, so nothing turns white or grey.
    @Test(arguments: Backdrop.all)
    fileprivate func surfacesAreTheSidebarColorDarker(_ backdrop: Backdrop) {
        let palette = backdrop.palette
        let bg = rgba(Color(hex: backdrop.hex))
        for surface in [palette.tile, palette.hover, palette.tileHover, palette.selection, palette.field] {
            let c = composite(surface, over: backdrop.hex)
            let factor = c.r / bg.r
            #expect(factor < 1, "\(backdrop.name) surface is not darker")
            #expect(abs(c.g - bg.g * factor) < 0.001 && abs(c.b - bg.b * factor) < 0.001, "\(backdrop.name) surface shifts the hue")
        }
    }

    @Test(arguments: Backdrop.all)
    fileprivate func hoveredRowMatchesARestingFavorite(_ backdrop: Backdrop) {
        let palette = backdrop.palette
        #expect(palette.rowFill(isSelected: false, isHovered: true) == palette.tileFill(isSelected: false, isHovered: false))
        #expect(palette.rowFill(isSelected: false, isHovered: false) == .clear)
    }

    /// Resting, hovered and selected each a visible step darker than the one before.
    @Test(arguments: Backdrop.all)
    fileprivate func statesGetDarkerInVisibleSteps(_ backdrop: Backdrop) {
        let palette = backdrop.palette
        let sidebar = luminance(composite(.clear, over: backdrop.hex))
        let resting = luminance(composite(palette.tileFill(isSelected: false, isHovered: false), over: backdrop.hex))
        let hovered = luminance(composite(palette.tileFill(isSelected: false, isHovered: true), over: backdrop.hex))
        let selected = luminance(composite(palette.tileFill(isSelected: true, isHovered: true), over: backdrop.hex))
        #expect(resting < sidebar * 0.95, "\(backdrop.name) resting")
        #expect(hovered < resting * 0.97, "\(backdrop.name) hovered")
        #expect(selected < hovered * 0.93, "\(backdrop.name) selected")
        #expect(palette.rowFill(isSelected: true, isHovered: false) == palette.tileFill(isSelected: true, isHovered: false))
    }

    @Test func darkSidebarsKeepWhiteInk() {
        #expect(SidebarPalette(style: .solid, colorHex: "#C0392B", scheme: .light).isDark)
        #expect(SidebarPalette(style: .solid, colorHex: "#1E1E24", scheme: .light).isDark)
        #expect(!SidebarPalette(style: .solid, colorHex: "#D9DCF2", scheme: .dark).isDark)
    }

    /// The sidebar before and after, for a look without launching the app:
    /// `LITHIUM_SNAPSHOT_DIR=/tmp/shots ./scripts/test --filter SidebarPalette`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHIUM_SNAPSHOT_DIR"] != nil, "Writes PNGs only when LITHIUM_SNAPSHOT_DIR is set"))
    func snapshots() throws {
        let directory = URL(filePath: ProcessInfo.processInfo.environment["LITHIUM_SNAPSHOT_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Theme.registerFonts()
        for backdrop in Backdrop.all {
            let renderer = ImageRenderer(content: SnapshotScene(backdrop: backdrop))
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let png = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]))
            try png.write(to: directory.appending(path: "sidebar-\(backdrop.name).png"))
        }
    }
}

/// How a sidebar paints its surfaces: what main shipped, or the palette the views use now.
private struct Look {
    let ink: Color
    /// Layers, bottom first: main put the hover over the resting color.
    let tile: (_ isSelected: Bool, _ isHovered: Bool) -> [Color]
    let row: (_ isSelected: Bool, _ isHovered: Bool) -> Color
    let card: Color
    let field: Color

    init(_ palette: SidebarPalette) {
        ink = palette.ink
        tile = { [palette.tileFill(isSelected: $0, isHovered: $1)] }
        row = palette.rowFill
        card = palette.tile
        field = palette.field
    }

    /// The white surfaces main shipped, copied here to compare against.
    init(before palette: SidebarPalette) {
        let dark = palette.isDark
        let ink = palette.ink
        let selection: Color = dark ? .white.opacity(0.16) : .white.opacity(0.85)
        let tile: Color = dark ? .white.opacity(0.08) : .white.opacity(0.4)
        let hover = ink.opacity(0.07)
        self.ink = ink
        self.tile = { [$0 ? selection : tile, $1 && !$0 ? hover : .clear] }
        row = { $0 ? selection : $1 ? hover : .clear }
        card = tile
        field = ink.opacity(0.06)
    }
}

/// A stand-in for the sidebar: 9 favorites (the fifth selected, the third hovered), New Tab,
/// three tabs (selected, hovered, plain) and the mini player, before and after side by side.
private struct SnapshotScene: View {
    let backdrop: Backdrop

    var body: some View {
        let palette = backdrop.palette
        HStack(alignment: .top, spacing: 24) {
            column("Before", Look(before: palette))
            column("After", Look(palette))
        }
        .padding(16)
        .frame(width: 2 * Layout.sidebarWidth + 56, height: 600)
        .background(Color(hex: backdrop.hex))
        .foregroundStyle(palette.ink)
        .font(Theme.font(13))
        .environment(\.sidebarPalette, palette)
        .environment(\.colorScheme, backdrop.scheme)
    }

    private static let hosts = ["github.com", "youtube.com", "mail.google.com", "notion.so", "figma.com", "linear.app", "x.com", "reddit.com", "spotify.com"]
    private static let tabs = [
        ("Le Monde — Actualités en direct", "lemonde.fr"),
        ("Apple Developer Documentation", "developer.apple.com"),
        ("Wikipédia, l'encyclopédie libre", "wikipedia.org"),
    ]

    private func column(_ title: String, _ look: Look) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(title) · \(backdrop.name)").font(Theme.font(11, .semibold)).opacity(0.6)
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(0..<3, id: \.self) { row in
                    GridRow {
                        ForEach(0..<3, id: \.self) { column in
                            let index = row * 3 + column
                            ZStack {
                                ForEach(Array(look.tile(index == 4, index == 2).enumerated()), id: \.offset) { _, fill in
                                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fill)
                                }
                                Favicon(image: nil, fallback: Self.hosts[index], size: 20)
                            }
                            .frame(height: 48)
                        }
                    }
                }
            }
            Rectangle().fill(look.ink.opacity(0.1)).frame(height: 1).padding(.horizontal, 4)
            tabRow(look, selected: false, hovered: false) {
                Icon(.plus, size: 14).frame(width: 16)
                Text("New Tab")
            }
            .opacity(0.7)
            VStack(spacing: 2) {
                ForEach(Array(Self.tabs.enumerated()), id: \.offset) { index, tab in
                    tabRow(look, selected: index == 0, hovered: index == 1) {
                        Favicon(image: nil, fallback: tab.1, size: 16)
                        Text(tab.0).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
            Spacer(minLength: 0)
            miniPlayer(look)
        }
        .frame(width: Layout.sidebarWidth - 20)
    }

    private func tabRow(_ look: Look, selected: Bool, hovered: Bool, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(look.row(selected, hovered)))
    }

    /// MiniPlayer's layout with its colors.
    private func miniPlayer(_ look: Look) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(look.field)
                    .frame(width: 36, height: 36)
                    .overlay { Favicon(image: nil, fallback: "youtube.com", size: 18) }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Lofi hip hop radio").font(Theme.font(12, .medium))
                    Text("Lofi Girl").font(Theme.font(11)).opacity(0.6)
                }
                Spacer(minLength: 0)
            }
            .padding(4)
            HStack(spacing: 6) {
                Text("1:12")
                ZStack(alignment: .leading) {
                    Capsule().fill(look.ink.opacity(0.15))
                    Capsule().fill(look.ink.opacity(0.7)).frame(width: 50)
                }
                .frame(height: 3)
                Text("3:40")
            }
            .font(Theme.font(10, .medium))
            .opacity(0.7)
            .padding(.horizontal, 4)
            HStack(spacing: 4) {
                ForEach(["backward.end.fill", "pause.fill", "forward.end.fill"], id: \.self) { symbol in
                    Image(systemName: symbol).font(.system(size: 13)).frame(width: 32, height: 26)
                }
            }
            .opacity(0.85)
            .frame(maxWidth: .infinity)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(look.card))
    }
}

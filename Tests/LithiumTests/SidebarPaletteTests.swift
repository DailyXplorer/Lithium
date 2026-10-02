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

    static let darkened = [
        Backdrop(name: "default", style: .solid, hex: Theme.defaultSidebarHex, scheme: .light),
        Backdrop(name: "lavender", style: .solid, hex: "#D9DCF2", scheme: .light),
        Backdrop(name: "red", style: .solid, hex: "#C0392B", scheme: .light),
        Backdrop(name: "very-dark", style: .solid, hex: "#1E1E24", scheme: .dark),
        Backdrop(name: "translucent-light", style: .translucent, hex: "#E7E5EA", scheme: .light),
        Backdrop(name: "translucent-dark", style: .translucent, hex: "#2C2B30", scheme: .dark),
        // Saturated: luminance calls the blues near-black, yet each has a channel to darken.
        Backdrop(name: "blue", style: .solid, hex: "#0000FF", scheme: .dark),
        Backdrop(name: "violet-blue", style: .solid, hex: "#1500FF", scheme: .dark),
        Backdrop(name: "medium-blue", style: .solid, hex: "#0000C0", scheme: .dark),
        Backdrop(name: "navy", style: .solid, hex: "#000080", scheme: .dark),
        Backdrop(name: "maroon", style: .solid, hex: "#800000", scheme: .dark),
        Backdrop(name: "dark-green", style: .solid, hex: "#006400", scheme: .dark),
    ]
    /// Too dark for black to show: these lift instead.
    static let lifted = [
        Backdrop(name: "black", style: .solid, hex: "#000000", scheme: .dark),
        Backdrop(name: "near-black", style: .solid, hex: "#0A0A0A", scheme: .dark),
        Backdrop(name: "near-black-grey", style: .solid, hex: "#111111", scheme: .dark),
        Backdrop(name: "near-black-navy", style: .solid, hex: "#0A0A14", scheme: .dark),
    ]
    static let all = darkened + lifted
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

/// Channels in the same proportions as the sidebar's, compared crosswise so black divides by
/// nothing. Black has no hue: its surfaces must be neutral grey.
private func keepsHue(_ c: (r: Double, g: Double, b: Double), of hex: String) -> Bool {
    let bg = rgba(Color(hex: hex))
    return proportional(c, (bg.r, bg.g, bg.b))
}

private func proportional(_ c: (r: Double, g: Double, b: Double), _ bg: (r: Double, g: Double, b: Double)) -> Bool {
    if max(bg.r, bg.g, bg.b) == 0 { return abs(c.r - c.g) < 0.001 && abs(c.g - c.b) < 0.001 }
    return abs(c.r * bg.g - c.g * bg.r) < 0.001 && abs(c.g * bg.b - c.b * bg.g) < 0.001 && abs(c.r * bg.b - c.b * bg.r) < 0.001
}

/// The hue alone, once each side's grey part (its lowest channel) is set aside: a light tint
/// greys the color but keeps its hue. A grey sidebar's surfaces stay grey.
private func sameHue(_ c: (r: Double, g: Double, b: Double), of hex: String) -> Bool {
    let bg = rgba(Color(hex: hex))
    let low = min(c.r, c.g, c.b), bgLow = min(bg.r, bg.g, bg.b)
    let hue = (r: bg.r - bgLow, g: bg.g - bgLow, b: bg.b - bgLow)
    if max(hue.r, hue.g, hue.b) == 0 { return max(c.r, c.g, c.b) - low < 0.001 }
    return proportional((c.r - low, c.g - low, c.b - low), hue)
}

/// The largest change in any one channel: a step in blue counts as much as one in green.
private func channelStep(_ a: (r: Double, g: Double, b: Double), _ b: (r: Double, g: Double, b: Double)) -> Double {
    max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b))
}

private func surfaces(_ palette: SidebarPalette) -> [Color] {
    [palette.tile, palette.hover, palette.tileHover, palette.selection, palette.field]
}

@MainActor
struct SidebarPaletteTests {
    /// Same hue, darker: every channel shrinks by the same factor, so nothing turns white or grey.
    @Test(arguments: Backdrop.darkened)
    fileprivate func surfacesAreTheSidebarColorDarker(_ backdrop: Backdrop) {
        let sidebar = luminance(composite(.clear, over: backdrop.hex))
        for surface in surfaces(backdrop.palette) {
            let c = composite(surface, over: backdrop.hex)
            #expect(luminance(c) < sidebar, "\(backdrop.name) surface is not darker")
            #expect(keepsHue(c, of: backdrop.hex), "\(backdrop.name) surface shifts the hue")
        }
    }

    /// Same hue, lighter, and still a dark grey: the selected tab never reads as light grey.
    @Test(arguments: Backdrop.lifted)
    fileprivate func nearBlackSurfacesAreTheSidebarColorLighter(_ backdrop: Backdrop) {
        let sidebar = luminance(composite(.clear, over: backdrop.hex))
        for surface in surfaces(backdrop.palette) {
            let c = composite(surface, over: backdrop.hex)
            #expect(luminance(c) > sidebar, "\(backdrop.name) surface is not lighter")
            #expect(luminance(c) < 0.25, "\(backdrop.name) surface reads as light grey")
            #expect(sameHue(c, of: backdrop.hex), "\(backdrop.name) surface shifts the hue")
        }
    }

    /// Resting, hovered and selected each a visible step lighter than the one before.
    @Test(arguments: Backdrop.lifted)
    fileprivate func nearBlackStatesGetLighterInVisibleSteps(_ backdrop: Backdrop) {
        let palette = backdrop.palette
        let sidebar = luminance(composite(.clear, over: backdrop.hex))
        let resting = luminance(composite(palette.tileFill(isSelected: false, isHovered: false), over: backdrop.hex))
        let hovered = luminance(composite(palette.tileFill(isSelected: false, isHovered: true), over: backdrop.hex))
        let selected = luminance(composite(palette.tileFill(isSelected: true, isHovered: true), over: backdrop.hex))
        #expect(resting - sidebar > 0.02, "\(backdrop.name) resting")
        #expect(hovered - resting > 0.02, "\(backdrop.name) hovered")
        #expect(selected - hovered > 0.02, "\(backdrop.name) selected")
    }

    /// Sidebar, resting, hovered, selected: each at least five 8-bit levels from the one before in
    /// some channel, whatever the color. Luminance alone is blind to a step in blue.
    @Test(arguments: Backdrop.all)
    fileprivate func everyStateIsAVisibleStep(_ backdrop: Backdrop) {
        let palette = backdrop.palette
        let shown = [
            Color.clear,
            palette.tileFill(isSelected: false, isHovered: false),
            palette.tileFill(isSelected: false, isHovered: true),
            palette.tileFill(isSelected: true, isHovered: true),
        ].map { composite($0, over: backdrop.hex) }
        for (state, (before, after)) in zip(["resting", "hovered", "selected"], zip(shown, shown.dropFirst())) {
            let levels = channelStep(before, after) * 255
            #expect(levels >= 5, "\(backdrop.name) \(state) is \(levels) levels from the step before")
        }
    }

    /// The lifting tint is never the color itself: even over pure blue, 6 % of it shows.
    @Test func lightTintShowsOverASaturatedColor() {
        for hex in ["#0000FF", "#FF0000", "#00FF00"] {
            let tinted = composite(Color(hex: hex).lightTint.opacity(0.06), over: hex)
            #expect(channelStep(tinted, composite(.clear, over: hex)) * 255 >= 5, "\(hex)")
            #expect(sameHue(tinted, of: hex), "\(hex)")
        }
    }

    @Test(arguments: Backdrop.all)
    fileprivate func hoveredRowMatchesARestingFavorite(_ backdrop: Backdrop) {
        let palette = backdrop.palette
        #expect(palette.rowFill(isSelected: false, isHovered: true) == palette.tileFill(isSelected: false, isHovered: false))
        #expect(palette.rowFill(isSelected: false, isHovered: false) == .clear)
    }

    /// Resting, hovered and selected each a visible step darker than the one before.
    @Test(arguments: Backdrop.darkened)
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

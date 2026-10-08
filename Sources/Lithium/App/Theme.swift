import AppKit
import SwiftUI

enum Resources {
    /// Inside Lithium.app the SwiftPM bundle lives in Contents/Resources, where `Bundle.module` does not look.
    static let bundle: Bundle = {
        if let url = Bundle.main.url(forResource: "Lithium_Lithium", withExtension: "bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }()
}

enum Theme {
    static let defaultSidebarHex = "#D5DAF5"
    private static let baseFontName = "DMSans-9ptRegular"
    private static let opticalSizeAxis = 1_869_640_570
    private static let weightAxis = 2_003_265_652

    static func registerFonts() {
        guard let url = Resources.bundle.url(forResource: "DMSans", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        nsFont(size, weight).map(Font.init) ?? .system(size: size, weight: weight)
    }

    static func nsFont(_ size: CGFloat, _ weight: Font.Weight = .regular) -> NSFont? {
        guard let base = NSFont(name: baseFontName, size: size) else { return nil }
        let descriptor = base.fontDescriptor.addingAttributes([
            NSFontDescriptor.AttributeName(kCTFontVariationAttribute as String): [
                opticalSizeAxis: min(max(size, 9), 40),
                weightAxis: weightValue(weight),
            ],
        ])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    private static func weightValue(_ weight: Font.Weight) -> CGFloat {
        switch weight {
        case .medium: 500
        case .semibold: 600
        case .bold, .heavy, .black: 700
        default: 400
        }
    }
}

enum Preference {
    static let sidebarStyle = "sidebarStyle"
    static let sidebarColor = "sidebarColor"
    static let sidebarReveal = "sidebarReveal"
    static let sidebarVisible = "sidebarVisible"
    static let zenMode = "zenMode"
    static let miniPlayer = "sidebarMiniPlayer"
    static let tabUsage = "tabHoverUsage"
    static let websiteFont = "dmSansOnWebsites"
    static let pdfSidebar = "pdfSidebar"
    static let videoPopoutCorner = "videoPopoutCorner"
    static let videoPopoutWidth = "videoPopoutWidth"
    static let videoPopoutInsetX = "videoPopoutInsetX"
    static let videoPopoutInsetY = "videoPopoutInsetY"
    static let agentAccess = "agentAccess"
    static let agentCaptureBodies = "agentCaptureBodies"
    static let agentRunScripts = "agentRunScripts"
    static let agentPort = "agentPort"
    static let developerTools = "developerTools"
    static let quickLinks = "quickLinkWindow"
    static let readerButton = "readerButton"
    static let readerStyle = "readerStyle"
    static let energySaving = "energySaving"
}

enum SidebarStyle: String, CaseIterable, Identifiable {
    case solid, translucent
    var id: Self { self }
    var label: String {
        switch self {
        case .solid: "Solid Color"
        case .translucent: "Translucent"
        }
    }
}

/// How eagerly the collapsed sidebar slides out from the window's left edge, and how long it
/// stays once the pointer wanders off it.
enum SidebarReveal: String, CaseIterable, Identifiable {
    case responsive, normal, calm
    var id: Self { self }
    var label: String {
        switch self {
        case .responsive: "Responsive"
        case .normal: "Normal"
        case .calm: "Calm"
        }
    }

    /// How long the pointer rests on the edge before the panel opens, so brushing past it doesn't.
    var openDelay: Duration {
        switch self {
        case .responsive: .milliseconds(50)
        case .normal: .milliseconds(150)
        case .calm: .milliseconds(300)
        }
    }

    /// How long the pointer stays off the panel and its margin before the panel closes.
    var closeDelay: Duration {
        switch self {
        case .responsive: .milliseconds(300)
        case .normal: .milliseconds(600)
        case .calm: .milliseconds(1200)
        }
    }

    /// Invisible band around the open panel that still counts as being on it.
    var margin: CGFloat {
        switch self {
        case .responsive: 24
        case .normal: 48
        case .calm: 80
        }
    }
}

/// Colors for everything drawn on the sidebar background (sidebar, toolbar, window margins).
/// Surfaces are black laid over that background: the chosen color, only darker, in Solid and
/// Translucent alike. White washed a colored sidebar out to grey. A near-black sidebar has no
/// darker left, so there the surfaces are the same color lighter: a dark grey of its hue.
struct SidebarPalette {
    let ink: Color
    let isDark: Bool
    private let overlay: Color
    private let steps: (tile: Double, tileHover: Double, selection: Double)

    /// Favorites, the mini player and the address field at rest.
    var tile: Color { overlay.opacity(steps.tile) }
    /// A hovered button takes a favorite's color: the sidebar has one raised surface.
    var hover: Color { tile }
    /// Another hovered tab row, half a resting favorite, so it never looks like the current tab.
    var rowHover: Color { overlay.opacity(steps.tile / 2) }
    /// A hovered favorite, one step past its resting color.
    var tileHover: Color { overlay.opacity(steps.tileHover) }
    /// The current favorite, well past hover. A dark color needs more black for a step
    /// the eye still sees.
    var selection: Color { overlay.opacity(steps.selection) }
    var field: Color { tile }

    func tileFill(isSelected: Bool, isHovered: Bool) -> Color {
        isSelected ? selection : isHovered ? tileHover : tile
    }

    /// Nothing behind a tab row at rest. The current tab takes a resting favorite's color: it
    /// only marks which tab is current, it need not stand out.
    func rowFill(isSelected: Bool, isHovered: Bool) -> Color {
        isSelected ? tile : isHovered ? rowHover : .clear
    }

    /// Under this brightest channel a resting tile's 18 % black takes less than 0.018 off every
    /// channel, under five 8-bit levels: the eye loses it. Luminance would call pure blue near-black.
    /// `#1E1E24` (0.14) still darkens, `#0A0A14` (0.08) lifts.
    private static let nearBlack = 0.1
    /// Under this brightest channel, 12 % more black for hover takes off under five levels: dim
    /// sidebars get wider steps.
    private static let dim = 0.2

    init(style: SidebarStyle, colorHex: String, scheme: ColorScheme) {
        var brightness = 1.0
        var tint = Color.white
        switch style {
        case .solid:
            let color = Color(hex: colorHex)
            isDark = color.luminance < 0.45
            brightness = color.brightness
            tint = color.lightTint
        case .translucent:
            // The dark material lays its own grey fill over the desktop, never near-black.
            isDark = scheme == .dark
        }
        ink = isDark ? .white : Color(white: 0.1)
        if brightness < Self.nearBlack {
            overlay = tint
            steps = (0.06, 0.11, 0.17)
        } else {
            overlay = .black
            steps = brightness < Self.dim ? (0.22, 0.42, 0.66) : isDark ? (0.18, 0.3, 0.5) : (0.06, 0.1, 0.17)
        }
    }
}

extension EnvironmentValues {
    @Entry var sidebarPalette = SidebarPalette(style: .solid, colorHex: Theme.defaultSidebarHex, scheme: .light)
}

extension Color {
    init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0xFFFFFF
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    var hex: String {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return String(
            format: "#%02X%02X%02X",
            Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()),
            Int((color.blueComponent * 255).rounded())
        )
    }

    /// The brightest channel: dark in every channel only when this is low.
    var brightness: Double {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return max(color.redComponent, color.greenComponent, color.blueComponent)
    }

    /// The same hue at full brightness, halfway to white. Laid over the color it lightens without
    /// shifting the hue, and it is never the color itself, even a saturated one. White for black.
    var lightTint: Color {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let peak = brightness
        guard peak > 0 else { return .white }
        return Color(
            .sRGB,
            red: 0.5 + 0.5 * color.redComponent / peak,
            green: 0.5 + 0.5 * color.greenComponent / peak,
            blue: 0.5 + 0.5 * color.blueComponent / peak
        )
    }

    var luminance: Double {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
    }
}

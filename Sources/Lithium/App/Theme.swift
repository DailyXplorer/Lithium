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
    static let miniPlayer = "sidebarMiniPlayer"
    static let tabUsage = "tabHoverUsage"
    static let websiteFont = "dmSansOnWebsites"
    static let pdfSidebar = "pdfSidebar"
    static let videoPopoutCorner = "videoPopoutCorner"
    static let videoPopoutWidth = "videoPopoutWidth"
    static let videoPopoutInsetX = "videoPopoutInsetX"
    static let videoPopoutInsetY = "videoPopoutInsetY"
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
/// Translucent alike. White washed a colored sidebar out to grey.
struct SidebarPalette {
    let ink: Color
    let isDark: Bool

    /// Favorites, the mini player and the address field at rest.
    var tile: Color { shade(isDark ? 0.18 : 0.06) }
    /// A hovered tab row or button takes a favorite's color: the sidebar has one raised surface.
    var hover: Color { tile }
    /// A hovered favorite, one step past its resting color.
    var tileHover: Color { shade(isDark ? 0.3 : 0.1) }
    /// The current tab or favorite, well past hover. A dark color needs more black for a step
    /// the eye still sees.
    var selection: Color { shade(isDark ? 0.5 : 0.17) }
    var field: Color { tile }

    func tileFill(isSelected: Bool, isHovered: Bool) -> Color {
        isSelected ? selection : isHovered ? tileHover : tile
    }

    /// Nothing behind a tab row at rest.
    func rowFill(isSelected: Bool, isHovered: Bool) -> Color {
        isSelected ? selection : isHovered ? hover : .clear
    }

    private func shade(_ opacity: Double) -> Color { .black.opacity(opacity) }

    init(style: SidebarStyle, colorHex: String, scheme: ColorScheme) {
        switch style {
        case .solid:
            isDark = Color(hex: colorHex).luminance < 0.45
        case .translucent:
            isDark = scheme == .dark
        }
        ink = isDark ? .white : Color(white: 0.1)
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

    var luminance: Double {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
    }
}

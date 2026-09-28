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
    static let websiteFont = "dmSansOnWebsites"
    static let pdfSidebar = "pdfSidebar"
    static let videoPopoutCorner = "videoPopoutCorner"
    static let videoPopoutWidth = "videoPopoutWidth"
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

/// Colors for everything drawn on the sidebar background (sidebar, toolbar, window margins).
struct SidebarPalette {
    let ink: Color
    let isDark: Bool

    var selection: Color { isDark ? .white.opacity(0.16) : .white.opacity(0.85) }
    var tile: Color { isDark ? .white.opacity(0.08) : .white.opacity(0.4) }
    var hover: Color { ink.opacity(0.07) }
    var field: Color { ink.opacity(0.06) }

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

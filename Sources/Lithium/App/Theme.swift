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

    @MainActor static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        nsFont(size, weight).map(Font.init) ?? .system(size: size, weight: weight)
    }

    /// Reading the choice inside a view's body makes the view redraw when it changes.
    @MainActor static func nsFont(_ size: CGFloat, _ weight: Font.Weight = .regular) -> NSFont? {
        if let family = FontChoice.shared.interface, let font = pickedFont(family, size, weight) { return font }
        let key = "\(size) \(weightValue(weight))"
        if let font = dmSansFonts[key] { return font }
        guard let base = NSFont(name: baseFontName, size: size) else { return nil }
        let descriptor = base.fontDescriptor.addingAttributes([
            NSFontDescriptor.AttributeName(kCTFontVariationAttribute as String): [
                opticalSizeAxis: min(max(size, 9), 40),
                weightAxis: weightValue(weight),
            ],
        ])
        let font = NSFont(descriptor: descriptor, size: size) ?? base
        dmSansFonts[key] = font
        return font
    }

    /// DM Sans at each size and weight, built once: the default font is asked for on every redraw too.
    @MainActor private static var dmSansFonts: [String: NSFont] = [:]

    /// Every view asks on each redraw, so each size and weight is matched once per family.
    /// A miss is kept as nil too, or a picked font later removed from the Mac is looked up again on every redraw.
    @MainActor private(set) static var pickedFonts: (family: String, fonts: [String: NSFont?]) = ("", [:])
    /// Fonts installed or removed while Lithium runs: a font reinstalled since its miss is found at the next redraw.
    @MainActor private static var fontSetObserver: (any NSObjectProtocol)?
    /// Lookups that missed the cache, for the tests.
    @MainActor private(set) static var pickedFontLookups = 0
    /// Font set changes seen by the observer, for the tests: only it moves this, unlike the family.
    @MainActor private(set) static var fontSetChanges = 0

    /// Nil for a family not on this Mac.
    @MainActor static func pickedFont(_ family: String, _ size: CGFloat, _ weight: Font.Weight) -> NSFont? {
        if pickedFonts.family != family { pickedFonts = (family, [:]) }
        let key = "\(size) \(weightValue(weight))"
        if let cached = pickedFonts.fonts[key] { return cached }
        // NSFontManager's weights run 0 to 15: 5 regular, 6 medium, 8 semibold, 9 bold.
        pickedFontLookups += 1
        let scale = switch weightValue(weight) { case 500: 6; case 600: 8; case 700: 9; default: 5 }
        let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: scale, size: size)
        if font == nil, fontSetObserver == nil {
            fontSetObserver = NotificationCenter.default.addObserver(forName: NSFont.fontSetChangedNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    pickedFonts = ("", [:])
                    fontSetChanges += 1
                }
            }
        }
        pickedFonts.fonts.updateValue(font, forKey: key)
        return font
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
    static let interfaceFont = "interfaceFont"
    static let websiteFamily = "websiteFontFamily"
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
    static let passwordOffers = "passwordOffers"
    static let passwordUnlock = "passwordUnlock"
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

/// How eagerly the collapsed sidebar slides out, and how long it stays once the pointer leaves.
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

    var openDelay: Duration {
        switch self {
        case .responsive: .milliseconds(50)
        case .normal: .milliseconds(150)
        case .calm: .milliseconds(300)
        }
    }

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

/// Colors drawn on the sidebar background. Surfaces are black over it (white washed a colored
/// sidebar out to grey); a near-black sidebar gets the same color lighter instead.
struct SidebarPalette {
    let ink: Color
    let isDark: Bool
    private let overlay: Color
    private let steps: (tile: Double, tileHover: Double, selection: Double)

    /// Favorites, the mini player and the address field at rest.
    var tile: Color { overlay.opacity(steps.tile) }
    var hover: Color { tile }
    /// Half a resting favorite, so a hovered row never looks like the current tab.
    var rowHover: Color { overlay.opacity(steps.tile / 2) }
    var tileHover: Color { overlay.opacity(steps.tileHover) }
    /// The current favorite. A dark color needs more black for a step the eye still sees.
    var selection: Color { overlay.opacity(steps.selection) }
    var field: Color { tile }

    func tileFill(isSelected: Bool, isHovered: Bool) -> Color {
        isSelected ? selection : isHovered ? tileHover : tile
    }

    func rowFill(isSelected: Bool, isHovered: Bool) -> Color {
        isSelected ? tile : isHovered ? rowHover : .clear
    }

    /// Under this brightest channel a tile's 18 % black takes off under five 8-bit levels: the eye
    /// loses it. Luminance would call pure blue near-black.
    private static let nearBlack = 0.1
    /// Under this brightest channel, hover's 12 % more black is under five levels: wider steps.
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

    /// The same hue at full brightness, halfway to white, so it lightens without shifting the hue.
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

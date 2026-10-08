import AppKit

/// The fonts the user picked instead of DM Sans: one for Lithium itself, one for websites.
/// Observable so that views drawn with `Theme.font` redraw when the interface font changes.
@MainActor @Observable
final class FontChoice {
    static let shared = FontChoice()
    static let dmSans = "DM Sans"

    /// Nil for DM Sans.
    private(set) var interface: String?
    /// Nil to follow the interface font.
    private(set) var website: String?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        interface = defaults.string(forKey: Preference.interfaceFont)
        website = defaults.string(forKey: Preference.websiteFamily)
    }

    /// The font websites get: DM Sans for a font no longer on this Mac, which pages would
    /// otherwise replace with the system's.
    var websiteFamily: String {
        let family = website ?? interface ?? Self.dmSans
        return Self.isInstalled(family) ? family : Self.dmSans
    }

    /// DM Sans or nil goes back to the default.
    func setInterface(_ family: String?) {
        interface = family == Self.dmSans || family?.isEmpty == true ? nil : family
        defaults.set(interface, forKey: Preference.interfaceFont)
    }

    /// Nil or empty follows the interface font.
    func setWebsite(_ family: String?) {
        website = family?.isEmpty == true ? nil : family
        defaults.set(website, forKey: Preference.websiteFamily)
    }

    /// The families Settings offers: DM Sans first, then the Mac's own, without the system's
    /// hidden ones (their names start with a dot). Read when Settings asks, never at launch.
    static func families() -> [String] {
        let installed = NSFontManager.shared.availableFontFamilies
            .filter { !$0.hasPrefix(".") && $0 != dmSans }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return [dmSans] + installed
    }

    /// DM Sans ships with Lithium; any other family must be installed on this Mac.
    static func isInstalled(_ family: String) -> Bool {
        family == dmSans || NSFontManager.shared.availableMembers(ofFontFamily: family) != nil
    }
}

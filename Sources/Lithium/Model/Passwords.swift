import AppKit

/// Apple's Passwords app, as far as Lithium can reach it. Filling and saving its passwords in web
/// pages takes either Safari's own WebKit hooks or Apple's iCloud Passwords extension, whose
/// helper app macOS 15.5 and later only start for browsers Apple lists by team ID; a passkey sheet
/// for any site takes an entitlement Apple grants to a developer team. Lithium has none of those,
/// so it hands off to the app instead: Open Passwords in a field's menu and in Settings. Nothing
/// here runs until one of them is used.
@MainActor
enum Passwords {
    static let bundleIdentifier = "com.apple.Passwords"
    /// Apple's iCloud Passwords in the Chrome Web Store, which can't reach the app from Lithium.
    static let iCloudExtensionID = "pejdijmoenmkgeppbflobdenhhabjlaj"
    static let menuTitle = "Open Passwords"

    /// Where the app is, looked up when a menu or the store asks; tests give their own.
    static var appURL: () -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) }
    static var openApp: (URL) -> Void = { url in
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Brings the app forward, where the user can copy a password. False on a Mac without it.
    @discardableResult
    static func open() -> Bool {
        guard let url = appURL() else { return false }
        openApp(url)
        return true
    }

    private static let pasteIdentifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierPaste")

    /// Open Passwords goes after Paste and Force Paste, so only in an editable field, where a
    /// password would be typed, as macOS puts AutoFill there in its own text fields.
    static func addOpenPasswords(to menu: NSMenu) {
        guard let paste = menu.items.firstIndex(where: { $0.identifier == pasteIdentifier }), appURL() != nil else { return }
        let next = menu.items.index(after: paste)
        let after = next < menu.items.endIndex && menu.items[next].title == PageOverrides.forcePasteTitle ? next + 1 : next
        let item = NSMenuItem(title: menuTitle, action: #selector(Target.open(_:)), keyEquivalent: "")
        item.target = Target.shared
        menu.insertItem(item, at: after)
    }

    /// The menu item's target: a menu holds its target weakly.
    @MainActor
    final class Target: NSObject {
        static let shared = Target()
        @objc func open(_ sender: Any?) { Passwords.open() }
    }
}

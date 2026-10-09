import AppKit

/// Apple's Passwords app, as far as Lithium can reach it. AutoFill takes Safari's own WebKit hooks
/// or the iCloud Passwords extension, whose helper macOS 15.5+ only starts for browsers Apple lists,
/// and passkeys take an entitlement Apple grants: Lithium has none, so it hands off to the app.
@MainActor
enum Passwords {
    static let bundleIdentifier = "com.apple.Passwords"
    /// Apple's iCloud Passwords in the Chrome Web Store, which can't reach the app from Lithium.
    static let iCloudExtensionID = "pejdijmoenmkgeppbflobdenhhabjlaj"
    static let menuTitle = "Open Passwords"

    /// Tests give their own.
    static var appURL: () -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) }
    static var openApp: (URL) -> Void = { url in
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    @discardableResult
    static func open() -> Bool {
        guard let url = appURL() else { return false }
        openApp(url)
        return true
    }

    private static let pasteIdentifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierPaste")

    /// After Paste and Force Paste, so only in an editable field, as macOS puts AutoFill.
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

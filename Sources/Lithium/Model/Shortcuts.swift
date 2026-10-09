import AppKit

/// Lithium's shortcuts win over the page's (#127). AppKit offers a key equivalent to the views
/// before the menu, and WebKit hands it to the page first, so a page that prevents its `keydown`
/// keeps the menu from ever seeing it. The web view asks the menu first instead, except for the
/// text-editing keys, which pages implement themselves.
@MainActor
enum Shortcuts {
    private static let editingKeys: Set<Key> = [
        Key("a", .command), Key("x", .command), Key("c", .command), Key("v", .command), Key("v", [.command, .option, .shift]),
        Key("z", .command), Key("z", [.command, .shift]), Key(";", .command), Key(":", [.command, .shift]),
    ]

    private struct Key: Hashable {
        static let modifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        let characters: String
        let flags: UInt

        init(_ characters: String, _ flags: NSEvent.ModifierFlags) {
            // ⇧⇥ comes as a back tab.
            self.characters = characters == "\u{19}" ? "\t" : characters.lowercased()
            self.flags = flags.intersection(Self.modifiers).rawValue
        }

        init(_ event: NSEvent) {
            self.init(event.charactersIgnoringModifiers ?? "", event.modifierFlags)
        }

        /// A menu item's: an uppercase letter means Shift.
        init(_ item: NSMenuItem) {
            let shift: NSEvent.ModifierFlags = item.keyEquivalent == item.keyEquivalent.lowercased() ? [] : .shift
            self.init(item.keyEquivalent, item.keyEquivalentModifierMask.union(shift))
        }
    }

    /// ⌘ keys not for editing, and only Lithium's ⌃ keys (⌃⇥, ⌃1–9): others move the cursor in text
    /// fields, and macOS 15's Fill is fn⌃F, but `keyEquivalentModifierMask` hides fn.
    static func isMenusFirst(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, !event.modifierFlags.isDisjoint(with: [.command, .control]) else { return false }
        let key = Key(event)
        if !event.modifierFlags.contains(.command), key.characters != "\t", !("1"..."9").contains(key.characters) { return false }
        return !editingKeys.contains(key) && !NativeInput.isAgents(event)
    }

    /// False for a disabled item (`NSMenu.performKeyEquivalent` would swallow the key): the page
    /// gets it, and WebKit passes it back to the menu if the page doesn't use it.
    static func performInMenu(_ event: NSEvent, menu: NSMenu?) -> Bool {
        guard isMenusFirst(event), let menu, let item = item(for: Key(event), in: menu), isEnabled(item),
              let owner = item.menu else { return false }
        owner.performActionForItem(at: owner.index(of: item))
        return true
    }

    /// The item and every submenu it is in (Developer, without the Web Inspector).
    private static func isEnabled(_ item: NSMenuItem) -> Bool {
        guard let menu = item.menu else { return false }
        menu.update()
        guard item.isEnabled else { return false }
        guard let parent = menu.supermenu else { return true }
        let index = parent.indexOfItem(withSubmenu: menu)
        return index >= 0 && isEnabled(parent.items[index])
    }

    /// Not in the Services menu, whose shortcuts are for other apps. A symbol typed with Shift
    /// (⇧⌘= for Zoom In's "+") matches the item without it.
    private static func item(for key: Key, in menu: NSMenu) -> NSMenuItem? {
        let unshifted = Key(key.characters, NSEvent.ModifierFlags(rawValue: key.flags).subtracting(.shift))
        for item in menu.items {
            if let submenu = item.submenu {
                if submenu !== NSApp.servicesMenu, let found = self.item(for: key, in: submenu) { return found }
            } else if !item.keyEquivalent.isEmpty, !item.isHidden {
                let own = Key(item)
                if own == key || (own == unshifted && !key.characters.contains(where: \.isLetter)) { return item }
            }
        }
        return nil
    }
}

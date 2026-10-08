import AppKit

/// Lithium's shortcuts win over the page's (#127). AppKit offers a key equivalent to the window's
/// views before the menu, and WebKit hands it to the page first: a page that prevents its
/// `keydown` (⌘B on claude.ai) keeps the menu from ever seeing it. The page's web view asks the
/// menu first instead, except for the text-editing keys, which pages implement themselves (a
/// web editor's own undo, copy and paste). The menu itself is the list of Lithium's shortcuts,
/// so there is nothing to keep in sync; a key it has no enabled item for still goes to the page.
@MainActor
enum Shortcuts {
    /// The page's first: Select All, Cut, Copy, Paste, Paste and Match Style, Undo, Redo and the
    /// spelling commands.
    private static let editingKeys: Set<Key> = [
        Key("a", .command), Key("x", .command), Key("c", .command), Key("v", .command), Key("v", [.command, .option, .shift]),
        Key("z", .command), Key("z", [.command, .shift]), Key(";", .command), Key(":", [.command, .shift]),
    ]

    /// Characters lowercased, as `charactersIgnoringModifiers` gives them, and the modifiers.
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

    /// Whether the menu gets `event` before the page: a ⌘ key the user pressed that isn't for
    /// editing text, or one of Lithium's ⌃ keys (⌃⇥, ⌃1–9). Other ⌃ keys move the cursor in text
    /// fields (⌃F), and macOS 15's Window ▸ Move & Resize items look like them: Fill is fn⌃F, but
    /// `keyEquivalentModifierMask` hides fn. An agent's keys are the page's (`NativeInput`).
    static func isMenusFirst(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, !event.modifierFlags.isDisjoint(with: [.command, .control]) else { return false }
        let key = Key(event)
        if !event.modifierFlags.contains(.command), key.characters != "\t", !("1"..."9").contains(key.characters) { return false }
        return !editingKeys.contains(key) && !NativeInput.isAgents(event)
    }

    /// Runs the menu item `event` is the shortcut of, if it is the menu's to take first. False
    /// when it isn't, or the item is disabled (`NSMenu.performKeyEquivalent` would swallow the key
    /// then): the page gets it as usual, and WebKit passes it back to the menu if the page doesn't
    /// use it. The item found is the one run, so the lookup alone decides.
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

    /// The item with that shortcut, outside the Services menu, whose shortcuts the user picks for
    /// other apps. A symbol typed with Shift (⇧⌘= for Zoom In's "+") matches the item without it.
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

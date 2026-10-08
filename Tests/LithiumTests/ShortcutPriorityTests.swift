import AppKit
import Testing
import WebKit
@testable import Lithium

/// Lithium's shortcuts before the page's (#127): which keys the menu takes first, and that the
/// page's web view hands them over. A menu of the test's own stands in for the app's.
@MainActor
@Suite(.serialized)
struct ShortcutPriorityTests {
    /// Lithium's shortcuts go to the menu first; editing keys and keys typed without ⌘ or ⌃
    /// stay the page's.
    @Test func lithiumsShortcutsGoToTheMenuFirstAndEditingKeysToThePage() throws {
        for (characters, flags) in [("b", NSEvent.ModifierFlags.command), ("t", .command), ("w", .command), ("l", .command),
                                    ("d", .command), ("f", .command), ("F", [.command, .shift]), ("[", .command), ("]", .command),
                                    ("1", .command), ("1", .control), ("\t", .control), ("C", [.command, .shift])] {
            #expect(Shortcuts.isMenusFirst(try key(characters, flags)), "\(flags) \(characters)")
        }
        #expect(Shortcuts.isMenusFirst(try key(arrow, [.command, .option, .function, .numericPad])), "Next Tab")
        // Caps Lock changes neither side.
        #expect(Shortcuts.isMenusFirst(try key("B", [.command, .capsLock])))

        for (characters, flags) in [("c", NSEvent.ModifierFlags.command), ("v", .command), ("x", .command), ("a", .command),
                                    ("z", .command), ("Z", [.command, .shift]), ("V", [.command, .option, .shift]),
                                    ("C", [.command, .capsLock])] {
            #expect(!Shortcuts.isMenusFirst(try key(characters, flags)), "editing: \(flags) \(characters)")
        }
        let typing: [(String, NSEvent.ModifierFlags)] = [("b", []), ("B", .shift), ("b", .option), (arrow, [.option, .function, .numericPad]), ("\u{1b}", [])]
        for (characters, flags) in typing {
            #expect(!Shortcuts.isMenusFirst(try key(characters, flags)), "typing: \(flags) \(characters)")
        }
    }

    /// The menu runs the shortcut it has an enabled item for, in a submenu too; anything else,
    /// and an item that is disabled or in a disabled submenu, is left to the page.
    @Test func onlyAnEnabledShortcutOfTheMenuIsTaken() throws {
        let (menu, actions) = testMenu()
        #expect(Shortcuts.performInMenu(try key("b", .command), menu: menu))
        #expect(Shortcuts.performInMenu(try key("C", [.command, .shift]), menu: menu))
        #expect(Shortcuts.performInMenu(try key("+", [.command, .shift]), menu: menu), "⇧⌘= is Zoom In's ⌘+")
        #expect(Shortcuts.performInMenu(try key(arrow, [.command, .option, .function, .numericPad]), menu: menu))
        #expect(Shortcuts.performInMenu(try key("\u{19}", [.control, .shift]), menu: menu), "⌃⇧⇥")
        #expect(actions.ran == ["sidebar", "copy link", "zoom in", "next tab", "previous recent tab"], "\(actions.ran)")

        #expect(!Shortcuts.performInMenu(try key("c", .command), menu: menu), "Copy is the page's")
        #expect(!Shortcuts.performInMenu(try key("k", .command), menu: menu), "not Lithium's")
        #expect(!Shortcuts.performInMenu(try key("B", [.command, .shift]), menu: menu), "not Lithium's")
        #expect(!Shortcuts.performInMenu(try key("d", .command), menu: menu), "disabled")
        #expect(!Shortcuts.performInMenu(try key("i", [.command, .option]), menu: menu), "in a disabled submenu")
        #expect(!Shortcuts.performInMenu(try key("b", .command), menu: nil))
        #expect(actions.ran.count == 5, "\(actions.ran)")
    }

    /// macOS 15's Window ▸ Move & Resize items need fn (Fill is fn⌃F), which their
    /// `keyEquivalentModifierMask` hides: ⌃F, ⌃C and ⌃← in a text field stay the page's, fn held
    /// or not (arrow keys always come with fn). Lithium's ⌃1 and ⌃⇥ still go to the menu.
    @Test func controlKeysOtherThanLithiumsStayThePages() throws {
        _ = NSApplication.shared
        let actions = Actions()
        let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (title, key) in [("fill", "f"), ("center", "c"), ("left", left), ("first tab", "1"), ("next recent tab", "\t")] {
            let item = NSMenuItem(title: title, action: #selector(Actions.run(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = [.function, .control]
            item.target = actions
            menu.addItem(item)
        }
        let keys: [(String, NSEvent.ModifierFlags)] = [("f", .control), ("f", [.control, .function]), ("c", .control),
                                                       (left, [.control, .function, .numericPad])]
        for (characters, flags) in keys {
            #expect(!Shortcuts.performInMenu(try key(characters, flags), menu: menu), "\(flags) \(characters)")
        }
        #expect(actions.ran.isEmpty, "\(actions.ran)")
        #expect(Shortcuts.performInMenu(try key("1", .control), menu: menu))
        #expect(Shortcuts.performInMenu(try key("\t", .control), menu: menu))
        #expect(actions.ran == ["first tab", "next recent tab"], "\(actions.ran)")
    }

    /// A page's web view gives Lithium's shortcut to the menu, whatever the page listens to, and
    /// keeps an editing key for the page.
    @Test func thePagesWebViewHandsLithiumsShortcutToTheMenu() throws {
        let (menu, actions) = testMenu()
        let original = PageWebView.mainMenu
        PageWebView.mainMenu = { menu }
        defer { PageWebView.mainMenu = original }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = PageWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)

        #expect(webView.performKeyEquivalent(with: try key("b", .command)))
        #expect(actions.ran == ["sidebar"])
        _ = webView.performKeyEquivalent(with: try key("c", .command))
        _ = webView.performKeyEquivalent(with: try key("k", .command))
        #expect(actions.ran == ["sidebar"], "Copy and unused keys aren't the menu's")
    }

    private let arrow = String(UnicodeScalar(NSRightArrowFunctionKey)!)

    /// Hide Sidebar (⌘B), Copy (⌘C), a disabled Pin Tab (⌘D), a Tabs submenu and a disabled
    /// Developer submenu.
    private func testMenu() -> (NSMenu, Actions) {
        // A menu item's action goes through NSApp, which the test process may not have yet.
        _ = NSApplication.shared
        let actions = Actions()
        func item(_ title: String, _ key: String, _ flags: NSEvent.ModifierFlags = .command, enabled: Bool = true) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(Actions.run(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = flags
            item.target = actions
            item.isEnabled = enabled
            return item
        }
        func menu(_ items: [NSMenuItem]) -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            items.forEach(menu.addItem)
            return menu
        }
        let tabs = NSMenuItem(title: "Tabs", action: nil, keyEquivalent: "")
        tabs.submenu = menu([item("copy link", "c", [.command, .shift]), item("zoom in", "+"), item("next tab", arrow, [.command, .option]),
                             item("previous recent tab", "\t", [.control, .shift])])
        let developer = NSMenuItem(title: "Developer", action: nil, keyEquivalent: "")
        developer.submenu = menu([item("inspector", "i", [.command, .option])])
        developer.isEnabled = false
        return (menu([item("sidebar", "b"), item("copy", "c"), item("pin", "d", enabled: false), tabs, developer]), actions)
    }

    private final class Actions: NSObject {
        var ran: [String] = []
        @objc func run(_ sender: NSMenuItem) { ran.append(sender.title) }
    }

    private func key(_ characters: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                      characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0))
    }
}

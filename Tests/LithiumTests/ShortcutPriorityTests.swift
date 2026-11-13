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
                                    ("V", [.command, .shift]), ("C", [.command, .capsLock])] {
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

    /// ⇧⌘V that no view took pastes without formatting into whatever has the keyboard. No other
    /// key does, ⌘V and the menu's own ⌥⇧⌘V included, and nothing happens where nothing can paste.
    @Test func shiftCommandVNobodyTookPastesWithoutFormatting() throws {
        _ = NSApplication.shared
        let window = OffscreenPageWindow(contentRect: NSRect(x: -30000, y: -30000, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let field = Pasting(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView = field
        defer { window.contentView = nil }
        #expect(window.makeFirstResponder(field))

        #expect(window.performKeyEquivalent(with: try key("V", [.command, .shift])))
        #expect(field.pastes == 1)
        #expect(window.performKeyEquivalent(with: try key("V", [.command, .shift, .capsLock])), "Caps Lock changes nothing")
        #expect(field.pastes == 2)
        let others: [(String, NSEvent.ModifierFlags)] = [("v", .command), ("V", [.command, .option, .shift]), ("B", [.command, .shift]),
                                                         ("V", .shift), ("V", [.control, .shift]), ("v", [])]
        for (characters, flags) in others {
            #expect(!window.performKeyEquivalent(with: try key(characters, flags)), "\(flags) \(characters)")
        }
        #expect(field.pastes == 2)

        // Nothing has the keyboard but the window, which cannot paste.
        #expect(window.makeFirstResponder(nil))
        #expect(!window.performKeyEquivalent(with: try key("V", [.command, .shift])))
        #expect(field.pastes == 2)
    }

    /// The whole way, in a page. The page has ⇧⌘V first, as a `keydown`. Left alone, WebKit sends
    /// the key to the app again and the window pastes without formatting: the page gets a `paste`.
    /// A page that takes the key (an editor with a ⇧⌘V of its own) gets no paste from Lithium.
    @Test func aPageHasShiftCommandVFirstAndThePasteWhenItLeavesTheKey() async throws {
        let app = NSApplication.shared
        let window = OffscreenPageWindow(contentRect: NSRect(x: -30000, y: -30000, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = PageWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        window.contentView = webView
        window.orderFrontRegardless()
        // The app sends a key to its key window. The test process is not the app in front, so this
        // takes no keyboard from anyone.
        window.makeKey()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        #expect(window.screen == nil, "the window must stay off screen")
        // The paste is prevented: the page hears of it, and the clipboard is never read.
        webView.loadHTMLString("""
            <div id="editor" contenteditable>text</div>
            <script>
              window.keys = []; window.pastes = 0;
              addEventListener('keydown', (event) => {
                keys.push((event.metaKey ? 'meta+' : '') + (event.shiftKey ? 'shift+' : '') + (event.altKey ? 'alt+' : '') + event.key.toLowerCase());
                if (window.takesTheKey) event.preventDefault();
              });
              addEventListener('paste', (event) => { pastes += 1; event.preventDefault(); });
              document.getElementById('editor').focus();
              getSelection().selectAllChildren(document.getElementById('editor'));
            </script>
            """, baseURL: nil)
        for _ in 0..<300 where webView.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        #expect(window.makeFirstResponder(webView))

        func press() async throws -> (keys: [String], pastes: Int) {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, characters: "V", charactersIgnoringModifiers: "V", isARepeat: false, keyCode: 9))
            app.sendEvent(event)
            // The page answers in its own process, then WebKit sends the key again.
            try await Task.sleep(for: .milliseconds(700))
            let state = try #require(try await webView.evaluateJavaScript("[keys, pastes]") as? [Any])
            return (state[0] as? [String] ?? [], state[1] as? Int ?? -1)
        }
        let left = try await press()
        #expect(left.keys == ["meta+shift+v"], "the page has the key first")
        #expect(left.pastes == 1, "left alone, it pastes without formatting")

        _ = try await webView.evaluateJavaScript("window.takesTheKey = true")
        let taken = try await press()
        #expect(taken.keys == ["meta+shift+v", "meta+shift+v"])
        #expect(taken.pastes == 1, "the page took the key: no paste of Lithium's")
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

    /// A `PageWindow` that stays where it is put: borderless, and never moved back on a screen.
    private final class OffscreenPageWindow: PageWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
        override var canBecomeKey: Bool { true }
    }

    /// A view that takes the keyboard and counts the plain pastes sent to it.
    private final class Pasting: NSView {
        var pastes = 0
        override var acceptsFirstResponder: Bool { true }
        @objc func pasteAsPlainText(_ sender: Any?) { pastes += 1 }
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

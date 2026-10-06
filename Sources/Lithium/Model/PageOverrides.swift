import AppKit
import WebKit

/// The user's own menu and paste, on sites that block them. Shift with a right click opens
/// Lithium's context menu even where the page cancels `contextmenu`, and Force Paste types the
/// clipboard's text into a field whose page cancels pasting.
@MainActor
enum PageOverrides {
    /// One capture listener on `window`, at document start in Lithium's own content world, so it
    /// runs before any of the page's and the page can neither see nor remove it. Without Shift it
    /// returns at once; with it, it stops the event there, so no page handler can cancel it and
    /// WebKit opens its menu. Added after `PageTranslation.script`, whose listener still runs.
    static let script = WKUserScript(source: """
        addEventListener('contextmenu', event => { if (event.shiftKey) event.stopImmediatePropagation(); }, true);
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient)

    static let forcePasteTitle = "Force Paste"
    /// The clipboard; tests paste from one of their own.
    static var pasteboard = { NSPasteboard.general }
    private static let pasteIdentifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierPaste")

    /// Force Paste goes right after WebKit's Paste, which the menu only has in an editable field.
    static func addForcePaste(to menu: NSMenu, in webView: PageWebView) {
        guard let paste = menu.items.firstIndex(where: { $0.identifier == pasteIdentifier }) else { return }
        let item = NSMenuItem(title: forcePasteTitle, action: #selector(PageWebView.forcePaste(_:)), keyEquivalent: "")
        item.target = webView
        menu.insertItem(item, at: paste + 1)
    }

    /// Types the clipboard's plain text where the page's focus is, in whichever frame, as an input
    /// method inserts text: the page gets `beforeinput` and `input` for typed text, never `paste`
    /// or the ⌘V keystroke, which is what sites cancel. The clipboard is read only here.
    @discardableResult
    static func forcePaste(into webView: WKWebView) -> Bool {
        guard let text = pasteboard().string(forType: .string), !text.isEmpty,
              let client = webView as NSView as? NSTextInputClient else { return false }
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        return true
    }
}

extension PageWebView {
    @objc func forcePaste(_ sender: Any?) {
        PageOverrides.forcePaste(into: self)
    }

    /// ⌥⇧⌘V reaches the page focused before the main menu, whose Paste and Match Style may have it too.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, !NativeInput.isAgents(event),
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .option, .shift],
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            forcePaste(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

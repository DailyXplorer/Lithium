import AppKit
import WebKit

/// The user's own menu and paste, on sites that block them. Shift with a right click opens
/// Lithium's context menu even where the page cancels `contextmenu`, and Force Paste types the
/// clipboard's text into a field whose page cancels pasting.
@MainActor
enum PageOverrides {
    /// A capture listener at document start in Lithium's world, so it runs before the page's and the
    /// page can't remove it; with Shift it stops the event so WebKit opens its menu. Added after
    /// `PageTranslation.script`, whose listener still runs. In `agent.js`'s world so an armed agent's
    /// right click reaches the page.
    static let script = WKUserScript(source: """
        addEventListener('contextmenu', event => {
          if (event.shiftKey && !(globalThis.lithiumAgentFrame?.agentMenu > Date.now())) event.stopImmediatePropagation();
        }, true);
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: PageProbe.world)

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

    /// Inserts the clipboard's text as an input method would, so the page never gets `paste` or ⌘V,
    /// which is what sites cancel. The clipboard is read only when a field or a frame has the focus.
    @discardableResult
    static func forcePaste(into webView: WKWebView) async -> Bool {
        let focused = try? await webView.callAsyncJavaScript("""
            const element = document.activeElement;
            return /^i?frame$|^textarea$/.test(element?.localName) || !!element?.isContentEditable
              || (element?.localName === 'input' && /^(text|search|email|url|tel|password|number)$/.test(element.type));
            """, contentWorld: .defaultClient) as? Bool
        guard focused == true, let text = pasteboard().string(forType: .string), !text.isEmpty,
              let client = webView as NSView as? NSTextInputClient else { return false }
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        return true
    }
}

extension PageWebView {
    @objc func forcePaste(_ sender: Any?) {
        Task { await PageOverrides.forcePaste(into: self) }
    }
}

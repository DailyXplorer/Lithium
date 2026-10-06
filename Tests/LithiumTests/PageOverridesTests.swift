import AppKit
import Network
import Testing
import WebKit
@testable import Lithium

/// Shift with a right click, and Force Paste, on a page that blocks its context menu and pasting.
/// A whole Browser keeps its data in the home folder, so this suite only runs in a throwaway one:
/// `scripts/test --filter PageOverridesTests`.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct PageOverridesTests {
    private static let page = """
        <!doctype html><title>Blocked</title>
        <script>
        window.log = [];
        const block = event => {
          log.push(event.type + (event.inputType ? ':' + event.inputType : ''));
          if (event.type !== 'beforeinput' || event.inputType === 'insertFromPaste') event.preventDefault();
        };
        for (const type of ['contextmenu', 'paste', 'beforeinput']) addEventListener(type, block, true);
        document.oncontextmenu = () => false;
        </script>
        <input id="field"><input id="secret" type="password">
        <iframe srcdoc="<p id=inner>Frame</p><script>addEventListener('contextmenu', event => { parent.log.push('frame:contextmenu'); event.preventDefault(); }, true)</script>"></iframe>
        """

    /// Counts the reads of a clipboard of the test's own, never the user's.
    private final class Clipboard {
        let board = NSPasteboard.withUniqueName()
        var reads = 0

        init(_ text: String) {
            board.declareTypes([.string], owner: nil)
            board.setString(text, forType: .string)
        }
    }

    private func withPage(_ body: @MainActor (PageWebView, Clipboard) async throws -> Void) async throws {
        let clipboard = Clipboard("hunter2")
        let previous = PageOverrides.pasteboard
        PageOverrides.pasteboard = { clipboard.reads += 1; return clipboard.board }
        defer {
            PageOverrides.pasteboard = previous
            clipboard.board.releaseGlobally()
        }
        let browser = Browser()
        let (server, base) = try await LocalHTTP.serve(["/": ("Content-Type: text/html", Self.page)])
        defer { server.cancel() }
        let tab = browser.newTab(url: base, selecting: false)
        let ready = await waitUntil(30) {
            try await tab.webView.evaluateJavaScript("document.readyState === 'complete' && !!frames[0].document.getElementById('inner')") as? Bool == true
        }
        try #require(ready)
        let webView = try #require(tab.webView as? PageWebView)
        try await body(webView, clipboard)
    }

    private func waitUntil(_ seconds: Double, _ condition: () async throws -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if (try? await condition()) == true { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private func page(_ webView: WKWebView, _ script: String) async throws -> Any? {
        try await webView.callAsyncJavaScript(script, contentWorld: .page)
    }

    /// Focuses a field and resolves `typed` with its value at its next `input`.
    private func focus(_ id: String, in webView: WKWebView) async throws {
        _ = try await page(webView, """
            const field = document.getElementById('\(id)');
            field.focus();
            log.length = 0;
            window.typed = new Promise(resolve => field.addEventListener('input', () => resolve(field.value), { once: true }));
            """)
    }

    @Test func shiftRightClickGetsPastThePagesHandlersInEveryFrame() async throws {
        try await withPage { webView, clipboard in
            // `dispatchEvent` returns false when a handler cancelled the menu.
            let shown = try await page(webView, """
                const fire = (target, shiftKey) => target.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, shiftKey }));
                const inner = frames[0].document.getElementById('inner');
                return [fire(document.body, false), fire(document.body, true), fire(inner, false), fire(inner, true)];
                """) as? [Bool]
            #expect(shown == [false, true, false, true])
            #expect(try await page(webView, "return log") as? [String] == ["contextmenu", "frame:contextmenu"])

            // One listener, in Lithium's world, added again with each page and nothing else.
            let scripts = { webView.configuration.userContentController.userScripts.filter { $0.source == PageOverrides.script.source } }
            #expect(scripts().count == 1)
            #expect(scripts().first?.isForMainFrameOnly == false)
            webView.reload()
            #expect(await waitUntil(30) { try await webView.evaluateJavaScript("window.log && log.length === 0 && document.readyState === 'complete'") as? Bool == true })
            #expect(scripts().count == 1)
            #expect(clipboard.reads == 0)
        }
    }

    @Test func forcePasteTypesTheClipboardWhereThePageBlocksPasting() async throws {
        try await withPage { webView, clipboard in
            try await focus("field", in: webView)
            #expect(PageOverrides.forcePaste(into: webView))
            #expect(try await page(webView, "return await typed") as? String == "hunter2")
            // Typed text, not a paste: the page's paste handlers never ran.
            #expect(try await page(webView, "return log") as? [String] == ["beforeinput:insertText"])
            #expect(clipboard.reads == 1)

            clipboard.board.clearContents()
            #expect(!PageOverrides.forcePaste(into: webView))
        }
    }

    /// WebKit's menu, which has Paste only in an editable field, opened by a right click.
    private func menu(withPaste: Bool, in webView: PageWebView) throws -> NSMenu {
        let menu = NSMenu()
        for identifier in withPaste ? ["Cut", "Copy", "Paste"] : ["Copy"] {
            let item = NSMenuItem(title: identifier, action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifier" + identifier)
            menu.addItem(item)
        }
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: NSPoint(x: 20, y: 20), modifierFlags: [.shift], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        webView.willOpenMenu(menu, with: event)
        return menu
    }

    @Test func contextMenuOfAFieldOffersForcePasteAfterPaste() async throws {
        try await withPage { webView, clipboard in
            #expect(try menu(withPaste: false, in: webView).items.map(\.title) == ["Copy"])
            let editable = try menu(withPaste: true, in: webView)
            #expect(editable.items.map(\.title) == ["Cut", "Copy", "Paste", "Force Paste"])
            #expect(clipboard.reads == 0)

            try await focus("secret", in: webView)
            let item = editable.items[3]
            #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
            #expect(try await page(webView, "return await typed") as? String == "hunter2")
            #expect(clipboard.reads == 1)
        }
    }

    @Test func optionShiftCommandVForcePastesInTheFocusedPageOnly() async throws {
        try await withPage { webView, clipboard in
            let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.contentView = nil }
            window.contentView = webView
            let key = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command, .option, .shift], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "◊", charactersIgnoringModifiers: "V", isARepeat: false, keyCode: 9
            ))
            window.makeFirstResponder(nil)
            _ = webView.performKeyEquivalent(with: key)
            #expect(clipboard.reads == 0)

            window.makeFirstResponder(webView)
            try await focus("field", in: webView)
            #expect(webView.performKeyEquivalent(with: key))
            #expect(try await page(webView, "return await typed") as? String == "hunter2")
            #expect(clipboard.reads == 1)
        }
    }
}

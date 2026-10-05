import AppKit
import Foundation
import Testing
import WebKit
@testable import Lithium

/// Keys and the key guard, without a page.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AgentKeysTests {
    @Test func namesKeysAsAUSKeyboardTypesThem() throws {
        #expect(NativeKey.typing("a") == NativeKey(code: 0, characters: "a"))
        #expect(NativeKey.typing("A") == NativeKey(code: 0, characters: "a", flags: .shift, shifted: "A"))
        #expect(NativeKey.typing("!") == NativeKey(code: 18, characters: "1", flags: .shift, shifted: "!"))
        #expect(NativeKey.typing("é") == nil)
        #expect(NativeKey.typing("✓") == nil)
        let combo = try #require(NativeKey.parse("Meta+K"))
        #expect(combo.key.code == 40 && combo.key.characters == "k" && combo.key.flags == [] && combo.modifiers == .command)
        let back = try #require(NativeKey.parse("Shift+Tab"))
        #expect(back.key.code == 48 && back.key.characters(with: back.modifiers) == "\u{19}")
        #expect(NativeKey.parse("ArrowDown")?.key.flags == .function)
        #expect(NativeKey.parse("F5")?.key.code == 96)
        #expect(NativeKey.parse("Hyper+K") == nil)
        #expect(NativeKey.parse("NoSuchKey") == nil)
    }

    @Test func theKeyGuardSwallowsOnlyTheAgentsEvents() throws {
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = webView
        defer { window.contentView = nil }
        let input = try NativeInput(webView: webView, check: {}, onPointer: { _ in })
        try input.key(try #require(NativeKey.parse("Meta+W")).key, modifiers: .command)
        let users = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        #expect(NativeInput.guarded(users) === users)
        #expect(!NativeInput.isAgents(users))
    }
}

/// The input tools on a whole Browser, called through the hub as an MCP client calls them, on
/// pages that log every event with `isTrusted`. Background tabs act in the stage, off every
/// screen: nothing here shows a window, activates Lithium, takes the key window or moves the
/// pointer, and every test checks that it didn't.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct AgentInputTests {
    typealias Client = AgentTabsTests.Client

    private static let html = "Content-Type: text/html; charset=utf-8"
    private static let otherOrigin = "location.protocol + '//' + (location.hostname === 'localhost' ? '127.0.0.1' : 'localhost') + ':' + location.port"
    /// Every event the tests look at, in the page's own world, as `type:isTrusted:target`.
    private static let logger = """
        <script>
          window.log = [];
          for (const type of ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click', 'dblclick', 'contextmenu', 'mouseover', 'keydown', 'beforeinput', 'input', 'keyup', 'wheel', 'change']) {
            addEventListener(type, (event) => {
              const target = event.target.id || event.target.localName;
              log.push(`${type}:${event.isTrusted}:${target}` + (type === 'click' ? `:${event.detail}` : '') + (type === 'keydown' && event.metaKey ? ':meta' : ''));
            }, true);
          }
          addEventListener('message', (event) => log.push(event.data));
        </script>
        """

    private static let pages: [String: (headers: String, body: String)] = [
        "/events": (html, """
            <title>Events</title>
            <style>
              body { margin: 0; font: 16px sans-serif; height: 3000px }
              #b { position: absolute; left: 40px; top: 40px; width: 120px; height: 40px }
              #hover { position: absolute; left: 200px; top: 40px; width: 100px; height: 40px; cursor: pointer }
              #hover:hover { background: rgb(255, 0, 0) }
              #field { position: absolute; left: 40px; top: 120px; width: 220px; height: 24px }
              #area { position: absolute; left: 40px; top: 170px; width: 220px; height: 60px }
              #edit { position: absolute; left: 300px; top: 170px; width: 220px; height: 60px; border: 1px solid }
              #range { position: absolute; left: 40px; top: 260px; width: 200px; margin: 0 }
              #pick { position: absolute; left: 300px; top: 260px }
              #agree { position: absolute; left: 300px; top: 120px }
            </style>
            <button id="b">Press</button>
            <div id="hover" role="button">Hover me</div>
            <input id="field" aria-label="Field">
            <textarea id="area" aria-label="Area"></textarea>
            <div id="edit" contenteditable aria-label="Editor"></div>
            <input id="range" type="range" min="0" max="100" value="0" aria-label="Volume">
            <select id="pick" aria-label="Pick"><option value="a">Alpha</option><option value="b">Beta</option></select>
            <label id="agree"><input id="box" type="checkbox"> Agree</label>
            \(logger)
            """),
        "/form": (html, """
            <title>Form</title>
            <form action="/done" method="get"><input id="name" name="name" aria-label="Name"><button>Send</button></form>
            <input id="other" aria-label="Other">
            \(logger)
            """),
        "/frames": (html, """
            <title>Frames</title><style>body { margin: 0 } iframe { position: absolute; left: 100px; top: 50px; border: 3px solid black; padding: 5px; width: 300px; height: 200px }</style>
            <iframe id="other"></iframe>
            <script>document.getElementById('other').src = \(otherOrigin) + '/child';</script>
            \(logger)
            """),
        "/child": (html, """
            <style>body { margin: 0 }</style><button style="position:absolute;left:10px;top:20px;width:80px;height:30px">Inside</button>
            <script>document.querySelector('button').addEventListener('click', (event) => parent.postMessage('child-click:' + event.isTrusted, '*'));</script>
            """),
        "/far-frame": (html, """
            <title>Far frame</title><style>body { margin: 0 } iframe { position: fixed; left: 0; top: 2500px; width: 300px; height: 100px }</style>
            <iframe id="far"></iframe>
            <script>document.getElementById('far').src = \(otherOrigin) + '/field-child';</script>
            \(logger)
            """),
        "/field-child": (html, """
            <input id="inner" aria-label="Inner">
            <script>document.getElementById('inner').addEventListener('input', (event) => parent.postMessage('inner:' + event.target.value, '*'));</script>
            """),
        "/covered": (html, """
            <title>Covered</title><style>body { margin: 0 }</style>
            <button id="under" style="position:absolute;left:40px;top:40px">Under</button>
            <button id="off" disabled style="position:absolute;left:40px;top:300px">Off</button>
            <button id="gone" style="position:absolute;left:200px;top:300px">Gone</button>
            <select id="menu" style="position:absolute;left:40px;top:360px"><option>One</option></select>
            <div id="cookie-banner" style="position:fixed;left:0;top:0;width:100%;height:120px;background:white">We use cookies</div>
            """),
        "/results": (html, """
            <title>Results</title><style>body { margin: 0 }</style>
            <a id="pop" href="/form" target="_blank" style="position:absolute;left:40px;top:40px">Open</a>
            <button id="al" onclick="alert('Saved')" style="position:absolute;left:40px;top:100px">Alert</button>
            <a id="file" href="/report.csv" style="position:absolute;left:40px;top:160px">Report</a>
            <a id="next" href="/done" style="position:absolute;left:40px;top:220px">Next</a>
            """),
        "/report.csv": ("Content-Type: text/csv\r\nContent-Disposition: attachment; filename=report.csv", "a,b"),
        "/pay": (html, """
            <title>Shop</title><style>body { margin: 0 }</style>
            <button id="pay" style="position:absolute;left:40px;top:40px">Pay €42.00</button>
            <form action="/done" style="position:absolute;left:40px;top:120px">
              <input id="user" aria-label="User"><input type="password" id="pw" aria-label="Password">
              <input id="card" autocomplete="cc-number" aria-label="Card number"><input id="cvc" name="cvc" aria-label="CVC">
              <input id="upload" type="file" aria-label="Attachment"><button>Sign in</button>
            </form>
            \(logger)
            """),
        "/moved": (html, """
            <title>Moved</title><style>body { margin: 0 } button { position: absolute; left: 40px; width: 160px; height: 40px }</style>
            <button id="pay" style="top: 40px">Pay €42.00</button>
            <button id="decoy" style="top: 140px">Decoy</button>
            \(logger)
            """),
        "/done": (html, "<title>Done</title>"),
    ]

    private func withAgent(_ body: (Client, URL) async throws -> Void) async throws {
        UserDefaults.standard.removeObject(forKey: Preference.agentAccess)
        let (listener, base) = try await LocalHTTP.serve(Self.pages)
        defer { listener.cancel() }
        let browser = Browser()
        await browser.privacy.waitUntilReady()
        await browser.extensions.waitUntilLoaded()
        await browser.setAgentAccess(true)
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let active = NSApp?.isActive
        let key = NSApp?.keyWindow
        let pointer = NSEvent.mouseLocation
        var failure: (any Error)?
        do { try await body(try await Client(browser: browser), base) } catch { failure = error }
        // Out of the user's sight and reach, whatever the test did: their app stays in front.
        let now = NSWorkspace.shared.frontmostApplication?.processIdentifier
        #expect(now != getpid() || frontmost == getpid(), "the tests' process came to the front")
        #expect(NSApp?.isActive != true || active == true)
        #expect(NSApp?.keyWindow === key)
        #expect(NSEvent.mouseLocation == pointer)
        let onScreen = (NSApp?.windows ?? []).filter { window in window.isVisible && NSScreen.screens.contains { $0.frame.intersects(window.frame) } }
        #expect(onScreen.isEmpty, "\(onScreen)")
        if let stage = browser.agent?.stage.window {
            #expect(!stage.canBecomeKey && !stage.canBecomeMain && stage.ignoresMouseEvents && stage.isExcludedFromWindowsMenu)
            #expect(!NSScreen.screens.contains { $0.frame.intersects(stage.frame) })
            #expect(!stage.isKeyWindow)
        }
        browser.tabs.forEach(browser.close)
        await browser.setAgentAccess(false)
        if let failure { throw failure }
    }

    private func open(_ client: Client, _ url: URL) async throws -> (id: String, tab: Lithium.Tab) {
        let opened = await client.call("tab_open", ["url": .string(url.absoluteString), "wait": "load"])
        #expect(!opened.isError, "\(opened.content)")
        let id = try #require(opened["tab"]?.string)
        return (id, try #require(client.tab(id)))
    }

    /// The ref of the first node a snapshot shows with this role and name.
    private func ref(_ client: Client, _ tab: String, _ role: String, _ name: String) async throws -> String {
        // A child frame says hello a moment after the page has loaded.
        var snapshot = AgentTabsTests.ToolResult(isError: true, content: .null)
        for _ in 0..<50 {
            snapshot = await client.call("snapshot", ["tab": .string(tab), "format": "json", "scope": "page"])
            if case .array(let nodes)? = snapshot["nodes"], let node = nodes.first(where: { $0["role"]?.string == role && $0["name"]?.string == name }) {
                return try #require(node["ref"]?.string)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("No \(role) “\(name)” in \(snapshot.content)")
        throw CancellationError()
    }

    private func page(_ tab: Lithium.Tab, _ script: String) async throws -> Any? {
        try await tab.webView.callAsyncJavaScript(script, contentWorld: .page)
    }

    private func log(_ tab: Lithium.Tab, _ types: Set<String>? = nil) async throws -> [String] {
        let all = try await page(tab, "return window.log") as? [String] ?? []
        guard let types else { return all }
        return all.filter { types.contains(String($0.prefix { $0 != ":" })) }
    }

    private func clearLog(_ tab: Lithium.Tab) async throws {
        _ = try await page(tab, "window.log.length = 0")
    }

    private func eventually(_ seconds: Double = 5, _ condition: () async throws -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if (try? await condition()) == true { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return (try? await condition()) == true
    }

    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// Starts a call, waits for the prompt it raises, and answers it as the user would.
    private func call(_ client: Client, _ tool: String, _ arguments: JSONValue, answering answer: ConfirmationAnswer, expecting kind: ConfirmationKind) async throws -> AgentTabsTests.ToolResult {
        let confirmations = client.hub.confirmations
        let task = Task { await client.call(tool, arguments) }
        guard await waitUntil(20, { !confirmations.pending.isEmpty }), let asked = confirmations.pending.first else {
            Issue.record("\(tool) asked nothing: \(await task.value.content)")
            throw CancellationError()
        }
        #expect(asked.kind == kind)
        confirmations.answer(asked.id, answer)
        return await task.value
    }

    // MARK: Pointer

    @Test func clicksDoubleClicksRightClicksAndHoversAreTrustedInAStagedTab() async throws {
        try await withAgent { client, base in
            let browser = client.browser
            let mine = browser.newTab(url: base.appending(path: "done"))
            let (id, tab) = try await open(client, base.appending(path: "events"))
            let press = try await ref(client, id, "button", "Press")

            let clicked = await client.call("click", ["tab": .string(id), "ref": .string(press)])
            #expect(!clicked.isError, "\(clicked.content)")
            #expect(clicked["navigated"] == false)
            #expect(clicked["diff"]?.string != nil)
            #expect(try await log(tab, ["pointerdown", "mousedown", "pointerup", "mouseup", "click"]) == [
                "pointerdown:true:b", "mousedown:true:b", "pointerup:true:b", "mouseup:true:b", "click:true:b:1",
            ])
            // The page counts as shown, though the user never sees it, and the selection stays theirs.
            #expect(try await page(tab, "return document.visibilityState") as? String == "visible")
            #expect(browser.selectedTabID == mine.id)
            #expect(tab.webView.window is AgentStageWindow)
            #expect(tab.webView.userWindow == nil)

            try await clearLog(tab)
            #expect(!(await client.call("click", ["tab": .string(id), "ref": .string(press), "clickCount": 2])).isError)
            #expect(try await log(tab, ["click", "dblclick"]) == ["click:true:b:1", "click:true:b:2", "dblclick:true:b"])

            // A right click: the page's contextmenu, and no native menu on the user's screen.
            try await clearLog(tab)
            #expect(!(await client.call("click", ["tab": .string(id), "ref": .string(press), "button": "right"])).isError)
            // The page's own menu event, and its button let go, as after any custom menu.
            #expect(Set(try await log(tab, ["contextmenu", "mouseup"])) == ["contextmenu:true:b", "mouseup:true:b"])
            // No native menu: none on the user's screen, no menu loop holding the main thread.
            let mode = CFRunLoopCopyCurrentMode(CFRunLoopGetMain()).map { $0.rawValue as String }
            #expect(mode != RunLoop.Mode.eventTracking.rawValue)
            let onScreen = (NSApp?.windows ?? []).filter { window in window.isVisible && NSScreen.screens.contains { $0.frame.intersects(window.frame) } }
            #expect(onScreen.isEmpty, "\(onScreen)")
            let webView = try #require(tab.webView as? PageWebView)
            #expect(webView.agentMenusCancelled == 0)

            // Typing works right after a right click (design section 3, item 11).
            let field = try await ref(client, id, "textbox", "Field")
            #expect(!(await client.call("type", ["tab": .string(id), "ref": .string(field), "text": "ok"])).isError)
            #expect(try await page(tab, "return document.getElementById('field').value") as? String == "ok")

            // WebKit gives a page out of the user's front window no pointer moves without a
            // button (design section 3, item 4): hover says so rather than claiming it worked.
            let hover = try await ref(client, id, "button", "Hover me")
            let hovered = await client.call("hover", ["tab": .string(id), "ref": .string(hover)])
            #expect(hovered.code == "unsupported", "\(hovered.content)")
            #expect(try await page(tab, "return document.getElementById('hover').matches(':hover')") as? Bool == false)

            // By point: the same element, trusted.
            try await clearLog(tab)
            #expect(!(await client.call("click", ["tab": .string(id), "x": 100, "y": 60])).isError)
            #expect(try await log(tab, ["click"]) == ["click:true:b:1"])
            #expect((await client.call("click", ["tab": .string(id), "x": 5000, "y": 60])).code == "not_in_viewport")
        }
    }

    @Test func dragsWheelsSelectsAndChecks() async throws {
        try await withAgent { client, base in
            let (id, tab) = try await open(client, base.appending(path: "events"))
            let volume = try await ref(client, id, "slider", "Volume")
            let dragged = await client.call("drag", ["tab": .string(id), "from": .string(volume), "to": ["x": 238, "y": 270]])
            #expect(!dragged.isError, "\(dragged.content)")
            let value = try #require(Int(try await page(tab, "return document.getElementById('range').value") as? String ?? ""))
            #expect(value > 80, "range at \(value)")

            let wheeled = await client.call("scroll", ["tab": .string(id), "dy": 400])
            #expect(!wheeled.isError, "\(wheeled.content)")
            #expect(try await log(tab, ["wheel"]).allSatisfy { $0.hasPrefix("wheel:true:") })
            let scrolled = try await page(tab, "return scrollY") as? Double ?? 0
            #expect(scrolled >= 300, "scrolled to \(scrolled)")
            let back = await client.call("scroll", ["tab": .string(id), "ref": .string(try await ref(client, id, "button", "Press"))])
            #expect(!back.isError, "\(back.content)")
            #expect(try await page(tab, "return scrollY") as? Double ?? -1 < scrolled)

            try await clearLog(tab)
            let pick = try await ref(client, id, "combobox", "Pick")
            let chosen = await client.call("select_option", ["tab": .string(id), "ref": .string(pick), "labels": ["Beta"]])
            #expect(!chosen.isError, "\(chosen.content)")
            #expect(chosen["selected"] == ["Beta"])
            #expect(chosen["untrustedEvents"] == true)
            #expect(try await page(tab, "return document.getElementById('pick').value") as? String == "b")
            #expect(try await log(tab, ["change"]) == ["change:false:pick"])
            let missing = await client.call("select_option", ["tab": .string(id), "ref": .string(pick), "labels": ["Gamma"]])
            #expect(missing.code == "invalid_params" && missing.message.contains("\"Alpha\", \"Beta\""), "\(missing.message)")
            #expect((await client.call("click", ["tab": .string(id), "ref": .string(pick)])).code == "use_select_option")

            let agree = try await ref(client, id, "checkbox", "Agree")
            let checked = await client.call("set_checked", ["tab": .string(id), "ref": .string(agree), "checked": true])
            #expect(!checked.isError, "\(checked.content)")
            #expect(checked["checked"] == true && checked["changed"] == true)
            #expect(try await log(tab, ["click"]).contains("click:true:box:1"))
            let again = await client.call("set_checked", ["tab": .string(id), "ref": .string(agree), "checked": true])
            #expect(again["changed"] == false)

            let field = try await ref(client, id, "textbox", "Field")
            let focused = await client.call("focus", ["tab": .string(id), "ref": .string(field)])
            #expect(focused["focused"] == true)
        }
    }

    // MARK: Keys

    @Test func typesInFieldsInOrderAndSubmits() async throws {
        try await withAgent { client, base in
            let (id, tab) = try await open(client, base.appending(path: "events"))
            let field = try await ref(client, id, "textbox", "Field")
            let typed = await client.call("type", ["tab": .string(id), "ref": .string(field), "text": "Hi ✓ 日本 ok"])
            #expect(!typed.isError, "\(typed.content)")
            #expect(try await page(tab, "return document.getElementById('field').value") as? String == "Hi ✓ 日本 ok")
            let keys = try await log(tab, ["keydown", "keyup"])
            // H, i, three spaces, o, k: the rest is inserted as an input method would.
            #expect(keys.count == 2 * 7 && keys.allSatisfy { $0.contains(":true:field") }, "\(keys)")
            #expect(try await log(tab, ["beforeinput"]).allSatisfy { $0.hasPrefix("beforeinput:true:") })

            // Typing again adds at the end; clear replaces.
            #expect(!(await client.call("type", ["tab": .string(id), "ref": .string(field), "text": "!"])).isError)
            #expect(try await page(tab, "return document.getElementById('field').value") as? String == "Hi ✓ 日本 ok!")
            #expect(!(await client.call("type", ["tab": .string(id), "ref": .string(field), "text": "new", "clear": true])).isError)
            #expect(try await page(tab, "return document.getElementById('field').value") as? String == "new")
            #expect((await client.call("type", ["tab": .string(id), "ref": .string(field), "text": "a\nb"])).code == "invalid_params")

            let area = try await ref(client, id, "textbox", "Area")
            #expect(!(await client.call("type", ["tab": .string(id), "ref": .string(area), "text": "one\ntwo"])).isError)
            #expect(try await page(tab, "return document.getElementById('area').value") as? String == "one\ntwo")
            let editor = try await ref(client, id, "textbox", "Editor")
            #expect(!(await client.call("type", ["tab": .string(id), "ref": .string(editor), "text": "Édith"])).isError)
            #expect(try await page(tab, "return document.getElementById('edit').textContent") as? String == "Édith")
            // Without ref, into the focused element.
            #expect(!(await client.call("type", ["tab": .string(id), "text": "!"])).isError)
            #expect(try await page(tab, "return document.getElementById('edit').textContent") as? String == "Édith!")
            let selected = await client.call("press", ["tab": .string(id), "keys": "Meta+A"])
            #expect(!selected.isError, "\(selected.content)")
            #expect(try await page(tab, "return String(getSelection())") as? String == "Édith!")

            let (formID, form) = try await open(client, base.appending(path: "form"))
            let name = try await ref(client, formID, "textbox", "Name")
            #expect(!(await client.call("press", ["tab": .string(formID), "keys": "Tab"])).isError)
            let sent = await client.call("type", ["tab": .string(formID), "ref": .string(name), "text": "Ann", "submit": true])
            #expect(!sent.isError, "\(sent.content)")
            #expect(sent["navigated"] == true)
            #expect(sent["state"] == "commit")
            #expect(form.url?.absoluteString.hasSuffix("/done?name=Ann") == true)
        }
    }

    @Test func agentShortcutsReachThePageButNeverLithium() async throws {
        try await withAgent { client, base in
            let browser = client.browser
            let (id, tab) = try await open(client, base.appending(path: "form"))
            let count = browser.tabs.count
            let other = try await ref(client, id, "textbox", "Other")
            #expect(!(await client.call("focus", ["tab": .string(id), "ref": .string(other)])).isError)
            for keys in ["Meta+W", "Meta+Q", "Meta+T"] {
                let pressed = await client.call("press", ["tab": .string(id), "keys": .string(keys)])
                #expect(!pressed.isError, "\(pressed.content)")
            }
            #expect(try await log(tab, ["keydown"]) == ["keydown:true:other:meta", "keydown:true:other:meta", "keydown:true:other:meta"])
            #expect(browser.tabs.count == count)
            #expect(client.tab(id) != nil)
            #expect((await client.call("press", ["tab": .string(id), "keys": "Meta+V"])).code == "clipboard_disabled")
            #expect((await client.call("press", ["tab": .string(id), "keys": "Meta+Nope"])).code == "invalid_params")
        }
    }

    @Test func typeAnswersOnceTheLastInsertedCharacterIsInThePage() async throws {
        try await withAgent { client, base in
            let (id, tab) = try await open(client, base.appending(path: "events"))
            let field = try await ref(client, id, "textbox", "Field")
            for word in ["café", "naïveté", "déjà vu ✓"] {
                let typed = await client.call("type", ["tab": .string(id), "ref": .string(field), "text": .string(word), "clear": true])
                #expect(!typed.isError, "\(typed.content)")
                #expect(try await page(tab, "return document.getElementById('field').value") as? String == word)
            }
        }
    }

    @Test func keysWithoutRefReachAFocusedFieldInAFrameOutOfView() async throws {
        try await withAgent { client, base in
            let (id, tab) = try await open(client, base.appending(path: "far-frame"))
            let inner = try await ref(client, id, "textbox", "Inner")
            #expect(inner.contains(":"))
            #expect(!(await client.call("focus", ["tab": .string(id), "ref": .string(inner)])).isError)
            // Fixed below the viewport: no scrolling brings it into view.
            #expect(try await page(tab, "return document.querySelector('iframe').getBoundingClientRect().top") as? Double ?? 0 > 2000)
            let typed = await client.call("type", ["tab": .string(id), "text": "far"])
            #expect(!typed.isError, "\(typed.content)")
            let pressed = await client.call("press", ["tab": .string(id), "keys": "Backspace"])
            #expect(!pressed.isError, "\(pressed.content)")
            // The frame tells its page by postMessage, which arrives a moment later.
            #expect(await eventually { try await log(tab).last == "inner:fa" })
        }
    }

    @Test func undoAndRedoPerformedAsManyTimesAsRepeatAsks() async throws {
        try await withAgent { client, base in
            let (id, tab) = try await open(client, base.appending(path: "events"))
            let field = try await ref(client, id, "textbox", "Field")
            let value = { try await self.page(tab, "return document.getElementById('field').value") as? String }
            for text in ["a", "b", "c", "d"] {
                #expect(!(await client.call("type", ["tab": .string(id), "ref": .string(field), "text": .string(text)])).isError)
            }
            #expect(try await value() == "abcd")
            #expect(!(await client.call("press", ["tab": .string(id), "keys": "Meta+Z"])).isError)
            #expect(try await value() == "abc")
            let undone = await client.call("press", ["tab": .string(id), "keys": "Meta+Z", "repeat": 3])
            #expect(!undone.isError, "\(undone.content)")
            #expect(try await value() == "")
            #expect(!(await client.call("press", ["tab": .string(id), "keys": "Shift+Meta+Z", "repeat": 2])).isError)
            #expect(try await value() == "ab")
        }
    }

    // MARK: Checks

    @Test func actionabilityErrorsNameWhatStandsInTheWay() async throws {
        try await withAgent { client, base in
            let (id, tab) = try await open(client, base.appending(path: "covered"))
            let under = try await ref(client, id, "button", "Under")
            let covered = await client.call("click", ["tab": .string(id), "ref": .string(under)])
            #expect(covered.code == "covered")
            let banner = try #require(covered.message.firstMatch(of: /\((e\d+)\)/)?.1)
            #expect(covered.message.hasPrefix("\(under) button \"Under\" is covered by DIV#cookie-banner \"We use cookies\" (\(banner))"), "\(covered.message)")
            #expect((await client.call("click", ["tab": .string(id), "ref": .string(try await ref(client, id, "button", "Off"))])).code == "disabled")
            let gone = try await ref(client, id, "button", "Gone")
            _ = try await page(tab, "document.getElementById('gone').style.display = 'none'")
            let hidden = await client.call("click", ["tab": .string(id), "ref": .string(gone)])
            #expect(hidden.code == "not_visible" && hidden.message.hasSuffix("has display:none."), "\(hidden.message)")
            _ = try await page(tab, "document.getElementById('gone').remove()")
            #expect((await client.call("click", ["tab": .string(id), "ref": .string(gone)])).code == "stale_ref")
            #expect((await client.call("click", ["tab": .string(id), "ref": "e9999"])).code == "stale_ref")
            #expect((await client.call("click", ["tab": .string(id)])).code == "invalid_params")
        }
    }

    @Test func clicksInACrossOriginFrameAndOnZoomedPagesLandOnTheirElement() async throws {
        try await withAgent { client, base in
            let (id, tab) = try await open(client, base.appending(path: "frames"))
            let inside = try await ref(client, id, "button", "Inside")
            #expect(inside.contains(":"))
            let clicked = await client.call("click", ["tab": .string(id), "ref": .string(inside)])
            #expect(!clicked.isError, "\(clicked.content)")
            // The frame tells its page by postMessage, which arrives a moment later.
            #expect(await eventually { try await log(tab).filter { $0 == "child-click:true" }.count == 1 })
            // By point, through the iframe's border and padding: 100 + 3 + 5 + 10 + 40, 50 + 3 + 5 + 20 + 15.
            #expect(!(await client.call("click", ["tab": .string(id), "x": 158, "y": 93])).isError)
            #expect(await eventually { try await log(tab).filter { $0 == "child-click:true" }.count == 2 })

            let (eventsID, events) = try await open(client, base.appending(path: "events"))
            let press = try await ref(client, eventsID, "button", "Press")
            events.webView.pageZoom = 1.5
            try await clearLog(events)
            #expect(!(await client.call("click", ["tab": .string(eventsID), "ref": .string(press)])).isError)
            #expect(try await log(events, ["click"]) == ["click:true:b:1"])
            events.webView.pageZoom = 1
            events.webView.setMagnification(2, centeredAt: .zero)
            try await clearLog(events)
            let magnified = await client.call("click", ["tab": .string(eventsID), "ref": .string(press)])
            #expect(!magnified.isError, "\(magnified.content)")
            #expect(try await log(events, ["click"]) == ["click:true:b:1"])
        }
    }

    // MARK: Results

    @Test func resultsNameNewTabsDialogsDownloadsAndPageLoads() async throws {
        try await withAgent { client, base in
            let browser = client.browser
            let selected = browser.selectedTabID
            let (id, tab) = try await open(client, base.appending(path: "results"))
            let opened = await client.call("click", ["tab": .string(id), "ref": .string(try await ref(client, id, "link", "Open"))])
            #expect(!opened.isError, "\(opened.content)")
            guard case .array(let newTabs)? = opened["newTabs"], let first = newTabs.first else {
                Issue.record("No new tab in \(opened.content)")
                return
            }
            #expect(first["openedBy"] == .string(id))
            let popup = try #require(client.tab(first["tab"]?.string ?? ""))
            #expect(popup.isInAgentGroup)
            #expect(browser.selectedTabID == selected)

            let alerted = await client.call("click", ["tab": .string(id), "ref": .string(try await ref(client, id, "button", "Alert"))])
            #expect(!alerted.isError, "\(alerted.content)")
            #expect(alerted["dialog"]?["type"] == "alert")
            #expect(alerted["dialog"]?["message"] == "Saved")
            #expect(!(await client.call("dialog_respond", ["tab": .string(id), "accept": true])).isError)

            let report = try await ref(client, id, "link", "Report")
            let denied = try await call(client, "click", ["tab": .string(id), "ref": .string(report)], answering: .deny, expecting: .download)
            #expect(denied.code == "denied_by_user")

            let next = await client.call("click", ["tab": .string(id), "ref": .string(try await ref(client, id, "link", "Next")), "wait": "load"])
            #expect(!next.isError, "\(next.content)")
            #expect(next["navigated"] == true)
            #expect(next["title"] == "Done")
            #expect(next["diff"]?.string != nil)
            #expect(tab.url?.path() == "/done")
        }
    }

    @Test func aLoadUnderWayBeforeAClickIsNotTheClicks() async throws {
        let (slow, slowBase) = try await LocalHTTP.serve(["/slow": (Self.html, "<title>Slow</title>")], delay: 20)
        defer { slow.cancel() }
        try await withAgent { client, base in
            let (id, tab) = try await open(client, base.appending(path: "events"))
            let press = try await ref(client, id, "button", "Press")
            tab.webView.load(URLRequest(url: slowBase.appending(path: "slow")))
            defer { tab.webView.stopLoading() }
            #expect(await waitUntil(5) { tab.isAwaitingCommit })
            let clicked = await client.call("click", ["tab": .string(id), "ref": .string(press), "timeoutMs": 5000])
            #expect(!clicked.isError, "\(clicked.content)")
            #expect(clicked["navigated"] == false)
            #expect(try await log(tab, ["mouseup", "click"]) == ["mouseup:true:b", "click:true:b:1"])
            #expect(tab.isAwaitingCommit)
        }
    }

    // MARK: Guardrails

    @Test func guardedActionsWaitForTheUserAndTypedSecretsAreNeverLogged() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "agent-upload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "notes.txt")
        try "notes".write(to: file, atomically: true, encoding: .utf8)
        try await withAgent { client, base in
            let (id, tab) = try await open(client, base.appending(path: "pay"))
            let pay = try await ref(client, id, "button", "Pay €42.00")
            let denied = try await call(client, "click", ["tab": .string(id), "ref": .string(pay)], answering: .deny, expecting: .payment)
            #expect(denied.code == "denied_by_user")
            // Nothing reached the page before the user's answer.
            #expect(try await log(tab, ["mousedown", "click"]).isEmpty)

            let user = try await ref(client, id, "textbox", "User")
            let typedUser = await client.call("type", ["tab": .string(id), "ref": .string(user), "text": "ann"])
            #expect(!typedUser.isError, "\(typedUser.content)")
            let password = try await ref(client, id, "textbox", "Password")
            let typed = try await call(client, "type", ["tab": .string(id), "ref": .string(password), "text": "hunter2secret"], answering: .allowOnce, expecting: .password)
            #expect(!typed.isError, "\(typed.content)")
            #expect(typed["grant"] == "once")
            #expect(try await page(tab, "return document.getElementById('pw').value") as? String == "hunter2secret")

            // Card number asks once for the form; its CVC then goes in on that Allow.
            let card = try await ref(client, id, "textbox", "Card number")
            let carded = try await call(client, "type", ["tab": .string(id), "ref": .string(card), "text": "4242424242424242"], answering: .allowOnce, expecting: .payment)
            #expect(!carded.isError, "\(carded.content)")
            let cvc = await client.call("type", ["tab": .string(id), "ref": .string(try await ref(client, id, "textbox", "CVC")), "text": "cvc-secret"])
            #expect(!cvc.isError, "\(cvc.content)")
            #expect(cvc["grant"] == "form")

            let upload = try await ref(client, id, "button", "Attachment")
            let uploaded = try await call(client, "upload_files", ["tab": .string(id), "ref": .string(upload), "paths": [.string(file.path())]], answering: .allowOnce, expecting: .upload)
            #expect(!uploaded.isError, "\(uploaded.content)")
            #expect(uploaded["inputFiles"] == ["notes.txt"])

            let entries = await client.hub.log.entries(limit: 100)
            let logged = String(decoding: JSONValue.array(entries).encoded(), as: UTF8.self)
            for secret in ["hunter2secret", "4242424242424242", "cvc-secret"] { #expect(!logged.contains(secret), "\(secret) in the log") }
            #expect(logged.contains("\"text\":\"ann\""))
        }
    }

    // MARK: The user wins

    @Test func theUsersInputEndsTheAgentsActionAndTheirEditingHoldsItUp() async throws {
        try await withAgent { client, base in
            let (id, tab) = try await open(client, base.appending(path: "pay"))
            let pay = try await ref(client, id, "button", "Pay €42.00")
            let confirmations = client.hub.confirmations
            let waiting = Task { await client.call("click", ["tab": .string(id), "ref": .string(pay)]) }
            #expect(await waitUntil(20) { !confirmations.pending.isEmpty })
            let webView = try #require(tab.webView as? PageWebView)
            let window = try #require(webView.window)
            let users = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 5, y: 5), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            webView.mouseDown(with: users)
            webView.mouseUp(with: try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: CGPoint(x: 5, y: 5), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)))
            let interrupted = await waiting.value
            #expect(interrupted.code == "user_interrupted", "\(interrupted.content)")
            #expect(confirmations.pending.isEmpty)

            // In a window the user sees, their editing in Lithium's own field holds the agent up.
            let user = try await ref(client, id, "textbox", "User")
            let shown = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
            shown.isReleasedWhenClosed = false
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
            let content = NSView(frame: shown.contentLayoutRect)
            content.addSubview(field)
            webView.frame = CGRect(x: 0, y: 30, width: 1000, height: 670)
            content.addSubview(webView)
            shown.contentView = content
            defer {
                webView.removeFromSuperview()
                shown.contentView = nil
            }
            client.browser.select(tab)
            #expect(shown.makeFirstResponder(field))
            let busy = await client.call("type", ["tab": .string(id), "ref": .string(user), "text": "x"])
            #expect(busy.code == "user_busy", "\(busy.content)")
            shown.makeFirstResponder(nil)
            let free = await client.call("type", ["tab": .string(id), "ref": .string(user), "text": "x"])
            #expect(!free.isError, "\(free.content)")

            // A press whose mouseUp a native loop took (a link dragged, a <select> or a context
            // menu open): only while the button is really down does it hold the agent up.
            let buttons = PageWebView.pressedMouseButtons
            defer { PageWebView.pressedMouseButtons = buttons }
            PageWebView.pressedMouseButtons = { 1 }
            webView.mouseDown(with: try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 5, y: 5), modifierFlags: [], timestamp: 0, windowNumber: shown.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1)))
            let pressing = await client.call("type", ["tab": .string(id), "ref": .string(user), "text": "x", "timeoutMs": 1000])
            #expect(pressing.code == "user_busy", "\(pressing.content)")
            PageWebView.pressedMouseButtons = { 0 }
            let released = await client.call("type", ["tab": .string(id), "ref": .string(user), "text": "y"])
            #expect(!released.isError, "\(released.content)")
            #expect(try await page(tab, "return document.getElementById('user').value") as? String == "xy")
        }
    }

    @Test func theTargetIsPlacedAgainWhenTheUserSelectsItsTabDuringTheirAllow() async throws {
        try await withAgent { client, base in
            let (id, tab) = try await open(client, base.appending(path: "moved"))
            let pay = try await ref(client, id, "button", "Pay €42.00")
            let confirmations = client.hub.confirmations
            let waiting = Task { await client.call("click", ["tab": .string(id), "ref": .string(pay)]) }
            #expect(await waitUntil(20) { !confirmations.pending.isEmpty })
            let asked = try #require(confirmations.pending.first)
            #expect(asked.kind == .payment)
            #expect(tab.webView.window is AgentStageWindow)
            // The user selects the tab: its web view goes to their window, 100 points taller
            // than the stage, where the stage's window point for Pay is on Decoy.
            let stageHeight = try #require(tab.webView.window).contentLayoutRect.height
            let shown = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1280, height: stageHeight + 100), styleMask: [.borderless], backing: .buffered, defer: false)
            shown.isReleasedWhenClosed = false
            let webView = tab.webView
            webView.removeFromSuperview()
            webView.frame = shown.contentLayoutRect
            shown.contentView = webView
            defer { shown.contentView = nil }
            client.browser.select(tab)
            confirmations.answer(asked.id, .allowOnce)
            let clicked = await waiting.value
            #expect(!clicked.isError, "\(clicked.content)")
            #expect(clicked["grant"] == "once")
            #expect(try await log(tab, ["click"]) == ["click:true:pay:1"])
            #expect(confirmations.pending.isEmpty)
        }
    }

    @Test func aButtonUpThatFailsIsStillLetGo() async throws {
        try await withAgent { client, base in
            let (_, tab) = try await open(client, base.appending(path: "events"))
            let webView = tab.webView
            let windows = (0..<2).map { _ in
                let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                return window
            }
            webView.removeFromSuperview()
            webView.frame = windows[0].contentLayoutRect
            windows[0].contentView = webView
            defer {
                webView.removeFromSuperview()
                windows.forEach { $0.contentView = nil }
            }
            try await clearLog(tab)
            let input = try NativeInput(webView: webView, check: {}, onPointer: { _ in })
            try input.down(at: CGPoint(x: 100, y: 60))
            #expect(await eventually { try await log(tab, ["mousedown"]) == ["mousedown:true:b"] })
            // The user selects the tab before the last event of a drag: the up fails, and the
            // button is let go in the window the web view is in now.
            webView.removeFromSuperview()
            windows[1].contentView = webView
            #expect(throws: NativeInput.WindowChanged.self) { try input.up() }
            #expect(await eventually { try await log(tab, ["mouseup"]) == ["mouseup:true:b"] })
            input.release()
            #expect(try await log(tab, ["mouseup"]) == ["mouseup:true:b"])
        }
    }

    // MARK: The stage

    @Test func twoBackgroundTabsActSideBySideInTheStageAndLeaveIt() async throws {
        try await withAgent { client, base in
            let hub = client.hub
            hub.stage.releaseDelay = .milliseconds(500)
            let (firstID, first) = try await open(client, base.appending(path: "events"))
            let (secondID, second) = try await open(client, base.appending(path: "events"))
            for (id, tab) in [(firstID, first), (secondID, second)] {
                let press = try await ref(client, id, "button", "Press")
                #expect(!(await client.call("click", ["tab": .string(id), "ref": .string(press)])).isError)
                #expect(try await log(tab, ["click"]) == ["click:true:b:1"])
            }
            // Item 26: both pages render and run animation frames in the one window.
            #expect(first.webView.window === second.webView.window)
            for tab in [first, second] {
                #expect(try await page(tab, "return document.visibilityState") as? String == "visible")
                #expect(try await page(tab, "return await new Promise((resolve) => { requestAnimationFrame(() => resolve(true)); setTimeout(() => resolve(false), 1000); })") as? Bool == true)
            }
            #expect(await waitUntil(5) { first.webView.window == nil && second.webView.window == nil })
            #expect(hub.stage.staged.isEmpty)

            // Closing the tab while its action waits for the user.
            let (payID, payTab) = try await open(client, base.appending(path: "pay"))
            let pay = try await ref(client, payID, "button", "Pay €42.00")
            let waiting = Task { await client.call("click", ["tab": .string(payID), "ref": .string(pay)]) }
            #expect(await waitUntil(20) { !hub.confirmations.pending.isEmpty })
            client.browser.close(payTab)
            #expect((await waiting.value).code == "tab_closed")
        }
    }

    @Test func anActionWaitingForTheUserKeepsItsTabStagedAndAsksOnce() async throws {
        try await withAgent { client, base in
            let hub = client.hub
            hub.stage.releaseDelay = .milliseconds(300)
            let (id, tab) = try await open(client, base.appending(path: "moved"))
            let pay = try await ref(client, id, "button", "Pay €42.00")
            var clicked: AgentTabsTests.ToolResult?
            Task { clicked = await client.call("click", ["tab": .string(id), "ref": .string(pay)]) }
            #expect(await waitUntil(20) { !hub.confirmations.pending.isEmpty })
            let asked = try #require(hub.confirmations.pending.first)
            // Many times the stage's delay, as a user reading the prompt takes.
            try await Task.sleep(for: .milliseconds(1500))
            #expect(tab.webView.window is AgentStageWindow)
            hub.confirmations.answer(asked.id, .allowOnce)
            #expect(await waitUntil(20) { clicked != nil || hub.confirmations.pending.contains { $0.id != asked.id } })
            let again = hub.confirmations.pending.filter { $0.id != asked.id }
            #expect(again.isEmpty, "asked again: \(again)")
            again.forEach { hub.confirmations.answer($0.id, .deny) }
            #expect(await waitUntil(20) { clicked != nil })
            #expect(clicked?.isError == false, "\(clicked?.content ?? .null)")
            #expect(try await log(tab, ["click"]) == ["click:true:pay:1"])
            // Once the action is over, the stage lets it go.
            #expect(await waitUntil(5) { tab.webView.window == nil })
        }
    }
}

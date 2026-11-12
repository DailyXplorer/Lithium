import AppKit
import Foundation
import Testing
import WebKit
@testable import Lithium
import LithiumTestGuard

/// Keys and the key guard, without a page.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AgentKeysTests {
    /// A point far out of range used to reach `Int(_:)` in an error message, which traps.
    @Test func refusesPointsFarOutOfRange() throws {
        for (x, y) in [(1e19, 0.0), (0, -1e19), (1_000_001, 0)] {
            #expect(throws: Arguments.invalid("x and y must be CSS pixels in the viewport, within ±1000000.")) {
                try Arguments(value: ["x": .double(x), "y": .double(y)]).point()
            }
        }
        #expect(try Arguments(value: ["x": .double(-1e6), "y": 5]).point() != nil)
    }

    @Test func namesKeysAsAUSKeyboardTypesThem() throws {
        #expect(NativeKey.typing("a") == NativeKey(code: 0, characters: "a", shifted: "A"))
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

    @Test func everySpellingOfAKeyIsThatKey() throws {
        let spellings = [
            "Enter": ["Enter", "enter", "ENTER", "Return", "return"], "Space": ["Space", "space", " "],
            "Escape": ["Escape", "escape", "Esc", "esc"], "ArrowDown": ["arrowdown"], "F5": ["f5"],
        ]
        for (name, spelled) in spellings {
            for spelling in spelled + spelled.map({ "shift+" + $0 }) {
                let parsed = try #require(NativeKey.parse(spelling), "\(spelling)")
                #expect(parsed.name == name && parsed.key == NativeKey.named[name], "\(spelling)")
            }
        }
        let enters = ["Enter", "enter", "return", "Shift+Enter", "Control+Enter", "Meta+enter", "Alt+Return", "Control+M", "control+m"]
        for combo in enters {
            let parsed = try #require(NativeKey.parse(combo))
            #expect(parsed.key.isEnter(with: parsed.modifiers), "\(combo)")
        }
        for combo in ["Tab", "Shift+Tab", "m", "Meta+M", "Space", "ArrowDown"] {
            let parsed = try #require(NativeKey.parse(combo))
            #expect(!parsed.key.isEnter(with: parsed.modifiers), "\(combo)")
        }
        for combo in ["Space", "space", " ", "Shift+Space", "Control+space"] { #expect(NativeKey.parse(combo)?.key.isSpace == true, "\(combo)") }
    }

    /// The characters a US keyboard gives, and those AppKit gives ignoring every modifier but Shift.
    @Test func shiftTypesTheShiftedCharacter() throws {
        let cases: [(combo: String, characters: String, ignoringModifiers: String)] = [
            ("Shift+A", "A", "A"), ("Shift+a", "A", "A"), ("A", "A", "A"), ("a", "a", "a"), ("Shift+1", "!", "!"),
            ("Shift+/", "?", "?"), ("1", "1", "1"), ("!", "!", "!"), ("Meta+K", "k", "k"), ("Meta+Shift+K", "K", "K"),
            ("Control+Shift+A", "\u{01}", "A"), ("Shift+Tab", "\u{19}", "\t"), ("Shift+Enter", "\r", "\r"),
        ]
        for (combo, characters, ignoring) in cases {
            let parsed = try #require(NativeKey.parse(combo))
            let flags = parsed.modifiers.union(parsed.key.flags)
            #expect(parsed.key.characters(with: flags) == characters, "\(combo)")
            #expect(parsed.key.charactersIgnoringModifiers(with: flags) == ignoring, "\(combo)")
        }
    }

    @Test func plusAloneOrWithModifiersIsThePlusKey() throws {
        for combo in ["+", "Meta++", "Shift+="] {
            let parsed = try #require(NativeKey.parse(combo), "\(combo)")
            #expect(parsed.key.code == 24, "\(combo)")
            #expect(parsed.key.charactersIgnoringModifiers(with: parsed.modifiers.union(parsed.key.flags)) == "+", "\(combo)")
        }
        #expect(NativeKey.parse("+")?.modifiers == [])
        #expect(NativeKey.parse("Meta++")?.modifiers == .command)
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

    /// WebKit hands a key the page didn't handle back to `NSApp.sendEvent` only once the page
    /// answered: an agent's ⌘W in a page busy for 3 seconds still never reaches the menu.
    @Test func anAgentsShortcutNeverReachesTheMenuHoweverLongThePageTakes() async throws {
        final class Closer: NSObject {
            var closed = 0
            @objc func performClose(_ sender: Any?) { closed += 1 }
        }
        let closer = Closer()
        let menu = NSMenu()
        let item = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        item.submenu = NSMenu(title: "File")
        let close = NSMenuItem(title: "Close Tab", action: #selector(Closer.performClose(_:)), keyEquivalent: "w")
        close.target = closer
        item.submenu?.addItem(close)
        menu.addItem(item)
        let app = NSApplication.shared
        let mainMenu = app.mainMenu
        app.mainMenu = menu
        let keyGuard = NativeInput.installKeyGuard()
        defer {
            if let keyGuard { NSEvent.removeMonitor(keyGuard) }
            app.mainMenu = mainMenu
        }

        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = webView
        defer { window.contentView = nil }
        webView.loadHTMLString("<script>window.ready = true; addEventListener('keydown', () => { const end = Date.now() + 3000; while (Date.now() < end) {} })</script>", baseURL: nil)
        for _ in 0..<100 where webView.isLoading { try await Task.sleep(for: .milliseconds(100)) }
        #expect(try await webView.evaluateJavaScript("window.ready") as? Bool == true)

        let input = try NativeInput(webView: webView, check: {}, onPointer: { _ in })
        try input.key(try #require(NativeKey.parse("Meta+W")).key, modifiers: .command)
        // The agent goes on meanwhile, here or in another tab.
        try await Task.sleep(for: .milliseconds(2500))
        try input.move(to: CGPoint(x: 10, y: 10))
        try await Task.sleep(for: .milliseconds(2500))
        #expect(closer.closed == 0)

        // The user's own ⌘W still reaches it.
        let users = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        app.sendEvent(users)
        #expect(closer.closed == 1)
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
        // A frame whose button replaces the frame's own document, from this server at once.
        "/nav-frame": (html, """
            <title>Nav frame</title><style>body { margin: 0 } iframe { position: absolute; left: 40px; top: 40px; width: 300px; height: 100px }</style>
            <iframe id="nav" src="/nav-child"></iframe>
            """),
        "/nav-child": (html, """
            <style>body { margin: 0 }</style><button style="position:absolute;left:10px;top:20px;width:80px;height:30px">Leave</button>
            <script>document.querySelector('button').addEventListener('mousedown', () => { location.href = '/child'; });</script>
            """),
        // A frame whose field takes the frame away at the first key.
        "/gone-frame": (html, """
            <title>Gone frame</title><style>body { margin: 0 } iframe { position: absolute; left: 40px; top: 40px; width: 300px; height: 100px }</style>
            <iframe id="gone" src="/gone-child"></iframe>
            """),
        "/gone-child": (html, """
            <input aria-label="Leaving" style="position:absolute;left:10px;top:20px;width:200px">
            <script>document.querySelector('input').addEventListener('keydown', () => frameElement.remove());</script>
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
        "/card-frame": (html, """
            <title>Card frame</title><style>body { margin: 0 } iframe { position: absolute; left: 40px; top: 40px; width: 300px; height: 100px }</style>
            <iframe id="card"></iframe>
            <script>document.getElementById('card').src = \(otherOrigin) + '/field-child'; document.getElementById('card').focus();</script>
            """),
        "/blank-frame": (html, """
            <title>Blank frame</title><iframe id="box" sandbox srcdoc="<input>"></iframe>
            <script>document.getElementById('box').focus();</script>
            """),
        "/user-opens": (html, """
            <title>User opens</title><style>body { margin: 0 } button, a { position: absolute; left: 40px; width: 120px; height: 30px }</style>
            <button id="pay" style="top: 40px">Pay €42.00</button>
            <button id="later" style="top: 100px">Later</button>
            <a id="plain" href="/form" style="top: 160px">Plain</a>
            <script>
              // What the user's click on Later opens comes a moment after it, once an agent's action is under way.
              window.next = '';
              document.getElementById('later').addEventListener('click', () => setTimeout(() => window.open(next), 700));
            </script>
            """),
        "/covered": (html, """
            <title>Covered</title><style>body { margin: 0 }</style>
            <button id="under" style="position:absolute;left:40px;top:40px">Under</button>
            <button id="off" disabled style="position:absolute;left:40px;top:300px">Off</button>
            <button id="gone" style="position:absolute;left:200px;top:300px">Gone</button>
            <select id="menu" style="position:absolute;left:40px;top:360px"><option>One</option></select>
            <div id="page-cover" style="position:fixed;left:0;top:0;width:100%;height:120px;background:white">We use cookies</div>
            """),
        "/results": (html, """
            <title>Results</title><style>body { margin: 0 }</style>
            <a id="pop" href="/form" target="_blank" style="position:absolute;left:40px;top:40px">Open</a>
            <button id="al" onclick="alert('Saved')" style="position:absolute;left:40px;top:100px">Alert</button>
            <a id="file" href="/report.csv" style="position:absolute;left:40px;top:160px">Report</a>
            <a id="next" href="/done" style="position:absolute;left:40px;top:220px">Next</a>
            <a id="plain" href="/form" style="position:absolute;left:40px;top:280px">Plain</a>
            <button id="win" onclick="window.open('/form')" style="position:absolute;left:40px;top:340px">Window</button>
            """),
        "/login": (html, """
            <title>Sign in</title><style>body { margin: 0 }</style>
            <form action="/done">
              <input id="who" aria-label="Who"><input type="password" id="secret" aria-label="Secret">
              <label><input type="checkbox" id="remember"> Remember</label><button>Sign in</button>
            </form>
            \(logger)
            """),
        "/decoy": (html, """
            <title>Decoy</title><style>body { margin: 0 } input { position: absolute; left: 40px; width: 160px }</style>
            <form action="/done">
              <input id="account" aria-label="Account" style="top: 40px"><input type="password" id="real" aria-label="Real" style="top: 100px">
            </form>
            <script>document.getElementById('account').addEventListener('focus', () => document.getElementById('real').focus());</script>
            """),
        "/to-one-line": (html, """
            <title>One line</title><style>body { margin: 0 } textarea, input { position: absolute; left: 40px; width: 160px }</style>
            <form action="/done">
              <textarea id="notes" aria-label="Notes" style="top: 40px"></textarea><input id="title" aria-label="Title" style="top: 120px">
            </form>
            <script>document.getElementById('notes').addEventListener('focus', () => document.getElementById('title').focus());</script>
            """),
        "/later": (html, """
            <title>Later</title><style>body { margin: 0 } input { position: absolute; left: 40px; width: 160px }</style>
            <form action="/done">
              <input id="account" aria-label="Account" style="top: 40px" data-next="real"><input type="password" id="real" aria-label="Real" style="top: 100px">
              <input id="card" autocomplete="cc-number" aria-label="Card number" style="top: 160px">
            </form>
            <script>
              const account = document.getElementById('account');
              account.addEventListener('click', () => setTimeout(() => document.getElementById(account.dataset.next).focus(), 0));
            </script>
            """),
        "/report.csv": ("Content-Type: text/csv\r\nContent-Disposition: attachment; filename=report.csv", "a,b"),
        "/pay": (html, """
            <title>Shop</title><style>body { margin: 0 }</style>
            <button id="pay" style="position:absolute;left:40px;top:40px">Pay €42.00</button>
            <form action="/done" style="position:absolute;left:40px;top:120px">
              <input id="user" aria-label="User"><input type="password" id="pw" aria-label="Password">
              <input id="card" autocomplete="cc-number" aria-label="Card number"><input id="cvc" name="cvc" aria-label="CVC">
              <input id="upload" type="file" aria-label="Attachment"><button>Sign in</button>
              <select id="exp" autocomplete="cc-exp-month" aria-label="Expiry month"><option>01</option><option>02</option></select>
            </form>
            \(logger)
            """),
        "/upload-hidden": (html, """
            <title>Upload</title><style>body { margin: 0 }</style>
            <button id="choose" style="position:absolute;left:40px;top:40px">Choose a file</button>
            <input id="hidden" type="file" style="display: none">
            <p id="names" style="position:absolute;left:40px;top:100px"></p>
            <script>document.getElementById('hidden').addEventListener('change', (event) => { document.getElementById('names').textContent = 'hidden:' + [...event.target.files].map((file) => file.name).join(','); });</script>
            """),
        "/upload-zone": (html, """
            <title>Upload zone</title><style>body { margin: 0 }</style>
            <div id="zone" role="button" style="position:absolute;left:40px;top:40px;width:240px;height:60px">Drop files here<input id="inner" type="file" multiple hidden></div>
            <input id="covered" type="file" aria-label="Covered" style="position:absolute;left:40px;top:140px;width:240px;height:30px">
            <div id="veil" style="position:absolute;left:0;top:130px;width:400px;height:60px;background:rgba(0,0,0,0.2)"></div>
            <p id="names" style="position:absolute;left:40px;top:220px"></p>
            <script>
              for (const input of document.querySelectorAll('input')) {
                input.addEventListener('change', () => { document.getElementById('names').textContent = input.id + ':' + [...input.files].map((file) => file.name).join(','); });
              }
            </script>
            """),
        "/login-frame": (html, """
            <title>Login frame</title><style>body { margin: 0 } iframe { position: absolute; left: 40px; top: 40px; width: 400px; height: 200px; border: 0 }</style>
            <iframe id="login" src="/login"></iframe>
            <script>
              const frame = document.getElementById('login');
              frame.addEventListener('load', () => frame.contentDocument.getElementById('secret').focus());
            </script>
            """),
        "/nothing": ("HTTP/1.1 204 No Content", ""),
        "/mail": ("HTTP/1.1 302 Found\r\nLocation: mailto:x@example.com", ""),
        "/mail-links": (html, """
            <title>Mail links</title><style>body { margin: 0 } a { position: absolute; left: 40px; width: 120px; height: 30px }</style>
            <a href="mailto:x@example.com" style="top: 40px">Write</a>
            <a href="/mail" style="top: 100px">Redirect</a>
            """),
        "/done": (html, "<title>Done</title>"),
        // Custom listboxes as Radix's Select builds them, one under another past the fold. Each
        // opens on a mouse's pointerdown (its default prevented, so focus stays on the trigger)
        // or on ArrowDown, Enter or Space; ignores the pointerup of the press that opened it
        // unless the pointer moved; takes an option on its pointerup or Enter; closes on a
        // pointerdown outside, Escape, or the window's blur or resize; keeps the pointer from
        // everything else while open; and goes once its closing animation ends. Space takes the
        // focused option, as Radix's does. Above them, a field that takes 200 characters on a
        // page slow over every key; below, a combobox typed into, whose list opens on input.
        // `log` says why each one opened and closed.
        "/pickers": (html, """
            <title>Pickers</title>
            <style>
              body { margin: 0; font: 16px sans-serif }
              .row { height: 260px; padding: 20px 40px 0 }
              [role=combobox] { width: 200px; height: 32px }
              [role=listbox] { position: absolute; width: 200px; background: white; border: 1px solid; pointer-events: auto }
              [role=listbox][data-state=closed] { animation: out 80ms forwards }
              @keyframes out { to { opacity: 0 } }
              [role=option] { height: 28px; line-height: 28px; padding-left: 8px }
            </style>
            <div class="row"><textarea aria-label="Pitch" id="pitch" maxlength="200"></textarea></div>
            <div class="row"><button role="combobox" aria-label="Country" aria-expanded="false">Choose</button></div>
            <div class="row"><button role="combobox" aria-label="Industry" aria-expanded="false">Choose</button></div>
            <div class="row"><button role="combobox" aria-label="Month" aria-expanded="false">Choose</button></div>
            <div class="row"><button role="combobox" aria-label="Year" aria-expanded="false">Choose</button></div>
            <div class="row"><button role="combobox" aria-label="Round" aria-expanded="false">Choose</button></div>
            <div class="row"><input role="combobox" aria-label="Spend" id="spend" aria-expanded="false"></div>
            <script>
              pitch.addEventListener('keydown', () => { const end = Date.now() + 10; while (Date.now() < end) {} });
              spend.addEventListener('input', () => {
                if (spend.getAttribute('aria-expanded') === 'true') return;
                const list = document.createElement('div');
                list.setAttribute('role', 'listbox');
                const box = spend.getBoundingClientRect();
                list.style.left = box.left + scrollX + 'px';
                list.style.top = box.bottom + scrollY + 'px';
                for (const label of ['1%', '10%', '25%']) {
                  const option = document.createElement('div');
                  option.setAttribute('role', 'option');
                  option.textContent = label;
                  option.addEventListener('pointerup', () => {
                    spend.value = label;
                    spend.setAttribute('aria-expanded', 'false');
                    list.remove();
                    log.push('closed Spend: chose');
                  });
                  list.append(option);
                }
                document.body.append(list);
                spend.setAttribute('aria-expanded', 'true');
                log.push('opened Spend');
              });
              window.log = [];
              for (const type of ['blur', 'resize', 'visibilitychange', 'pointercancel']) addEventListener(type, () => log.push(type), true);
              const choices = { Country: ['France', 'Spain', 'Italy'], Industry: ['Health', 'Finance', 'Retail'], Month: ['January', 'February', 'March'], Year: ['2020', '2021', '2022'], Round: ['Seed', 'Series A', 'Series B'] };
              let open = null;
              for (const trigger of document.querySelectorAll('[role=combobox]')) {
                const name = trigger.getAttribute('aria-label');
                const show = (pressed) => {
                  if (open) return;
                  const list = document.createElement('div');
                  list.setAttribute('role', 'listbox');
                  list.dataset.state = 'open';
                  const box = trigger.getBoundingClientRect();
                  list.style.left = box.left + scrollX + 'px';
                  list.style.top = box.bottom + scrollY + 'px';
                  const hide = (why) => {
                    if (open !== list) return;
                    open = null;
                    log.push('closed ' + name + ': ' + why);
                    removeEventListener('blur', onBlur);
                    removeEventListener('resize', onResize);
                    document.removeEventListener('pointermove', move);
                    document.removeEventListener('pointerup', up, true);
                    document.removeEventListener('pointerdown', outside);
                    document.removeEventListener('keydown', escape);
                    trigger.setAttribute('aria-expanded', 'false');
                    list.dataset.state = 'closed';
                    list.addEventListener('animationend', () => { list.remove(); document.body.style.pointerEvents = ''; }, { once: true });
                    trigger.focus();
                  };
                  for (const label of choices[name]) {
                    const option = document.createElement('div');
                    option.setAttribute('role', 'option');
                    option.tabIndex = -1;
                    option.textContent = label;
                    const choose = () => { trigger.textContent = label; hide('chose'); };
                    option.addEventListener('pointerup', (event) => { if (!event.defaultPrevented) choose(); });
                    option.addEventListener('keydown', (event) => {
                      if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); choose(); }
                      if (event.key === 'ArrowDown') { event.preventDefault(); option.nextElementSibling?.focus(); }
                    });
                    list.append(option);
                  }
                  let moved = 0;
                  const move = (event) => { moved = Math.max(moved, Math.abs(event.pageX - pressed.pageX), Math.abs(event.pageY - pressed.pageY)); };
                  const up = (event) => {
                    if (moved <= 10) event.preventDefault(); else if (!list.contains(event.target)) hide('pointerup outside');
                    document.removeEventListener('pointermove', move);
                  };
                  const outside = (event) => { if (!list.contains(event.target)) hide('pointerdown outside'); };
                  const escape = (event) => { if (event.key === 'Escape') hide('Escape'); };
                  const onBlur = () => hide('window blur');
                  const onResize = () => hide('window resize');
                  open = list;
                  document.body.append(list);
                  document.body.style.pointerEvents = 'none';
                  trigger.setAttribute('aria-expanded', 'true');
                  log.push('opened ' + name);
                  addEventListener('blur', onBlur);
                  addEventListener('resize', onResize);
                  document.addEventListener('keydown', escape);
                  if (pressed) {
                    document.addEventListener('pointermove', move);
                    document.addEventListener('pointerup', up, { capture: true, once: true });
                  }
                  setTimeout(() => { if (open === list) document.addEventListener('pointerdown', outside); }, 0);
                  list.firstElementChild.focus({ preventScroll: true });
                };
                trigger.addEventListener('pointerdown', (event) => {
                  if (event.button !== 0 || event.ctrlKey || event.pointerType !== 'mouse') return;
                  show(event);
                  event.preventDefault();
                });
                trigger.addEventListener('keydown', (event) => {
                  if (![' ', 'Enter', 'ArrowDown', 'ArrowUp'].includes(event.key)) return;
                  show(null);
                  event.preventDefault();
                });
              }
            </script>
            """),
        "/busy-pad": (html, """
            <title>Busy pad</title><style>body { margin: 0 } #pad { position: absolute; left: 0; top: 0; width: 400px; height: 200px }</style>
            <div id="pad" role="button" aria-label="Pad"></div>
            <script>
              window.xs = [];
              document.getElementById('pad').addEventListener('mousemove', (event) => {
                xs.push(event.clientX);
                const end = Date.now() + 40;
                while (Date.now() < end) {}
              });
            </script>
            """),
    ]

    /// `openingFirst`: pages opened before agent access is on, whose frames never say hello.
    private func withAgent(openingFirst paths: [String] = [], _ body: (Client, URL) async throws -> Void) async throws {
        UserDefaults.standard.removeObject(forKey: Preference.agentAccess)
        // The throwaway home the tests run in has no Downloads folder, and a transfer into none fails.
        try FileManager.default.createDirectory(at: .downloadsDirectory, withIntermediateDirectories: true)
        let (listener, base) = try await LocalHTTP.serve(Self.pages)
        defer { listener.cancel() }
        let browser = Browser()
        await browser.privacy.waitUntilReady()
        await browser.extensions.waitUntilLoaded()
        for path in paths {
            let tab = browser.newTab(url: base.appending(path: path))
            #expect(await waitUntil(20) { tab.url?.path() == "/\(path)" && !tab.isLoading && tab.title != "" })
        }
        await browser.setAgentAccess(true)
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let active = NSApp?.isActive
        let key = NSApp?.keyWindow
        let pointer = NSEvent.mouseLocation
        let started = ContinuousClock.now
        var failure: (any Error)?
        do { try await body(try await Client(browser: browser), base) } catch { failure = error }
        // Out of the user's sight and reach, whatever the test did: their app stays in front.
        let now = NSWorkspace.shared.frontmostApplication?.processIdentifier
        #expect(now != getpid() || frontmost == getpid(), "the tests' process came to the front")
        #expect(NSApp?.isActive != true || active == true)
        #expect(NSApp?.keyWindow === key)
        // Lithium never moves the pointer. The user may, while the tests run: their mouse's own
        // moves (hardware events only) since the test started leave the pointer theirs to place.
        if !Self.userMovedTheMouse(since: started) { #expect(NSEvent.mouseLocation == pointer) }
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

    static func userMovedTheMouse(since start: ContinuousClock.Instant) -> Bool {
        let elapsed = (ContinuousClock.now - start) / .seconds(1)
        return [CGEventType.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains {
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) < elapsed
        }
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
            #expect(browser.commandWindow.selectedTabID == mine.id)
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

            // With Shift too, which opens the user's menu past the page's handlers: an agent's is
            // still the page's, and `agent.js` spends its arm, so the user's next right click is theirs.
            try await clearLog(tab)
            #expect(!(await client.call("click", ["tab": .string(id), "ref": .string(press), "button": "right", "modifiers": ["Shift"]])).isError)
            #expect(Set(try await log(tab, ["contextmenu", "mouseup"])) == ["contextmenu:true:b", "mouseup:true:b"])
            #expect(webView.agentMenusCancelled == 0)
            #expect(try await webView.callAsyncJavaScript("return lithiumAgentFrame.agentMenu", contentWorld: PageProbe.world) as? Int == 0)

            // Typing works right after a right click (design section 3, item 11).
            let field = try await ref(client, id, "textbox", "Field")
            #expect(!(await client.call("type", ["tab": .string(id), "ref": .string(field), "text": "ok"])).isError)
            #expect(try await page(tab, "return document.getElementById('field').value") as? String == "ok")

            // A page out of the user's front window gets no pointer move without a button
            // (design section 3, item 4), so the hover goes as a drag of a button never pressed.
            let hover = try await ref(client, id, "button", "Hover me")
            try await clearLog(tab)
            let hovered = await client.call("hover", ["tab": .string(id), "ref": .string(hover)])
            #expect(!hovered.isError, "\(hovered.content)")
            #expect(try await page(tab, "return document.getElementById('hover').matches('#hover:hover')") as? Bool == true)
            #expect(try await page(tab, "return getComputedStyle(document.getElementById('hover')).backgroundColor") as? String == "rgb(255, 0, 0)")
            #expect(try await log(tab, ["mousedown", "mouseup", "click"]).isEmpty, "a hover presses nothing")

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

            // Four wheel events, of which WebKit hands the page fewer: the call answers once the
            // page has come to rest where they lead, not a second later.
            let wheelStarted = ContinuousClock.now
            let wheeled = await client.call("scroll", ["tab": .string(id), "dy": 400])
            let wheelTook = ContinuousClock.now - wheelStarted
            #expect(!wheeled.isError, "\(wheeled.content)")
            #expect(wheelTook < .milliseconds(700), "scroll took \(wheelTook)")
            #expect(try await log(tab, ["wheel"]).allSatisfy { $0.hasPrefix("wheel:true:") })
            let scrolled = try await page(tab, "return scrollY") as? Double ?? 0
            #expect(scrolled == 400, "scrolled to \(scrolled)")
            // As other browser tools ask for it.
            let further = await client.call("scroll", ["tab": .string(id), "direction": "down", "amount": 200])
            #expect(!further.isError, "\(further.content)")
            #expect(try await page(tab, "return scrollY") as? Double == 600)
            #expect(!(await client.call("scroll", ["tab": .string(id), "direction": "up", "amount": 200])).isError)
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
            #expect(await eventually { await client.hub.log.entries(limit: 1).first?["params"]?["labels"] == ["Beta"] })
            let single = await client.call("select_option", ["tab": .string(id), "ref": .string(pick), "value": "a"])
            #expect(single["selected"] == ["Alpha"], "\(single.content)")
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

    @Test func aDragOnABusyPageReachesEveryStep() async throws {
        try await withAgent { client, base in
            let (id, tab) = try await open(client, base.appending(path: "busy-pad"))
            let dragged = await client.call("drag", ["tab": .string(id), "from": ["x": 20, "y": 100], "to": ["x": 220, "y": 100], "steps": 10])
            #expect(!dragged.isError, "\(dragged.content)")
            // The press's own move, at 20, reaches only a page in the window in front.
            let xs = try JSONDecoder().decode([Int].self, from: Data((try await page(tab, "return JSON.stringify(xs)") as? String ?? "").utf8))
            #expect(Array(xs.drop { $0 == 20 }) == (1...10).map { 20 + 20 * $0 }, "\(xs)")
        }
    }

    /// Custom listboxes open one after another to the agent's clicks, keys and typing, those past
    /// the fold too, and one stays open while its tab leaves the stage between two actions. A
    /// value longer than the field above them takes, on a page slow over every key, leaves no
    /// key queued: one would reach the listbox the next click opens, and a space take an option.
    @Test func customListboxesKeepOpeningOneAfterAnother() async throws {
        try await withAgent { client, base in
            let (id, tab) = try await open(client, base.appending(path: "pickers"))
            let long = String(repeating: "abcd fghij", count: 26)
            let filled = await client.call("fill_form", ["tab": .string(id), "fields": [["ref": .string(try await ref(client, id, "textbox", "Pitch")), "type": "textbox", "value": .string(long)]]])
            #expect(!filled.isError, "\(filled.content)")
            let expanded = { (name: String) in try await self.page(tab, "return document.querySelector('[aria-label=\"\(name)\"]').getAttribute('aria-expanded')") as? String }
            // What the trigger shows once the list has gone, and the pointer is the page's again.
            let shown = { (name: String) in try await self.page(tab, "return document.querySelector('[aria-label=\"\(name)\"]').textContent + '|' + document.body.style.pointerEvents + '|' + document.querySelectorAll('[role=listbox]').length") as? String }
            let click = { (role: String, name: String) in
                let clicked = await client.call("click", ["tab": .string(id), "ref": .string(try await self.ref(client, id, role, name))])
                #expect(!clicked.isError, "\(name): \(clicked.content)")
            }

            for (name, option) in [("Country", "Spain"), ("Industry", "Retail"), ("Month", "February")] {
                try await click("combobox", name)
                var events = try await log(tab)
                #expect(try await expanded(name) == "true", "\(name): \(events)")
                try await click("option", option)
                let chosen = await eventually { try await shown(name) == "\(option)||0" }
                events = try await log(tab)
                #expect(chosen, "\(name): \(events)")
            }

            // By keys: focus, ArrowDown opens and moves through the options, Enter takes one.
            #expect(!(await client.call("focus", ["tab": .string(id), "ref": .string(try await ref(client, id, "combobox", "Year"))])).isError)
            for keys in ["ArrowDown", "ArrowDown", "Enter"] {
                let pressed = await client.call("press", ["tab": .string(id), "keys": .string(keys)])
                #expect(!pressed.isError, "\(keys): \(pressed.content)")
            }
            let typed = await eventually { try await shown("Year") == "2021||0" }
            var events = try await log(tab)
            #expect(typed, "\(events)")

            // Open while the stage lets its tab go, as when an agent takes long to answer.
            client.hub.stage.releaseDelay = .milliseconds(50)
            try await click("combobox", "Round")
            #expect(await waitUntil(5) { tab.webView.window == nil })
            events = try await log(tab)
            #expect(try await expanded("Round") == "true", "\(events)")
            try await click("option", "Series A")
            let late = await eventually { try await shown("Round") == "Series A||0" }
            events = try await log(tab)
            #expect(late, "\(events)")

            // Typed into, it opens on input.
            let typedIn = await client.call("type", ["tab": .string(id), "ref": .string(try await ref(client, id, "combobox", "Spend")), "text": "1"])
            #expect(!typedIn.isError, "\(typedIn.content)")
            events = try await log(tab)
            #expect(try await expanded("Spend") == "true", "\(events)")
            try await click("option", "10%")
            #expect(try await page(tab, "return spend.value") as? String == "10%")

            // Each opened once, and closed once on its choice.
            events = try await log(tab).filter { $0.hasPrefix("opened ") || $0.hasPrefix("closed ") }
            #expect(events == ["Country", "Industry", "Month", "Year", "Round", "Spend"].flatMap { ["opened \($0)", "closed \($0): chose"] }, "\(events)")
            #expect(try await page(tab, "return pitch.value") as? String == String(long.prefix(200)))
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

    @Test func undoInOnePageNeverUndoesAnotherPagesOrLithiumsEdits() async throws {
        try await withAgent { client, base in
            let (firstID, first) = try await open(client, base.appending(path: "events"))
            let (secondID, second) = try await open(client, base.appending(path: "events"))
            let value = { (tab: Lithium.Tab) in try await self.page(tab, "return document.getElementById('field').value") as? String }
            for (id, text) in [(firstID, "one"), (secondID, "two")] {
                let typed = await client.call("type", ["tab": .string(id), "ref": .string(try await ref(client, id, "textbox", "Field")), "text": .string(text)])
                #expect(!typed.isError, "\(typed.content)")
            }
            #expect(first.webView.window === second.webView.window)
            #expect(!(await client.call("press", ["tab": .string(firstID), "keys": "Meta+Z"])).isError)
            #expect(try await value(first) == "")
            #expect(try await value(second) == "two")

            // The selected tab, in a window whose own undo stack holds an edit of Lithium's (the address bar's).
            let shown = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
            shown.isReleasedWhenClosed = false
            let webView = second.webView
            webView.removeFromSuperview()
            webView.frame = shown.contentLayoutRect
            shown.contentView = webView
            defer { shown.contentView = nil }
            client.browser.select(second)
            let typed = await client.call("type", ["tab": .string(secondID), "ref": .string(try await ref(client, secondID, "textbox", "Field")), "text": "three"])
            #expect(!typed.isError, "\(typed.content)")
            #expect(try await value(second) == "twothree")
            let addressBar = NSMutableString()
            shown.undoManager?.registerUndo(withTarget: addressBar) { $0.append("undone") }
            #expect(!(await client.call("press", ["tab": .string(secondID), "keys": "Meta+Z"])).isError)
            #expect(try await value(second) == "two")
            #expect(addressBar as String == "")
            #expect(shown.undoManager?.canUndo == true)
        }
    }

    @Test func shiftWithALetterOrADigitTypesItsShiftedCharacter() async throws {
        try await withAgent { client, base in
            let (id, tab) = try await open(client, base.appending(path: "events"))
            #expect(!(await client.call("focus", ["tab": .string(id), "ref": .string(try await ref(client, id, "textbox", "Field"))])).isError)
            for keys in ["Shift+A", "Shift+1", "Shift+/", "b"] {
                let pressed = await client.call("press", ["tab": .string(id), "keys": .string(keys)])
                #expect(!pressed.isError, "\(keys): \(pressed.content)")
            }
            #expect(try await page(tab, "return document.getElementById('field').value") as? String == "A!?b")
        }
    }

    // MARK: Checks

    @Test func actionabilityErrorsNameWhatStandsInTheWay() async throws {
        try await withAgent { client, base in
            let (id, tab) = try await open(client, base.appending(path: "covered"))
            let under = try await ref(client, id, "button", "Under")
            let covered = await client.call("click", ["tab": .string(id), "ref": .string(under)])
            #expect(covered.code == "covered", "\(covered.content)")
            let banner = try #require(covered.message.firstMatch(of: /\((e\d+)\)/)?.1)
            #expect(covered.message.hasPrefix("\(under) button \"Under\" is covered by DIV#page-cover \"We use cookies\" (\(banner))"), "\(covered.message)")
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

    /// A click whose press replaces its frame's document answers once the frame shows another
    /// one: the document asked to settle never answers, and the frame's going commits nothing
    /// in the tab.
    @Test func aClickThatNavigatesItsFrameEndsWithTheFramesDocument() async throws {
        try await withAgent { client, base in
            let (id, tab) = try await open(client, base.appending(path: "nav-frame"))
            let leave = try await ref(client, id, "button", "Leave")
            let started = ContinuousClock.now
            let clicked = await client.call("click", ["tab": .string(id), "ref": .string(leave), "timeoutMs": 15_000])
            #expect(!clicked.isError, "\(clicked.content)")
            #expect(ContinuousClock.now - started < .seconds(5))
            #expect(await eventually { try await page(tab, "return document.getElementById('nav').contentDocument.querySelector('button')?.textContent") as? String == "Inside" })
        }
    }

    /// Text no key types, after a key that took the field's frame away, isn't inserted into
    /// whatever has focus next: the call says the frame went.
    @Test func textInsertedAfterItsFrameWentIsRefused() async throws {
        try await withAgent { client, base in
            let (id, _) = try await open(client, base.appending(path: "gone-frame"))
            let field = try await ref(client, id, "textbox", "Leaving")
            let started = ContinuousClock.now
            let typed = await client.call("type", ["tab": .string(id), "ref": .string(field), "text": "a✓", "timeoutMs": 15_000])
            #expect(typed.code == "frame_gone", "\(typed.content)")
            #expect(ContinuousClock.now - started < .seconds(5))
        }
    }

    // MARK: Results

    @Test func resultsNameNewTabsDialogsDownloadsAndPageLoads() async throws {
        try await withAgent { client, base in
            let browser = client.browser
            let selected = browser.commandWindow.selectedTabID
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
            #expect(browser.commandWindow.selectedTabID == selected)

            let alerted = await client.call("click", ["tab": .string(id), "ref": .string(try await ref(client, id, "button", "Alert"))])
            #expect(!alerted.isError, "\(alerted.content)")
            #expect(alerted["dialog"]?["type"] == "alert")
            #expect(alerted["dialog"]?["message"] == "Saved")
            #expect(!(await client.call("dialog_respond", ["tab": .string(id), "accept": true])).isError)

            let report = try await ref(client, id, "link", "Report")
            let downloaded = await client.call("click", ["tab": .string(id), "ref": .string(report)])
            #expect(downloaded["download"]?["file"] == "report.csv" && downloaded["download"]?["done"] == true, "\(downloaded.content)")
            #expect(downloaded["navigated"] == false)
            #expect(try String(contentsOfFile: try #require(downloaded["download"]?["path"]?.string), encoding: .utf8) == "a,b")
            #expect(tab.url?.path() == "/results")

            let next = await client.call("click", ["tab": .string(id), "ref": .string(try await ref(client, id, "link", "Next")), "wait": "load"])
            #expect(!next.isError, "\(next.content)")
            #expect(next["navigated"] == true)
            #expect(next["title"] == "Done")
            #expect(next["diff"]?.string != nil)
            #expect(tab.url?.path() == "/done")
        }
    }

    @Test func everyTabAnAgentsClickOpensIsTheAgentsAndUnselected() async throws {
        try await withAgent { client, base in
            let browser = client.browser
            let selected = browser.commandWindow.selectedTabID
            let (id, tab) = try await open(client, base.appending(path: "results"))
            let usersTabs = browser.tabs.filter { !$0.isInAgentGroup }.count
            let plain = try await ref(client, id, "link", "Plain")
            let clicks: [(name: String, arguments: JSONValue)] = [
                ("⌘-click", ["tab": .string(id), "ref": .string(plain), "modifiers": ["Meta"]]),
                ("⌘⇧-click", ["tab": .string(id), "ref": .string(plain), "modifiers": ["Meta", "Shift"]]),
                ("middle click", ["tab": .string(id), "ref": .string(plain), "button": "middle"]),
                ("target=_blank", ["tab": .string(id), "ref": .string(try await ref(client, id, "link", "Open"))]),
                ("window.open", ["tab": .string(id), "ref": .string(try await ref(client, id, "button", "Window"))]),
            ]
            for (name, arguments) in clicks {
                let clicked = await client.call("click", arguments)
                #expect(!clicked.isError, "\(name): \(clicked.content)")
                guard case .array(let newTabs)? = clicked["newTabs"], newTabs.count == 1, let opened = client.tab(newTabs[0]["tab"]?.string ?? "") else {
                    Issue.record("\(name) named no new tab: \(clicked.content)")
                    continue
                }
                #expect(newTabs[0]["openedBy"] == .string(id), "\(name)")
                #expect(opened.isInAgentGroup, "\(name)")
                #expect(await waitUntil(5) { opened.url?.path() == "/form" }, "\(name)")
                #expect(tab.url?.path() == "/results", "\(name)")
                #expect(browser.commandWindow.selectedTabID == selected, "\(name)")
            }
            #expect(browser.tabs.filter { !$0.isInAgentGroup }.count == usersTabs)
        }
    }

    /// The user's own click opens the user's tab, even while an agent's action is under way in
    /// the same tab: the agent didn't press.
    @Test func whatTheUsersClickOpensDuringAnAgentsActionIsTheUsers() async throws {
        try await withAgent { client, base in
            let browser = client.browser
            let (_, tab) = try await open(client, base.appending(path: "user-opens"))
            let hub = client.hub
            let session = try #require(hub.sessions.first)
            let shown = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
            shown.isReleasedWhenClosed = false
            let webView = tab.webView
            webView.removeFromSuperview()
            webView.frame = shown.contentLayoutRect
            shown.contentView = webView
            defer { shown.contentView = nil }
            let agents = browser.tabs.filter(\.isInAgentGroup).count
            let press = { (css: CGPoint, modifiers: NSEvent.ModifierFlags) in
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try #require(NSEvent.mouseEvent(with: type, location: webView.convert(css, to: nil), modifierFlags: modifiers, timestamp: 0, windowNumber: shown.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                    type == .leftMouseDown ? webView.mouseDown(with: event) : webView.mouseUp(with: event)
                }
            }
            for next in ["/form", "file:///tmp/"] {
                browser.select(tab)
                let tabs = Set(browser.tabs.map(\.id))
                _ = try await page(tab, "window.next = '\(next)'")
                try press(CGPoint(x: 100, y: 115), [])
                // An agent's action begins in the tab, and has pressed nothing yet.
                hub.tabs[tab.id]?.acting = AgentActing(session: session.id, caption: "Clicking")
                defer { hub.tabs[tab.id]?.acting = nil }
                #expect(hub.isActing(in: tab) && hub.actingSession(in: tab) == nil, "\(next)")
                // The page opens it 700 ms after the user's click.
                try await Task.sleep(for: .milliseconds(1500))
                let opened = browser.tabs.filter { !tabs.contains($0.id) }
                #expect(opened.count == 1, "\(next)")
                #expect(opened.allSatisfy { !$0.isInAgentGroup && browser.commandWindow.selectedTabID == $0.id }, "\(next)")
                #expect(hub.tabs[tab.id]?.opened.isEmpty == true, "\(next)")
                opened.forEach(browser.close)
            }

            // The user's own ⌘⇧-click during the agent's action: their tab, selected.
            browser.select(tab)
            let tabs = Set(browser.tabs.map(\.id))
            hub.tabs[tab.id]?.acting = AgentActing(session: session.id, caption: "Clicking")
            defer { hub.tabs[tab.id]?.acting = nil }
            try press(CGPoint(x: 60, y: 175), [.command, .shift])
            #expect(await waitUntil(5) { browser.tabs.contains { !tabs.contains($0.id) } })
            let opened = browser.tabs.filter { !tabs.contains($0.id) }
            #expect(opened.count == 1 && opened.allSatisfy { !$0.isInAgentGroup && browser.commandWindow.selectedTabID == $0.id })
            #expect(hub.tabs[tab.id]?.interruption == .userInput, "the user's press ends the agent's action")
            #expect(browser.tabs.filter(\.isInAgentGroup).count == agents)
            #expect(tab.url?.path() == "/user-opens")
        }
    }

    /// Only an agent's middle click opens a tab; the user's follows the link in place.
    @Test func theUsersMiddleClickOnALinkFollowsItInPlace() async throws {
        try await withAgent { client, base in
            let browser = client.browser
            let (_, tab) = try await open(client, base.appending(path: "results"))
            let shown = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
            shown.isReleasedWhenClosed = false
            let webView = tab.webView
            webView.removeFromSuperview()
            webView.frame = shown.contentLayoutRect
            shown.contentView = webView
            defer { shown.contentView = nil }
            browser.select(tab)
            let count = browser.tabs.count
            let plain = webView.convert(CGPoint(x: 55, y: 290), to: nil)
            for type in [NSEvent.EventType.otherMouseDown, .otherMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: plain, modifierFlags: [], timestamp: 0, windowNumber: shown.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: type == .otherMouseDown ? 1 : 0))
                let cg = try #require(event.cgEvent)
                cg.setIntegerValueField(.mouseEventButtonNumber, value: Int64(CGMouseButton.center.rawValue))
                cg.setIntegerValueField(.mouseEventNumber, value: 2)
                let middle = try #require(NSEvent(cgEvent: cg))
                type == .otherMouseDown ? webView.otherMouseDown(with: middle) : webView.otherMouseUp(with: middle)
            }
            #expect(await waitUntil(5) { tab.url?.path() == "/form" })
            #expect(browser.tabs.count == count)
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

    /// The load under way before the click fails while the page handles it: Lithium's error page
    /// for it is no load of the click's.
    @Test func aLoadUnderWayBeforeAClickThatFailsDuringItIsNotTheClicks() async throws {
        let (slow, slowBase) = try await LocalHTTP.serve(["/fail": ("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/", "")], delay: 1)
        defer { slow.cancel() }
        try await withAgent { client, base in
            let (id, tab) = try await open(client, base.appending(path: "events"))
            _ = try await page(tab, """
                document.body.insertAdjacentHTML('beforeend', '<button id="busy" style="position:absolute;left:40px;top:320px">Busy</button>');
                document.getElementById('busy').addEventListener('click', () => { const end = Date.now() + 2000; while (Date.now() < end) {} });
                """)
            let busy = try await ref(client, id, "button", "Busy")
            tab.webView.load(URLRequest(url: slowBase.appending(path: "fail")))
            #expect(await waitUntil(5) { tab.isAwaitingCommit })
            let clicked = await client.call("click", ["tab": .string(id), "ref": .string(busy), "timeoutMs": 5000])
            #expect(!clicked.isError, "\(clicked.content)")
            #expect(clicked["navigated"] == false, "\(clicked.content)")
            #expect(await waitUntil(5) { tab.loadError != nil }, "the load failed")
        }
    }

    @Test func waitNoneAnswersOnceTheActionStartedALoad() async throws {
        let (slow, slowBase) = try await LocalHTTP.serve(["/slow": (Self.html, "<title>Slow</title>")], delay: 20)
        defer { slow.cancel() }
        try await withAgent { client, base in
            let (id, tab) = try await open(client, base.appending(path: "events"))
            _ = try await page(tab, "document.body.insertAdjacentHTML('beforeend', '<a href=\"\(slowBase.appending(path: "slow").absoluteString)\" style=\"position:absolute;left:40px;top:320px\">Slow</a>')")
            defer { tab.webView.stopLoading() }
            let clicked = await client.call("click", ["tab": .string(id), "ref": .string(try await ref(client, id, "link", "Slow")), "wait": "none", "timeoutMs": 3000])
            #expect(!clicked.isError, "\(clicked.content)")
            #expect(clicked["navigated"] == true)
            #expect(clicked["state"] == "started")
            #expect(tab.isAwaitingCommit)
        }
    }

    /// A load that ends before it shows a page (a 204 answer, a load the page stops) ends the
    /// action that started it: it happened, and nothing navigated.
    @Test func aLoadGivenUpBeforeItShowsAPageEndsTheAction() async throws {
        let (slow, slowBase) = try await LocalHTTP.serve(["/slow": (Self.html, "<title>Slow</title>")], delay: 20)
        defer { slow.cancel() }
        try await withAgent { client, base in
            let (id, tab) = try await open(client, base.appending(path: "events"))
            _ = try await page(tab, """
                document.body.insertAdjacentHTML('beforeend', '<a href="/nothing" style="position:absolute;left:40px;top:320px">Nothing</a>'
                  + '<a href="\(slowBase.appending(path: "slow").absoluteString)" onclick="setTimeout(() => stop(), 300)" style="position:absolute;left:40px;top:360px">Stopped</a>')
                """)
            for name in ["Nothing", "Stopped"] {
                let started = ContinuousClock.now
                let clicked = await client.call("click", ["tab": .string(id), "ref": .string(try await ref(client, id, "link", name)), "timeoutMs": 5000])
                #expect(!clicked.isError, "\(name): \(clicked.content)")
                #expect(clicked["navigated"] == false, "\(name): \(clicked.content)")
                #expect(ContinuousClock.now - started < .seconds(3), "\(name)")
                #expect(tab.url?.path() == "/events")
            }
            let navigated = await client.call("navigate", ["tab": .string(id), "url": .string(base.appending(path: "nothing").absoluteString), "timeoutMs": 5000])
            #expect(navigated.code == "navigation_cancelled", "\(navigated.content)")
            #expect(!(await client.call("click", ["tab": .string(id), "ref": .string(try await ref(client, id, "button", "Press"))])).isError)
        }
    }

    /// Tests never open another app on the user's screen: every hand-off is only recorded.
    @Test func theTestsRecordHandOffsToOtherApps() {
        #expect(ExternalApps.isRecording)
        #expect(ExternalApps.runsTests, "recording even without scripts/test's LITHIUM_NO_EXTERNAL_OPEN")
        #expect(LithiumHandOffGuardInstalled(), "NSWorkspace opens nothing, whoever calls it")
        if ProcessInfo.processInfo.environment["LITHIUM_HANDOFF_LOG"] != nil {
            #expect(LithiumLaunchServicesDenied(), "scripts/test's sandbox refuses LaunchServices' opens")
        }
    }

    /// The app itself hands off for real: system frameworks every AppKit app loads don't pass for a test runner.
    @Test func onlyTestFrameworksMarkATestRun() {
        #expect(ExternalApps.isTestImage("/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks/Testing.framework/Versions/A/Testing"))
        #expect(ExternalApps.isTestImage("/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework/Versions/A/XCTest"))
        #expect(ExternalApps.isTestImage("/Applications/Xcode.app/Contents/Developer/usr/lib/lib_TestingInterop.dylib"))
        #expect(ExternalApps.isTestImage("/tmp/build/debug/LithiumPackageTests.xctest/Contents/MacOS/LithiumPackageTests"))
        #expect(!ExternalApps.isTestImage("/System/Library/PrivateFrameworks/RecapPerformanceTesting.framework/Versions/A/RecapPerformanceTesting"))
        #expect(!ExternalApps.isTestImage("/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit"))
    }

    /// A closed tab's web view hands nothing to another app: a load still on its way when the tab
    /// closed (a redirect to `mailto:`) reaches a delegate that refuses it, not WebKit's own
    /// fallback, which opens it with NSWorkspace.
    @Test func aClosedTabsWebViewOpensNoOtherApp() async throws {
        try await withAgent { client, base in
            let browser = client.browser
            let (_, tab) = try await open(client, base.appending(path: "mail-links"))
            let webView = tab.webView
            let before = (LithiumHandOffCount(), ExternalApps.recorded)
            browser.close(tab)
            #expect(webView.navigationDelegate != nil)
            webView.load(URLRequest(url: URL(string: "mailto:x@example.com")!))
            webView.load(URLRequest(url: base.appending(path: "mail")))
            try await Task.sleep(for: .seconds(1))
            #expect(LithiumHandOffCount() == before.0, "see \(LithiumHandOffLogPath())")
            #expect(ExternalApps.recorded == before.1)
        }
    }

    /// An agent's click never hands an address to another app: a `mailto:` link, or a link the
    /// server redirects to one, ends as `navigation_cancelled`. The user's own click on the same
    /// link still opens their mail app.
    @Test func anAgentsClickNeverOpensAnotherApp() async throws {
        try await withAgent { client, base in
            let browser = client.browser
            let (id, tab) = try await open(client, base.appending(path: "mail-links"))
            let before = ExternalApps.recorded
            for name in ["Write", "Redirect"] {
                let started = ContinuousClock.now
                let clicked = await client.call("click", ["tab": .string(id), "ref": .string(try await ref(client, id, "link", name)), "timeoutMs": 5000])
                #expect(clicked.code == "navigation_cancelled", "\(name): \(clicked.content)")
                #expect(clicked.message.contains("mailto:"), "\(name): \(clicked.message)")
                #expect(ContinuousClock.now - started < .seconds(3), "\(name)")
                #expect(tab.title == "Mail links", "\(name): the page before stays")
            }
            #expect(ExternalApps.recorded == before, "\(ExternalApps.recorded)")

            let shown = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
            shown.isReleasedWhenClosed = false
            let webView = tab.webView
            webView.removeFromSuperview()
            webView.frame = shown.contentLayoutRect
            shown.contentView = webView
            defer { shown.contentView = nil }
            browser.select(tab)
            let write = webView.convert(CGPoint(x: 55, y: 50), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: write, modifierFlags: [], timestamp: 0, windowNumber: shown.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                type == .leftMouseDown ? webView.mouseDown(with: event) : webView.mouseUp(with: event)
            }
            #expect(await waitUntil(5) { ExternalApps.recorded == before + [.open(URL(string: "mailto:x@example.com")!)] }, "\(ExternalApps.recorded)")
        }
    }

    // MARK: Sensitive actions

    /// Lithium asks the user nothing: a payment button, a password, a card number and an upload
    /// go through like any action, and what is typed into a secret field is never logged.
    @Test func sensitiveActionsRunUnaskedAndTypedSecretsAreNeverLogged() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "agent-upload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "notes.txt")
        try "notes".write(to: file, atomically: true, encoding: .utf8)
        try await withAgent { client, base in
            await client.hub.log.clear()
            let (id, tab) = try await open(client, base.appending(path: "pay"))
            let started = ContinuousClock.now
            let pay = try await ref(client, id, "button", "Pay €42.00")
            let paid = await client.call("click", ["tab": .string(id), "ref": .string(pay)])
            #expect(!paid.isError && paid["grant"] == nil, "\(paid.content)")
            #expect(try await log(tab, ["click"]) == ["click:true:pay:1"])

            let user = try await ref(client, id, "textbox", "User")
            let typedUser = await client.call("type", ["tab": .string(id), "ref": .string(user), "text": "ann"])
            #expect(!typedUser.isError && typedUser["typed"] == nil, "\(typedUser.content)")
            let password = try await ref(client, id, "textbox", "Password")
            let typed = await client.call("type", ["tab": .string(id), "ref": .string(password), "text": "hunter2secret"])
            #expect(!typed.isError && typed["grant"] == nil && typed["typed"] == 13, "\(typed.content)")
            #expect(try await page(tab, "return document.getElementById('pw').value") as? String == "hunter2secret")

            let card = try await ref(client, id, "textbox", "Card number")
            let carded = await client.call("type", ["tab": .string(id), "ref": .string(card), "text": "4242424242424242"])
            #expect(!carded.isError && carded["typed"] == 16, "\(carded.content)")
            let cvc = await client.call("type", ["tab": .string(id), "ref": .string(try await ref(client, id, "textbox", "CVC")), "text": "cvc-secret"])
            #expect(!cvc.isError && cvc["grant"] == nil, "\(cvc.content)")
            let month = await client.call("select_option", ["tab": .string(id), "ref": .string(try await ref(client, id, "combobox", "Expiry month")), "labels": ["02"]])
            #expect(!month.isError && month["selected"] == nil, "\(month.content)")
            #expect(try await page(tab, "return [document.getElementById('card').value, document.getElementById('cvc').value, document.getElementById('exp').value]") as? [String] == ["4242424242424242", "cvc-secret", "02"])

            let upload = try await ref(client, id, "button", "Attachment")
            let uploaded = await client.call("upload_files", ["tab": .string(id), "ref": .string(upload), "paths": [.string(file.path())]])
            #expect(!uploaded.isError && uploaded["grant"] == nil, "\(uploaded.content)")
            #expect(uploaded["inputFiles"] == ["notes.txt"])
            #expect(ContinuousClock.now - started < .seconds(20), "no call waited on the user")

            var entries: [JSONValue] = []
            #expect(await eventually {
                entries = await client.hub.log.entries(limit: 100)
                return entries.filter { $0["tool"] == "type" }.count == 4
            })
            #expect(entries.allSatisfy { $0["event"] == nil && $0["confirmation"] == nil }, "no prompt is logged")
            let logged = String(decoding: JSONValue.array(entries).encoded(), as: UTF8.self)
            for secret in ["hunter2secret", "4242424242424242", "cvc-secret"] { #expect(!logged.contains(secret), "\(secret) in the log") }
            #expect(logged.contains("\"text\":\"ann\""))
            #expect(entries.first { $0["tool"] == "select_option" }?["params"]?["labels"] == "[redacted]")
        }
    }

    /// A file input the page hides behind a button, or covers, takes its files all the same: by
    /// its own ref, by the drop zone around it, or as the page's only one with no ref at all.
    @Test func uploadsReachFileInputsThePageHidesOrCovers() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "agent-upload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (notes, photo) = (folder.appending(path: "notes.txt"), folder.appending(path: "photo.txt"))
        try "notes".write(to: notes, atomically: true, encoding: .utf8)
        try "photo".write(to: photo, atomically: true, encoding: .utf8)
        try await withAgent { client, base in
            let (id, tab) = try await open(client, base.appending(path: "upload-hidden"))
            let tabID: JSONValue = .string(id)
            // The button opens no chooser on a click: the call says so, and how to go on.
            let choose = try await ref(client, id, "button", "Choose a file")
            let none = await client.call("upload_files", ["tab": tabID, "ref": .string(choose), "paths": [.string(notes.path())]])
            #expect(none.code == "unsupported" && none.message.contains("leave ref out"), "\(none.content)")
            // No ref: the page's only file input, which no snapshot shows.
            let only = await client.call("upload_files", ["tab": tabID, "paths": .string(notes.path())])
            #expect(!only.isError, "\(only.content)")
            #expect(only["inputFiles"] == ["notes.txt"] && only["files"] == ["notes.txt"])
            #expect(try await page(tab, "return document.getElementById('names').textContent") as? String == "hidden:notes.txt")
            #expect(only["diff"]?.string?.contains("hidden:notes.txt") == true, "\(only["diff"] ?? .null)")
            #expect((await client.call("upload_files", ["tab": tabID, "paths": [.string(folder.appending(path: "missing.txt").path())]])).code == "invalid_params")

            let (zones, zoneTab) = try await open(client, base.appending(path: "upload-zone"))
            let zonesID: JSONValue = .string(zones)
            // Two inputs: without a ref the call names them rather than picking one.
            let which = await client.call("upload_files", ["tab": zonesID, "paths": [.string(notes.path())]])
            #expect(which.code == "invalid_params" && which.message.contains("2 file inputs") && which.message.contains("\"Covered\""), "\(which.content)")
            // The drop zone stands for the input inside it.
            let zone = try await ref(client, zones, "button", "Drop files here")
            let dropped = await client.call("upload_files", ["tab": zonesID, "ref": .string(zone), "paths": [.string(notes.path()), .string(photo.path())]])
            #expect(dropped["inputFiles"] == ["notes.txt", "photo.txt"], "\(dropped.content)")
            // An overlay over the input would refuse a click; its chooser opens all the same.
            let covered = try await ref(client, zones, "button", "Covered")
            #expect((await client.call("click", ["tab": zonesID, "ref": .string(covered)])).code == "covered")
            let given = await client.call("upload_files", ["tab": zonesID, "ref": .string(covered), "paths": [.string(photo.path())]])
            #expect(given["inputFiles"] == ["photo.txt"], "\(given.content)")
            #expect(try await page(zoneTab, "return document.getElementById('names').textContent") as? String == "covered:photo.txt")
        }
    }

    /// Keys pressed in a password field are never logged, named or not; elsewhere a named key is,
    /// and a character key never.
    @Test func keysInAPasswordFieldAreNeverLogged() async throws {
        try await withAgent { client, base in
            await client.hub.log.clear()
            let (id, tab) = try await open(client, base.appending(path: "login"))
            let focus = { (role: String, name: String) in
                let focused = await client.call("focus", ["tab": .string(id), "ref": .string(try await ref(client, id, role, name))])
                #expect(!focused.isError, "\(focused.content)")
            }
            try await focus("textbox", "Secret")
            // As other browser tools name the argument.
            let typed = await client.call("press", ["tab": .string(id), "key": "q", "repeat": 2])
            #expect(!typed.isError && typed["grant"] == nil, "\(typed.content)")
            #expect(try await page(tab, "return document.getElementById('secret').value") as? String == "qq")
            #expect(!(await client.call("press", ["tab": .string(id), "keys": "Backspace"])).isError)
            try await focus("checkbox", "Remember")
            #expect(!(await client.call("press", ["tab": .string(id), "keys": "Space"])).isError)
            #expect(try await page(tab, "return document.getElementById('remember').checked") as? Bool == true)
            try await focus("textbox", "Who")
            #expect(!(await client.call("press", ["tab": .string(id), "keys": "z"])).isError)
            #expect(!(await client.call("press", ["tab": .string(id), "keys": "ArrowLeft"])).isError)

            let expected = ["[redacted]", "[redacted]", "Space", "[redacted]", "ArrowLeft"]
            var entries: [JSONValue] = []
            var keys: [String] = []
            _ = await eventually {
                entries = await client.hub.log.entries(limit: 200)
                keys = entries.filter { $0["tool"] == "press" }.reversed().compactMap { $0["params"]?["keys"]?.string }
                return keys == expected
            }
            #expect(keys == expected)
            let logged = String(decoding: JSONValue.array(entries).encoded(), as: UTF8.self)
            #expect(!logged.contains("\"q\"") && !logged.contains("\"key\""), "\(logged)")

            // Enter on a checkbox submits its form, password and all, unasked.
            try await focus("checkbox", "Remember")
            let submitted = await client.call("press", ["tab": .string(id), "keys": "Enter", "wait": "load"])
            #expect(submitted["navigated"] == true, "\(submitted.content)")
            #expect(tab.url?.path() == "/done")
        }
    }

    /// Text and keys sent into a frame Lithium can't read (open before agent access was on) go
    /// through, and are never logged: the field there may be a password's.
    @Test func whatIsTypedIntoAFrameLithiumCantReadIsNeverLogged() async throws {
        try await withAgent(openingFirst: ["login-frame"]) { client, _ in
            // Earlier tests' tabs had the same ids.
            await client.hub.log.clear()
            let frameTab = try #require(client.browser.tabs.first { $0.url?.path() == "/login-frame" })
            let frame = client.hub.id(for: frameTab)
            for (tool, arguments) in [
                ("type", ["tab": .string(frame), "text": "hunter2"]), ("press", ["tab": .string(frame), "keys": "q"]),
                ("press", ["tab": .string(frame), "keys": "Tab"]), ("click", ["tab": .string(frame), "x": 45, "y": 45]),
            ] as [(String, JSONValue)] {
                let result = await client.call(tool, arguments)
                #expect(!result.isError, "\(tool): \(result.content)")
            }
            #expect(try await page(frameTab, "return document.getElementById('login').contentDocument.getElementById('secret').value") as? String == "hunter2q")

            var logged: [String] = []
            _ = await eventually {
                let entries = await client.hub.log.entries(limit: 400)
                logged = entries.filter { $0["tab"]?["id"]?.string == frame && ["type", "press"].contains($0["tool"]?.string ?? "") }
                    .compactMap { $0["params"]?["text"]?.string ?? $0["params"]?["keys"]?.string }
                return logged.count == 3
            }
            #expect(logged == ["[redacted]", "[redacted]", "[redacted]"], "\(logged)")
            let all = String(decoding: JSONValue.array(await client.hub.log.entries(limit: 400)).encoded(), as: UTF8.self)
            #expect(!all.contains("hunter2"))
        }
    }

    // MARK: The user wins

    @Test func theUsersInputEndsTheAgentsActionAndTheirEditingHoldsItUp() async throws {
        let (slow, slowBase) = try await LocalHTTP.serve(["/slow": (Self.html, "<title>Slow</title>")], delay: 3)
        defer { slow.cancel() }
        try await withAgent { client, base in
            let (id, tab) = try await open(client, base.appending(path: "pay"))
            // An action under way: the agent's click on a link whose page is slow to come.
            _ = try await page(tab, "document.body.insertAdjacentHTML('beforeend', '<a href=\"\(slowBase.appending(path: "slow").absoluteString)\" style=\"position:absolute;left:40px;top:320px\">Slow</a>')")
            let link = try await ref(client, id, "link", "Slow")
            let waiting = Task { await client.call("click", ["tab": .string(id), "ref": .string(link)]) }
            #expect(await waitUntil(5) { tab.isAwaitingCommit })
            let webView = try #require(tab.webView as? PageWebView)
            let window = try #require(webView.window)
            let users = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 5, y: 5), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            webView.mouseDown(with: users)
            webView.mouseUp(with: try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: CGPoint(x: 5, y: 5), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)))
            let interrupted = await waiting.value
            #expect(interrupted.code == "user_interrupted", "\(interrupted.content)")
            tab.stopLoading()
            #expect(await waitUntil(5) { !tab.isLoading })

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

    /// The user scrolling and typing while the agent's download is on its way doesn't make it
    /// theirs: it goes ahead unasked. Only a load of their own, from their click, takes the tab back.
    @Test func theUsersInputLeavesTheAgentsDownloadTheAgents() async throws {
        // Redirected on its way, as download links often are: the redirect is still the agent's load.
        #expect(WKNavigationAction.instancesRespond(to: NSSelectorFromString("_isRedirect")))
        let (slow, slowBase) = try await LocalHTTP.serve([
            "/report.csv": Self.pages["/report.csv"]!, "/to-report": ("HTTP/1.1 302 Found\r\nLocation: /report.csv", ""),
            "/elsewhere": (Self.html, "<title>Elsewhere</title>"),
        ], delay: 1.5)
        defer { slow.cancel() }
        try await withAgent { client, base in
            let (id, tab) = try await open(client, base.appending(path: "events"))
            _ = try await page(tab, """
                document.body.insertAdjacentHTML('beforeend', '<a href="\(slowBase.appending(path: "to-report").absoluteString)" style="position:absolute;left:40px;top:320px">Slow report</a>'
                  + '<a href="\(slowBase.appending(path: "elsewhere").absoluteString)" style="position:absolute;left:40px;top:360px">Elsewhere</a>');
                """)
            let report = try await ref(client, id, "link", "Slow report")
            let webView = try #require(tab.webView as? PageWebView)
            let permissions = client.browser.permissions

            let clicking = Task { await client.call("click", ["tab": .string(id), "ref": .string(report)]) }
            #expect(await waitUntil(5) { tab.isAwaitingCommit })
            // In the stage while the agent acts there.
            let window = try #require(webView.window)
            let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -40, wheel2: 0, wheel3: 0))
            webView.scrollWheel(with: try #require(NSEvent(cgEvent: wheel)))
            webView.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)))
            #expect((await clicking.value).code == "user_interrupted")
            #expect(await waitUntil(10) { tab.lastDownload?.state == .finished }, "the download goes ahead")
            #expect(permissions.pending.isEmpty, "nothing asked")

            let again = Task { await client.call("click", ["tab": .string(id), "ref": .string(report)]) }
            #expect(await waitUntil(5) { tab.isAwaitingCommit && client.hub.drive(of: tab) != nil })
            // Where the user's wheel left it.
            let top = try #require(try await page(tab, "return document.querySelector('a[href$=\"elsewhere\"]').getBoundingClientRect().top") as? Double)
            let elsewhere = webView.convert(CGPoint(x: 50, y: top + 10), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: elsewhere, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                type == .leftMouseDown ? webView.mouseDown(with: event) : webView.mouseUp(with: event)
            }
            let interrupted = await again.value
            #expect(interrupted.code == "user_interrupted", "\(interrupted.content)")
            // The user's page is still on its way: the agent's claim ended with their click.
            #expect(await waitUntil(5) { tab.isAwaitingCommit && tab.url?.path() == "/elsewhere" })
            #expect(client.hub.tabs[tab.id]?.drive == nil)
            #expect(await waitUntil(10) { tab.title == "Elsewhere" })
            #expect(permissions.pending.isEmpty)
        }
    }

    /// A download the page starts a moment after the agent's click, while the user presses
    /// arrows and letters, is still the agent's. The user's own click on a download link is theirs.
    @Test func theUsersKeysLeaveTheAgentsDelayedDownloadTheAgents() async throws {
        let (slow, slowBase) = try await LocalHTTP.serve(["/export": (Self.html, "<title>Exported</title>")], delay: 20)
        defer { slow.cancel() }
        // Never answers within the test: the user's file never downloads.
        let (stalled, stalledBase) = try await LocalHTTP.serve(["/mine.csv": Self.pages["/report.csv"]!], delay: 60)
        defer { stalled.cancel() }
        try await withAgent { client, base in
            let (id, tab) = try await open(client, base.appending(path: "events"))
            // Into a hidden frame, as sites' Export buttons often do: the agent's load goes on.
            _ = try await page(tab, """
                document.body.insertAdjacentHTML('beforeend', '<iframe name="sink" style="display:none"></iframe>'
                  + '<a id="export" href="\(slowBase.appending(path: "export").absoluteString)" style="position:absolute;left:40px;top:320px">Export</a>'
                  + '<a id="save" href="/report.csv" target="sink" style="position:absolute;left:40px;top:360px">Save</a>'
                  + '<a id="mine" href="\(stalledBase.appending(path: "mine.csv").absoluteString)" target="sink" style="position:absolute;left:40px;top:440px">Mine</a>');
                document.getElementById('export').addEventListener('click', () => setTimeout(() => document.getElementById('save').click(), 400), { once: true });
                """)
            let export = try await ref(client, id, "link", "Export")
            let webView = try #require(tab.webView as? PageWebView)
            let permissions = client.browser.permissions

            let clicking = Task { await client.call("click", ["tab": .string(id), "ref": .string(export)]) }
            #expect(await waitUntil(5) { tab.isAwaitingCommit })
            let window = try #require(webView.window)
            for (characters, code) in [("\u{F701}", UInt16(125)), ("a", 0)] {
                webView.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)))
            }
            #expect((await clicking.value).code == "user_interrupted")
            // A frame's download the user's own click starts asks them; the agent's doesn't.
            #expect(await waitUntil(10) { tab.lastDownload?.state == .finished }, "the page's download goes ahead")
            #expect(permissions.pending.isEmpty, "nothing asked")

            #expect(tab.isAwaitingCommit && client.hub.drive(of: tab) != nil, "the agent's page is still on its way")
            let top = try #require(try await page(tab, "return document.getElementById('mine').getBoundingClientRect().top") as? Double)
            let mine = webView.convert(CGPoint(x: 50, y: top + 10), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: mine, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                type == .leftMouseDown ? webView.mouseDown(with: event) : webView.mouseUp(with: event)
            }
            // Their click's load took the tab back: what it downloads is no longer the agent's.
            #expect(await waitUntil(5) { client.hub.tabs[tab.id]?.drive == nil })
            #expect(tab.isLoading, "the agent's page is still on its way")
        }
    }

    /// A field whose click moves focus to a password field: the keys go there, and the text is
    /// never logged.
    @Test func typingWhereTheClickMovesFocusIsLoggedAsForTheFieldFocused() async throws {
        try await withAgent { client, base in
            let (id, tab) = try await open(client, base.appending(path: "decoy"))
            let account = try await ref(client, id, "textbox", "Account")
            _ = try await page(tab, "document.getElementById('real').value = 'kept'")
            let typed = await client.call("type", ["tab": .string(id), "ref": .string(account), "text": "hunter2decoy", "clear": true])
            #expect(!typed.isError && typed["typed"] == 12, "\(typed.content)")
            #expect(try await page(tab, "return [document.getElementById('account').value, document.getElementById('real').value]") as? [String] == ["", "hunter2decoy"])

            var entries: [JSONValue] = []
            #expect(await eventually {
                entries = await client.hub.log.entries(limit: 100).filter { $0["tool"] == "type" && $0["tab"]?["url"] == .string(tab.url?.absoluteString ?? "") }
                return entries.count == 1
            })
            let logged = String(decoding: JSONValue.array(entries).encoded(), as: UTF8.self)
            #expect(!logged.contains("hunter2decoy"), "\(logged)")
            #expect(entries.allSatisfy { $0["params"]?["text"] == "[redacted]" }, "\(entries)")
        }
    }

    /// A multi-line field whose click moves focus to a one-line one: "\n" would be Enter there,
    /// which submits its form, so the call is refused before any key.
    @Test func newlinesAreRefusedWhenFocusMovesToAOneLineField() async throws {
        try await withAgent { client, base in
            let (id, tab) = try await open(client, base.appending(path: "to-one-line"))
            let notes = try await ref(client, id, "textbox", "Notes")
            let typed = await client.call("type", ["tab": .string(id), "ref": .string(notes), "text": "a\nb"])
            #expect(typed.code == "invalid_params", "\(typed.content)")
            #expect(typed.message.contains("holds one line"), "\(typed.message)")
            #expect(try await page(tab, "return document.getElementById('title').value") as? String == "")
            #expect(tab.url?.path() == "/to-one-line")
        }
    }

    /// A field whose click moves focus to a password field a moment later: the keys go where
    /// focus is before the first, and the text is never logged.
    @Test func typingWhereFocusMovesAfterTheClickIsLoggedAsForTheFieldFocused() async throws {
        try await withAgent { client, base in
            let (id, tab) = try await open(client, base.appending(path: "later"))
            let account = try await ref(client, id, "textbox", "Account")
            _ = try await page(tab, "document.getElementById('real').value = 'kept'")
            let typed = await client.call("type", ["tab": .string(id), "ref": .string(account), "text": "hunter2later", "clear": true])
            #expect(!typed.isError, "\(typed.content)")
            #expect(typed["typed"] == 12)
            #expect(try await page(tab, "return [document.getElementById('account').value, document.getElementById('real').value]") as? [String] == ["", "hunter2later"])

            var entries: [JSONValue] = []
            #expect(await eventually {
                entries = await client.hub.log.entries(limit: 100).filter { $0["tool"] == "type" && $0["tab"]?["url"] == .string(tab.url?.absoluteString ?? "") }
                return entries.count == 1
            })
            let logged = String(decoding: JSONValue.array(entries).encoded(), as: UTF8.self)
            #expect(!logged.contains("hunter2later"), "\(logged)")
            #expect(entries.allSatisfy { $0["params"]?["text"] == "[redacted]" }, "\(entries)")
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
        }
    }
}

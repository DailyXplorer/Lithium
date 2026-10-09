import AppKit
import Foundation
import Testing
import WebKit
@testable import Lithium

@MainActor
struct PageFontTests {
    private static let page = """
        <style>
          .fa { font-family: "Font Awesome 6 Free"; } .fa-user::before { content: "\\f007"; }
          .mystery { font-family: brandglyphs; } .mystery::before { content: "\\e900"; }
          .material { font-family: "Material Symbols Outlined"; }
          .deep .deeper p { font-family: Georgia !important; }
          pre { font-family: Menlo, monospace; }
        </style>
        <p id="text">Hello</p>
        <i id="fa" class="fa fa-user"></i>
        <span id="mystery" class="mystery"></span>
        <span id="material" class="material">home</span>
        <div class="deep"><div class="deeper"><p id="important">Styled</p></div></div>
        <pre id="code"><span id="token">let</span></pre>
        <span id="restyled"></span>
        <div id="host"></div>
        <script>
          document.getElementById('host').attachShadow({ mode: 'open' }).innerHTML =
            '<style>.fa { font-family: "Font Awesome 6 Free"; }</style><p>Shadow text</p><i class="fa"></i>';
        </script>
        """

    private static let probe = """
        const late = document.createElement('i');
        late.id = 'late';
        late.className = 'fa fa-user';
        document.body.append(late);
        document.getElementById('restyled').className = 'fa fa-user';
        await new Promise((resolve) => setTimeout(resolve, 400));
        const first = (id) => getComputedStyle(document.getElementById(id)).fontFamily.split(',')[0].replace(/"/g, '').trim();
        const ids = ['text', 'fa', 'mystery', 'material', 'important', 'code', 'token', 'late', 'restyled'];
        const fonts = Object.fromEntries(ids.map((id) => [id, first(id)]));
        const shadow = document.getElementById('host').shadowRoot;
        fonts.shadowText = getComputedStyle(shadow.querySelector('p')).fontFamily.split(',')[0].replace(/"/g, '').trim();
        fonts.shadowIcon = getComputedStyle(shadow.querySelector('i')).fontFamily.split(',')[0].replace(/"/g, '').trim();
        fonts.loaded = [...document.fonts].some((face) => face.family.includes('Lithium DM Sans') && face.status === 'loaded') ? 'yes' : 'no';
        return fonts;
        """

    /// A site exception for an IPv6 address is listed bare, and its Remove button sends that back:
    /// it names the same site as the address typed in with brackets.
    @Test func anIPv6SiteFontExceptionCanBeRemoved() {
        #expect(InternalBridge.siteFontHost("2001:db8::1") == "2001:db8::1")
        #expect(InternalBridge.siteFontHost(" [2001:DB8::1] ").map(SiteInfo.registrable) == "2001:db8::1")
        #expect(InternalBridge.siteFontHost("https://Example.com/page") == "example.com")
        #expect(InternalBridge.siteFontHost("example.com") == "example.com")
        #expect(InternalBridge.siteFontHost("192.168.0.1") == "192.168.0.1")
        #expect(InternalBridge.siteFontHost("") == nil)
    }

    /// A font installed or removed while Lithium runs has the website font checked again: one
    /// uninstalled since gives way to DM Sans without a relaunch.
    @Test func fontsChangingOnTheMacRebuildTheScript() async {
        let built = PageStyle.fontScript
        #expect(PageStyle.fontScript === built, "kept while nothing changes")
        NotificationCenter.default.post(name: NSFont.fontSetChangedNotification, object: nil)
        let deadline = Date().addingTimeInterval(2)
        while PageStyle.fontScript === built, Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(PageStyle.fontScript !== built)
    }

    @Test func dmSansReplacesTextFontsButNotIconsCodeOrMath() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(PageStyle.fontScript)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let loaded = PageLoad()
        webView.navigationDelegate = loaded
        webView.loadHTMLString(Self.page, baseURL: URL(string: "https://example.com/")!)
        try await loaded.wait()

        let fonts = try #require(try await webView.callAsyncJavaScript(Self.probe, contentWorld: .page) as? [String: String])
        #expect(fonts["loaded"] == "yes")
        #expect(fonts["text"] == "Lithium DM Sans")
        #expect(fonts["important"] == "Lithium DM Sans")
        #expect(fonts["fa"] == "Font Awesome 6 Free")
        #expect(fonts["late"] == "Font Awesome 6 Free")
        #expect(fonts["restyled"] == "Font Awesome 6 Free")
        #expect(fonts["mystery"] == "brandglyphs")
        #expect(fonts["material"] == "Material Symbols Outlined")
        #expect(fonts["code"] == "Menlo")
        #expect(fonts["token"] == "Menlo")
        #expect(fonts["shadowText"] == "Lithium DM Sans")
        #expect(fonts["shadowIcon"] == "Font Awesome 6 Free")
    }

    /// Like ProseMirror, the editor re-renders its content on any change it didn't make, and
    /// ignores its own. Probing the nodes it renders made the two answer each other forever.
    @Test func richTextEditorStaysIdle() async throws {
        let page = """
            <div id="editor" contenteditable="true"><p>Hello <span class="mark">world</span></p></div>
            <script>
              window.renders = 0;
              const editor = document.getElementById('editor');
              const options = { attributes: true, childList: true, subtree: true, characterData: true };
              const observer = new MutationObserver(() => {
                observer.disconnect();
                window.renders++;
                editor.replaceChildren(editor.firstElementChild.cloneNode(true));
                editor.firstElementChild.setAttribute('data-render', String(window.renders));
                observer.observe(editor, options);
              });
              observer.observe(editor, options);
            </script>
            """
        let probe = """
            const editor = document.getElementById('editor');
            // Typed once the page's first scan is done; before it, the scan covers the new nodes.
            await new Promise((resolve) => setTimeout(resolve, 400));
            editor.firstElementChild.append(document.createElement('span'));
            await new Promise((resolve) => setTimeout(resolve, 2000));
            return { renders: window.renders, font: getComputedStyle(editor.querySelector('.mark')).fontFamily.split(',')[0].replace(/"/g, '').trim() };
            """
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(PageStyle.fontScript)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let loaded = PageLoad()
        webView.navigationDelegate = loaded
        webView.loadHTMLString(page, baseURL: URL(string: "https://example.com/")!)
        try await loaded.wait()

        let result = try #require(try await webView.callAsyncJavaScript(probe, contentWorld: .page) as? [String: Any])
        #expect(result["renders"] as? Int == 1)
        #expect(result["font"] as? String == "Lithium DM Sans")
    }

    /// An editor this script can't recognize (no contenteditable) rewrites its class whenever
    /// anyone else touches its attributes, so every pass brings another one. The throttle must hold:
    /// fewer passes lower the burst count, and that alone must not lift it.
    @Test func unrecognizedEditorStaysThrottled() async throws {
        let page = """
            <div id="editor" class="pass-0"><p>Hello</p></div>
            <script>
              window.passes = 0;
              const editor = document.getElementById('editor');
              const options = { attributes: true, subtree: true };
              const observer = new MutationObserver(() => {
                observer.disconnect();
                editor.className = 'pass-' + ++window.passes;
                observer.observe(editor, options);
              });
              observer.observe(editor, options);
            </script>
            """
        let probe = """
            const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
            await wait(400);
            document.getElementById('editor').className = 'start';
            await wait(3000);
            const before = window.passes;
            await wait(6000);
            return { passes: window.passes - before };
            """
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(PageStyle.fontScript)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        // In a window WebKit takes for visible, so animation frames run and the loop goes at full
        // speed until throttled; hidden, timers alone would keep it below the throttle's threshold.
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        let occlusion = Selector(("_setWindowOcclusionDetectionEnabled:"))
        if webView.responds(to: occlusion) {
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(webView.method(for: occlusion), to: Setter.self)(webView, occlusion, false)
        }
        window.orderFrontRegardless()
        defer { window.close() }
        let loaded = PageLoad()
        webView.navigationDelegate = loaded
        webView.loadHTMLString(page, baseURL: URL(string: "https://example.com/")!)
        try await loaded.wait()

        let result = try #require(try await webView.callAsyncJavaScript(probe, contentWorld: .page) as? [String: Any])
        let passes = try #require(result["passes"] as? Int)
        #expect(passes > 0)
        #expect(passes <= 14)
    }

    /// A chat or live feed appends content on every frame for good: its icons must still keep their
    /// font once the page has been busy longer than the anti-loop budget.
    @Test func streamingPageKeepsLateIconFonts() async throws {
        let page = """
            <style>.material { font-family: "Material Symbols Outlined"; }</style>
            <div id="feed"></div>
            """
        let probe = """
            const feed = document.getElementById('feed');
            const first = (element) => getComputedStyle(element).fontFamily.split(',')[0].replace(/"/g, '').trim();
            const start = performance.now();
            // Timers are slowed in a web view outside a window: each one carries several bursts.
            while (performance.now() - start < 3000) {
              for (let i = 0; i < 10; i++) {
                const line = document.createElement('p');
                line.innerHTML = 'Message <span class="material">home</span>';
                feed.append(line);
                await Promise.resolve();
              }
              await new Promise((resolve) => setTimeout(resolve, 16));
            }
            await new Promise((resolve) => setTimeout(resolve, 700));
            const last = feed.lastElementChild;
            const lost = [...feed.querySelectorAll('.material')].filter((icon) => first(icon) !== 'Material Symbols Outlined').length;
            return { lines: feed.children.length, lost, icon: first(last.querySelector('.material')), text: first(last) };
            """
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(PageStyle.fontScript)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let loaded = PageLoad()
        webView.navigationDelegate = loaded
        webView.loadHTMLString(page, baseURL: URL(string: "https://example.com/")!)
        try await loaded.wait()

        let result = try #require(try await webView.callAsyncJavaScript(probe, contentWorld: .page) as? [String: Any])
        #expect((result["lines"] as? Int ?? 0) > 100)
        #expect(result["lost"] as? Int == 0)
        #expect(result["icon"] as? String == "Material Symbols Outlined")
        #expect(result["text"] as? String == "Lithium DM Sans")
    }

    /// Large containers don't rescan their whole subtree when their class changes, yet a switch to
    /// a code font still reaches everything inside them, and so does a font rule for one descendant.
    @Test func largeContainerFollowsItsClassChanges() async throws {
        let page = """
            <style>
              .mono { font-family: Menlo, monospace; } .fa { font-family: "Font Awesome 6 Free"; }
              .special .icon { font-family: Menlo, monospace; }
              .serif { font-family: Georgia; } .special .serif { font-family: Menlo, monospace; }
            </style>
            <div id="big"><section><span class="icon">x</span><span class="serif">y</span></section></div>
            <div id="late-host"></div>
            <script>
              const big = document.getElementById('big');
              for (let i = 0; i < 200; i++) { const p = document.createElement('p'); p.textContent = 'row ' + i; big.append(p); }
            </script>
            """
        let probe = """
            const first = (element) => getComputedStyle(element).fontFamily.split(',')[0].replace(/"/g, '').trim();
            const settle = () => new Promise((resolve) => setTimeout(resolve, 400));
            const big = document.getElementById('big');
            const row = big.querySelector('p');
            const fonts = {};
            await settle();
            big.className = 'mono';
            await settle();
            fonts.monoRow = first(row);
            big.className = '';
            await settle();
            fonts.plainRow = first(row);
            const nested = big.querySelector('.icon');
            const serif = big.querySelector('.serif');
            big.className = 'special';
            await settle();
            fonts.nestedSpecial = first(nested);
            fonts.serifSpecial = first(serif);
            big.className = '';
            await settle();
            fonts.nestedPlain = first(nested);
            fonts.serifPlain = first(serif);
            const icon = document.createElement('i');
            big.append(icon);
            await settle();
            icon.className = 'fa';
            await settle();
            fonts.icon = first(icon);
            const host = document.getElementById('late-host');
            host.attachShadow({ mode: 'open' }).innerHTML = '<p>shadow</p>';
            dispatchEvent(new Event('load'));
            await settle();
            fonts.lateShadow = first(host.shadowRoot.querySelector('p'));
            return fonts;
            """
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(PageStyle.fontScript)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let loaded = PageLoad()
        webView.navigationDelegate = loaded
        webView.loadHTMLString(page, baseURL: URL(string: "https://example.com/")!)
        try await loaded.wait()

        let fonts = try #require(try await webView.callAsyncJavaScript(probe, contentWorld: .page) as? [String: String])
        #expect(fonts["monoRow"] == "Menlo")
        #expect(fonts["plainRow"] == "Lithium DM Sans")
        #expect(fonts["nestedSpecial"] == "Menlo")
        #expect(fonts["nestedPlain"] == "Lithium DM Sans")
        #expect(fonts["serifSpecial"] == "Menlo")
        #expect(fonts["serifPlain"] == "Lithium DM Sans")
        #expect(fonts["icon"] == "Font Awesome 6 Free")
        #expect(fonts["lateShadow"] == "Lithium DM Sans")
    }

    /// A large container toggling its class many times a second (a carousel, a player) has its
    /// font rules looked up when the changes are checked, not at each change.
    @Test func largeContainerClassChangesWaitForTheCheck() async throws {
        let page = """
            <style>.special .icon { font-family: Menlo, monospace; }</style>
            <div id="big"><span class="icon">x</span></div>
            <script>
              const big = document.getElementById('big');
              for (let i = 0; i < 200; i++) { const p = document.createElement('p'); p.textContent = 'row ' + i; big.append(p); }
            </script>
            """
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(PageStyle.fontScript)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let loaded = PageLoad()
        webView.navigationDelegate = loaded
        webView.loadHTMLString(page, baseURL: URL(string: "https://example.com/")!)
        try await loaded.wait()
        // The font script's world counts its lookups of the rule.
        _ = try await webView.callAsyncJavaScript("""
            window.lookups = 0;
            const all = Element.prototype.querySelectorAll;
            Element.prototype.querySelectorAll = function (selector) {
              if (String(selector).includes('.special')) window.lookups++;
              return all.call(this, selector);
            };
            """, contentWorld: .defaultClient)

        let probe = """
            const big = document.getElementById('big');
            const first = (element) => getComputedStyle(element).fontFamily.split(',')[0].replace(/"/g, '').trim();
            await new Promise((resolve) => setTimeout(resolve, 400));
            // Each change reaches the observer on its own, before the next.
            for (let i = 0; i < 60; i++) {
              big.classList.toggle('special');
              await Promise.resolve();
            }
            big.classList.add('special');
            await new Promise((resolve) => setTimeout(resolve, 700));
            return first(big.querySelector('.icon'));
            """
        let font = try await webView.callAsyncJavaScript(probe, contentWorld: .page) as? String
        #expect(font == "Menlo", "the change still reaches the element")
        let lookups = try await webView.callAsyncJavaScript("return lookups", contentWorld: .defaultClient) as? Int
        #expect((lookups ?? .max) < 20, "looked up \(lookups ?? -1) times for 61 changes")
    }

    /// A sheet added later (CSS-in-JS, a lazy chunk) has only what its font rules select checked
    /// again, not every element of the page; those still take the font it names.
    @Test func anAddedSheetChecksOnlyWhatItsFontRulesSelect() async throws {
        let page = """
            <div id="rows"></div><i id="icon" class="glyph"></i>
            <script>
              const rows = document.getElementById('rows');
              for (let i = 0; i < 300; i++) { const p = document.createElement('p'); p.textContent = 'row ' + i; rows.append(p); }
            </script>
            """
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(PageStyle.fontScript)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let loaded = PageLoad()
        webView.navigationDelegate = loaded
        webView.loadHTMLString(page, baseURL: URL(string: "https://example.com/")!)
        try await loaded.wait()
        // The font script's world counts the elements it reads the style of.
        _ = try await webView.callAsyncJavaScript("""
            window.reads = 0;
            const read = window.getComputedStyle;
            window.getComputedStyle = function (...args) { window.reads++; return read.apply(this, args); };
            """, contentWorld: .defaultClient)

        let probe = """
            const first = (element) => getComputedStyle(element).fontFamily.split(',')[0].replace(/"/g, '').trim();
            const settle = () => new Promise((resolve) => setTimeout(resolve, 400));
            await settle();
            const plain = document.createElement('style');
            plain.textContent = '#rows p { color: #333; }';
            document.head.append(plain);
            await settle();
            const icons = document.createElement('style');
            icons.textContent = '.glyph { font-family: "Font Awesome 6 Free"; }';
            document.head.append(icons);
            await settle();
            return { icon: first(document.getElementById('icon')), row: first(document.querySelector('#rows p')) };
            """
        _ = try await webView.callAsyncJavaScript("await new Promise((resolve) => setTimeout(resolve, 400)); window.reads = 0", contentWorld: .defaultClient)
        let fonts = try #require(try await webView.callAsyncJavaScript(probe, contentWorld: .page) as? [String: String])
        #expect(fonts["icon"] == "Font Awesome 6 Free")
        #expect(fonts["row"] == "Lithium DM Sans")
        let reads = try await webView.callAsyncJavaScript("return reads", contentWorld: .defaultClient) as? Int
        #expect((reads ?? .max) < 20, "read the style of \(reads ?? -1) elements for two sheets")
    }

    /// An icon sheet from another origin (a CDN without CORS) can't be read: its icons still keep
    /// their font right after it loads, not after a delayed recheck.
    @Test func anUnreadableSheetKeepsItsIconsAtOnce() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(IconSheet(), forURLScheme: "lithium-test")
        configuration.userContentController.addUserScript(PageStyle.fontScript)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let loaded = PageLoad()
        webView.navigationDelegate = loaded
        webView.loadHTMLString(#"<p id="text">Hello</p><i id="icon" class="glyph"></i>"#, baseURL: URL(string: "lithium-test://example.com/")!)
        try await loaded.wait()

        let probe = """
            const first = (element) => getComputedStyle(element).fontFamily.split(',')[0].replace(/"/g, '').trim();
            await new Promise((resolve) => setTimeout(resolve, 300));
            const link = document.createElement('link');
            link.rel = 'stylesheet';
            link.href = 'lithium-test://cdn.example.net/icons.css';
            await new Promise((resolve, reject) => { link.onload = resolve; link.onerror = reject; document.head.append(link); });
            let readable = true;
            try { link.sheet.cssRules; } catch (_) { readable = false; }
            await new Promise((resolve) => setTimeout(resolve, 200));
            return { readable, icon: first(document.getElementById('icon')), text: first(document.getElementById('text')) };
            """
        let result = try #require(try await webView.callAsyncJavaScript(probe, contentWorld: .page) as? [String: Any])
        #expect(result["readable"] as? Bool == false)
        #expect(result["icon"] as? String == "Font Awesome 6 Free")
        #expect(result["text"] as? String == "Lithium DM Sans")
    }

    /// A font the user picked from the Mac's: named, not shipped, and icons and code keep theirs.
    @Test func pickedFontReplacesTextFontsButNotIconsCodeOrMath() async throws {
        let script = PageStyle.fontScript(family: "Helvetica Neue")
        #expect(script.source.count < PageStyle.fontScript(family: "DM Sans").source.count, "no DM Sans bytes")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(script)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let loaded = PageLoad()
        webView.navigationDelegate = loaded
        webView.loadHTMLString(Self.page, baseURL: URL(string: "https://example.com/")!)
        try await loaded.wait()

        let fonts = try #require(try await webView.callAsyncJavaScript(Self.probe, contentWorld: .page) as? [String: String])
        #expect(fonts["loaded"] == "no")
        #expect(fonts["text"] == "Helvetica Neue")
        #expect(fonts["important"] == "Helvetica Neue")
        #expect(fonts["shadowText"] == "Helvetica Neue")
        #expect(fonts["fa"] == "Font Awesome 6 Free")
        #expect(fonts["material"] == "Material Symbols Outlined")
        #expect(fonts["code"] == "Menlo")
    }

    /// Settings changes the font of an open page, turns it off and on again, without a reload.
    /// While off, the page's changes are left alone.
    @Test func openPageChangesFontWithoutReload() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(PageStyle.fontScript(family: "DM Sans"))
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let loaded = PageLoad()
        webView.navigationDelegate = loaded
        webView.loadHTMLString(Self.page, baseURL: URL(string: "https://example.com/")!)
        try await loaded.wait()
        _ = try await webView.callAsyncJavaScript("window.marked = true", contentWorld: .page)

        let run = { (source: String) async in _ = try? await webView.evaluateJavaScript(source, in: nil, contentWorld: .defaultClient) }
        let font = { (id: String) async throws -> String? in
            try await webView.callAsyncJavaScript("""
                await new Promise((resolve) => setTimeout(resolve, 300));
                return getComputedStyle(document.getElementById(id)).fontFamily.split(',')[0].replace(/"/g, '').trim();
                """, arguments: ["id": id], contentWorld: .page) as? String
        }
        #expect(try await font("text") == "Lithium DM Sans")

        await run(PageStyle.fontScript(family: "Helvetica Neue").source)
        #expect(try await font("text") == "Helvetica Neue")
        #expect(try await font("fa") == "Font Awesome 6 Free")

        await run(PageStyle.fontOffSource)
        #expect(try await font("text") != "Helvetica Neue")
        _ = try await webView.callAsyncJavaScript("""
            const late = document.createElement('i');
            late.id = 'late';
            late.className = 'fa fa-user';
            document.body.append(late);
            """, contentWorld: .page)
        #expect(try await font("late") == "Font Awesome 6 Free")
        let checked = try await webView.callAsyncJavaScript("return document.getElementById('late').hasAttribute('data-lithium-font-keep')", contentWorld: .page) as? Bool
        #expect(checked == false, "nothing watched while off")

        await run(PageStyle.fontScript(family: "DM Sans").source)
        #expect(try await font("text") == "Lithium DM Sans")
        #expect(try await font("late") == "Font Awesome 6 Free")
        #expect(try await webView.callAsyncJavaScript("return window.marked === true", contentWorld: .page) as? Bool == true)
    }
}

/// Serves an icon sheet under a custom scheme without CORS headers, so a page on another host
/// can't read its rules.
@MainActor
private final class IconSheet: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let url = task.request.url!
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/css"])!)
        task.didReceive(Data(#".glyph { font-family: "Font Awesome 6 Free"; }"#.utf8))
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

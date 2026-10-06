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
}

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
        let loaded = Loaded()
        webView.navigationDelegate = loaded
        webView.loadHTMLString(Self.page, baseURL: URL(string: "https://example.com/")!)
        await loaded.wait()

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
}

@MainActor
private final class Loaded: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var done = false
    func wait() async { if !done { await withCheckedContinuation { continuation = $0 } } }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true; continuation?.resume() }
}

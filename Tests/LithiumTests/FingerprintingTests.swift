import CryptoKit
import Foundation
import Testing
import WebKit
@testable import Lithium

@MainActor
struct FingerprintingTests {
    private static let probe = """
        (() => {
          const hash = (win) => {
            const c = win.document.createElement('canvas'); c.width = 200; c.height = 40;
            const x = c.getContext('2d'); x.font = '18px Arial'; x.fillStyle = '#f60'; x.fillRect(0, 0, 200, 40);
            x.fillStyle = '#069'; x.fillText('Lithium fp', 4, 26);
            let h = 0; const d = c.toDataURL(); for (let i = 0; i < d.length; i++) h = (Math.imul(h, 31) + d.charCodeAt(i)) | 0;
            return (h >>> 0).toString(16);
          };
          const frame = document.createElement('iframe');
          document.body.appendChild(frame);
          return JSON.stringify({ page: hash(window), frame: hash(frame.contentWindow),
            native: /\\[native code\\]/.test(frame.contentWindow.HTMLCanvasElement.prototype.toDataURL.toString()) });
        })()
        """

    /// A frame that is still navigating to its srcdoc shows a blank window WebKit injects nothing into;
    /// only the insertion hooks protect it when the page reaches it through `frames`.
    private static let srcdocProbe = """
        (() => {
          const hash = (win) => {
            const c = win.document.createElement('canvas'); c.width = 200; c.height = 40;
            const x = c.getContext('2d'); x.fillStyle = '#f60'; x.fillRect(0, 0, 200, 40);
            let h = 0; const d = c.toDataURL(); for (let i = 0; i < d.length; i++) h = (Math.imul(h, 31) + d.charCodeAt(i)) | 0;
            return (h >>> 0).toString(16);
          };
          const frame = document.createElement('iframe');
          frame.srcdoc = '<p>frame</p>';
          document.body.appendChild(frame);
          return JSON.stringify({ page: hash(window), frame: hash(frames[frames.length - 1]) });
        })()
        """

    /// A popup the page opens is a blank window of its site until its first page loads, and
    /// WebKit injects nothing into it; the opener reaches it at once.
    private static let popupProbe = """
        (() => {
          const hash = (win) => {
            const c = win.document.createElement('canvas'); c.width = 200; c.height = 40;
            const x = c.getContext('2d'); x.fillStyle = '#f60'; x.fillRect(0, 0, 200, 40);
            let h = 0; const d = c.toDataURL(); for (let i = 0; i < d.length; i++) h = (Math.imul(h, 31) + d.charCodeAt(i)) | 0;
            return (h >>> 0).toString(16);
          };
          return JSON.stringify({ page: hash(window), popup: hash(open('')) });
        })()
        """

    /// The names the page's window has of its own.
    private static let namesProbe = "JSON.stringify([...Object.getOwnPropertyNames(window), ...Object.getOwnPropertySymbols(window).map(String)])"

    private static func farbling(key: String = "test-key", site: String = "example.com") throws -> String {
        let url = try #require(Resources.bundle.url(forResource: "farbling", withExtension: "js"))
        return Privacy.farbling(try String(contentsOf: url, encoding: .utf8), key: SymmetricKey(data: Data(key.utf8)), site: site)
    }

    /// A page's canvas hash under `source`.
    private func canvasHash(_ source: String, at base: String = "https://example.com/") async throws -> AnyHashable? {
        let result: [String: AnyHashable] = try await run(Self.probe, farbling: source, at: base)
        return result["page"]
    }

    private func run(withFarbling: Bool, probe: String = Self.probe) async throws -> [String: AnyHashable] {
        let source = withFarbling ? try Self.farbling() : nil
        return try await run(probe, farbling: source)
    }

    /// `before` runs ahead of the script; `awaiting` runs the probe as an async function body,
    /// for what the page only gets later.
    /// `headers` serves the page with them, from a custom scheme, instead of loading the markup.
    private func run<Value>(_ probe: String, farbling source: String?, at base: String = "https://example.com/", html: String = "<body></body>", headers: [String: String]? = nil, before: String? = nil, awaiting: Bool = false) async throws -> Value {
        let configuration = WKWebViewConfiguration()
        let served = headers.map { ServedPage(html: html, headers: $0) }
        if let served { configuration.setURLSchemeHandler(served, forURLScheme: ServedPage.scheme) }
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        if let before {
            configuration.userContentController.addUserScript(WKUserScript(source: before, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        if let source {
            configuration.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
            // Added after it, as Tab does on the response.
            if let headers, let response = HTTPURLResponse(url: URL(string: "\(ServedPage.scheme)://example.com/")!, statusCode: 200, httpVersion: nil, headerFields: headers),
               let flag = Privacy.trustedTypesScript(for: response, key: SymmetricKey(data: Data("test-key".utf8))) {
                configuration.userContentController.addUserScript(WKUserScript(source: flag, injectionTime: .atDocumentStart, forMainFrameOnly: false))
            }
        }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let loaded = PageLoad()
        let popups = Popups()
        webView.navigationDelegate = loaded
        webView.uiDelegate = popups
        if served != nil {
            webView.load(URLRequest(url: URL(string: "\(ServedPage.scheme)://example.com/")!))
        } else {
            webView.loadHTMLString(html, baseURL: URL(string: base)!)
        }
        try await loaded.wait()
        let result: Any? = awaiting
            ? try await webView.callAsyncJavaScript(probe, contentWorld: .page)
            : try await webView.evaluateJavaScript(probe) as Any?
        let json = try #require(result as? String)
        return try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? Value)
    }

    /// Serves one page with the given response headers.
    @MainActor
    private final class ServedPage: NSObject, WKURLSchemeHandler {
        static let scheme = "lithium-test"
        let html: String
        let headers: [String: String]

        init(html: String, headers: [String: String]) {
            self.html = html
            self.headers = headers
        }

        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            let url = task.request.url!
            task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers.merging(["Content-Type": "text/html"]) { $1 })!)
            task.didReceive(Data(html.utf8))
            task.didFinish()
        }

        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
    }

    /// Opens popups as Lithium does (`Privacy.harden`): with a content controller of their own,
    /// which has no scripts until their first page.
    @MainActor
    private final class Popups: NSObject, WKUIDelegate {
        private var opened: [WKWebView] = []

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            configuration.userContentController = WKUserContentController()
            let popup = WKWebView(frame: .zero, configuration: configuration)
            opened.append(popup)
            return popup
        }
    }

    /// A protected window carries no marker a page could list: the window property it once had
    /// said "Lithium" on every site.
    @Test func windowCarriesNoMarker() async throws {
        let bare: [String] = try await run(Self.namesProbe, farbling: nil)
        let protected: [String] = try await run(Self.namesProbe, farbling: Self.farbling())
        #expect(protected == bare)
    }

    /// The seed is an HMAC of the registrable site under the launch's key: a page that recovers
    /// its own can't run it back to the key, and the subdomains of a public suffix such as
    /// github.io, or two IP addresses, are sites of their own.
    @Test func seedIsAKeyedHashOfTheRegistrableSite() throws {
        let site = { (address: String) in Privacy.farblingSite(URL(string: address)!) }
        #expect(site("https://alice.github.io/") == "alice.github.io")
        #expect(site("https://www.example.co.uk/a") == "example.co.uk")
        #expect(site("https://shop.example.co.uk/") == "example.co.uk")
        #expect(site("http://10.0.0.1/") == "10.0.0.1")
        #expect(site("http://192.168.0.1:8080/") == "192.168.0.1")
        #expect(site("http://[::1]/") == "::1")

        let key = SymmetricKey(size: .bits256)
        let template = "'__LITHIUM_SEED__' '__LITHIUM_MARK__'"
        let source = Privacy.farbling(template, key: key, site: "alice.github.io")
        let hmac = HMAC<SHA256>.authenticationCode(for: Data("seed:alice.github.io".utf8), using: key)
        let seed = hmac.prefix(16).map { String(format: "%02x", $0) }.joined()
        #expect(source.hasPrefix("'\(seed)' 'm"))
        #expect(!source.contains("__LITHIUM_"))
        #expect(Privacy.farbling(template, key: key, site: "bob.github.io") != source)
        #expect(Privacy.farbling(template, key: key, site: "10.0.0.1") != Privacy.farbling(template, key: key, site: "192.168.0.1"))

        let privacy = Privacy()
        let script = { (address: String) in privacy.scripts(true, for: URL(string: address)!).first?.source }
        #expect(script("https://alice.github.io/") != script("https://bob.github.io/"))
        #expect(script("https://www.example.co.uk/") == script("https://shop.example.co.uk/"))
    }

    /// Private tabs farble with keys of their own: the same site's canvas reads differently there.
    @Test func privateTabsGetTheirOwnKeys() async throws {
        let privacy = Privacy()
        let url = URL(string: "https://news.example/")!
        let normal = try #require(privacy.scripts(true, for: url).first?.source)
        let ephemeral = try #require(privacy.scripts(true, for: url, isPrivate: true).first?.source)
        #expect(!normal.contains("__LITHIUM_") && !ephemeral.contains("__LITHIUM_"))
        #expect(normal != ephemeral)
        #expect(try await canvasHash(normal, at: url.absoluteString) != canvasHash(ephemeral, at: url.absoluteString))
    }

    /// Built-ins the page replaced before adding a frame don't keep the frame unprotected: a
    /// `call` that always answers true once made it look protected already. Nor do they strip the
    /// page's own noise (a `Math.floor` returning a huge gap once skipped every pixel, a canvas
    /// `width` reading 0 or an empty `putImageData` once handed back the clean canvas).
    @Test func replacedBuiltInsDontUnprotectAFrame() async throws {
        let tamper = """
            Object.defineProperty(HTMLCanvasElement.prototype, 'width', { get: () => 0 });
            CanvasRenderingContext2D.prototype.putImageData = function () {};
            Function.prototype.call = function () { return true; };
            Object.defineProperty = function (target) { return target; };
            Object.getOwnPropertyDescriptor = function () { return undefined; };
            WeakMap = undefined;
            Math.floor = () => 1e9;
            """
        let bare: [String: AnyHashable] = try await run(tamper + Self.probe, farbling: nil)
        let protected: [String: AnyHashable] = try await run(tamper + Self.probe, farbling: Self.farbling())

        #expect(protected["page"] != bare["page"])
        #expect(protected["frame"] == protected["page"])
    }

    /// Image and array members the page redefines don't skip the noise of `getImageData` or of
    /// audio either (an `ImageData` width past the limit, a `length` past the sample limit).
    @Test func replacedImageAndArrayMembersDontSkipTheNoise() async throws {
        let probe = """
            (() => {
              Object.defineProperty(ImageData.prototype, 'width', { get: () => 1e9 });
              Object.defineProperty(Object.getPrototypeOf(Float32Array.prototype), 'length', { get: () => 1e9 });
              const c = document.createElement('canvas'); c.width = 20; c.height = 20;
              const x = c.getContext('2d'); x.fillStyle = '#f60'; x.fillRect(0, 0, 20, 20);
              const data = x.getImageData(0, 0, 20, 20).data;
              let pixels = 0; for (let i = 0; i < 1600; i++) pixels += data[i];
              const samples = new AudioBuffer({ length: 4096, sampleRate: 44100 }).getChannelData(0);
              let audio = 0; for (let i = 0; i < 4096; i++) audio += Math.abs(samples[i]);
              return JSON.stringify({ pixels, audio: audio > 0 });
            })()
            """
        let bare: [String: AnyHashable] = try await run(probe, farbling: nil)
        let protected: [String: AnyHashable] = try await run(probe, farbling: Self.farbling())

        #expect(protected["pixels"] != bare["pixels"])
        #expect(bare["audio"] == AnyHashable(false))
        #expect(protected["audio"] == AnyHashable(true))
    }

    /// The voice filter reads only what it saved at load: a page that replaces `Array` `filter`,
    /// a voice's `default`, the navigator's `language` or `startsWith` still gets the same few voices.
    @Test func replacedBuiltInsDontRevealEveryVoice() async throws {
        // WebKit lists the voices once they've loaded, after the first call.
        let probe = """
            if (!speechSynthesis.getVoices().length) {
              await new Promise((done) => { speechSynthesis.onvoiceschanged = done; setTimeout(done, 3000); });
            }
            const before = speechSynthesis.getVoices().length;
            Array.prototype.filter = function () { return this.slice(); };
            Object.defineProperty(SpeechSynthesisVoice.prototype, 'default', { get: () => true });
            Object.defineProperty(Navigator.prototype, 'language', { get: () => '' });
            String.prototype.startsWith = () => true;
            return JSON.stringify({ before, after: speechSynthesis.getVoices().length });
            """
        // WebKit marks every voice a Mac ships as a default one, which the filter keeps; run before
        // the script, this stands for the voices a user downloads, which it hides.
        let downloaded = "Object.defineProperty(SpeechSynthesisVoice.prototype, 'default', { get: () => false });"
        let bare: [String: AnyHashable] = try await run(probe, farbling: nil, awaiting: true)
        let protected: [String: AnyHashable] = try await run(probe, farbling: Self.farbling(), before: downloaded, awaiting: true)

        let installed = try #require(bare["before"] as? Int)
        let shown = try #require(protected["before"] as? Int)
        #expect(shown < installed, "\(shown) of \(installed) voices shown")
        #expect(protected["after"] as? Int == shown)
    }

    /// WebGL2 integer reads into an `Int8Array` get the same noise as byte reads.
    @Test func signedByteReadPixelsGetsNoise() async throws {
        let probe = """
            (() => {
              const gl = document.createElement('canvas').getContext('webgl2');
              const buffer = gl.createRenderbuffer(); gl.bindRenderbuffer(gl.RENDERBUFFER, buffer);
              gl.renderbufferStorage(gl.RENDERBUFFER, gl.RGBA8I, 64, 64);
              gl.bindFramebuffer(gl.FRAMEBUFFER, gl.createFramebuffer());
              gl.framebufferRenderbuffer(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.RENDERBUFFER, buffer);
              gl.clearBufferiv(gl.COLOR, 0, new Int32Array([2, 4, 6, 8]));
              const pixels = new Int8Array(64 * 64 * 4);
              gl.readPixels(0, 0, 64, 64, gl.RGBA_INTEGER, gl.BYTE, pixels);
              let sum = 0; for (let i = 0; i < pixels.length; i++) sum += pixels[i];
              return JSON.stringify({ error: gl.getError(), sum });
            })()
            """
        let bare: [String: AnyHashable] = try await run(probe, farbling: nil)
        let protected: [String: AnyHashable] = try await run(probe, farbling: Self.farbling())

        #expect(bare["error"] == AnyHashable(0))
        #expect(bare["sum"] == AnyHashable(64 * 64 * 20))
        #expect(try #require(protected["sum"] as? Int) > 64 * 64 * 20)
    }

    @Test func popupIsProtectedBeforeItsFirstPage() async throws {
        let bare: [String: AnyHashable] = try await run(Self.popupProbe, farbling: nil)
        let protected: [String: AnyHashable] = try await run(Self.popupProbe, farbling: Self.farbling())

        #expect(bare["page"] == bare["popup"])
        #expect(protected["page"] != bare["page"])
        #expect(protected["popup"] == protected["page"])
    }

    @Test func freshIframeCannotHandBackUnprotectedCanvas() async throws {
        let bare = try await run(withFarbling: false)
        let protected = try await run(withFarbling: true)

        #expect(bare["page"] == bare["frame"])
        #expect(protected["page"] != bare["page"])
        #expect(protected["frame"] == protected["page"])
        #expect(protected["native"] == AnyHashable(true))
    }

    @Test func frameStillNavigatingToItsSrcdocIsProtected() async throws {
        let bare = try await run(withFarbling: false, probe: Self.srcdocProbe)
        let protected = try await run(withFarbling: true, probe: Self.srcdocProbe)

        #expect(bare["page"] == bare["frame"])
        #expect(protected["page"] != bare["page"])
        #expect(protected["frame"] == protected["page"])
    }

    /// Frames made from markup, from a fragment, or by an insertion method other than the
    /// classic three are protected by the time the page reaches them through `frames`.
    @Test func framesFromMarkupAndFragmentsAreProtected() async throws {
        let probe = """
            (() => {
              const hash = (win) => {
                const c = win.document.createElement('canvas'); c.width = 200; c.height = 40;
                const x = c.getContext('2d'); x.fillStyle = '#f60'; x.fillRect(0, 0, 200, 40);
                let h = 0; const d = c.toDataURL(); for (let i = 0; i < d.length; i++) h = (Math.imul(h, 31) + d.charCodeAt(i)) | 0;
                return (h >>> 0).toString(16);
              };
              const last = () => hash(frames[frames.length - 1]);
              const box = () => document.body.appendChild(document.createElement('div'));
              const iframe = () => document.createElement('iframe');
              const fragment = () => { const f = document.createDocumentFragment(); f.appendChild(iframe()); return f; };
              const routes = { page: hash(window) };
              box().insertAdjacentHTML('beforeend', '<iframe></iframe>'); routes.insertAdjacentHTML = last();
              box().innerHTML = '<IFRAME></IFRAME>'; routes.innerHTML = last();
              box().appendChild(document.createElement('p')).outerHTML = '<iframe></iframe>'; routes.outerHTML = last();
              box().appendChild(fragment()); routes.appendChildFragment = last();
              box().append(fragment()); routes.appendFragment = last();
              const template = document.createElement('template'); template.innerHTML = '<iframe></iframe>';
              box().appendChild(template.content); routes.template = last();
              box().replaceChildren(iframe()); routes.replaceChildren = last();
              box().insertAdjacentElement('beforeend', iframe()); routes.insertAdjacentElement = last();
              const range = document.createRange(); range.selectNodeContents(box()); range.insertNode(iframe()); routes.insertNode = last();
              if (Element.prototype.setHTMLUnsafe) { box().setHTMLUnsafe('<iframe></iframe>'); routes.setHTMLUnsafe = last(); }
              const host = box().appendChild(iframe());
              host.contentDocument.write('<iframe></iframe>'); routes.write = hash(host.contentWindow.frames[0]);
              return JSON.stringify(routes);
            })()
            """
        let bare: [String: AnyHashable] = try await run(probe, farbling: nil)
        let protected: [String: AnyHashable] = try await run(probe, farbling: Self.farbling())

        #expect(bare.count >= 11)
        #expect(Set(bare.values).count == 1, "\(bare)")
        #expect(protected["page"] != bare["page"])
        for (route, value) in protected {
            #expect(value == protected["page"], "\(route)")
        }
    }

    /// Any realm's `toString` sees through the replacements of every other: of a frame the hooks
    /// protected, and of one WebKit's injection protected with a copy of the script of its own.
    /// A blank frame that keeps its realm when its page loads gets the noise once, not twice.
    @Test func toStringHoldsAcrossRealms() async throws {
        let probe = """
            const hash = (win) => {
              const c = win.document.createElement('canvas'); c.width = 200; c.height = 40;
              const x = c.getContext('2d'); x.fillStyle = '#f60'; x.fillRect(0, 0, 200, 40);
              let h = 0; const d = c.toDataURL(); for (let i = 0; i < d.length; i++) h = (Math.imul(h, 31) + d.charCodeAt(i)) | 0;
              return (h >>> 0).toString(16);
            };
            const native = (fn, toString) => /\\[native code\\]/.test(toString.call(fn));
            const disguised = (child) => native(child.HTMLCanvasElement.prototype.toDataURL, Function.prototype.toString)
              && native(HTMLCanvasElement.prototype.toDataURL, child.Function.prototype.toString)
              && native(child.Function.prototype.toString, Function.prototype.toString);
            const blank = document.body.appendChild(document.createElement('iframe')).contentWindow;
            const reused = document.createElement('iframe');
            reused.srcdoc = '<p>frame</p>';
            document.body.appendChild(reused);
            await new Promise((done) => { reused.onload = done; setTimeout(done, 3000); });
            return JSON.stringify({ page: hash(window), loaded: hash(frames[0]), reused: hash(reused.contentWindow),
              blank: disguised(blank), loadedDisguised: disguised(frames[0]), reusedDisguised: disguised(reused.contentWindow) });
            """
        let html = "<body><iframe srcdoc=\"<p>frame</p>\"></iframe></body>"
        let bare: [String: AnyHashable] = try await run(probe, farbling: nil, html: html, awaiting: true)
        let protected: [String: AnyHashable] = try await run(probe, farbling: Self.farbling(), html: html, awaiting: true)

        #expect(protected["page"] != bare["page"])
        #expect(protected["loaded"] == protected["page"])
        #expect(protected["reused"] == protected["page"])
        #expect(protected["blank"] == AnyHashable(true))
        #expect(protected["loadedDisguised"] == AnyHashable(true))
        #expect(protected["reusedDisguised"] == AnyHashable(true))
    }

    /// Pixel noise moves values up or down, so clearing each byte's lowest bit doesn't remove it,
    /// and where it lands follows the image: a blank canvas doesn't show where it goes in another.
    @Test func pixelNoiseSurvivesClearingTheLowBit() async throws {
        let probe = """
            (() => {
              const read = (draw) => {
                const c = document.createElement('canvas'); c.width = 200; c.height = 40;
                const x = c.getContext('2d'); draw(x);
                return x.getImageData(0, 0, 200, 40).data;
              };
              const text = read((x) => { x.font = '18px Arial'; x.fillStyle = '#f60'; x.fillRect(0, 0, 200, 40); x.fillStyle = '#069'; x.fillText('Lithium fp', 4, 26); });
              let masked = 0; for (let i = 0; i < text.length; i++) masked = (Math.imul(masked, 31) + (text[i] & 0xfe)) | 0;
              const spots = (data, clean) => { const at = []; for (let i = 0; i < data.length; i++) if (i % 4 !== 3 && data[i] !== clean) at.push(i); return at.join(); };
              const blank = spots(read(() => {}), 0);
              const grey = spots(read((x) => { x.fillStyle = '#808080'; x.fillRect(0, 0, 200, 40); }), 128);
              return JSON.stringify({ masked, blank, grey });
            })()
            """
        let bare: [String: AnyHashable] = try await run(probe, farbling: nil)
        let protected: [String: AnyHashable] = try await run(probe, farbling: Self.farbling())

        #expect(bare["blank"] == AnyHashable("") && bare["grey"] == AnyHashable(""))
        #expect(protected["masked"] != bare["masked"])
        #expect(protected["blank"] != AnyHashable(""))
        #expect(protected["grey"] != AnyHashable(""))
        #expect(protected["blank"] != protected["grey"])
    }

    /// Pixels the page reads back after writing them (an editor's fill, a filter, an undo step)
    /// aren't noised again: fresh noise each round trip once drifted a flat canvas into grain.
    @Test func pixelNoiseDoesntBuildUpOverRoundTrips() async throws {
        let probe = """
            (() => {
              const c = document.createElement('canvas'); c.width = 200; c.height = 40;
              const x = c.getContext('2d'); x.fillStyle = '#808080'; x.fillRect(0, 0, 200, 40);
              const first = x.getImageData(0, 0, 200, 40).data;
              let image = x.getImageData(0, 0, 200, 40);
              for (let i = 0; i < 100; i++) { x.putImageData(image, 0, 0); image = x.getImageData(0, 0, 200, 40); }
              let noisy = 0, changed = 0, spread = 0;
              for (let i = 0; i < first.length; i++) {
                if (first[i] !== (i % 4 === 3 ? 255 : 128)) noisy++;
                if (image.data[i] !== first[i]) changed++;
                spread = Math.max(spread, Math.abs(image.data[i] - (i % 4 === 3 ? 255 : 128)));
              }
              return JSON.stringify({ noisy, changed, spread });
            })()
            """
        let protected: [String: AnyHashable] = try await run(probe, farbling: Self.farbling())

        #expect(try #require(protected["noisy"] as? Int) > 0)
        #expect(protected["changed"] == AnyHashable(0))
        #expect(protected["spread"] == AnyHashable(1))
    }

    /// A paint app that reads the whole canvas, paints a dab and puts it back each time leaves
    /// the rest of the image as it first read it: white doesn't drift grey, nothing turns to grain.
    @Test func pixelNoiseDoesntBuildUpWhenThePageEditsBetweenReads() async throws {
        let probe = """
            (() => {
              const c = document.createElement('canvas'); c.width = 200; c.height = 40;
              const x = c.getContext('2d'); x.fillStyle = '#fff'; x.fillRect(0, 0, 200, 40);
              const first = x.getImageData(0, 0, 200, 40).data;
              let image = x.getImageData(0, 0, 200, 40);
              x.fillStyle = '#f00';
              for (let i = 0; i < 200; i++) {
                x.putImageData(image, 0, 0);
                x.fillRect(i, 0, 1, 1);
                image = x.getImageData(0, 0, 200, 40);
              }
              // Row 0 holds the dabs; the rest was never painted.
              let noisy = 0, changed = 0, spread = 0;
              for (let i = 200 * 4; i < first.length; i++) {
                if (first[i] !== 255) noisy++;
                if (image.data[i] !== first[i]) changed++;
                spread = Math.max(spread, 255 - image.data[i]);
              }
              return JSON.stringify({ noisy, changed, spread });
            })()
            """
        let protected: [String: AnyHashable] = try await run(probe, farbling: Self.farbling())

        #expect(try #require(protected["noisy"] as? Int) > 0)
        #expect(protected["changed"] == AnyHashable(0))
        #expect(protected["spread"] == AnyHashable(1))
    }

    /// A blank `<iframe>` in the page's own markup is protected before the next inline script can
    /// reach it through `frames`: the parser calls none of the hooks, and WebKit injects nothing there.
    @Test func blankFrameFromThePageMarkupIsProtected() async throws {
        let html = """
            <body><iframe></iframe><script>
              const hash = (win) => {
                const c = win.document.createElement('canvas'); c.width = 200; c.height = 40;
                const x = c.getContext('2d'); x.fillStyle = '#f60'; x.fillRect(0, 0, 200, 40);
                let h = 0; const d = c.toDataURL(); for (let i = 0; i < d.length; i++) h = (Math.imul(h, 31) + d.charCodeAt(i)) | 0;
                return (h >>> 0).toString(16);
              };
              window.result = JSON.stringify({ page: hash(window), frame: hash(frames[0]),
                native: /\\[native code\\]/.test(Function.prototype.toString.call(frames[0].HTMLCanvasElement.prototype.toDataURL)) });
            </script></body>
            """
        let bare: [String: AnyHashable] = try await run("window.result", farbling: nil, html: html)
        let protected: [String: AnyHashable] = try await run("window.result", farbling: Self.farbling(), html: html)

        #expect(bare["page"] == bare["frame"])
        #expect(protected["page"] != bare["page"])
        #expect(protected["frame"] == protected["page"])
        #expect(protected["native"] == AnyHashable(true))
    }

    /// A blank frame fires `load` while it is inserted, before the observer or the insertion hooks
    /// get to it: a handler there, in the markup or added by a script, finds it already protected.
    @Test func blankFrameIsProtectedInItsOwnLoadEvent() async throws {
        let html = """
            <body><iframe onload="window.fromMarkup = frames[0].HTMLCanvasElement.prototype.toDataURL"></iframe><script>
              document.addEventListener('load', (event) => {
                if (event.target.localName === 'iframe' && !window.fromScript) window.fromScript = frames[frames.length - 1].HTMLCanvasElement.prototype.toDataURL;
              }, true);
              document.body.appendChild(document.createElement('iframe'));
            </script></body>
            """
        let probe = """
            (() => {
              const c = document.createElement('canvas'); c.width = 200; c.height = 40;
              const x = c.getContext('2d'); x.fillStyle = '#f60'; x.fillRect(0, 0, 200, 40);
              const hash = (d) => { let h = 0; for (let i = 0; i < d.length; i++) h = (Math.imul(h, 31) + d.charCodeAt(i)) | 0; return (h >>> 0).toString(16); };
              const through = (toDataURL) => toDataURL ? hash(toDataURL.call(c)) : 'missing';
              return JSON.stringify({ page: hash(c.toDataURL()), markup: through(window.fromMarkup), script: through(window.fromScript) });
            })()
            """
        let bare: [String: AnyHashable] = try await run(probe, farbling: nil, html: html)
        let protected: [String: AnyHashable] = try await run(probe, farbling: Self.farbling(), html: html)

        #expect(bare["markup"] == bare["page"])
        #expect(bare["script"] == bare["page"])
        #expect(protected["page"] != bare["page"])
        #expect(protected["markup"] == protected["page"])
        #expect(protected["script"] == protected["page"])
    }

    /// Writing to a loaded document opens it inside the native call, which used to drop the `load`
    /// listener: a blank frame in the written markup was reached clean from its own `load` event
    /// or a script written after it.
    @Test func blankFrameWrittenIntoALoadedDocumentIsProtected() async throws {
        let html = """
            <body><script>
              const written = document.body.appendChild(document.createElement('iframe')).contentDocument;
              written.write('<iframe onload="parent.fromHandler = frames[0].HTMLCanvasElement.prototype.toDataURL"></iframe>' +
                '<script>parent.fromScript = frames[0].HTMLCanvasElement.prototype.toDataURL<\\/script>');
              written.close();
            </script></body>
            """
        let probe = """
            (() => {
              const c = document.createElement('canvas'); c.width = 200; c.height = 40;
              const x = c.getContext('2d'); x.fillStyle = '#f60'; x.fillRect(0, 0, 200, 40);
              const hash = (d) => { let h = 0; for (let i = 0; i < d.length; i++) h = (Math.imul(h, 31) + d.charCodeAt(i)) | 0; return (h >>> 0).toString(16); };
              const through = (toDataURL) => toDataURL ? hash(toDataURL.call(c)) : 'missing';
              return JSON.stringify({ page: hash(c.toDataURL()), handler: through(window.fromHandler), script: through(window.fromScript) });
            })()
            """
        let bare: [String: AnyHashable] = try await run(probe, farbling: nil, html: html)
        let protected: [String: AnyHashable] = try await run(probe, farbling: Self.farbling(), html: html)

        #expect(bare["handler"] == bare["page"])
        #expect(bare["script"] == bare["page"])
        #expect(protected["page"] != bare["page"])
        #expect(protected["handler"] == protected["page"])
        #expect(protected["script"] == protected["page"])
    }

    /// A write into a document that is still loading, with no script of its own running (its parser
    /// waits on an external script), opens it too: the frames it writes are protected the same way.
    @Test func blankFrameWrittenIntoALoadingDocumentIsProtected() async throws {
        let html = """
            <body><script>
              const written = document.body.appendChild(document.createElement('iframe')).contentDocument;
              written.open();
              written.write('<script src="data:text/javascript,"><\\/script>');
              written.close();
              window.state = written.readyState;
              written.write('<iframe onload="parent.fromHandler = frames[0].HTMLCanvasElement.prototype.toDataURL"></iframe>' +
                '<script>parent.fromScript = frames[0].HTMLCanvasElement.prototype.toDataURL<\\/script>');
              written.close();
            </script></body>
            """
        let probe = """
            (() => {
              const c = document.createElement('canvas'); c.width = 200; c.height = 40;
              const x = c.getContext('2d'); x.fillStyle = '#f60'; x.fillRect(0, 0, 200, 40);
              const hash = (d) => { let h = 0; for (let i = 0; i < d.length; i++) h = (Math.imul(h, 31) + d.charCodeAt(i)) | 0; return (h >>> 0).toString(16); };
              const through = (toDataURL) => toDataURL ? hash(toDataURL.call(c)) : 'missing';
              return JSON.stringify({ state: window.state, page: hash(c.toDataURL()), handler: through(window.fromHandler), script: through(window.fromScript) });
            })()
            """
        let bare: [String: AnyHashable] = try await run(probe, farbling: nil, html: html)
        let protected: [String: AnyHashable] = try await run(probe, farbling: Self.farbling(), html: html)

        #expect(bare["state"] == AnyHashable("loading"))
        #expect(protected["state"] == AnyHashable("loading"))
        #expect(bare["handler"] == bare["page"])
        #expect(bare["script"] == bare["page"])
        #expect(protected["page"] != bare["page"])
        #expect(protected["handler"] == protected["page"])
        #expect(protected["script"] == protected["page"])
    }

    /// The browser ignores a write to a loaded document while one of its external or module scripts
    /// runs, an inline script added by an external one included; opening the document ahead of
    /// such a write would wipe the page instead.
    @Test func lateWriteFromAnExternalScriptStillLeavesThePage() async throws {
        let write = "document.write(\"<p>written</p>\")"
        let loaders = [
            "external": """
                const script = document.createElement('script');
                script.src = 'data:text/javascript,' + encodeURIComponent('\(write)');
                await new Promise((resolve) => { script.onload = script.onerror = resolve; document.body.append(script); });
                """,
            "module": """
                const script = document.createElement('script');
                script.type = 'module';
                script.text = 'try { \(write) } finally { window.ran() }';
                await new Promise((resolve) => { window.ran = resolve; document.body.append(script); });
                """,
            "inlineFromExternal": """
                window.inlineText = '\(write)';
                const script = document.createElement('script');
                script.src = 'data:text/javascript,' + encodeURIComponent('const inline = document.createElement("script"); inline.text = inlineText; document.body.append(inline)');
                await new Promise((resolve) => { script.onload = script.onerror = resolve; document.body.append(script); });
                """,
        ]
        let html = "<body><p id=\"kept\">kept</p></body>"
        for (name, loader) in loaders {
            let probe = loader + "return JSON.stringify({ kept: document.getElementById('kept') !== null, written: [...document.querySelectorAll('p')].some((p) => p.textContent === 'written') });"
            for source in [nil, try Self.farbling()] {
                let result: [String: Bool] = try await run(probe, farbling: source, html: html, awaiting: true)
                #expect(result == ["kept": true, "written": false], "\(name), farbling: \(source != nil)")
            }
        }
    }

    /// Trusted Types are checked before a write opens the document: one they reject throws and
    /// leaves the page, one a default policy lets through still replaces it. Required by the
    /// markup or by the response's header, which only Lithium tells farbling of.
    @Test func writeRejectedByTrustedTypesLeavesThePage() async throws {
        let csp = "<meta http-equiv=\"Content-Security-Policy\" content=\"require-trusted-types-for 'script'\">"
        let header = ["Content-Security-Policy": "require-trusted-types-for 'script'"]
        let pages: [String: (html: String, headers: [String: String]?, expected: [String: Bool])] = [
            "rejected": (csp + "<body><p id=\"kept\">kept</p></body>", nil, ["kept": true, "written": false, "threw": true]),
            "rejectedByHeader": ("<body><p id=\"kept\">kept</p></body>", header, ["kept": true, "written": false, "threw": true]),
            "defaultPolicy": (csp + "<body><p id=\"kept\">kept</p><script>trustedTypes.createPolicy('default', { createHTML: (s) => s })</script></body>",
                              nil, ["kept": false, "written": true, "threw": false]),
        ]
        // With a frame, which farbling opens the document ahead of.
        let probe = """
            let threw = false;
            try { document.write('<p>written</p><iframe></iframe>'); } catch (error) { threw = error instanceof TypeError; }
            return JSON.stringify({ threw, kept: document.getElementById('kept') !== null, written: [...document.querySelectorAll('p')].some((p) => p.textContent === 'written') });
            """
        for (name, page) in pages {
            for source in [nil, try Self.farbling()] {
                let result: [String: Bool] = try await run(probe, farbling: source, html: page.html, headers: page.headers, awaiting: true)
                #expect(result == page.expected, "\(name), farbling: \(source != nil)")
            }
        }
    }

    /// What farbling is told of a response's Trusted Types: only a policy requiring them for
    /// scripts counts, and an enforced one wins over one that only reports.
    @Test func trustedTypesAreReadFromTheResponsesPolicies() {
        let mode = { (headers: [String: String]) in
            Privacy.trustedTypes(of: HTTPURLResponse(url: URL(string: "https://example.com/")!, statusCode: 200, httpVersion: nil, headerFields: headers)!)
        }
        #expect(mode(["Content-Security-Policy": "default-src 'self'; Require-Trusted-Types-For 'script'"]) == "enforce")
        #expect(mode(["Content-Security-Policy-Report-Only": "img-src *, require-trusted-types-for 'script'"]) == "report")
        #expect(mode(["Content-Security-Policy": "require-trusted-types-for 'script'", "Content-Security-Policy-Report-Only": "require-trusted-types-for 'script'"]) == "enforce")
        #expect(mode(["Content-Security-Policy": "trusted-types default; script-src 'self'"]) == nil)
        #expect(mode([:]) == nil)
    }

    /// A page may make a default policy without requiring Trusted Types: the browser never calls
    /// it then, and farbling doesn't either.
    @Test func defaultPolicyWithoutTrustedTypesIsLeftAlone() async throws {
        let probe = """
            let calls = 0;
            trustedTypes.createPolicy('default', { createHTML: (s) => (calls++, '') });
            document.write('<p>written</p><iframe></iframe>');
            document.close();
            return JSON.stringify({ calls, written: [...document.querySelectorAll('p')].some((p) => p.textContent === 'written') ? 1 : 0 });
            """
        for source in [nil, try Self.farbling()] {
            let result: [String: Int] = try await run(probe, farbling: source, html: "<body></body>", awaiting: true)
            #expect(result == ["calls": 0, "written": 1], "farbling: \(source != nil)")
        }
    }

    /// A write converts each argument once, and never through TrustedHTML's `toString`: a page
    /// counting the calls tells nothing apart.
    @Test func writeConvertsItsArgumentsOnce() async throws {
        let html = """
            <body><script>
              window.calls = 0;
              const counted = { toString() { calls++; return '<p>written</p>'; } };
              document.write(counted);
              document.writeln(counted, '<p>more</p>');
            </script></body>
            """
        let probe = """
            const plain = calls;
            let trusted = 0;
            const text = TrustedHTML.prototype.toString;
            TrustedHTML.prototype.toString = function () { trusted++; return text.call(this); };
            const policy = trustedTypes.createPolicy('test', { createHTML: (s) => s });
            calls = 0;
            document.write(policy.createHTML('<p>late</p>'), counted);
            document.close();
            return JSON.stringify({ parsing: plain, loaded: calls, trusted });
            """
        for source in [nil, try Self.farbling()] {
            let result: [String: Int] = try await run(probe, farbling: source, html: html, awaiting: true)
            #expect(result == ["parsing": 2, "loaded": 1, "trusted": 0], "farbling: \(source != nil)")
        }
    }

    /// A default policy gets the sink of the write itself, and once: one that answers by sink
    /// decides as it would without farbling, and the frames of a write it allows are protected.
    /// One that refuses markup with a frame sees it twice: farbling can't tell its refusal from
    /// an empty answer, which only the browser's own call reports.
    @Test func defaultPolicyAnsweringBySinkDecidesTheWrite() async throws {
        let csp = "<meta http-equiv=\"Content-Security-Policy\" content=\"require-trusted-types-for 'script'\">"
        let policy = { (allowed: String) in
            csp + """
                <body><p id="kept">kept</p><script>
                  window.sinks = [];
                  trustedTypes.createPolicy('default', { createHTML: (s, _, sink) => { sinks.push(sink); return sink === '\(allowed)' ? s : null; } });
                </script></body>
                """
        }
        let probe = """
            let threw = false;
            try {
              document.write('<iframe onload="window.fromHandler = frames[0].HTMLCanvasElement.prototype.toDataURL"></iframe>');
              document.close();
            } catch (error) { threw = error instanceof TypeError; }
            const c = document.createElement('canvas'); c.width = 200; c.height = 40;
            const x = c.getContext('2d'); x.fillStyle = '#f60'; x.fillRect(0, 0, 200, 40);
            const hash = (d) => { let h = 0; for (let i = 0; i < d.length; i++) h = (Math.imul(h, 31) + d.charCodeAt(i)) | 0; return (h >>> 0).toString(16); };
            return JSON.stringify({
              threw, kept: document.getElementById('kept') !== null, sinks: sinks.join(),
              page: hash(c.toDataURL()), handler: window.fromHandler ? hash(window.fromHandler.call(c)) : 'missing',
            });
            """
        let allowsWrite = policy("Document write")
        let bare: [String: AnyHashable] = try await run(probe, farbling: nil, html: allowsWrite, awaiting: true)
        let protected: [String: AnyHashable] = try await run(probe, farbling: Self.farbling(), html: allowsWrite, awaiting: true)
        for result in [bare, protected] {
            #expect(result["threw"] == AnyHashable(false))
            #expect(result["kept"] == AnyHashable(false))
            #expect(result["sinks"] == AnyHashable("Document write"))
            #expect(result["handler"] == result["page"])
        }
        #expect(protected["page"] != bare["page"])

        let allowsSrcdoc = policy("HTMLIFrameElement srcdoc")
        for source in [nil, try Self.farbling()] {
            let result: [String: AnyHashable] = try await run(probe, farbling: source, html: allowsSrcdoc, awaiting: true)
            #expect(result["threw"] == AnyHashable(true), "farbling: \(source != nil)")
            #expect(result["kept"] == AnyHashable(true), "farbling: \(source != nil)")
            #expect(result["sinks"] == AnyHashable(source == nil ? "Document write" : "Document write,Document write"), "farbling: \(source != nil)")
        }
    }

    /// Under a report-only Trusted Types policy, a write files the one report the browser files,
    /// for the write's own sink: while the page parses, and after it loaded, when farbling opens
    /// the document ahead of a write with a frame.
    @Test func reportOnlyTrustedTypesSeeOneReportPerWrite() async throws {
        let html = """
            <body><script>
              window.reports = [];
              document.addEventListener('securitypolicyviolation', (event) => reports.push(event.sample), true);
            </script><script>document.write('<p>written</p>')</script></body>
            """
        let probe = """
            await new Promise((resolve) => setTimeout(resolve, 100));
            const parsing = reports.length;
            document.write('<iframe></iframe>');
            document.close();
            // Opening the document dropped the listener; the events come in a later task.
            document.addEventListener('securitypolicyviolation', (event) => reports.push(event.sample), true);
            await new Promise((resolve) => setTimeout(resolve, 100));
            return JSON.stringify({ parsing, sinks: reports.map((sample) => sample.split('|')[0]).join(), opened: document.querySelector('iframe') !== null });
            """
        let headers = ["Content-Security-Policy-Report-Only": "require-trusted-types-for 'script'"]
        for source in [nil, try Self.farbling()] {
            let result: [String: AnyHashable] = try await run(probe, farbling: source, html: html, headers: headers, awaiting: true)
            #expect(result["parsing"] == AnyHashable(1), "farbling: \(source != nil)")
            #expect(result["sinks"] == AnyHashable("Document write,Document write"), "farbling: \(source != nil)")
            #expect(result["opened"] == AnyHashable(true), "farbling: \(source != nil)")
        }
    }

    /// Copies of the script for different sites agree on the marker: a cross-site frame's copy (of
    /// the top page's site) and that of the popup it opens (of its own) find each other, so
    /// toString holds between them and a window they both reach is noised once.
    @Test func copiesForDifferentSitesShareTheMarker() async throws {
        let key = SymmetricKey(data: Data("test-key".utf8))
        #expect(Privacy.farbling("__LITHIUM_MARK__", key: key, site: "a.example") == Privacy.farbling("__LITHIUM_MARK__", key: key, site: "b.example"))

        let probe = """
            const hash = (win) => {
              const c = win.document.createElement('canvas'); c.width = 200; c.height = 40;
              const x = c.getContext('2d'); x.fillStyle = '#f60'; x.fillRect(0, 0, 200, 40);
              let h = 0; const d = c.toDataURL(); for (let i = 0; i < d.length; i++) h = (Math.imul(h, 31) + d.charCodeAt(i)) | 0;
              return (h >>> 0).toString(16);
            };
            const native = (fn, toString) => /\\[native code\\]/.test(toString.call(fn));
            // Through the getter, so the page's copy reaches the frame its own copy protected.
            const child = document.querySelector('iframe').contentWindow;
            return JSON.stringify({ frame: hash(child),
              disguised: native(child.HTMLCanvasElement.prototype.toDataURL, Function.prototype.toString)
                && native(HTMLCanvasElement.prototype.toDataURL, child.Function.prototype.toString) });
            """
        let html = "<body><iframe srcdoc=\"<p>frame</p>\"></iframe></body>"
        // The top page farbles for one site, its frame with a copy for another.
        let mixed = "if (window === top) {\(try Self.farbling(site: "a.example"))} else {\(try Self.farbling(site: "b.example"))}"
        let frameOnly: [String: AnyHashable] = try await run(probe, farbling: Self.farbling(site: "b.example"), html: html, awaiting: true)
        let protected: [String: AnyHashable] = try await run(probe, farbling: nil, html: html, before: mixed, awaiting: true)

        #expect(protected["disguised"] == AnyHashable(true))
        #expect(protected["frame"] == frameOnly["frame"])
    }

    /// `document.open` on a frame's document keeps that frame's marker (it drops the window's
    /// listeners), and its three-argument form, which opens a popup, protects the popup.
    @Test func documentOpenKeepsTheMarkerAndProtectsItsPopup() async throws {
        let key = SymmetricKey(data: Data("test-key".utf8))
        let mark = Privacy.farbling("__LITHIUM_MARK__", key: key, site: "example.com")
        let probe = """
            (() => {
              const hash = (win) => {
                const c = win.document.createElement('canvas'); c.width = 200; c.height = 40;
                const x = c.getContext('2d'); x.fillStyle = '#f60'; x.fillRect(0, 0, 200, 40);
                let h = 0; const d = c.toDataURL(); for (let i = 0; i < d.length; i++) h = (Math.imul(h, 31) + d.charCodeAt(i)) | 0;
                return (h >>> 0).toString(16);
              };
              const frame = document.body.appendChild(document.createElement('iframe'));
              Document.prototype.open.call(frame.contentDocument);
              frame.contentDocument.close();
              const marked = !frame.contentWindow.dispatchEvent(new CustomEvent('\(mark)', { cancelable: true, detail: {} }));
              return JSON.stringify({ page: hash(window), popup: hash(document.open('', '', '')), marked });
            })()
            """
        let bare: [String: AnyHashable] = try await run(probe, farbling: nil)
        let protected: [String: AnyHashable] = try await run(probe, farbling: Self.farbling())

        #expect(bare["page"] == bare["popup"])
        #expect(protected["page"] != bare["page"])
        #expect(protected["popup"] == protected["page"])
        #expect(protected["marked"] == AnyHashable(true))
    }

    /// Frequency data is in decibels, where an offset as small as the samples' rounds away in
    /// float32; the noise is relative there, so it shows.
    @Test func frequencyNoiseSurvivesFloat32Rounding() async throws {
        // Stands for an analyser's output, without audio hardware: -30.5 dB in every bin.
        let analyser = "AnalyserNode.prototype.getFloatFrequencyData = function (values) { values.fill(-30.5); };"
        let probe = """
            (() => {
              const analyser = new OfflineAudioContext(1, 128, 44100).createAnalyser();
              const values = new Float32Array(analyser.frequencyBinCount);
              analyser.getFloatFrequencyData(values);
              let moved = 0, most = 0;
              for (let i = 0; i < values.length; i++) if (values[i] !== -30.5) { moved++; most = Math.max(most, Math.abs(values[i] + 30.5)); }
              return JSON.stringify({ moved, count: values.length, small: most < 0.001 });
            })()
            """
        let bare: [String: AnyHashable] = try await run(probe, farbling: nil, before: analyser)
        let protected: [String: AnyHashable] = try await run(probe, farbling: Self.farbling(), before: analyser)

        #expect(bare["moved"] == AnyHashable(0))
        let count = try #require(protected["count"] as? Int)
        #expect(try #require(protected["moved"] as? Int) > count / 2)
        #expect(protected["small"] == AnyHashable(true))
    }
}

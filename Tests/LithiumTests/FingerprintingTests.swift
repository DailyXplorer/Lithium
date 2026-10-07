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
    private func run<Value>(_ probe: String, farbling source: String?, at base: String = "https://example.com/", html: String = "<body></body>", before: String? = nil, awaiting: Bool = false) async throws -> Value {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        if let before {
            configuration.userContentController.addUserScript(WKUserScript(source: before, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        if let source {
            configuration.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let loaded = PageLoad()
        let popups = Popups()
        webView.navigationDelegate = loaded
        webView.uiDelegate = popups
        webView.loadHTMLString(html, baseURL: URL(string: base)!)
        try await loaded.wait()
        let result: Any? = awaiting
            ? try await webView.callAsyncJavaScript(probe, contentWorld: .page)
            : try await webView.evaluateJavaScript(probe) as Any?
        let json = try #require(result as? String)
        return try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? Value)
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

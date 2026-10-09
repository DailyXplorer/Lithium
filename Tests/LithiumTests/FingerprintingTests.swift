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
    /// `headers` serves the page with them, from a custom scheme, instead of loading the markup;
    /// `frames` serves other hosts of that scheme, for the page's frames.
    private func run<Value>(_ probe: String, farbling source: String?, at base: String = "https://example.com/", html: String = "<body></body>", headers: [String: String]? = nil, frames: [String: String] = [:], before: String? = nil, awaiting: Bool = false) async throws -> Value {
        let configuration = WKWebViewConfiguration()
        let served = headers.map { ServedPage(html: html, headers: $0, frames: frames) }
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

    /// Serves one page with the given response headers, and the markup of `frames` for their hosts.
    @MainActor
    private final class ServedPage: NSObject, WKURLSchemeHandler {
        static let scheme = "lithium-test"
        let html: String
        let headers: [String: String]
        let frames: [String: String]

        init(html: String, headers: [String: String], frames: [String: String] = [:]) {
            self.html = html
            self.headers = headers
            self.frames = frames
        }

        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            let url = task.request.url!
            let frame = url.host().flatMap { frames[$0] }
            task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: (frame == nil ? headers : [:]).merging(["Content-Type": "text/html"]) { $1 })!)
            task.didReceive(Data((frame ?? html).utf8))
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
    /// said "Lithium" on every site. Nor does a frame's, listed from either realm, or seen by the
    /// traps of a proxy of it (which `Object.keys` or `for…in` ask about each of its keys); and
    /// `Proxy`, which keeps it from them, looks native.
    @Test func windowCarriesNoMarker() async throws {
        let bare: [String] = try await run(Self.namesProbe, farbling: nil)
        let protected: [String] = try await run(Self.namesProbe, farbling: Self.farbling())
        #expect(protected == bare)

        let frameProbe = """
            (() => {
              const w = document.body.appendChild(document.createElement('iframe')).contentWindow;
              const names = (keys) => keys.map(String).join(',');
              const asked = (ProxyCtor, make, list) => {
                const keys = [];
                list(make(ProxyCtor, w, { getOwnPropertyDescriptor: (t, k) => (keys.push(k), Reflect.getOwnPropertyDescriptor(t, k)) }));
                return names(keys);
              };
              const plain = (P, t, h) => new P(t, h), revocable = (P, t, h) => P.revocable(t, h).proxy;
              const forIn = (p) => { for (const k in p); };
              return JSON.stringify([names(Object.getOwnPropertyNames(w)), names(Reflect.ownKeys(w)),
                names(Object.keys(Object.getOwnPropertyDescriptors(w))), names(w.Object.getOwnPropertyNames(w)),
                names(Object.getOwnPropertyNames(new Proxy(w, {}))), names(Object.getOwnPropertyNames(new Proxy(w, { ownKeys: (t) => Reflect.ownKeys(t) }))),
                asked(Proxy, plain, Object.keys), asked(Proxy, plain, forIn), asked(Proxy, plain, Object.getOwnPropertyDescriptors),
                asked(Proxy, revocable, Object.keys), asked(w.Proxy, plain, Object.keys), asked(w.Proxy, revocable, Object.getOwnPropertyDescriptors),
                [typeof Proxy.prototype, Proxy.name, Proxy.length, Function.prototype.toString.call(Proxy), Function.prototype.toString.call(Proxy.revocable),
                 Object.getOwnPropertyNames(Proxy).sort()].join('|'), (() => { try { Proxy(w, {}); return 'called'; } catch (e) { return e.constructor.name; } })()]);
            })()
            """
        let bareFrame: [String] = try await run(frameProbe, farbling: nil)
        let protectedFrame: [String] = try await run(frameProbe, farbling: Self.farbling())
        #expect(protectedFrame == bareFrame)
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

    /// A top-level `blob:` page farbles as its creator's site: every site's blob pages once shared
    /// the seed of "", which linked them. An opaque creator's gets a seed of its own each time.
    @Test func blobPagesTakeTheirCreatorsSite() {
        let site = { (address: String) in Privacy.farblingSite(URL(string: address)!) }
        #expect(site("blob:https://www.example.co.uk/6f1c0a52-8d3e-4b7a-9c11-2f4e5d6a7b8c") == "example.co.uk")
        #expect(site("BLOB:http://10.0.0.1:8080/6f1c0a52") == "10.0.0.1")
        let opaque = site("blob:null/6f1c0a52-8d3e-4b7a-9c11-2f4e5d6a7b8c")
        #expect(!opaque.isEmpty)
        #expect(opaque != site("blob:null/6f1c0a52-8d3e-4b7a-9c11-2f4e5d6a7b8c"))
        // A blob inside a blob, however deep, is opaque too, and read at once.
        let nested = site("blob:blob:https://www.example.co.uk/6f1c0a52")
        #expect(!nested.isEmpty && nested != "example.co.uk")
        let deep = site(String(repeating: "blob:", count: 30_000) + "https://www.example.co.uk/6f1c0a52")
        #expect(!deep.isEmpty && deep != "example.co.uk")

        let privacy = Privacy()
        let script = { (address: String) in privacy.scripts(true, for: URL(string: address)!).first?.source }
        #expect(script("blob:https://alice.example/1") == script("https://alice.example/"))
        #expect(script("blob:https://alice.example/1") != script("blob:https://bob.example/1"))
    }

    /// Private tabs farble with keys of their own: the same site's canvas reads differently there.
    @Test func privateTabsGetTheirOwnKeys() async throws {
        let privacy = Privacy()
        let url = URL(string: "https://news.example/")!
        let normal = try #require(privacy.scripts(true, for: url).first?.source)
        // Held, so the second store can't take the first one's identity.
        let stores = [WKWebsiteDataStore.nonPersistent(), WKWebsiteDataStore.nonPersistent()]
        let session = ObjectIdentifier(stores[0])
        let ephemeral = try #require(privacy.scripts(true, for: url, privateSession: session).first?.source)
        #expect(!normal.contains("__LITHIUM_") && !ephemeral.contains("__LITHIUM_"))
        #expect(normal != ephemeral)
        #expect(try await canvasHash(normal, at: url.absoluteString) != canvasHash(ephemeral, at: url.absoluteString))

        // The same session keeps its key; another one, or the next once it is forgotten, has its own.
        #expect(privacy.scripts(true, for: url, privateSession: session).first?.source == ephemeral)
        let other = ObjectIdentifier(stores[1])
        let second = try #require(privacy.scripts(true, for: url, privateSession: other).first?.source)
        #expect(second != ephemeral && second != normal)
        privacy.forget(privateSession: session)
        #expect(privacy.scripts(true, for: url, privateSession: session).first?.source != ephemeral)
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

    /// `readPixels` noise stays inside what the read wrote (from its offset into the array), and
    /// leaves exact the reads GPU picking relies on: integer formats and reads of a few pixels.
    @Test func readPixelsNoiseSparesPickingAndTheRestOfTheArray() async throws {
        let probe = """
            (() => {
              const gl = document.createElement('canvas').getContext('webgl2', { preserveDrawingBuffer: true });
              gl.canvas.width = 64; gl.canvas.height = 64; gl.viewport(0, 0, 64, 64);
              gl.clearColor(0.5, 0.25, 0.75, 1); gl.clear(gl.COLOR_BUFFER_BIT);
              const one = new Uint8Array(4); gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, one);
              const clean = [...one];
              // Every pixel read alone, as picking does.
              let picked = 0;
              for (let y = 0; y < 64; y++) for (let x = 0; x < 64; x++) {
                gl.readPixels(x, y, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, one);
                for (let i = 0; i < 4; i++) if (one[i] !== clean[i]) picked++;
              }
              // The whole buffer, 8 bytes into a larger array.
              const big = new Uint8Array(64 * 64 * 4 + 16).fill(7);
              gl.readPixels(0, 0, 64, 64, gl.RGBA, gl.UNSIGNED_BYTE, big, 8);
              let outside = 0, noisy = 0;
              for (let i = 0; i < big.length; i++) {
                if (i < 8 || i >= 8 + 64 * 64 * 4) { if (big[i] !== 7) outside++; }
                else if (big[i] !== clean[(i - 8) % 4]) noisy++;
              }
              // An integer target.
              const buffer = gl.createRenderbuffer(); gl.bindRenderbuffer(gl.RENDERBUFFER, buffer);
              gl.renderbufferStorage(gl.RENDERBUFFER, gl.RGBA8I, 64, 64);
              gl.bindFramebuffer(gl.FRAMEBUFFER, gl.createFramebuffer());
              gl.framebufferRenderbuffer(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.RENDERBUFFER, buffer);
              gl.clearBufferiv(gl.COLOR, 0, new Int32Array([2, 4, 6, 8]));
              const ids = new Int8Array(64 * 64 * 4);
              gl.readPixels(0, 0, 64, 64, gl.RGBA_INTEGER, gl.BYTE, ids);
              let sum = 0; for (let i = 0; i < ids.length; i++) sum += ids[i];
              return JSON.stringify({ error: gl.getError(), picked, outside, noisy, sum });
            })()
            """
        let bare: [String: AnyHashable] = try await run(probe, farbling: nil)
        let protected: [String: AnyHashable] = try await run(probe, farbling: Self.farbling())

        #expect(bare["error"] == AnyHashable(0))
        #expect(protected["error"] == AnyHashable(0))
        #expect(bare["noisy"] == AnyHashable(0))
        #expect(protected["picked"] == AnyHashable(0))
        #expect(protected["outside"] == AnyHashable(0))
        #expect(try #require(protected["noisy"] as? Int) > 0)
        #expect(protected["sum"] == AnyHashable(64 * 64 * 20))
    }

    /// `readPixels` noise follows the arguments as the native call converts them and the rows as
    /// the pack settings lay them out, and stays off a read that wrote nothing and off pixels past
    /// the canvas's edges.
    @Test func readPixelsNoiseFollowsThePackedLayout() async throws {
        let probe = """
            (() => {
              const gl = document.createElement('canvas').getContext('webgl2', { preserveDrawingBuffer: true });
              gl.canvas.width = 64; gl.canvas.height = 64; gl.viewport(0, 0, 64, 64);
              gl.clearColor(0.5, 0.25, 0.75, 1); gl.clear(gl.COLOR_BUFFER_BIT);
              const clean = new Uint8Array(4); gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, clean);
              const result = {};
              // Counts the read bytes off the clean color, and the bytes around them (filled with 7) changed.
              const layout = (name, pixels, first, stride, rows, width) => {
                let noisy = 0, outside = 0;
                for (let i = 0; i < pixels.length; i++) {
                  const at = i - first, row = Math.floor(at / stride), column = at - row * stride;
                  if (at >= 0 && row < rows && column < width * 4) { if (pixels[i] !== clean[column % 4]) noisy++; }
                  else if (pixels[i] !== 7) outside++;
                }
                result[name + 'Noisy'] = noisy; result[name + 'Outside'] = outside;
              };
              const strings = new Uint8Array(64 * 64 * 4).fill(7);
              gl.readPixels('0', '0', '64', '64', String(gl.RGBA), String(gl.UNSIGNED_BYTE), strings);
              layout('strings', strings, 0, 256, 64, 64);
              gl.pixelStorei(gl.PACK_ROW_LENGTH, 80); gl.pixelStorei(gl.PACK_SKIP_ROWS, 2); gl.pixelStorei(gl.PACK_SKIP_PIXELS, 8);
              const skipped = new Uint8Array(31 * 320 + 32 + 256).fill(7);
              gl.readPixels(0, 0, 64, 30, gl.RGBA, gl.UNSIGNED_BYTE, skipped);
              layout('skipped', skipped, 2 * 320 + 32, 320, 30, 64);
              gl.pixelStorei(gl.PACK_ROW_LENGTH, 0); gl.pixelStorei(gl.PACK_SKIP_ROWS, 0); gl.pixelStorei(gl.PACK_SKIP_PIXELS, 0);
              gl.pixelStorei(gl.PACK_ALIGNMENT, 8);
              const aligned = new Uint8Array(32 * 136 + 132).fill(7);
              gl.readPixels(0, 0, 33, 33, gl.RGBA, gl.UNSIGNED_BYTE, aligned);
              layout('aligned', aligned, 0, 136, 33, 33);
              gl.pixelStorei(gl.PACK_ALIGNMENT, 4);
              // A read past the canvas's edges: only the 64 × 64 pixels inside are written.
              const past = new Uint8Array(80 * 80 * 4).fill(7);
              gl.readPixels(-8, -8, 80, 80, gl.RGBA, gl.UNSIGNED_BYTE, past);
              result.pastNoisy = 0; result.pastOutside = 0;
              for (let i = 0; i < past.length; i++) {
                const x = (i >> 2) % 80 - 8, y = Math.floor(i / 320) - 8;
                if (x >= 0 && x < 64 && y >= 0 && y < 64) { if (past[i] !== clean[i % 4]) result.pastNoisy++; }
                else if (past[i] !== 7) result.pastOutside++;
              }
              // WebGL1 ignores an 8th argument: the read lands at the start of the array all the same.
              const one = document.createElement('canvas').getContext('webgl', { preserveDrawingBuffer: true });
              one.canvas.width = 16; one.canvas.height = 16; one.viewport(0, 0, 16, 16);
              one.clearColor(0.5, 0.25, 0.75, 1); one.clear(one.COLOR_BUFFER_BIT);
              const plain = new Uint8Array(16 * 16 * 4), offset = new Uint8Array(16 * 16 * 4 + 16).fill(7);
              one.readPixels(0, 0, 16, 16, one.RGBA, one.UNSIGNED_BYTE, plain);
              one.readPixels(0, 0, 16, 16, one.RGBA, one.UNSIGNED_BYTE, offset, 16);
              result.webgl1Noisy = plain.filter((value, i) => value !== clean[i % 4]).length;
              result.webgl1Moved = offset.filter((value, i) => i < plain.length ? value !== plain[i] : value !== 7).length;
              // Reads that write nothing: through a bound pack buffer, from an incomplete framebuffer, on a lost context,
              // with a row length shorter than the row and its skipped pixels.
              const unwritten = new Uint8Array(64 * 64 * 4).fill(7), errors = [];
              gl.pixelStorei(gl.PACK_ROW_LENGTH, 60); gl.pixelStorei(gl.PACK_SKIP_PIXELS, 8);
              gl.readPixels(0, 0, 56, 64, gl.RGBA, gl.UNSIGNED_BYTE, unwritten); errors.push(gl.getError());
              gl.pixelStorei(gl.PACK_ROW_LENGTH, 0); gl.pixelStorei(gl.PACK_SKIP_PIXELS, 0);
              gl.bindBuffer(gl.PIXEL_PACK_BUFFER, gl.createBuffer());
              gl.bufferData(gl.PIXEL_PACK_BUFFER, 64 * 64 * 4, gl.STREAM_READ);
              gl.readPixels(0, 0, 64, 64, gl.RGBA, gl.UNSIGNED_BYTE, unwritten); errors.push(gl.getError());
              gl.bindBuffer(gl.PIXEL_PACK_BUFFER, null);
              gl.bindFramebuffer(gl.FRAMEBUFFER, gl.createFramebuffer());
              gl.readPixels(0, 0, 64, 64, gl.RGBA, gl.UNSIGNED_BYTE, unwritten); errors.push(gl.getError());
              gl.bindFramebuffer(gl.FRAMEBUFFER, null);
              gl.getExtension('WEBGL_lose_context').loseContext();
              gl.readPixels(0, 0, 64, 64, gl.RGBA, gl.UNSIGNED_BYTE, unwritten); errors.push(gl.getError());
              result.unwritten = unwritten.filter((value) => value !== 7).length;
              result.errors = errors.join();
              return JSON.stringify(result);
            })()
            """
        let bare: [String: AnyHashable] = try await run(probe, farbling: nil)
        let protected: [String: AnyHashable] = try await run(probe, farbling: Self.farbling())

        for name in ["strings", "skipped", "aligned", "past"] {
            #expect(bare["\(name)Noisy"] == AnyHashable(0), "\(name)")
            #expect(bare["\(name)Outside"] == AnyHashable(0), "\(name)")
            #expect(try #require(protected["\(name)Noisy"] as? Int) > 0, "\(name)")
            #expect(protected["\(name)Outside"] == AnyHashable(0), "\(name)")
        }
        #expect(bare["webgl1Noisy"] == AnyHashable(0))
        #expect(try #require(protected["webgl1Noisy"] as? Int) > 0)
        #expect(bare["webgl1Moved"] == AnyHashable(0))
        #expect(protected["webgl1Moved"] == AnyHashable(0))
        #expect(bare["unwritten"] == AnyHashable(0))
        #expect(protected["unwritten"] == AnyHashable(0))
        #expect(bare["errors"] == AnyHashable("1282,1282,1286,37442"))
        #expect(protected["errors"] == bare["errors"])
    }

    /// A read into a pack buffer gets the noise a read into an array does, whatever binding the page
    /// reads the buffer back through, and only where the read wrote; a read past the size limit
    /// still gets noise on a share of its pixels.
    @Test func readPixelsNoiseCoversPackBuffersAndLargeReads() async throws {
        let probe = """
            (() => {
              const gl = document.createElement('canvas').getContext('webgl2', { preserveDrawingBuffer: true });
              gl.canvas.width = 64; gl.canvas.height = 64; gl.viewport(0, 0, 64, 64);
              gl.clearColor(0.5, 0.25, 0.75, 1); gl.clear(gl.COLOR_BUFFER_BIT);
              const clean = new Uint8Array(4); gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, clean);
              const array = new Uint8Array(64 * 64 * 4); gl.readPixels(0, 0, 64, 64, gl.RGBA, gl.UNSIGNED_BYTE, array);
              const buffer = gl.createBuffer();
              gl.bindBuffer(gl.PIXEL_PACK_BUFFER, buffer);
              gl.bufferData(gl.PIXEL_PACK_BUFFER, 64 * 64 * 4 + 16, gl.STREAM_READ);
              gl.readPixels(0, 0, 64, 64, gl.RGBA, gl.UNSIGNED_BYTE, 8);
              gl.bindBuffer(gl.PIXEL_PACK_BUFFER, null);
              gl.bindBuffer(gl.COPY_READ_BUFFER, buffer);
              const packed = new Uint8Array(64 * 64 * 4 + 16);
              gl.getBufferSubData(gl.COPY_READ_BUFFER, 0, packed);
              let noisy = 0, different = 0, outside = 0;
              for (let i = 0; i < packed.length; i++) {
                if (i < 8 || i >= 8 + array.length) { if (packed[i] !== 0) outside++; continue; }
                if (packed[i] !== clean[(i - 8) % 4]) noisy++;
                if (packed[i] !== array[i - 8]) different++;
              }
              const large = document.createElement('canvas').getContext('webgl2', { preserveDrawingBuffer: true });
              large.canvas.width = 1024; large.canvas.height = 512; large.viewport(0, 0, 1024, 512);
              large.clearColor(0.5, 0.25, 0.75, 1); large.clear(large.COLOR_BUFFER_BIT);
              const pixels = new Uint8Array(1024 * 512 * 4); large.readPixels(0, 0, 1024, 512, large.RGBA, large.UNSIGNED_BYTE, pixels);
              let largeNoisy = 0; for (let i = 0; i < pixels.length; i++) if (pixels[i] !== clean[i % 4]) largeNoisy++;
              return JSON.stringify({ error: gl.getError() + large.getError(), noisy, different, outside, largeNoisy });
            })()
            """
        let bare: [String: Int] = try await run(probe, farbling: nil)
        let protected: [String: Int] = try await run(probe, farbling: Self.farbling())

        #expect(bare == ["error": 0, "noisy": 0, "different": 0, "outside": 0, "largeNoisy": 0])
        #expect(protected["error"] == 0)
        #expect(try #require(protected["noisy"]) > 0)
        #expect(protected["different"] == 0)
        #expect(protected["outside"] == 0)
        #expect(try #require(protected["largeNoisy"]) > 0)
    }

    /// A read far larger than the canvas noises every pixel it covers, not one in a few at spots the
    /// page can predict; offsets that WebKit reads as 0 (NaN, Infinity, 2^32, an object that isn't
    /// an array view) get the noise a read at 0 does, into a pack buffer or an array.
    @Test func readPixelsOversizedReadsAndOddOffsetsAreNoised() async throws {
        let probe = """
            (() => {
              const gl = document.createElement('canvas').getContext('webgl2', { preserveDrawingBuffer: true });
              gl.canvas.width = 300; gl.canvas.height = 150; gl.viewport(0, 0, 300, 150);
              gl.clearColor(0.5, 0.25, 0.75, 1); gl.clear(gl.COLOR_BUFFER_BIT);
              const clean = new Uint8Array(4); gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, clean);
              const count = (pixels, width, odd) => {
                let noisy = 0;
                for (let y = 0; y < 150; y++) for (let x = 0; x < 300; x++) {
                  if (odd && !((x + y) & 1)) continue;
                  for (let c = 0; c < 4; c++) if (pixels[(y * width + x) * 4 + c] !== clean[c]) { noisy++; break; }
                }
                return noisy;
              };
              const huge = new Uint8Array(1000 * 1000 * 4); gl.readPixels(0, 0, 1000, 1000, gl.RGBA, gl.UNSIGNED_BYTE, huge);
              const result = { oversizedOdd: count(huge, 1000, true) };
              const size = 300 * 150 * 4, buffer = gl.createBuffer();
              gl.bindBuffer(gl.PIXEL_PACK_BUFFER, buffer);
              gl.bufferData(gl.PIXEL_PACK_BUFFER, size, gl.STREAM_READ);
              for (const [name, offset] of [['packNaN', NaN], ['packInfinity', Infinity], ['packArray', []], ['packObject', {}]]) {
                gl.bufferSubData(gl.PIXEL_PACK_BUFFER, 0, new Uint8Array(size));
                gl.readPixels(0, 0, 300, 150, gl.RGBA, gl.UNSIGNED_BYTE, offset);
                const packed = new Uint8Array(size); gl.getBufferSubData(gl.PIXEL_PACK_BUFFER, 0, packed);
                result[name] = count(packed, 300, false);
              }
              gl.bindBuffer(gl.PIXEL_PACK_BUFFER, null);
              for (const [name, offset] of [['arrayInfinity', Infinity], ['arrayWrapped', 2 ** 32]]) {
                const pixels = new Uint8Array(size); gl.readPixels(0, 0, 300, 150, gl.RGBA, gl.UNSIGNED_BYTE, pixels, offset);
                result[name] = count(pixels, 300, false);
              }
              result.error = gl.getError();
              return JSON.stringify(result);
            })()
            """
        let names = ["oversizedOdd", "packNaN", "packInfinity", "packArray", "packObject", "arrayInfinity", "arrayWrapped"]
        let bare: [String: Int] = try await run(probe, farbling: nil)
        let protected: [String: Int] = try await run(probe, farbling: Self.farbling())

        #expect(bare == Dictionary(uniqueKeysWithValues: (names + ["error"]).map { ($0, 0) }))
        #expect(protected["error"] == 0)
        for name in names {
            #expect(try #require(protected[name]) > 0, "\(name)")
        }
    }

    /// Canvas noise follows the pixel's spot in the canvas, not where the read starts: a 1×1 read,
    /// an offset window or one with a negative size hands back what the full read has there.
    @Test func smallReadsGetTheNoiseOfTheFullRead() async throws {
        let probe = """
            (() => {
              const draw = (x) => { x.font = '18px Arial'; x.fillStyle = '#f60'; x.fillRect(0, 0, 200, 40); x.fillStyle = '#069'; x.fillText('Lithium fp', 4, 26); };
              const check = (x) => {
                const full = x.getImageData(0, 0, 200, 40).data;
                let different = 0;
                for (let y = 0; y < 40; y++) for (let left = 0; left < 200; left++) {
                  const one = x.getImageData(left, y, 1, 1).data;
                  for (let i = 0; i < 4; i++) if (one[i] !== full[(y * 200 + left) * 4 + i]) different++;
                }
                const windows = [[3, 5, 17, 9], [150, 20, 50, 20], [40, 30, -13, -7]];
                for (const [sx, sy, sw, sh] of windows) {
                  const part = x.getImageData(sx, sy, sw, sh).data;
                  const left = sw < 0 ? sx + sw : sx, top = sh < 0 ? sy + sh : sy, width = Math.abs(sw);
                  for (let i = 0; i < part.length; i++) {
                    const p = i >> 2;
                    if (part[i] !== full[((top + Math.floor(p / width)) * 200 + left + p % width) * 4 + (i & 3)]) different++;
                  }
                }
                let h = 0; for (let i = 0; i < full.length; i++) h = (Math.imul(h, 31) + full[i]) | 0;
                return { different, hash: h };
              };
              const canvas = document.createElement('canvas'); canvas.width = 200; canvas.height = 40;
              const page = canvas.getContext('2d'); draw(page);
              const offscreen = new OffscreenCanvas(200, 40).getContext('2d'); draw(offscreen);
              return JSON.stringify({ page: check(page), offscreen: check(offscreen) });
            })()
            """
        let bare: [String: [String: Int]] = try await run(probe, farbling: nil)
        let protected: [String: [String: Int]] = try await run(probe, farbling: Self.farbling())

        for kind in ["page", "offscreen"] {
            #expect(protected[kind]?["different"] == 0, "\(kind)")
            #expect(protected[kind]?["hash"] != bare[kind]?["hash"], "\(kind)")
        }
    }

    /// A frame of another origin mixes its origin into the top site's noise: a tracker framed on a
    /// site doesn't farble as the site's own pages do (nor as it does on another site).
    @Test func crossOriginFrameFarblesApartFromItsPage() async throws {
        let hash = """
            const hash = (win) => {
              const c = win.document.createElement('canvas'); c.width = 200; c.height = 40;
              const x = c.getContext('2d'); x.fillStyle = '#f60'; x.fillRect(0, 0, 200, 40);
              let h = 0; const d = c.toDataURL(); for (let i = 0; i < d.length; i++) h = (Math.imul(h, 31) + d.charCodeAt(i)) | 0;
              return (h >>> 0).toString(16);
            };
            """
        let html = """
            <body><script>window.fromFrame = new Promise((done) => addEventListener('message', (event) => done(event.data)));</script>
            <iframe src="\(ServedPage.scheme)://tracker.example/"></iframe></body>
            """
        let frames = ["tracker.example": "<body><script>\(hash) parent.postMessage(hash(window), '*');</script></body>"]
        let probe = hash + "return JSON.stringify({ page: hash(window), frame: await fromFrame });"
        let result = { (source: String?) async throws -> [String: String] in
            try await self.run(probe, farbling: source, html: html, headers: [:], frames: frames, awaiting: true)
        }
        let bare = try await result(nil)
        let protected = try await result(Self.farbling())
        let elsewhere = try await result(Self.farbling(site: "other.example"))

        #expect(bare["page"] == bare["frame"])
        #expect(protected["page"] != bare["page"])
        #expect(protected["frame"] != bare["frame"])
        #expect(protected["frame"] != protected["page"])
        #expect(elsewhere["frame"] != protected["frame"])
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

    /// The insertion hooks read nodes through the members saved at load: a frame, a fragment or a
    /// box with own `nodeType`, `localName` or `querySelector` values doesn't go in unprotected.
    /// Srcdoc frames, which are still blank windows when the page reaches them.
    @Test func framesWithOwnNodeMembersAreProtected() async throws {
        let probe = """
            (() => {
              const hash = (win) => {
                const c = win.document.createElement('canvas'); c.width = 200; c.height = 40;
                const x = c.getContext('2d'); x.fillStyle = '#f60'; x.fillRect(0, 0, 200, 40);
                let h = 0; const d = c.toDataURL(); for (let i = 0; i < d.length; i++) h = (Math.imul(h, 31) + d.charCodeAt(i)) | 0;
                return (h >>> 0).toString(16);
              };
              const last = () => hash(frames[frames.length - 1]);
              const frame = () => { const f = document.createElement('iframe'); f.srcdoc = '<p>frame</p>'; return f; };
              const own = (node, name, value) => { Object.defineProperty(node, name, { value }); return node; };
              const routes = { page: hash(window) };
              document.body.appendChild(own(frame(), 'nodeType', 3)); routes.nodeType = last();
              document.body.append(own(own(frame(), 'localName', 'div'), 'firstElementChild', null)); routes.localName = last();
              const box = document.createElement('div'); box.appendChild(frame());
              document.body.appendChild(own(box, 'querySelector', () => null)); routes.querySelector = last();
              const fragment = document.createDocumentFragment(); fragment.appendChild(frame());
              document.body.appendChild(own(fragment, 'nodeType', 1)); routes.fragment = last();
              return JSON.stringify(routes);
            })()
            """
        let bare: [String: AnyHashable] = try await run(probe, farbling: nil)
        let protected: [String: AnyHashable] = try await run(probe, farbling: Self.farbling())

        #expect(bare.count == 5)
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

    /// Frames deep in the page's markup, and one the parser moves along with its parent (misnested
    /// `<a>`), are protected too: the observer searches only the outermost elements of a batch.
    @Test func framesNestedInThePageMarkupAreProtected() async throws {
        let html = """
            <body><div><section><div><p><span><iframe></iframe></span></p></div></section></div>
            <a>link<div><iframe></iframe>text</a>more</div><script>
              const hash = (win) => {
                const c = win.document.createElement('canvas'); c.width = 200; c.height = 40;
                const x = c.getContext('2d'); x.fillStyle = '#f60'; x.fillRect(0, 0, 200, 40);
                let h = 0; const d = c.toDataURL(); for (let i = 0; i < d.length; i++) h = (Math.imul(h, 31) + d.charCodeAt(i)) | 0;
                return (h >>> 0).toString(16);
              };
              const result = { page: hash(window), count: frames.length };
              for (let i = 0; i < frames.length; i++) result['frame' + i] = hash(frames[i]);
              window.result = JSON.stringify(result);
            </script></body>
            """
        let bare: [String: AnyHashable] = try await run("window.result", farbling: nil, html: html)
        let protected: [String: AnyHashable] = try await run("window.result", farbling: Self.farbling(), html: html)

        #expect(bare["count"] == AnyHashable(2))
        #expect(bare["frame0"] == bare["page"] && bare["frame1"] == bare["page"])
        #expect(protected["page"] != bare["page"])
        #expect(protected["frame0"] == protected["page"])
        #expect(protected["frame1"] == protected["page"])
    }

    /// A page keeps one Trusted Types script, whatever its frames' addresses: a frame that reloads,
    /// several frames of one address, and frames of new addresses once added a script each, which
    /// piled up until the next main-frame navigation. That navigation's page starts afresh.
    @Test func trustedTypesScriptsDontPileUp() throws {
        let privacy = Privacy()
        let controller = WKUserContentController()
        let response = { (address: String, header: String) in
            HTTPURLResponse(url: URL(string: address)!, statusCode: 200, httpVersion: nil,
                            headerFields: [header: "require-trusted-types-for 'script'"])!
        }
        let enforced = "Content-Security-Policy", reported = "Content-Security-Policy-Report-Only"
        let farbling = WKUserScript(source: "farbling", injectionTime: .atDocumentStart, forMainFrameOnly: false)
        controller.addUserScript(farbling)
        privacy.addTrustedTypesScript(true, for: response("https://example.com/frame", enforced), to: controller)
        privacy.addTrustedTypesScript(true, for: response("https://example.com/frame#again", enforced), to: controller)
        #expect(controller.userScripts.count == 2)
        for index in 0..<20 {
            privacy.addTrustedTypesScript(true, for: response("https://example.com/other?\(index)", reported), to: controller)
        }
        privacy.addTrustedTypesScript(false, for: response("https://example.com/off", enforced), to: controller)
        #expect(controller.userScripts.count == 2)
        // After the page's farbling, holding every address but the one it was off for.
        let source = try #require(controller.userScripts.last?.source)
        #expect(controller.userScripts.first?.source == farbling.source)
        #expect(source.contains("\"https:\\/\\/example.com\\/frame\":\"enforce\""))
        #expect(source.contains("\"https:\\/\\/example.com\\/other?19\":\"report\""))
        #expect(!source.contains("off"))

        controller.removeAllUserScripts()
        privacy.addTrustedTypesScript(true, for: response("https://example.org/", enforced), to: controller)
        #expect(controller.userScripts.count == 1)
        #expect(controller.userScripts.first?.source.contains("example.com") == false)
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
            // The policy stays once its markup is gone.
            "rejectedAfterTheMetaIsRemoved": (csp + "<body><p id=\"kept\">kept</p><script>document.querySelector('meta').remove()</script></body>",
                                              nil, ["kept": true, "written": false, "threw": true]),
            // Outside the head the browser ignores it, and so does farbling.
            "metaOutsideTheHead": ("<body>" + csp + "<p id=\"kept\">kept</p></body>", nil, ["kept": false, "written": true, "threw": false]),
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

    /// Blank and `srcdoc` frames and popups have no response: they take the Trusted Types of the
    /// page that made them, and a write those reject leaves them as it does the page.
    @Test func writeRejectedByInheritedTrustedTypesLeavesTheDocument() async throws {
        let probe = """
            const policy = trustedTypes.createPolicy('test', { createHTML: (s) => s });
            const kept = (doc) => { const p = doc.createElement('p'); p.id = 'kept'; doc.body.append(p); return doc; };
            const blank = document.body.appendChild(document.createElement('iframe'));
            const srcdoc = document.createElement('iframe');
            srcdoc.srcdoc = policy.createHTML('<body></body>');
            await new Promise((resolve) => { srcdoc.onload = resolve; document.body.append(srcdoc); });
            // A popup whose opener is gone still has its creator's policies.
            const orphan = open();
            orphan.opener = null;
            const targets = { blank: kept(blank.contentDocument), srcdoc: kept(srcdoc.contentDocument), popup: kept(open().document), orphan: kept(orphan.document) };
            const results = {};
            for (const [name, doc] of Object.entries(targets)) {
              let threw = false;
              try { doc.write('<p>written</p><iframe></iframe>'); } catch (error) { threw = error.name === 'TypeError'; }
              results[name] = threw && doc.getElementById('kept') !== null && doc.readyState === 'complete';
            }
            return JSON.stringify(results);
            """
        let headers = ["Content-Security-Policy": "require-trusted-types-for 'script'"]
        for source in [nil, try Self.farbling()] {
            let result: [String: Bool] = try await run(probe, farbling: source, headers: headers, awaiting: true)
            #expect(result == ["blank": true, "srcdoc": true, "popup": true, "orphan": true], "farbling: \(source != nil)")
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

    /// A frame's initial blank window, which the page reaches before the frame's page loads, is
    /// kept, with what the page put in it, when that page is of the same origin: the copy of the
    /// script for that page, and the Trusted Types flag, call nothing the page left there (its
    /// `CustomEvent` once read the marker), and the frames in the new page's markup are still
    /// protected. Whoever has the marker gets no native function through it.
    @Test func aKeptWindowLeaksNothingToThePage() async throws {
        let mark = Privacy.farbling("__LITHIUM_MARK__", key: SymmetricKey(data: Data("test-key".utf8)), site: "example.com")
        let probe = """
            const hash = (win) => {
              const c = win.document.createElement('canvas'); c.width = 200; c.height = 40;
              const x = c.getContext('2d'); x.fillStyle = '#f60'; x.fillRect(0, 0, 200, 40);
              let h = 0; const d = c.toDataURL(); for (let i = 0; i < d.length; i++) h = (Math.imul(h, 31) + d.charCodeAt(i)) | 0;
              return (h >>> 0).toString(16);
            };
            // This same page, its address set first: a frame inserted without one loads its blank
            // page at once, and that window isn't kept.
            const frame = document.createElement('iframe');
            frame.src = location.href;
            const loaded = new Promise((done) => { frame.onload = done; setTimeout(done, 3000); });
            document.body.appendChild(frame);
            const child = frame.contentWindow;
            let calls = 0;
            const spy = (owner, name) => {
              const real = owner[name];
              owner[name] = function (...args) { calls++; return new.target ? Reflect.construct(real, args) : Reflect.apply(real, this, args); };
              return owner[name];
            };
            const fake = spy(child, 'CustomEvent');
            spy(child.EventTarget.prototype, 'dispatchEvent');
            spy(child.Reflect, 'apply');
            await loaded;
            const reused = frame.contentWindow.CustomEvent === fake, asked = calls;
            const box = {};
            dispatchEvent(new CustomEvent('\(mark)', { cancelable: true, detail: box }));
            const shared = box.disguises;
            return JSON.stringify({ reused, asked, page: hash(window), nested: hash(frame.contentWindow.frames[0]),
              natives: !!shared && typeof shared.get === 'function',
              source: !!shared && /\\[native code\\]/.test(shared.source(HTMLCanvasElement.prototype.toDataURL)) });
            """
        // Served with a Trusted Types policy, so its flag runs in the kept window too.
        let html = "<body><iframe></iframe></body>"
        let headers = ["Content-Security-Policy-Report-Only": "require-trusted-types-for 'script'"]
        let bare: [String: AnyHashable] = try await run(probe, farbling: nil, html: html, headers: headers, awaiting: true)
        let protected: [String: AnyHashable] = try await run(probe, farbling: Self.farbling(), html: html, headers: headers, awaiting: true)

        #expect(bare["reused"] == AnyHashable(true), "the frame keeps its window")
        #expect(protected["reused"] == AnyHashable(true), "the frame keeps its window")
        #expect(protected["asked"] == AnyHashable(0))
        #expect(protected["page"] != bare["page"])
        #expect(protected["nested"] == protected["page"])
        #expect(protected["natives"] == AnyHashable(false))
        #expect(protected["source"] == AnyHashable(true))
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

    /// An array longer than the old sample limit still gets its frequencies noised: it once came
    /// back exact. Only the analyser's bins are touched, not the rest of the page's array.
    @Test func frequencyNoiseCoversLargeArrays() async throws {
        let analyser = "AnalyserNode.prototype.getFloatFrequencyData = function (values) { values.fill(-30.5, 0, this.frequencyBinCount); };"
        let probe = """
            (() => {
              const analyser = new OfflineAudioContext(1, 128, 44100).createAnalyser();
              const values = new Float32Array(600000), count = analyser.frequencyBinCount;
              analyser.getFloatFrequencyData(values);
              let moved = 0, past = 0;
              for (let i = 0; i < values.length; i++) if (i < count ? values[i] !== -30.5 : values[i] !== 0) i < count ? moved++ : past++;
              return JSON.stringify({ moved, count, past });
            })()
            """
        let bare: [String: Int] = try await run(probe, farbling: nil, before: analyser)
        let protected: [String: Int] = try await run(probe, farbling: Self.farbling(), before: analyser)

        #expect(bare["moved"] == 0)
        #expect(try #require(protected["moved"]) > (protected["count"] ?? 0) / 2)
        #expect(protected["past"] == 0)
    }

    /// Canvas reads past the pixel limit are noised on a share of their pixels: a large
    /// `getImageData`, `toDataURL` or OffscreenCanvas `convertToBlob` once came back exact.
    @Test func largeCanvasReadsAreNoised() async throws {
        let probe = """
            const hash = (bytes) => { let h = 0; for (let i = 0; i < bytes.length; i++) h = (Math.imul(h, 31) + bytes[i]) | 0; return h >>> 0; };
            const text = (s) => hash(Array.from(s, (c) => c.charCodeAt(0)));
            const draw = (x) => { x.fillStyle = '#f60'; x.fillRect(0, 0, 1000, 600); x.fillStyle = '#069'; x.fillRect(100, 100, 500, 300); };
            const c = document.createElement('canvas'); c.width = 1000; c.height = 600;
            const x = c.getContext('2d'); draw(x);
            const image = hash(x.getImageData(0, 0, 1000, 600).data);
            const url = text(c.toDataURL());
            const o = new OffscreenCanvas(1000, 600); draw(o.getContext('2d'));
            const blob = hash(new Uint8Array(await (await o.convertToBlob()).arrayBuffer()));
            return JSON.stringify({ image, url, blob });
            """
        let bare: [String: Int] = try await run(probe, farbling: nil, awaiting: true)
        let protected: [String: Int] = try await run(probe, farbling: Self.farbling(), awaiting: true)

        #expect(protected["image"] != bare["image"])
        #expect(protected["url"] != bare["url"])
        #expect(protected["blob"] != bare["blob"])
    }

    /// Sample noise depends on each sample's value: what a silent buffer shows can't be taken off
    /// another buffer's samples, as it once could, leaving them exact. A window copied from the
    /// middle gets the whole buffer's noise there, and nothing past what it copied; a long buffer is
    /// noised on every sample, not on a share at known places, and so are the analyser's
    /// time-domain and byte reads.
    @Test func audioNoiseCantBeMeasuredAndRemoved() async throws {
        // Stand for an analyser's output, without audio hardware.
        let analyser = """
            AnalyserNode.prototype.getFloatTimeDomainData = function (values) { values.fill(0.25); };
            AnalyserNode.prototype.getByteTimeDomainData = function (values) { values.fill(128); };
            AnalyserNode.prototype.getByteFrequencyData = function (values) { values.fill(100); };
            """
        let probe = """
            (() => {
              const length = 4096, wave = (i) => Math.fround(Math.sin(i / 7) * 0.5);
              const make = (size) => {
                const buffer = new AudioBuffer({ length: size, sampleRate: 44100 }), data = new Float32Array(size);
                for (let i = 0; i < size; i++) data[i] = wave(i);
                buffer.copyToChannel(data, 0);
                return buffer;
              };
              const silent = new AudioBuffer({ length, sampleRate: 44100 }).getChannelData(0);
              const buffer = make(length), full = buffer.getChannelData(0);
              let noisy = 0, removed = 0;
              for (let i = 0; i < length; i++) {
                if (full[i] !== wave(i)) noisy++;
                if (Math.fround(full[i] - silent[i]) === wave(i)) removed++;
              }
              // From the last 200 samples of a fresh buffer, into a longer array filled with 7.
              const window = new Float32Array(300).fill(7);
              make(length).copyFromChannel(window, 0, length - 200);
              let windowOff = 0, past = 0;
              for (let i = 0; i < 300; i++) {
                if (i < 200) { if (window[i] !== full[length - 200 + i]) windowOff++; } else if (window[i] !== 7) past++;
              }
              const again = new Float32Array(length); buffer.copyFromChannel(again, 0);
              let twice = 0; for (let i = 0; i < length; i++) if (again[i] !== full[i]) twice++;
              const long = make(600000).getChannelData(0);
              // Odd samples too: they once came back exact past the limit, the same on every site.
              let longNoisy = 0, longOdd = 0;
              for (let i = 0; i < long.length; i++) if (long[i] !== wave(i)) { longNoisy++; if (i & 1) longOdd++; }
              const node = new OfflineAudioContext(1, 128, 44100).createAnalyser();
              const moved = (values, clean) => values.filter((value) => value !== clean).length;
              const times = new Float32Array(node.fftSize); node.getFloatTimeDomainData(times);
              const timeBytes = new Uint8Array(node.fftSize); node.getByteTimeDomainData(timeBytes);
              const frequencyBytes = new Uint8Array(node.frequencyBinCount); node.getByteFrequencyData(frequencyBytes);
              const byteSpread = Math.max(...timeBytes.map((value) => Math.abs(value - 128)), ...frequencyBytes.map((value) => Math.abs(value - 100)));
              return JSON.stringify({ noisy, removed, windowOff, past, twice, longNoisy, longOdd, times: moved(times, 0.25),
                timeBytes: moved(timeBytes, 128), frequencyBytes: moved(frequencyBytes, 100), byteSpread });
            })()
            """
        let bare: [String: Int] = try await run(probe, farbling: nil, before: analyser)
        let protected: [String: Int] = try await run(probe, farbling: Self.farbling(), before: analyser)

        #expect(bare == ["noisy": 0, "removed": 4096, "windowOff": 0, "past": 0, "twice": 0, "longNoisy": 0, "longOdd": 0,
                         "times": 0, "timeBytes": 0, "frequencyBytes": 0, "byteSpread": 0])
        #expect(try #require(protected["noisy"]) > 4096 / 4)
        #expect(try #require(protected["removed"]) < 4096 * 3 / 4)
        #expect(protected["windowOff"] == 0)
        #expect(protected["past"] == 0)
        #expect(protected["twice"] == 0)
        // About half the samples move, wherever they are.
        #expect(try #require(protected["longNoisy"]) > 600000 / 4)
        #expect(try #require(protected["longOdd"]) > 600000 / 8)
        for name in ["times", "timeBytes", "frequencyBytes"] {
            #expect(try #require(protected[name]) > 0, "\(name)")
        }
        #expect(protected["byteSpread"] == 1)
    }
}

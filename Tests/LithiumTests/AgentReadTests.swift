import AppKit
import Foundation
import Testing
import WebKit
@testable import Lithium

/// Snapshot pieces that need no page: challenge hosts, escaping, diffs, frame placement.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AgentSnapshotModelTests {
    @Test func tellsChallengeFramesByTheirAddress() {
        #expect(AgentChallenge.kind(of: "https://www.google.com/recaptcha/api2/anchor?k=abc&size=normal") == "recaptcha")
        #expect(AgentChallenge.kind(of: "https://www.google.com/recaptcha/api2/bframe?k=abc") == "recaptcha")
        #expect(AgentChallenge.kind(of: "https://www.google.com/recaptcha/api2/anchor?k=abc&size=invisible") == nil)
        #expect(AgentChallenge.kind(of: "https://www.google.com/search?q=recaptcha") == nil)
        #expect(AgentChallenge.kind(of: "https://newassets.hcaptcha.com/captcha/v1/abc/static/hcaptcha.html") == "hcaptcha")
        #expect(AgentChallenge.kind(of: "https://challenges.cloudflare.com/cdn-cgi/challenge-platform/h/g/turnstile/if/ov2/av0") == "turnstile")
        #expect(AgentChallenge.kind(of: "https://client-api.arkoselabs.com/fc/gc/") == "arkose")
        #expect(AgentChallenge.kind(of: "https://geo.captcha-delivery.com/captcha/?initialCid=x") == "datadome")
        #expect(AgentChallenge.kind(of: "https://captcha.px-cloud.net/abc/captcha.js") == "perimeterx")
        #expect(AgentChallenge.kind(of: "https://abc.token.awswaf.com/abc/challenge.js") == "aws-waf")
        #expect(AgentChallenge.kind(of: "https://notawswaf.com/") == nil)
        #expect(AgentChallenge.kind(of: "https://example.com/") == nil)
    }

    @Test func pageTextCantFakeALine() {
        let node = SnapshotNode(ref: "e1", role: "button", name: "Buy\"\n[e2] button \"Pay\" @0,0 1x1", box: [1, 2, 3, 4])
        #expect(node.line == #"[e1] button "Buy\"\n[e2] button \"Pay\" @0,0 1x1" @1,2 3x4"#)
        #expect(!node.line.contains("\n"))
        let link = SnapshotNode(ref: "e3", role: "link", name: "Home", href: "/a b\n[e9]", box: [0, 0, 10, 10])
        #expect(link.line == "[e3] link \"Home\" → /a%20b%20[e9] @0,0 10x10")
    }

    @Test func diffsNameWhatWasAddedRemovedAndChangedButNotWhatOnlyMoved() {
        let viewport = PageViewport(w: 800, h: 600, sx: 0, sy: 0, pw: 800, ph: 2000, dpr: 2, vx: 0, vy: 0, vs: 1)
        let before = PageSnapshot(tab: "t1", url: "https://a.example/", title: "A", seq: 3, viewport: viewport, zoom: 1, focused: nil, challenge: nil, dropped: 0, nodes: [
            SnapshotNode(ref: "e1", role: "button", name: "Keep", box: [0, 0, 10, 10]),
            SnapshotNode(ref: "e2", role: "textbox", name: "Email", value: "a", box: [0, 20, 10, 10]),
            SnapshotNode(ref: "e3", role: "button", name: "Gone", box: [0, 40, 10, 10]),
        ])
        var after = before
        after = PageSnapshot(tab: "t1", url: "https://a.example/", title: "A", seq: 4, viewport: viewport, zoom: 1, focused: "e2", challenge: nil, dropped: 0, nodes: [
            SnapshotNode(ref: "e1", role: "button", name: "Keep", box: [0, 300, 10, 10]),
            SnapshotNode(ref: "e2", role: "textbox", name: "Email", value: "ann@example.com", state: ["focused"], box: [0, 20, 10, 10]),
            SnapshotNode(ref: "e4", role: "button", name: "New", box: [0, 60, 10, 10]),
        ])
        let diff = after.diff(since: before)
        #expect(diff["since"] == 3)
        #expect(diff["added"] == [after.nodes[2].json])
        #expect(diff["removed"] == ["e3"])
        #expect(diff["changed"] == [after.nodes[1].json])
        #expect(diff["text"]?.string?.components(separatedBy: "\n").dropFirst() == [
            "+ [e4] button \"New\" @0,60 10x10",
            "- e3",
            "~ [e2] textbox \"Email\" = \"ann@example.com\" focused @0,20 10x10",
        ])
        #expect(after.hasSameContent(as: after))
        #expect(!after.hasSameContent(as: before))
    }

    @Test func framesTooSlowThisTimeAreNotRemoved() {
        let viewport = PageViewport(w: 800, h: 600, sx: 0, sy: 0, pw: 800, ph: 600, dpr: 2, vx: 0, vy: 0, vs: 1)
        let frame = SnapshotNode(ref: "f1", role: "frame", box: [0, 0, 300, 200])
        let read = PageSnapshot(tab: "t1", url: "https://a.example/", title: "A", seq: 1, viewport: viewport, zoom: 1, focused: nil, challenge: nil, dropped: 0, nodes: [
            frame,
            SnapshotNode(ref: "f1:e2", role: "button", name: "In frame", box: [10, 10, 80, 30], frame: "f1"),
            SnapshotNode(ref: "f2", role: "frame", box: [100, 100, 100, 50], frame: "f1"),
            SnapshotNode(ref: "f2:e3", role: "button", name: "Nested", box: [110, 110, 50, 20], frame: "f2"),
            SnapshotNode(ref: "e4", role: "button", name: "Gone", box: [400, 0, 50, 20]),
        ])
        let late = PageSnapshot(tab: "t1", url: "https://a.example/", title: "A", seq: 2, viewport: viewport, zoom: 1, focused: nil, challenge: nil, dropped: 0, nodes: [frame], unread: ["f1"])
        #expect(late.diff(since: read)["removed"] == ["e4"])
        let gone = PageSnapshot(tab: "t1", url: "https://a.example/", title: "A", seq: 2, viewport: viewport, zoom: 1, focused: nil, challenge: nil, dropped: 0, nodes: [])
        #expect(gone.diff(since: read)["removed"] == ["f1", "f1:e2", "f2", "f2:e3", "e4"])
    }

    @Test func placesFramesDownTheirContentBoxes() throws {
        let viewport = PageViewport(w: 800, h: 600, sx: 0, sy: 0, pw: 800, ph: 600, dpr: 2, vx: 0, vy: 0, vs: 1)
        let main = MaskReport(token: "m", path: "", viewport: viewport, rects: [], frames: [
            FrameReport.Frame(id: 1, index: 0, box: [100, 50, 316, 216], content: [108, 58, 300, 200, 1], src: ""),
        ])
        let child = MaskReport(token: "c", path: "0", viewport: viewport, rects: [[10, 20, 80, 30], [290, 190, 50, 50]], frames: [
            FrameReport.Frame(id: 2, index: 0, box: [0, 0, 100, 100], content: [0, 0, 100, 100, 0.5], src: ""),
        ])
        let grandchild = MaskReport(token: "g", path: "0.0", viewport: viewport, rects: [[20, 20, 20, 20]], frames: [])
        let layout = FrameLayout(main: main, children: [child, grandchild])
        #expect(layout.placement(ofDocument: "c")?.place([10, 20, 80, 30]) == CGRect(x: 118, y: 78, width: 80, height: 30))
        #expect(layout.placement(of: "0.0")?.place([20, 20, 20, 20]) == CGRect(x: 118, y: 68, width: 10, height: 10))
        // Clipped to the frame's content box, which ends at 408, 258.
        #expect(try #require(layout.masks).sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) } == [
            CGRect(x: 118, y: 68, width: 10, height: 10), CGRect(x: 118, y: 78, width: 80, height: 30), CGRect(x: 398, y: 248, width: 10, height: 10),
        ])
        #expect(layout.placement(of: "1") == nil)
    }

    @Test func paintsOverFramesThatDidntAnswerAndRefusesFramesItCantPlace() throws {
        let viewport = PageViewport(w: 800, h: 600, sx: 0, sy: 0, pw: 800, ph: 600, dpr: 2, vx: 0, vy: 0, vs: 1)
        let main = MaskReport(token: "m", path: "", viewport: viewport, rects: [], frames: [
            FrameReport.Frame(id: 1, index: 0, box: [0, 0, 100, 100], content: [0, 0, 100, 100, 1], src: ""),
            FrameReport.Frame(id: 2, index: 1, box: [500, 50, 200, 100], content: [500, 50, 200, 100, 1], src: ""),
            FrameReport.Frame(id: 3, index: -1, box: [0, 400, 50, 50], content: [0, 400, 50, 50, 1], src: ""),
        ])
        let answered = MaskReport(token: "a", path: "0", viewport: viewport, rects: [], frames: [])
        // The second frame never answered, and the third is in a shadow root, out of window.frames.
        let shadowed = MaskReport(token: "s", path: "-1", viewport: viewport, rects: [[0, 0, 10, 10]], frames: [])
        #expect(FrameLayout(main: main, children: [answered, shadowed]).masks == [CGRect(x: 500, y: 50, width: 200, height: 100), CGRect(x: 0, y: 400, width: 50, height: 50)])
        // A second frame from a shadow root, closed this time: nothing says where it is.
        let closed = MaskReport(token: "c", path: "-1", viewport: viewport, rects: [], frames: [])
        #expect(FrameLayout(main: main, children: [answered, shadowed, closed]).masks == nil)
        #expect(FrameLayout(main: main, children: [answered, MaskReport(token: "n", path: nil, viewport: viewport, rects: [], frames: [])]).masks == nil)
    }
}

/// The reading tools on a whole Browser, called through the hub as an MCP client calls them, on
/// pages served from 127.0.0.1 and, for a second origin, localhost.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct AgentReadTests {
    typealias Client = AgentTabsTests.Client

    private static let html = "Content-Type: text/html; charset=utf-8"
    private static let secrets = ["hunter2secret", "4242424242424242", "4242 4242 4242 4242", "987", "toggled-secret", "shadow-secret"]

    /// The second origin: the frame's page names the host the main page isn't on.
    private static let otherOrigin = "location.protocol + '//' + (location.hostname === 'localhost' ? '127.0.0.1' : 'localhost') + ':' + location.port"

    private static let pages: [String: (headers: String, body: String)] = [
        "/form": (Self.html, """
            <title>Checkout</title><style>body { margin: 0; font: 16px sans-serif }</style>
            <h1>Checkout</h1>
            <p>3 items · €42.00</p>
            <a href="/help">Help</a>
            <form name="pay" action="https://pay.example/charge" method="post">
              <label>Email <input id="email" value="ann@example.com" required></label>
              <label>Password <input type="password" id="password" value="hunter2secret"></label>
              <label>Card number <input autocomplete="cc-number" id="card" value="4242424242424242"></label>
              <label>CVC <input name="cvc" id="cvc" value="987"></label>
              <label><input type="checkbox" checked> Keep me signed in</label>
              <select id="country"><option>Belgium</option><option selected>France</option><option>Spain</option></select>
              <input type="hidden" name="csrf" value="csrf-token-value">
              <button>Pay €42.00</button>
            </form>
            <input id="loose" placeholder="Coupon">
            <p style="display:none">HIDDEN-DISPLAY</p>
            <p style="visibility:hidden">HIDDEN-VISIBILITY</p>
            <p style="opacity:0">HIDDEN-OPACITY</p>
            <p aria-hidden="true">HIDDEN-ARIA</p>
            <p style="position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0,0,0,0)">HIDDEN-CLIPPED</p>
            <p style="font-size:4px">HIDDEN-TINY</p>
            """),
        "/toggle": (Self.html, """
            <title>Toggle</title>
            <input type="password" id="secret" value="toggled-secret">
            <div id="host"></div>
            <script>
              document.getElementById('secret').type = 'text';
              const root = document.getElementById('host').attachShadow({ mode: 'open' });
              root.innerHTML = '<input type="password" id="inner" value="shadow-secret">';
            </script>
            """),
        "/frames": (Self.html, """
            <title>Frames</title><style>body { margin: 0 } iframe { position: absolute; border: 3px solid black; padding: 5px; width: 300px; height: 200px }</style>
            <button id="top">Top</button>
            <iframe id="same" src="/child?same" style="left: 100px; top: 50px"></iframe>
            <iframe id="other" style="left: 450px; top: 50px"></iframe>
            <script>document.getElementById('other').src = \(otherOrigin) + '/child?other';</script>
            """),
        "/child?same": (Self.html, """
            <style>body { margin: 0 }</style><button style="position:absolute;left:10px;top:20px;width:80px;height:30px">Same</button>
            <input type="password" value="hunter2secret" style="position:absolute;left:10px;top:100px;width:120px;height:20px">
            """),
        "/child?other": (Self.html, """
            <style>body { margin: 0 }</style><button style="position:absolute;left:10px;top:20px;width:80px;height:30px">Other</button>
            """),
        "/shadow": (Self.html, """
            <title>Shadow</title>
            <div id="open"></div><closed-widget id="closed" style="display:block;width:120px;height:40px"></closed-widget>
            <script>
              document.getElementById('open').attachShadow({ mode: 'open' }).innerHTML = '<button>Inside open</button>';
              document.getElementById('closed').attachShadow({ mode: 'closed' }).innerHTML = '<button>Inside closed</button>';
            </script>
            """),
        "/list": (Self.html, """
            <title>List</title><style>body { margin: 0 }</style>
            <div id="list"><button id="a">Alpha</button><button id="b">Beta</button><button id="c">Gamma</button></div>
            <input id="field" value="one">
            """),
        "/extension": (Self.html, """
            <title>Extension</title><style>body { margin: 0; background: rgb(255, 0, 0) }</style>
            <p>Page text</p>
            <com-1password-menu style="display:block;position:absolute;left:0;top:200px;width:200px;height:100px;background:white"><button>1P SECRET MENU</button></com-1password-menu>
            <iframe src="webkit-extension://abcdef/menu.html" style="position:absolute;left:300px;top:200px;width:100px;height:100px"></iframe>
            """),
        "/challenge": (Self.html, """
            <title>Just a moment...</title><div id="challenge-stage">Checking your browser before accessing the site.</div>
            <script src="/cdn-cgi/challenge-platform/h/b/orchestrate/chl_page/v1"></script>
            """),
        "/later": (Self.html, """
            <title>Later</title><button id="go">Going</button><p id="stays">Stays</p>
            <script>
              setTimeout(() => { document.body.insertAdjacentHTML('beforeend', '<p>Order confirmed</p>'); document.getElementById('go').style.display = 'none'; document.getElementById('stays').remove(); }, 300);
            </script>
            """),
        "/moving-on": (Self.html, "<title>Moving on</title><script>setTimeout(() => { location.href = '/arrived'; }, 200);</script>"),
        "/arrived": (Self.html, "<title>Arrived</title><p>Welcome aboard</p>"),
        "/many": (Self.html, "<title>Many</title><style>body { margin: 0 } button { display: block; height: 20px }</style>"
            + (1...1000).map { "<button>Item \($0)</button>" }.joined()
            + "<p>\(String(repeating: "needle ", count: 60))</p><button>\(String(repeating: "Long name ", count: 20))</button>"),
        "/article": (Self.html, """
            <title>Article</title><nav>Menu Home About</nav>
            <article><h1>Big news</h1><p>The first paragraph of the story, long enough to be the content. \(String(repeating: "More words follow here. ", count: 30))</p>
            <ul><li>One point</li><li>Another point</li></ul><p>Read <a href="/more">more</a>.</p><input value="typed-value"></article>
            <footer>Footer links</footer>
            """),
        "/covered": (Self.html, """
            <title>Covered</title><style>body { margin: 0 }</style>
            <button id="under" style="position:absolute;left:20px;top:20px;width:100px;height:40px">Accept</button>
            <div id="cookie-banner" style="position:fixed;left:0;top:0;width:400px;height:100px;background:white">We use cookies</div>
            <a href="/one" style="position:absolute;top:200px">First link</a><a href="https://example.org/two" style="position:absolute;top:240px">Second link</a>
            """),
        "/geometry": (Self.html, """
            <title>Geometry</title><style>body { margin: 0; background: white }</style>
            <div id="red" role="button" aria-label="Red" style="position:absolute;left:100px;top:50px;width:100px;height:100px;background:rgb(255,0,0)"></div>
            <input type="password" value="hunter2secret" style="position:absolute;left:300px;top:50px;width:200px;height:40px;background:rgb(0,0,255);border:0">
            <div style="height:3000px"></div>
            <input type="password" value="hunter2secret" style="position:absolute;left:0;top:2500px;width:400px;height:100px;background:rgb(0,0,255);border:0">
            """),
        "/pay": (Self.html, """
            <title>Pay</title><style>body { margin: 0; background: white }</style>
            <iframe id="card" style="position:absolute;left:100px;top:100px;width:300px;height:200px;border:0"></iframe>
            <script>document.getElementById('card').src = \(otherOrigin) + '/card';</script>
            """),
        "/card": (Self.html, """
            <style>body { margin: 0; background: rgb(0, 0, 255) }</style>
            <input autocomplete="cc-number" value="4242 4242 4242 4242" style="position:absolute;left:10px;top:10px;width:200px;height:30px">
            """),
        "/table": (Self.html, """
            <title>Table</title>
            <table>
              <tr><td></td><td></td></tr>
              <tr><td>Story one</td><td>12 points<span style="opacity:0">IGNORE-ROW-OPACITY</span></td></tr>
              <tr style="height:5px"></tr>
              <tr><td>Story two</td><td><span aria-hidden="true">IGNORE-ROW-ARIA</span>3 points</td></tr>
            </table>
            <p>See <a href="/one">the <span style="position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0,0,0,0)">IGNORE-LINK-CLIPPED</span>docs<span style="font-size:4px">IGNORE-LINK-TINY</span></a>.</p>
            """),
        "/controls": (Self.html, """
            <title>Controls</title>
            <input id="name" value="one"><input type="checkbox" id="agree" aria-label="Agree">
            <select id="pick"><option>A</option><option>B</option></select>
            """),
        "/widgets": (Self.html, """
            <title>Widgets</title><p>A healthy page</p>
            <iframe src="https://challenges.cloudflare.com/cdn-cgi/challenge-platform/h/g/turnstile/if/ov2" srcdoc="<p>t</p>" style="width:0;height:0;border:0"></iframe>
            <iframe src="https://geo.captcha-delivery.com/captcha/?initialCid=x" srcdoc="<p>d</p>" style="width:300px;height:300px;visibility:hidden"></iframe>
            <iframe src="https://newassets.hcaptcha.com/captcha/v1/abc/static/hcaptcha.html" srcdoc="<p>h</p>" style="width:300px;height:80px;display:none"></iframe>
            """),
        "/turnstile": (Self.html, """
            <title>Sign in</title><p>Sign in</p>
            <iframe src="https://challenges.cloudflare.com/cdn-cgi/challenge-platform/h/g/turnstile/if/ov2" srcdoc="<p>t</p>" style="width:300px;height:65px"></iframe>
            """),
        "/datadome": (Self.html, """
            <title>Shop</title>
            <iframe src="https://geo.captcha-delivery.com/captcha/?initialCid=x" srcdoc="<p>d</p>" style="width:400px;height:400px"></iframe>
            """),
        "/long": (Self.html, """
            <title>Long</title><style>body { margin: 0; background: white }</style>
            <input type="password" value="hunter2secret" style="position:absolute;left:0;top:10000px;width:400px;height:100px;background:rgb(0,0,255);border:0">
            <div style="position:absolute;left:0;top:11900px;width:1280px;height:100px;background:rgb(255,0,0)"></div>
            """),
        "/chart": (Self.html, """
            <title>Chart</title>
            <svg width="300" height="100"><a href="one"><rect width="100" height="40" fill="red"></rect><text x="10" y="30">Bar one</text></a></svg>
            <p><a href="/help">Help</a></p>
            """),
        "/help": (Self.html, "<title>Help</title><p>help</p>"),
        "/one": (Self.html, "<title>One</title><p>one</p>"),
    ]

    private func withAgent(_ body: (Client, URL) async throws -> Void) async throws {
        UserDefaults.standard.removeObject(forKey: Preference.agentAccess)
        let (listener, base) = try await LocalHTTP.serve(Self.pages)
        defer { listener.cancel() }
        let browser = Browser()
        await browser.privacy.waitUntilReady()
        await browser.extensions.waitUntilLoaded()
        await browser.setAgentAccess(true)
        var failure: (any Error)?
        do { try await body(try await Client(browser: browser), base) } catch { failure = error }
        browser.tabs.forEach(browser.close)
        await browser.setAgentAccess(false)
        if let failure { throw failure }
    }

    /// Opens `path` in an agent tab, loaded.
    private func open(_ client: Client, _ base: URL, _ path: String) async throws -> String {
        let opened = await client.call("tab_open", ["url": .string(base.absoluteString + path.dropFirst()), "wait": "load"])
        #expect(!opened.isError, "\(opened.message)")
        return try #require(opened["tab"]?.string)
    }

    private func nodes(_ result: AgentTabsTests.ToolResult) -> [JSONValue] {
        items(result["nodes"])
    }

    private func items(_ value: JSONValue?) -> [JSONValue] {
        if case .array(let items) = value { return items }
        return []
    }

    private func node(_ result: AgentTabsTests.ToolResult, role: String, name: String) -> JSONValue? {
        nodes(result).first { $0["role"] == .string(role) && ($0["name"] ?? "") == .string(name) }
    }

    private func text(_ value: JSONValue?) -> String {
        guard let value else { return "" }
        return String(decoding: value.encoded(), as: UTF8.self)
    }

    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    // MARK: Snapshot

    @Test func snapshotNamesRolesValuesAndStatesAndNeverShowsSecrets() async throws {
        try await withAgent { client, base in
            let tab = try await open(client, base, "/form")
            let json = await client.call("snapshot", ["tab": .string(tab), "format": "json"])
            #expect(!json.isError, "\(json.message)")
            #expect(json["title"] == "Checkout")
            #expect(json["seq"] == 1)
            #expect(node(json, role: "heading", name: "Checkout")?["level"] == 1, "\(text(json.content))")
            #expect(node(json, role: "text", name: "3 items · €42.00") != nil)
            #expect(node(json, role: "link", name: "Help")?["href"] == "/help")
            let email = try #require(node(json, role: "textbox", name: "Email"))
            #expect(email["value"] == "ann@example.com")
            #expect(email["state"] == ["required"])
            let password = try #require(node(json, role: "textbox", name: "Password"))
            #expect(password["value"] == "[redacted]")
            #expect(password["filled"] == true)
            #expect(password["guard"] == "password")
            let card = try #require(node(json, role: "textbox", name: "Card number"))
            #expect(card["value"] == "•••• 4242")
            #expect(card["guard"] == "payment")
            #expect(node(json, role: "textbox", name: "CVC")?["value"] == "[redacted]")
            #expect(node(json, role: "checkbox", name: "Keep me signed in")?["state"] == ["checked"])
            let country = try #require(nodes(json).first { $0["role"] == "combobox" })
            #expect(country["value"] == "France")
            #expect(country["options"] == 3)
            #expect(node(json, role: "button", name: "Pay €42.00") != nil)
            #expect(node(json, role: "form", name: "") == nil)

            let snapshot = await client.call("snapshot", ["tab": .string(tab)])
            let lines = try #require(snapshot["text"]?.string).components(separatedBy: "\n")
            #expect(lines[0].hasPrefix("\(tab) \(base.absoluteString)form \"Checkout\" seq 1 · viewport "))
            #expect(lines.contains { $0.wholeMatch(of: /\[e\d+\] textbox "Password" = \[redacted\] filled guard:password @\d+,\d+ \d+x\d+/) != nil })
            #expect(lines.contains { $0.wholeMatch(of: /\[e\d+\] textbox "Card number" = "•••• 4242" filled guard:payment @\d+,\d+ \d+x\d+/) != nil })

            let forms = await client.call("forms", ["tab": .string(tab)])
            #expect(!forms.isError, "\(forms.message)")
            let form = try #require(forms["forms"].flatMap { if case .array(let forms) = $0 { forms.first } else { nil } })
            #expect(form["action"] == "pay.example")
            #expect(form["method"] == "post")
            #expect(form["name"] == "pay")
            let fields = try #require(form["fields"].flatMap { if case .array(let fields) = $0 { fields } else { nil } })
            #expect(fields.map { $0["name"] } == ["Email", "Password", "Card number", "CVC", "Keep me signed in", ""].map { .string($0) })
            #expect(fields[1]["value"] == "[redacted]")
            #expect(fields[5]["options"] == [["label": "Belgium"], ["label": "France", "selected": true], ["label": "Spain"]])
            #expect(text(form["submits"]).contains("\"e"))
            #expect(text(forms["fieldsOutsideForms"]).contains("Coupon"))

            let everything = [text(json.content), text(snapshot.content), text(forms.content)].joined()
            for secret in Self.secrets + ["csrf-token-value"] {
                #expect(!everything.contains(secret), "\(secret) leaked")
            }
            for hidden in ["HIDDEN-DISPLAY", "HIDDEN-VISIBILITY", "HIDDEN-OPACITY", "HIDDEN-ARIA", "HIDDEN-CLIPPED", "HIDDEN-TINY"] {
                #expect(!everything.contains(hidden), "\(hidden) is hidden")
            }
            let logged = String(decoding: await client.hub.log.export(), as: UTF8.self)
            #expect(logged.contains("\"tool\":\"forms\""))
            for secret in Self.secrets { #expect(!logged.contains(secret)) }
        }
    }

    @Test func aFieldThatWasEverAPasswordStaysRedacted() async throws {
        try await withAgent { client, base in
            let tab = try await open(client, base, "/toggle")
            let json = await client.call("snapshot", ["tab": .string(tab), "format": "json"])
            let fields = nodes(json).filter { $0["role"] == "textbox" }
            #expect(fields.count == 2)
            #expect(fields.allSatisfy { $0["value"] == "[redacted]" && $0["guard"] == "password" })
            let forms = await client.call("forms", ["tab": .string(tab)])
            for secret in Self.secrets { #expect(!text(json.content).contains(secret) && !text(forms.content).contains(secret)) }
        }
    }

    @Test func framesOfBothOriginsShowInPlaceWithTheirOwnRefs() async throws {
        try await withAgent { client, base in
            let tab = try await open(client, base, "/frames")
            let named = try #require(client.tab(tab))
            // Both frames have said hello once their buttons are there.
            var json = await client.call("snapshot", ["tab": .string(tab), "format": "json"])
            for _ in 0..<100 where node(json, role: "button", name: "Other") == nil || node(json, role: "button", name: "Same") == nil {
                try await Task.sleep(for: .milliseconds(50))
                json = await client.call("snapshot", ["tab": .string(tab), "format": "json"])
            }
            let frames = nodes(json).filter { $0["role"] == "frame" }
            try #require(frames.count == 2, "\(text(json.content))")
            #expect(frames.allSatisfy { $0["ref"]?.string?.wholeMatch(of: /f\d+/) != nil })
            #expect(frames[0]["box"] == [100, 50, 316, 216])
            #expect(frames[0]["origin"] == .string("http://127.0.0.1:\(base.port!)"))
            #expect(frames[1]["origin"] == .string("http://localhost:\(base.port!)"))
            let same = try #require(node(json, role: "button", name: "Same"))
            let other = try #require(node(json, role: "button", name: "Other"))
            // The content box: the iframe's place, plus 3 px of border and 5 px of padding.
            #expect(same["box"] == [118, 78, 80, 30])
            #expect(other["box"] == [468, 78, 80, 30])
            #expect(same["in"] == frames[0]["ref"])
            #expect(other["in"] == frames[1]["ref"])
            let sameRef = try #require(same["ref"]?.string)
            #expect(sameRef.hasPrefix(frames[0]["ref"]!.string! + ":e"))
            #expect(node(json, role: "textbox", name: "")?["value"] == "[redacted]")
            #expect(!text(json.content).contains("hunter2secret"))

            let info = await client.call("element_info", ["tab": .string(tab), "ref": .string(sameRef)])
            #expect(!info.isError, "\(info.message)")
            #expect(info["box"]?["css"] == [118, 78, 80, 30])
            #expect(info["visible"] == true)
            #expect(info["inViewport"] == true)
            #expect(named.loadedWebView != nil)

            let links = await client.call("find_text", ["tab": .string(tab), "text": "other"])
            #expect(links["count"] == 1)
            #expect(links["matches"].flatMap { if case .array(let matches) = $0 { matches.first?["in"] } else { nil } } == frames[1]["ref"])
        }
    }

    @Test func openShadowRootsAreReadAndClosedOnesShowAsTheirHost() async throws {
        try await withAgent { client, base in
            let tab = try await open(client, base, "/shadow")
            let json = await client.call("snapshot", ["tab": .string(tab), "format": "json"])
            #expect(node(json, role: "button", name: "Inside open") != nil)
            #expect(node(json, role: "shadow-closed", name: "closed-widget")?["box"]?.encoded() != nil)
            #expect(!text(json.content).contains("Inside closed"))
        }
    }

    @Test func refsStayAsTheDocumentChangesAndDiffsSayWhat() async throws {
        try await withAgent { client, base in
            let tab = try await open(client, base, "/list")
            let first = await client.call("snapshot", ["tab": .string(tab), "format": "json"])
            let alpha = try #require(node(first, role: "button", name: "Alpha")?["ref"])
            let beta = try #require(node(first, role: "button", name: "Beta")?["ref"])
            let gamma = try #require(node(first, role: "button", name: "Gamma")?["ref"])
            let field = try #require(node(first, role: "textbox", name: "")?["ref"])
            let page = try #require(client.tab(tab)?.webView)
            _ = try await page.callAsyncJavaScript("""
                const list = document.getElementById('list');
                list.insertAdjacentHTML('afterbegin', '<button>Delta</button>');
                const box = document.createElement('section');
                box.append(document.getElementById('b'));
                document.body.append(box);
                document.getElementById('c').remove();
                document.getElementById('field').value = 'two';
                document.getElementById('a').style.marginTop = '30px';
                """, contentWorld: .page)
            let diff = await client.call("snapshot", ["tab": .string(tab), "since": 1, "format": "json"])
            #expect(diff["seq"] == 2)
            #expect(diff["since"] == 1)
            #expect(text(diff["added"]).contains("Delta"))
            #expect(diff["removed"] == [gamma])
            #expect(items(diff["changed"]).compactMap { $0["ref"] } == [field])
            let after = await client.call("snapshot", ["tab": .string(tab), "format": "json"])
            #expect(node(after, role: "button", name: "Alpha")?["ref"] == alpha)
            #expect(node(after, role: "button", name: "Beta")?["ref"] == beta)
            #expect(node(after, role: "textbox", name: "")?["value"] == "two")

            let unchanged = await client.call("snapshot", ["tab": .string(tab), "since": 2])
            #expect(unchanged["seq"] == 2)
            #expect(unchanged["text"]?.string?.hasSuffix("\nno changes") == true)

            let gone = await client.call("element_info", ["tab": .string(tab), "ref": gamma])
            #expect(gone.code == "stale_ref")
            #expect(gone.message.contains("button \"Gamma\" was removed"))
            #expect(await client.call("element_info", ["tab": .string(tab), "ref": "e99999"]).code == "stale_ref")
            #expect(await client.call("element_info", ["tab": .string(tab), "ref": "button"]).code == "invalid_params")

            // A ref from the page before never names an element of the next.
            _ = await client.call("navigate", ["tab": .string(tab), "url": .string(base.absoluteString + "list")])
            #expect(await client.call("element_info", ["tab": .string(tab), "ref": alpha]).code == "stale_ref")
            let again = await client.call("snapshot", ["tab": .string(tab), "format": "json"])
            #expect(node(again, role: "button", name: "Alpha")?["ref"] != alpha)
        }
    }

    @Test func navigationsAndWaitsAnswerWithWhatChanged() async throws {
        try await withAgent { client, base in
            let tab = try await open(client, base, "/list")
            let first = await client.call("navigate", ["tab": .string(tab), "url": .string(base.absoluteString + "form")])
            let diff = try #require(first["diff"]?.string)
            #expect(diff.hasPrefix("\(tab) \(base.absoluteString)form \"Checkout\" seq 1"))
            #expect(diff.contains("button \"Pay €42.00\""))
            #expect(!diff.contains("hunter2secret"))
            let reload = await client.call("reload", ["tab": .string(tab)])
            // A reload is a new document, whose nodes all have new refs: the whole snapshot comes.
            let reloaded = try #require(reload["diff"]?.string)
            #expect(reloaded.hasPrefix("\(tab) \(base.absoluteString)form \"Checkout\" seq 2 · viewport"))
            #expect(!reloaded.contains(" · since "))
            #expect(reloaded.contains("button \"Pay €42.00\""))
            let waited = await client.call("wait_for", ["tab": .string(tab), "load": "load"])
            #expect(waited["diff"]?.string?.hasSuffix("seq 2 · viewport 1280x800 scroll 0,0 · page 1280x800 · since 2\nno changes") == true, "\(waited["diff"]?.string ?? "")")
            // A page snapshot shows nodes the default view leaves out: diffs never compare the two.
            _ = await client.call("navigate", ["tab": .string(tab), "url": .string(base.absoluteString + "many"), "diff": false])
            #expect(await client.call("snapshot", ["tab": .string(tab), "scope": "page", "maxNodes": 2000])["seq"] == 3)
            let afterWhole = try #require(await client.call("wait_for", ["tab": .string(tab), "text": "Item 1"])["diff"]?.string)
            #expect(!afterWhole.contains(" · since ") && !afterWhole.contains("\n- "), "\(afterWhole.prefix(300))")
            let again = await client.call("snapshot", ["tab": .string(tab), "scope": "page", "maxNodes": 2000, "since": 3])
            #expect(again["seq"] == 3)
            #expect(again["text"]?.string?.hasSuffix(" · since 3\nno changes") == true, "\(again["text"]?.string?.prefix(300) ?? "")")
            let quiet = await client.call("navigate", ["tab": .string(tab), "url": .string(base.absoluteString + "list"), "diff": false])
            #expect(quiet["diff"] == nil)
            #expect(await client.call("navigate", ["tab": .string(tab), "url": .string(base.absoluteString + "list"), "diff": "yes"]).code == "invalid_params")
        }
    }

    // MARK: Extension UI and challenges

    @Test func passwordManagerUIIsLeftOutAndPaintedOver() async throws {
        try await withAgent { client, base in
            let tab = try await open(client, base, "/extension")
            let json = await client.call("snapshot", ["tab": .string(tab), "format": "json"])
            #expect(node(json, role: "text", name: "Page text") != nil, "\(text(json.content))")
            #expect(!text(json.content).contains("1P SECRET MENU"))
            #expect(nodes(json).filter { $0["role"] == "frame" }.isEmpty, "\(text(json.content))")
            let found = await client.call("find_text", ["tab": .string(tab), "text": "1P SECRET"])
            #expect(found["count"] == 0)
            let shot = await client.call("screenshot", ["tab": .string(tab)])
            #expect(!shot.isError, "\(shot.message)")
            let masked = text(shot["masked"])
            #expect(shot["masked"].map { if case .array(let rects) = $0 { rects.count } else { 0 } } == 2, "\(masked)")
        }
    }

    @Test func aChallengePageStopsReadsAndAsksForTheUser() async throws {
        try await withAgent { client, base in
            let tab = try await open(client, base, "/challenge")
            let read = await client.call("read_text", ["tab": .string(tab)])
            #expect(read.code == "challenge_requires_user")
            #expect(read.message.contains("Cloudflare check"))
            #expect(read.message.contains("ask the user"))
            for tool in ["links", "forms"] {
                #expect(await client.call(tool, ["tab": .string(tab)]).code == "challenge_requires_user")
            }
            let snapshot = await client.call("snapshot", ["tab": .string(tab), "format": "json"])
            #expect(snapshot["challenge"] == ["kind": "cloudflare", "page": true])
            let state = try #require(client.tab(tab).flatMap { client.hub.agentTab(for: $0) })
            #expect(state.challenge == AgentChallenge(kind: "cloudflare", page: true))
            // The user passes the check and the page moves on: no agent reads it again.
            let page = try #require(client.tab(tab)?.webView)
            _ = try await page.callAsyncJavaScript("location.href = '/one'", contentWorld: .page)
            #expect(await waitUntil(10) { state.challenge == nil })
        }
    }

    // MARK: Waiting

    @Test func waitsForElementsAndTextInThePage() async throws {
        try await withAgent { client, base in
            let tab = try await open(client, base, "/later")
            let first = await client.call("snapshot", ["tab": .string(tab), "format": "json"])
            let going = try #require(node(first, role: "button", name: "Going")?["ref"])
            let stays = try #require(node(first, role: "text", name: "Stays")?["ref"])
            let shown = await client.call("wait_for", ["tab": .string(tab), "text": "order   CONFIRMED"])
            #expect(!shown.isError, "\(shown.message)")
            #expect(shown["met"] == true)
            #expect(shown["diff"]?.string?.contains("+ ") == true)
            #expect(await client.call("wait_for", ["tab": .string(tab), "ref": going, "state": "hidden"])["met"] == true)
            #expect(await client.call("wait_for", ["tab": .string(tab), "ref": stays, "state": "detached"])["met"] == true)
            #expect(await client.call("wait_for", ["tab": .string(tab), "text": "Stays", "present": false])["met"] == true)
            let never = await client.call("wait_for", ["tab": .string(tab), "text": "Never here", "timeoutMs": 300])
            #expect(never.code == "timeout")
            #expect(await client.call("wait_for", ["tab": .string(tab), "ref": stays, "state": "visible", "timeoutMs": 300]).code == "stale_ref")
            #expect(await client.call("wait_for", ["tab": .string(tab), "ref": going, "state": "shown"]).code == "invalid_params")
            #expect(await client.call("wait_for", ["tab": .string(tab), "text": "a", "url": "*"]).code == "invalid_params")
            #expect(await client.call("wait_for", ["tab": .string(tab), "networkIdle": 500]).code == "unsupported")

            let moving = try await open(client, base, "/moving-on")
            let arrived = await client.call("wait_for", ["tab": .string(moving), "text": "Welcome aboard"])
            #expect(!arrived.isError, "\(arrived.message)")
            #expect(arrived["title"] == "Arrived")
        }
    }

    // MARK: Sizes

    @Test func snapshotsAndReadsKeepToTheirSizes() async throws {
        try await withAgent { client, base in
            let tab = try await open(client, base, "/many")
            // The viewport, 800 pixels high, and as much again below: 80 buttons of 20 pixels.
            let viewport = await client.call("snapshot", ["tab": .string(tab), "format": "json"])
            #expect(nodes(viewport).count == 80)
            #expect(viewport["truncated"] == nil)
            let json = await client.call("snapshot", ["tab": .string(tab), "format": "json", "scope": "page"])
            #expect(nodes(json).count == 300)
            #expect(json["truncated"] == true)
            #expect(json["dropped"] == 702)
            #expect(node(json, role: "button", name: "Item 1") != nil)
            #expect(node(json, role: "button", name: "Item 1000") == nil)
            let page = await client.call("snapshot", ["tab": .string(tab), "format": "json", "scope": "page", "maxNodes": 2000])
            #expect(nodes(page).count == 1002)
            let long = try #require(nodes(page).last { $0["role"] == "button" }?["name"]?.string)
            #expect(long.count == 80)
            #expect(long.hasSuffix("…"))
            #expect(await client.call("snapshot", ["tab": .string(tab), "maxNodes": 5000]).code == "invalid_params")
            let read = await client.call("read_text", ["tab": .string(tab), "maxChars": 100, "main": false])
            #expect(read["text"]?.string?.count == 100)
            #expect(read["truncated"] == true)
            let found = await client.call("find_text", ["tab": .string(tab), "text": "NEEDLE"])
            #expect(found["count"] == 60)
            #expect(found["matches"].map { if case .array(let matches) = $0 { matches.count } else { 0 } } == 50)
            #expect(found["matches"].flatMap { if case .array(let matches) = $0 { matches.first?["context"]?.string?.count } else { nil } } == 80)
            #expect(await client.call("find_text", ["tab": .string(tab), "text": "NEEDLE", "caseSensitive": true])["count"] == 0)
        }
    }

    // MARK: Reading

    @Test func readTextKeepsToTheContentAndLeavesValuesOut() async throws {
        try await withAgent { client, base in
            let tab = try await open(client, base, "/article")
            let main = try #require(await client.call("read_text", ["tab": .string(tab)])["text"]?.string)
            #expect(main.hasPrefix("Big news\nThe first paragraph of the story"))
            #expect(!main.contains("Menu Home"))
            #expect(!main.contains("Footer links"))
            #expect(!main.contains("typed-value"))
            let whole = try #require(await client.call("read_text", ["tab": .string(tab), "main": false])["text"]?.string)
            #expect(whole.hasPrefix("Menu Home About\nBig news"))
            let markdown = try #require(await client.call("read_text", ["tab": .string(tab), "format": "markdown"])["text"]?.string)
            #expect(markdown.hasPrefix("# Big news\n"))
            #expect(markdown.contains("\n- One point\n- Another point\n"))
            #expect(markdown.contains("Read [more](\(base.absoluteString)more) ."))
            let snapshot = await client.call("snapshot", ["tab": .string(tab), "format": "json"])
            let heading = try #require(node(snapshot, role: "heading", name: "Big news")?["ref"])
            #expect(await client.call("read_text", ["tab": .string(tab), "ref": heading])["text"] == "Big news")
        }
    }

    @Test func linksAndCoveringElementsAreNamed() async throws {
        try await withAgent { client, base in
            let tab = try await open(client, base, "/covered")
            let links = await client.call("links", ["tab": .string(tab)])
            #expect(text(links["links"]).contains(#""href":"\#(base.absoluteString)one","ref":"e"#))
            #expect(links["count"] == 2)
            let filtered = await client.call("links", ["tab": .string(tab), "filter": "EXAMPLE.ORG"])
            #expect(filtered["count"] == 1)
            #expect(items(filtered["links"]).first?["text"] == "Second link")
            let snapshot = await client.call("snapshot", ["tab": .string(tab), "format": "json"])
            let accept = try #require(node(snapshot, role: "button", name: "Accept")?["ref"])
            let info = await client.call("element_info", ["tab": .string(tab), "ref": accept])
            #expect(info["visible"] == true)
            #expect(info["coveredBy"]?["element"] == "div#cookie-banner")
            #expect(info["coveredBy"]?["text"] == "We use cookies")
            #expect(info["box"]?["css"] == [20, 20, 100, 40])
        }
    }

    @Test func svgLinksAreListedWithTheirAddress() async throws {
        try await withAgent { client, base in
            let tab = try await open(client, base, "/chart")
            let links = await client.call("links", ["tab": .string(tab)])
            #expect(!links.isError, "\(links.message)")
            #expect(links["count"] == 2)
            let bar = try #require(items(links["links"]).first { $0["text"] == "Bar one" }, "\(text(links.content))")
            #expect(bar["href"] == .string(base.absoluteString + "one"))
            let filtered = await client.call("links", ["tab": .string(tab), "filter": "BAR"])
            #expect(!filtered.isError, "\(filtered.message)")
            #expect(items(filtered["links"]).compactMap { $0["text"] } == ["Bar one"])
            let markdown = await client.call("read_text", ["tab": .string(tab), "ref": try #require(bar["ref"]), "format": "markdown"])
            #expect(!markdown.isError, "\(markdown.message)")
            #expect(markdown["text"]?.string == "[Bar one](\(base.absoluteString)one)")
        }
    }

    @Test func aTabOpenBeforeAccessWasOnIsReadToo() async throws {
        UserDefaults.standard.removeObject(forKey: Preference.agentAccess)
        let (listener, base) = try await LocalHTTP.serve(Self.pages)
        defer { listener.cancel() }
        let browser = Browser()
        await browser.privacy.waitUntilReady()
        await browser.extensions.waitUntilLoaded()
        let mine = browser.newTab(url: base.appending(path: "one"))
        #expect(await waitUntil(20) { mine.title == "One" && !mine.isLoading })
        await browser.setAgentAccess(true)
        defer {
            browser.tabs.forEach(browser.close)
            Task { await browser.setAgentAccess(false) }
        }
        let client = try await Client(browser: browser)
        let listed = await client.call("tabs_list")
        let id = try #require(listed["tabs"].flatMap { if case .array(let tabs) = $0 { tabs.first?["tab"]?.string } else { nil } })
        let json = await client.call("snapshot", ["tab": .string(id), "format": "json"])
        #expect(!json.isError, "\(json.message)")
        #expect(node(json, role: "text", name: "one") != nil)
        #expect(!client.hub.isTouched(mine))
        await browser.setAgentAccess(false)
    }

    // MARK: Pictures

    @Test func screenshotsPaintOverPasswordsInTheViewportAndTheWholePage() async throws {
        try await withAgent { client, base in
            let tab = try await open(client, base, "/geometry")
            let shot = await client.call("screenshot", ["tab": .string(tab)])
            #expect(!shot.isError, "\(shot.message)")
            let image = try #require(Self.image(shot))
            let scale = try #require(shot["scale"].flatMap { if case .double(let value) = $0 { value } else if case .int(let value) = $0 { Double(value) } else { nil } })
            #expect(Self.near(Self.color(image, x: 150 * scale, y: 100 * scale), [255, 0, 0]))
            // The password field, blue in the page, is gray in the picture.
            #expect(Self.near(Self.color(image, x: 400 * scale, y: 70 * scale), [128, 128, 128]))
            let mask = items(shot["masked"]).first.map(items) ?? []
            let expected = [300, 50, 200, 40].map { Int(Double($0) * scale) }
            #expect(items(shot["masked"]).count == 1)
            #expect(mask.count == 4 && zip(mask, expected).allSatisfy { if case .int(let value) = $0 { abs(value - $1) <= 1 } else { false } }, "\(mask)")

            let full = await client.call("screenshot", ["tab": .string(tab), "fullPage": true, "maxWidth": 800])
            #expect(!full.isError, "\(full.message)")
            let page = try #require(Self.image(full))
            let fullScale = try #require(full["scale"].flatMap { if case .double(let value) = $0 { value } else { nil } })
            #expect(Self.near(Self.color(page, x: 200 * fullScale, y: 2550 * fullScale), [128, 128, 128]))
            #expect(Self.near(Self.color(page, x: 150 * fullScale, y: 100 * fullScale), [255, 0, 0]))
            #expect(full["masked"].map { if case .array(let rects) = $0 { rects.count } else { 0 } } == 2)

            let snapshot = await client.call("snapshot", ["tab": .string(tab), "format": "json"])
            let red = try #require(node(snapshot, role: "button", name: "Red")?["ref"])
            let element = await client.call("screenshot", ["tab": .string(tab), "ref": red])
            let elementScale = try #require(element["scale"].flatMap { if case .double(let value) = $0 { value } else if case .int(let value) = $0 { Double(value) } else { nil } })
            #expect(element["width"] == .int(Int((100 * elementScale).rounded())))
            #expect(Self.near(Self.color(try #require(Self.image(element)), x: 10, y: 10), [255, 0, 0]))

            let pdf = await client.call("pdf", ["tab": .string(tab)])
            #expect(!pdf.isError, "\(pdf.message)")
            #expect(pdf["maskedRegions"] == 2)
            let resource = try #require(pdf.result?["content"].flatMap { if case .array(let items) = $0 { items.last?["resource"] } else { nil } })
            #expect(resource["mimeType"] == "application/pdf")
            let data = try #require(resource["blob"]?.string.flatMap { Data(base64Encoded: $0) })
            #expect(data.starts(with: Data("%PDF".utf8)))
        }
    }

    /// Design item 25: CSS pixels map to the view through the visual viewport, then pageZoom.
    @Test func boxesFollowPageZoomAndMagnification() async throws {
        try await withAgent { client, base in
            let tab = try await open(client, base, "/geometry")
            let webView = try #require(client.tab(tab)?.webView)
            let snapshot = await client.call("snapshot", ["tab": .string(tab), "format": "json"])
            let red = try #require(node(snapshot, role: "button", name: "Red")?["ref"])
            webView.pageZoom = 1.5
            var info = await client.call("element_info", ["tab": .string(tab), "ref": red])
            #expect(info["box"]?["css"] == [100, 50, 100, 100])
            #expect(info["box"]?["view"] == [150, 75, 150, 150])
            var shot = try #require(Self.image(await client.call("screenshot", ["tab": .string(tab)])))
            var pixels = Double(shot.width) / webView.bounds.width
            #expect(Self.near(Self.color(shot, x: 155 * pixels, y: 80 * pixels), [255, 0, 0]))
            #expect(Self.near(Self.color(shot, x: 145 * pixels, y: 80 * pixels), [255, 255, 255]))
            webView.pageZoom = 1
            webView.setMagnification(2, centeredAt: .zero)
            #expect(await waitUntil(5) { webView.magnification == 2 })
            info = await client.call("element_info", ["tab": .string(tab), "ref": red])
            #expect(info["box"]?["view"] == [200, 100, 200, 200])
            shot = try #require(Self.image(await client.call("screenshot", ["tab": .string(tab)])))
            pixels = Double(shot.width) / webView.bounds.width
            #expect(Self.near(Self.color(shot, x: 205 * pixels, y: 105 * pixels), [255, 0, 0]))
            #expect(Self.near(Self.color(shot, x: 195 * pixels, y: 105 * pixels), [255, 255, 255]))
        }
    }

    @Test func framesThatNeverAnsweredArePaintedOverWhole() async throws {
        UserDefaults.standard.removeObject(forKey: Preference.agentAccess)
        let (listener, base) = try await LocalHTTP.serve(Self.pages)
        defer { listener.cancel() }
        let browser = Browser()
        await browser.privacy.waitUntilReady()
        await browser.extensions.waitUntilLoaded()
        // Open before access was on: its payment frame, of another origin, never said hello.
        let mine = browser.newTab(url: base.appending(path: "pay"))
        #expect(await waitUntil(20) { mine.title == "Pay" && !mine.isLoading })
        await browser.setAgentAccess(true)
        var failure: (any Error)?
        do {
            let client = try await Client(browser: browser)
            let id = client.hub.id(for: mine)
            let shot = await client.call("screenshot", ["tab": .string(id)])
            #expect(!shot.isError, "\(shot.message)")
            let image = try #require(Self.image(shot))
            let scale = Self.number(shot["scale"])
            // The frame's middle, blue in the page, and its card field are gray; the page around isn't.
            #expect(Self.near(Self.color(image, x: 250 * scale, y: 250 * scale), [128, 128, 128]))
            #expect(Self.near(Self.color(image, x: 150 * scale, y: 125 * scale), [128, 128, 128]))
            #expect(Self.near(Self.color(image, x: 50 * scale, y: 50 * scale), [255, 255, 255]))
            #expect(items(shot["masked"]).count == 1)
            #expect(await client.call("pdf", ["tab": .string(id)])["maskedRegions"] == 1)
        } catch { failure = error }
        browser.tabs.forEach(browser.close)
        await browser.setAgentAccess(false)
        if let failure { throw failure }
    }

    @Test func lateFramesAreLeftOutAndStopOrTheUserEndTheRead() async throws {
        try await withAgent { client, base in
            let tab = try await open(client, base, "/frames")
            let named = try client.hub.tab(named: tab)
            let state = try #require(client.hub.agentTab(for: named.tab))
            #expect(await waitUntil(10) { state.frames.count >= 2 })
            let token = try #require(state.frames.keys.first)
            let silent = [(token: token, answer: PageAnswer<Data>())]
            let started = ContinuousClock.now
            let read = try await client.hub.childAnswers(silent, of: state, from: named, until: .now + AgentHub.readTimeout)
            #expect(read.late == 1)
            #expect(read.answers.isEmpty)
            #expect(ContinuousClock.now - started < AgentHub.frameTimeout + .seconds(1))
            for (interruption, code) in [(AgentInterruption.agentStop, "stopped"), (.user, "user_interrupted")] {
                Task {
                    try? await Task.sleep(for: .milliseconds(200))
                    state.interruption = interruption
                }
                do {
                    _ = try await client.hub.childAnswers(silent, of: state, from: named, until: .now + AgentHub.readTimeout)
                    Issue.record("\(code) didn’t end the read")
                } catch let error as AgentToolError {
                    #expect(error.code == code)
                }
                state.interruption = nil
            }
        }
    }

    @Test func framesComeBackWhenBackRestoresAPage() async throws {
        try await withAgent { client, base in
            let tab = try await open(client, base, "/frames")
            var json = await client.call("snapshot", ["tab": .string(tab), "format": "json"])
            for _ in 0..<100 where node(json, role: "button", name: "Other") == nil || node(json, role: "button", name: "Same") == nil {
                try await Task.sleep(for: .milliseconds(50))
                json = await client.call("snapshot", ["tab": .string(tab), "format": "json"])
            }
            let same = try #require(node(json, role: "button", name: "Same")?["ref"])
            _ = await client.call("navigate", ["tab": .string(tab), "url": .string(base.absoluteString + "one")])
            let back = await client.call("go_back", ["tab": .string(tab), "wait": "load"])
            #expect(!back.isError, "\(back.message)")
            // WebKit's cache brought the page back as it was, without running document-start scripts.
            let restored = await client.call("snapshot", ["tab": .string(tab), "format": "json"])
            #expect(!restored.isError, "\(restored.message)")
            #expect(node(restored, role: "button", name: "Same")?["ref"] == same, "\(text(restored.content))")
            #expect(node(restored, role: "button", name: "Other") != nil)
            #expect(await client.call("element_info", ["tab": .string(tab), "ref": same])["visible"] == true)
        }
    }

    @Test func invisibleChallengeFramesLeaveThePageAlone() async throws {
        try await withAgent { client, base in
            let healthy = try await open(client, base, "/widgets")
            let state = { (id: String) in client.tab(id).flatMap { client.hub.agentTab(for: $0) } }
            for tool in ["read_text", "links", "forms"] {
                let read = await client.call(tool, ["tab": .string(healthy)])
                #expect(!read.isError, "\(tool): \(read.message)")
            }
            #expect(await client.call("snapshot", ["tab": .string(healthy), "format": "json"])["challenge"] == nil)
            #expect(state(healthy)?.challenge == nil)

            let signIn = try await open(client, base, "/turnstile")
            #expect(!(await client.call("read_text", ["tab": .string(signIn)])).isError)
            #expect(state(signIn)?.challenge == AgentChallenge(kind: "turnstile", page: false))
            let shop = try await open(client, base, "/datadome")
            #expect(await client.call("read_text", ["tab": .string(shop)]).code == "challenge_requires_user")
        }
    }

    @Test func tableRowsAndLinksReadOnlyVisibleText() async throws {
        try await withAgent { client, base in
            let tab = try await open(client, base, "/table")
            let markdown = await client.call("read_text", ["tab": .string(tab), "format": "markdown", "main": false])
            #expect(!markdown.isError, "\(markdown.message)")
            #expect(markdown["text"]?.string == "| Story one | 12 points |\n| Story two | 3 points |\nSee [the docs](\(base.absoluteString)one) .")
            let plain = await client.call("read_text", ["tab": .string(tab), "main": false])
            #expect(plain["text"]?.string == "Story one | 12 points\nStory two | 3 points\nSee the docs.")
            #expect(await client.call("find_text", ["tab": .string(tab), "text": "IGNORE"])["count"] == 0)
        }
    }

    @Test func valuesSetByPageScriptsShowInDiffs() async throws {
        try await withAgent { client, base in
            let tab = try await open(client, base, "/controls")
            let first = await client.call("snapshot", ["tab": .string(tab), "format": "json"])
            let refs = try ["textbox", "checkbox", "combobox"].map { role in try #require(nodes(first).first { $0["role"] == .string(role) }?["ref"]?.string) }
            // Setting properties fires no event and changes no attribute.
            _ = try await client.tab(tab)?.webView.callAsyncJavaScript("""
                document.getElementById('name').value = 'two';
                document.getElementById('agree').checked = true;
                document.getElementById('pick').selectedIndex = 1;
                """, contentWorld: .page)
            let diff = await client.call("snapshot", ["tab": .string(tab), "since": 1, "format": "json"])
            #expect(diff["seq"] == 2)
            #expect(Set(items(diff["changed"]).compactMap { $0["ref"]?.string }) == Set(refs), "\(text(diff.content))")
            let changed = text(diff["changed"])
            #expect(changed.contains("\"two\"") && changed.contains("\"checked\"") && changed.contains("\"B\""))
        }
    }

    @Test func longPagesComeWholeInThePDF() async throws {
        try await withAgent { client, base in
            let tab = try await open(client, base, "/long")
            let pdf = await client.call("pdf", ["tab": .string(tab)])
            #expect(!pdf.isError, "\(pdf.message)")
            #expect(pdf["maskedRegions"] == 1)
            let resource = try #require(pdf.result?["content"].flatMap { if case .array(let items) = $0 { items.last?["resource"] } else { nil } })
            let data = try #require(resource["blob"]?.string.flatMap { Data(base64Encoded: $0) })
            let document = try #require(CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init))
            let pages = (1...max(1, document.numberOfPages)).compactMap { document.page(at: $0) }
            // 12000 CSS pixels in pages of at most 2048: six, the whole page, at its own proportions.
            #expect(pages.count == 6)
            #expect(pdf["pages"] == 6)
            let points = try #require(pages.first).getBoxRect(.mediaBox).width / 1280
            #expect(abs(pages.map { $0.getBoxRect(.mediaBox).height }.reduce(0, +) - 12000 * points) < 2)
            guard pages.count == 6 else { return }
            let fifth = try #require(Self.picture(pages[4]))
            #expect(Self.near(Self.color(fifth, x: 200 * points, y: (10050 - 4 * 2048) * points), [128, 128, 128]))
            let last = try #require(Self.picture(pages[5]))
            #expect(Self.near(Self.color(last, x: 200 * points, y: (11950 - 5 * 2048) * points), [255, 0, 0]))
        }
    }

    private static func number(_ value: JSONValue?) -> Double {
        switch value {
        case .double(let number): number
        case .int(let number): Double(number)
        default: 0
        }
    }

    /// A PDF page drawn at one pixel per point.
    private static func picture(_ page: CGPDFPage) -> CGImage? {
        let box = page.getBoxRect(.mediaBox)
        guard let context = CGContext(data: nil, width: Int(box.width), height: Int(box.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.drawPDFPage(page)
        return context.makeImage()
    }

    private static func image(_ result: AgentTabsTests.ToolResult) -> CGImage? {
        guard case .array(let items) = result.result?["content"],
              let base64 = items.first(where: { $0["type"] == "image" })?["data"]?.string,
              let data = Data(base64Encoded: base64) else { return nil }
        return NSBitmapImageRep(data: data)?.cgImage
    }

    /// WebKit draws in the display's color space; a pure color comes back a little off in sRGB.
    private static func near(_ color: [Int], _ expected: [Int]) -> Bool {
        color.count == 3 && zip(color, expected).allSatisfy { abs($0 - $1) <= 48 }
    }

    private static func color(_ image: CGImage, x: Double, y: Double) -> [Int] {
        guard let color = NSBitmapImageRep(cgImage: image).colorAt(x: Int(x), y: Int(y))?.usingColorSpace(.sRGB) else { return [] }
        return [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
    }
}

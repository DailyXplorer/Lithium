import Foundation
import Network
import Testing
import WebKit
@testable import Lithium

/// What the network log and the console hide, as table tests.
@Suite(.timeLimit(.minutes(1)))
struct AgentRedactionTests {
    @Test @MainActor func redactsSecretHeadersAndAddressesInTheOthers() {
        let headers = AgentRedaction.headers([
            "Authorization": "Bearer abc", "Proxy-Authorization": "Basic abc", "Cookie": "a=b", "Set-Cookie": "sid=1",
            "X-Api-Key": "k", "X-CSRF-Token": "t", "Content-Type": "text/html", "Location": "https://a.example/next?code=xyz&page=2",
        ])
        #expect(headers == [
            "Authorization": "[redacted]", "Proxy-Authorization": "[redacted]", "Cookie": "[redacted]", "Set-Cookie": "[redacted]",
            "X-Api-Key": "[redacted]", "X-CSRF-Token": "[redacted]", "Content-Type": "text/html", "Location": "https://a.example/next?code=[redacted]&page=2",
        ])
    }

    @Test func redactsSecretFieldsOfJSONAndFormBodies() {
        #expect(AgentRedaction.body(#"{"user":"ann","password":"p4ss","nested":{"api_key":"k1","count":3},"cvc":123,"ok":true}"#)
            == #"{"user":"ann","password":"[redacted]","nested":{"api_key":"[redacted]","count":3},"cvc":"[redacted]","ok":true}"#)
        #expect(AgentRedaction.body("user=ann&password=p4ss&session_id=s1&page=2") == "user=ann&password=[redacted]&session_id=[redacted]&page=2")
        #expect(AgentRedaction.body(#"<a href="/next?token=t1&x=1">"#) == #"<a href="/next?token=[redacted]&x=1">"#)
        #expect(AgentRedaction.body(#"<input type="hidden" name="csrf" value="c1"><input name=q value="shoes"><input type=password value='p'>"#)
            == #"<input type="hidden" name="csrf" value="[redacted]"><input name=q value="shoes"><input type=password value="[redacted]">"#)
    }

    @Test func redactsCardsTokensAndCredentialLinesInAnyText() {
        #expect(AgentRedaction.text("card 4242 4242 4242 4242, order 1234567890123") == "card [card], order 1234567890123")
        #expect(AgentRedaction.text("Authorization: Bearer abc.def-ghi") == "Authorization: [redacted]")
        #expect(AgentRedaction.text("sent Bearer abcdefgh123 to the API") == "sent Bearer [redacted] to the API")
        #expect(AgentRedaction.text("jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl end") == "jwt [redacted] end")
        #expect(AgentRedaction.text("Set-Cookie: sid=abc; Path=/\nnext line") == "Set-Cookie: [redacted]\nnext line")
        #expect(AgentRedaction.scrubbing(["cookie-value-1", "a"], in: "x cookie-value-1 a") == "x [redacted] a")
        #expect(AgentRedaction.isLuhn("4242424242424242"))
        #expect(!AgentRedaction.isLuhn("4242424242424241"))
    }

    /// Header values and redirect addresses are cut as request addresses are, before they are kept.
    @Test @MainActor func cutsLongHeaderValuesAndRedirectAddresses() throws {
        let long = String(repeating: "a", count: 100_000)
        #expect(AgentRedaction.headers(["X-Long": long])["X-Long"]?.count == AgentRedaction.maxValue)

        let capture = TabCapture()
        let load = try #require(ResourceLoadSpy.Load(LoadInfo()))
        let start = try #require(URL(string: "https://a.example/start"))
        let next = try #require(URL(string: "https://a.example/\(long)"))
        capture.requestStarted(load, method: "GET", url: start, headers: [:])
        let response = try #require(HTTPURLResponse(url: start, statusCode: 302, httpVersion: nil, headerFields: ["Location": next.absoluteString]))
        capture.redirected(load, response: response, to: URLRequest(url: next))
        let entry = try #require(capture.entries.first)
        #expect(entry.redirectedTo.map { $0.count <= AgentRedaction.maxValue && $0.hasPrefix("https://a.example/aaa") } == true)
        #expect(entry.responseHeaders?["Location"].map { $0.count <= AgentRedaction.maxValue } == true)
        #expect(capture.entries.allSatisfy { $0.url.count <= AgentRedaction.maxValue })
    }

    /// What `_WKResourceLoadInfo` gives a load, as far as `ResourceLoadSpy.Load` reads it.
    private final class LoadInfo: NSObject {
        @objc let resourceLoadID: NSNumber = 7
    }
}

/// The network log, the console and network idle waits on a whole Browser, called through the
/// hub as an MCP client calls them, on pages served from 127.0.0.1 and, for a second origin,
/// localhost.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct AgentNetworkTests {
    typealias Client = AgentTabsTests.Client

    private static let html = "Content-Type: text/html; charset=utf-8"
    private static let json = "Content-Type: application/json"
    private static let otherOrigin = "location.protocol + '//' + (location.hostname === 'localhost' ? '127.0.0.1' : 'localhost') + ':' + location.port"

    private static let pages: [String: (headers: String, body: String)] = [
        "/net": (html, """
            <title>Net</title><img src="/pixel.png">
            <script>
              const frame = document.createElement('iframe');
              frame.src = \(otherOrigin) + '/frame';
              document.body.append(frame);
              fetch('/api/data', { headers: { 'X-Probe': 'yes' } });
              const xhr = new XMLHttpRequest();
              xhr.open('POST', '/api/xhr');
              xhr.send('a=1');
              fetch('/redirect');
              fetch('REFUSED').catch(() => {});
            </script>
            """),
        "/frame": (html, "<button>In frame</button><script>fetch('/api/frame').then(() => console.log('from the frame'))</script>"),
        "/api/data": (json, #"{"ok":true}"#),
        "/api/xhr": ("Content-Type: text/plain", "xhr"),
        "/api/frame": (json, "{}"),
        "/api/after": (json, "{}"),
        "/redirect": ("HTTP/1.1 302 Found\r\nLocation: /api/after", ""),
        "/pixel.png": ("Content-Type: image/png", ""),
        "/plain": (html, "<title>Plain</title><p>plain</p>"),
        "/console": (html, """
            <title>Console</title><p>Console</p>
            <script>
              const nativeLog = Function.prototype.toString.call(console.clear).replace('clear', 'log');
              const checks = {
                native: Function.prototype.toString.call(console.log) === nativeLog,
                own: console.log.toString() === nativeLog,
                name: console.log.name,
                length: console.log.length,
                returns: console.log('plain', 42, { a: 1, b: [1, 2] }) === undefined,
                getter: (() => { try { console.info({ get boom() { throw new Error('getter ran'); } }); return true; } catch (_) { return false; } })(),
                unbound: (() => { const warn = console.warn; warn('unbound warning'); return true; })(),
                webdriver: navigator.webdriver,
                globals: Object.getOwnPropertyNames(window).filter((key) => /lithium/i.test(key)).length,
              };
              console.error('bad thing', new Error('inner'));
              console.debug('quiet');
              document.title = JSON.stringify(checks);
              const frame = document.createElement('iframe');
              frame.src = \(otherOrigin) + '/console-frame';
              document.body.append(frame);
              setTimeout(() => { throw new Error('uncaught boom'); }, 0);
              Promise.reject(new Error('rejected nope'));
            </script>
            """),
        "/console-frame": (html, "<script>console.log('from the frame')</script>"),
    ]

    /// A browser with agent access on and one session, as `AgentTabsTests` sets one up.
    private func withAgent(_ pages: [String: (headers: String, body: String)] = Self.pages, _ body: (Client, URL) async throws -> Void) async throws {
        UserDefaults.standard.removeObject(forKey: Preference.agentAccess)
        let (listener, base) = try await LocalHTTP.serve(pages)
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

    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func open(_ client: Client, _ url: URL) async throws -> String {
        let opened = await client.call("tab_open", ["url": .string(url.absoluteString), "wait": "load"])
        return try #require(opened["tab"]?.string, "\(opened.content)")
    }

    private func entries(_ result: AgentTabsTests.ToolResult) -> [JSONValue] {
        if case .array(let entries)? = result["entries"] { entries } else { [] }
    }

    private func entry(_ entries: [JSONValue], endingWith suffix: String) -> JSONValue? {
        entries.first { $0["url"]?.string?.hasSuffix(suffix) == true }
    }

    // MARK: Network

    @Test func logsEachKindOfRequestWithItsFrame() async throws {
        // A port nothing listens on any more; WebKit refuses well-known ones such as 1 before asking.
        let (closed, refusing) = try await LocalHTTP.serve([:])
        closed.cancel()
        var pages = Self.pages
        pages["/net"]?.body = Self.pages["/net"]!.body.replacingOccurrences(of: "REFUSED", with: refusing.appending(path: "refused").absoluteString)
        try await withAgent(pages) { client, base in
            let id = try await open(client, base.appending(path: "net"))
            let idle = await client.call("wait_for", ["tab": .string(id), "networkIdle": 300])
            #expect(idle["met"] == true, "\(idle.content)")
            let log = await client.call("network_log", ["tab": .string(id), "headers": true])
            #expect(log["source"] == "resource-load-delegate")
            let all = entries(log)
            let document = try #require(entry(all, endingWith: "/net"), "\(log.content)")
            #expect(document["type"] == "document")
            #expect(document["status"] == 200)
            #expect(document["frame"] == nil)
            let data = try #require(entry(all, endingWith: "/api/data"))
            #expect(data["type"] == "fetch")
            #expect(data["method"] == "GET")
            #expect(data["mimeType"] == "application/json")
            #expect(data["requestHeaders"]?["X-Probe"] == "yes")
            #expect(entry(all, endingWith: "/api/xhr")?["type"] == "xhr")
            #expect(entry(all, endingWith: "/api/xhr")?["method"] == "POST")
            #expect(entry(all, endingWith: "/pixel.png")?["type"] == "image")
            let redirect = try #require(entry(all, endingWith: "/redirect"))
            #expect(redirect["status"] == 302)
            #expect(redirect["redirectedTo"]?.string?.hasSuffix("/api/after") == true)
            #expect(entry(all, endingWith: "/api/after")?["status"] == 200)
            let refused = try #require(entry(all, endingWith: "/refused"))
            #expect(refused["status"] == nil)
            #expect(refused["error"]?.string?.isEmpty == false)

            // The frame's own document and its fetch name the frame as the snapshot does.
            let frame = try #require(entry(all, endingWith: "/frame")?["frame"]?.string)
            #expect(frame.wholeMatch(of: /f\d+/) != nil)
            #expect(entry(all, endingWith: "/api/frame")?["frame"]?.string == frame)
            let snapshot = await client.call("snapshot", ["tab": .string(id)])
            #expect(snapshot["text"]?.string?.contains("[\(frame)] frame") == true, "\(snapshot.content)")

            #expect(entries(await client.call("network_log", ["tab": .string(id), "type": "fetch"])).allSatisfy { $0["type"] == "fetch" })
            #expect(entries(await client.call("network_log", ["tab": .string(id), "filter": "API/AFTER"])).count == 1)
            let failures = entries(await client.call("network_log", ["tab": .string(id), "minStatus": 300]))
            #expect(Set(failures.compactMap { $0["url"]?.string?.split(separator: "/").last.map(String.init) }) == ["redirect", "refused"])
            let last = try #require(all.last?["id"])
            #expect(entries(await client.call("network_log", ["tab": .string(id), "since": last])).isEmpty)
            #expect(entries(await client.call("network_log", ["tab": .string(id), "limit": 2])).count == 2)
            #expect((await client.call("network_body", ["tab": .string(id), "id": last])).code == "bodies_off")

            // The next page starts a new log; a page put to sleep leaves none.
            let navigated = await client.call("navigate", ["tab": .string(id), "url": .string(base.appending(path: "plain").absoluteString)])
            #expect(navigated["title"] == "Plain")
            // Lithium's own favicon fallback may load in the page too, when its own fetch fails.
            let next = entries(await client.call("network_log", ["tab": .string(id)])).compactMap { $0["url"]?.string?.split(separator: "/").last.map(String.init) }
            #expect(next.first == "plain" && next.allSatisfy { ["plain", "favicon.ico"].contains($0) }, "\(next)")
            let tab = try #require(client.tab(id))
            tab.sleep(configuration: client.browser.makeConfiguration())
            #expect(client.hub.tabs[tab.id]?.capture?.entries.isEmpty == true)
        }
    }

    @Test func waitsForTheNetworkToGoQuiet() async throws {
        let (slowListener, slow) = try await LocalHTTP.serve(["/slow": ("Content-Type: text/plain\r\nAccess-Control-Allow-Origin: *", "late")], delay: 1)
        defer { slowListener.cancel() }
        let hanging = try await HangingHTTP()
        defer { hanging.stop() }
        let late = slow.appending(path: "slow").absoluteString
        let pages = Self.pages.merging([
            "/idle": (Self.html, "<title>Idle</title><button onclick=\"fetch('\(late)').then(() => document.title = 'Saved')\">Save</button><script>fetch('\(late)')</script>"),
            "/hang": (Self.html, "<title>Hang</title><script>fetch('\(hanging.url.absoluteString)').catch(() => {})</script>"),
        ]) { $1 }
        try await withAgent(pages) { client, base in
            let id = try #require((await client.call("tab_open"))["tab"]?.string)
            let started = ContinuousClock.now
            let quiet = await client.call("navigate", ["tab": .string(id), "url": .string(base.appending(path: "idle").absoluteString), "wait": "networkidle"])
            #expect(quiet["state"] == "networkidle", "\(quiet.content)")
            #expect(ContinuousClock.now - started >= .milliseconds(1400))
            let tab = try #require(client.tab(id))
            #expect(client.hub.tabs[tab.id]?.capture?.inFlight.isEmpty == true)

            // A click's own request, with no page load: the action waits for it.
            let save = try #require(await client.call("snapshot", ["tab": .string(id)])["text"]?.string?.firstMatch(of: /\[(e\d+)\] button "Save"/)?.1)
            let clicked = await client.call("click", ["tab": .string(id), "ref": .string(String(save)), "wait": "networkidle", "diff": false])
            #expect(!clicked.isError, "\(clicked.content)")
            let fetched = client.hub.tabs[tab.id]?.capture?.entries.filter { $0.url == late } ?? []
            #expect(fetched.count == 2 && fetched.allSatisfy { $0.ended != nil }, "\(fetched)")
            #expect(await waitUntil(2) { tab.title == "Saved" })

            // A request that never ends: the deadline, the user navigating and the tab closing end the wait.
            _ = await client.call("navigate", ["tab": .string(id), "url": .string(base.appending(path: "hang").absoluteString)])
            let busy = await client.call("wait_for", ["tab": .string(id), "networkIdle": 200, "timeoutMs": 600])
            #expect(busy.code == "timeout", "\(busy.content)")
            let interrupted = Task { await client.call("wait_for", ["tab": .string(id), "networkIdle": 200, "timeoutMs": 30_000]) }
            #expect(await waitUntil(5) { client.hub.isBusy(tab) })
            client.browser.navigate(tab, .reload)
            #expect(await interrupted.value.code == "user_interrupted")
            let closed = Task { await client.call("wait_for", ["tab": .string(id), "networkIdle": 200, "timeoutMs": 30_000]) }
            #expect(await waitUntil(5) { client.hub.isBusy(tab) })
            client.browser.close(tab)
            #expect(await closed.value.code == "tab_closed")
        }
    }

    @Test func aSleepingTabWaitsForWhatItsPageLoads() async throws {
        let (slowListener, slow) = try await LocalHTTP.serve(["/slow": ("Content-Type: text/plain\r\nAccess-Control-Allow-Origin: *", "late")], delay: 0.3)
        defer { slowListener.cancel() }
        let late = slow.appending(path: "slow").absoluteString
        let pages = Self.pages.merging([
            "/after-load": (Self.html, "<title>After load</title><script>addEventListener('load', () => fetch('\(late)'))</script>"),
        ]) { $1 }
        try await withAgent(pages) { client, base in
            let id = try await open(client, base.appending(path: "after-load"))
            let tab = try #require(client.tab(id))
            #expect((await client.call("wait_for", ["tab": .string(id), "networkIdle": 200]))["met"] == true)
            tab.sleep(configuration: client.browser.makeConfiguration())
            try await Task.sleep(for: .milliseconds(300))
            let started = ContinuousClock.now
            let idle = await client.call("wait_for", ["tab": .string(id), "networkIdle": 200])
            #expect(idle["met"] == true, "\(idle.content)")
            #expect(ContinuousClock.now - started >= .milliseconds(500))
            let fetched = client.hub.tabs[tab.id]?.capture?.entries.filter { $0.url == late } ?? []
            #expect(fetched.count == 1 && fetched.allSatisfy { $0.ended != nil }, "\(fetched)")
        }
    }

    @Test func aBodyFollowsARedirectThatChangesTheMethod() async throws {
        let pages = Self.pages.merging([
            "/post": (Self.html, "<title>Post</title><script>fetch('/submit', { method: 'POST', body: 'a=1' }).then((response) => response.text()).then((text) => document.title = text)</script>"),
            "/submit": ("HTTP/1.1 303 See Other\r\nLocation: /result", ""),
            "/result": ("Content-Type: text/plain", "after the redirect"),
        ]) { $1 }
        UserDefaults.standard.set(true, forKey: Preference.agentCaptureBodies)
        defer { UserDefaults.standard.removeObject(forKey: Preference.agentCaptureBodies) }
        try await withAgent(pages) { client, base in
            let id = try await open(client, base.appending(path: "post"))
            let tab = try #require(client.tab(id))
            #expect(await waitUntil(5) { tab.title == "after the redirect" })
            #expect(await waitUntil(5) { client.hub.tabs[tab.id]?.capture?.entries.contains { $0.body != nil } == true })
            let all = entries(await client.call("network_log", ["tab": .string(id)]))
            #expect(entry(all, endingWith: "/submit")?["method"] == "POST")
            let result = try #require(entry(all, endingWith: "/result"), "\(all)")
            #expect(result["method"] == "GET")
            let body = await client.call("network_body", ["tab": .string(id), "id": result["id"] ?? .null])
            #expect(body["text"] == "after the redirect", "\(body.content)")
        }
    }

    /// A load that shows no page (a download the user denies) leaves the log to the page shown,
    /// and a page Back brings from WebKit's cache starts a log of its own.
    @Test func aPageBackBringsFromTheCacheStartsAFreshLog() async throws {
        let pages = Self.pages.merging([
            "/first": (Self.html, "<title>First</title><p>first</p><script>addEventListener('pageshow', (event) => { if (event.persisted) document.title = 'Restored' })</script>"),
            "/links": (Self.html, "<title>Links</title><a href='/report.csv'>Report</a><script>console.log('links page')</script>"),
            "/report.csv": ("Content-Type: text/csv\r\nContent-Disposition: attachment; filename=report.csv", "a,b"),
        ]) { $1 }
        try await withAgent(pages) { client, base in
            let id = try await open(client, base.appending(path: "first"))
            let tab = try #require(client.tab(id))
            #expect((await client.call("navigate", ["tab": .string(id), "url": .string(base.appending(path: "links").absoluteString)]))["title"] == "Links")
            let report = try #require(await client.call("snapshot", ["tab": .string(id)])["text"]?.string?.firstMatch(of: /\[(e\d+)\] link "Report"/)?.1)
            let clicked = await client.call("click", ["tab": .string(id), "ref": .string(String(report)), "diff": false])
            #expect(clicked["download"]?["file"] == "report.csv", "\(clicked.content)")
            if let path = clicked["download"]?["path"]?.string { try? FileManager.default.removeItem(atPath: path) }
            _ = try await tab.webView.evaluateJavaScript("console.log('after the download'); fetch('/api/data'); 0")
            let capture = try #require(client.hub.tabs[tab.id]?.capture)
            #expect(await waitUntil(5) { capture.entries.contains { $0.url.hasSuffix("/api/data") && $0.ended != nil } })

            let back = await client.call("go_back", ["tab": .string(id)])
            #expect(!back.isError, "\(back.content)")
            #expect(await waitUntil(5) { tab.title == "Restored" })
            let log = entries(await client.call("network_log", ["tab": .string(id)]))
            #expect(log.isEmpty, "\(log)")
            #expect((await client.call("console_log", ["tab": .string(id)]))["messages"] == [])
        }
    }

    // MARK: Console

    @Test func logsConsoleMessagesAndUncaughtErrorsWithoutChangingThePage() async throws {
        try await withAgent { client, base in
            let id = try await open(client, base.appending(path: "console"))
            let tab = try #require(client.tab(id))
            let checks = try JSONValue.decode(Data(tab.title.utf8))
            #expect(checks == ["native": true, "own": true, "name": "log", "length": 0, "returns": true, "getter": true, "unbound": true, "webdriver": false, "globals": 0])
            #expect(await waitUntil(10) {
                let texts = client.hub.tabs[tab.id]?.capture?.messages.map(\.text) ?? []
                return ["from the frame", "uncaught boom", "rejected nope"].allSatisfy { needle in texts.contains { $0.contains(needle) } }
            })
            let log = await client.call("console_log", ["tab": .string(id)])
            guard case .array(let messages)? = log["messages"] else { Issue.record("\(log.content)"); return }
            let byText = { (needle: String) in messages.first { $0["text"]?.string?.contains(needle) == true } }
            #expect(byText("plain")?["text"] == "plain 42 {a: 1, b: [1, 2]}")
            #expect(byText("plain")?["level"] == "log")
            #expect(byText("[getter]")?["level"] == "info")
            #expect(byText("unbound warning")?["level"] == "warn")
            #expect(byText("bad thing")?["text"] == "bad thing Error: inner")
            #expect(byText("quiet")?["level"] == "debug")
            let uncaught = try #require(byText("uncaught boom"))
            #expect(uncaught["kind"] == "exception")
            #expect(uncaught["source"]?.string?.hasSuffix("/console") == true)
            #expect((uncaught["line"].flatMap { if case .int(let line) = $0 { line } else { nil } } ?? 0) > 0)
            #expect(byText("rejected nope")?["kind"] == "rejection")
            #expect(byText("rejected nope")?["text"] == "Error: rejected nope")
            #expect(byText("from the frame")?["frame"]?.string?.wholeMatch(of: /f\d+/) != nil)
            #expect(byText("plain")?["frame"] == nil)

            let filtered = await client.call("console_log", ["tab": .string(id), "level": "warn"])
            guard case .array(let serious)? = filtered["messages"] else { Issue.record("\(filtered.content)"); return }
            #expect(Set(serious.compactMap { $0["level"]?.string }) == ["warn", "error"])
            let last = try #require(messages.last?["id"])
            #expect((await client.call("console_log", ["tab": .string(id), "since": last]))["messages"] == [])
        }
    }

    /// A page posting to the console handler itself, past the console script's limit, or firing
    /// error events the agent's world hears, gets a few hundred a second through and no more.
    @Test func aPageCantFloodTheConsole() async throws {
        try await withAgent { client, base in
            let id = try await open(client, base.appending(path: "plain"))
            let tab = try #require(client.tab(id))
            let webView = try #require(tab.loadedWebView)
            _ = try await webView.callAsyncJavaScript("""
                for (let i = 0; i < 3000; i++) webkit.messageHandlers.lithiumAgentConsole.postMessage({ level: 'log', text: 'posted ' + i });
                for (let i = 0; i < 3000; i++) dispatchEvent(new ErrorEvent('error', { message: 'fired ' + i }));
                await new Promise((done) => setTimeout(done, 1100));
                webkit.messageHandlers.lithiumAgentConsole.postMessage({ level: 'log', text: 'after the flood' });
                """, contentWorld: .page)
            #expect(await waitUntil(10) { client.hub.tabs[tab.id]?.capture?.messages.contains { $0.text == "after the flood" } == true })
            let texts = client.hub.tabs[tab.id]?.capture?.messages.map(\.text) ?? []
            let flood = texts.filter { $0.hasPrefix("posted ") || $0.hasPrefix("fired ") }
            // Without the limit, the 500 newest would be kept.
            #expect(flood.count >= TabCapture.messagesPerSecond && flood.count < 450, "\(flood.count)")
            #expect(texts.contains { $0.hasPrefix("Lithium left out ") && $0.hasSuffix(" messages: the page sent more than 200 in a second.") }, "\(texts.suffix(3))")
        }
    }

    /// An error event's message and file name are the page's to size: `agent-errors.js` cuts them
    /// before they cross to Lithium, as it does a rejection's reason. In a bare web view, whose
    /// handler sees what the page posts before Lithium cuts anything.
    @Test func errorEventsAreCutBeforeTheyLeaveThePage() async throws {
        let recorder = ErrorRecorder()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(recorder, contentWorld: PageProbe.world, name: PageProbe.messageName)
        configuration.userContentController.addUserScript(WKUserScript(source: AgentConsoleHandler.errorsSource, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: PageProbe.world))
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 200, height: 200), configuration: configuration)
        webView.loadHTMLString("<title>Plain</title>", baseURL: URL(string: "https://a.example/"))
        #expect(await waitUntil(10) { webView.title == "Plain" && !webView.isLoading })
        _ = try await webView.callAsyncJavaScript(
            "dispatchEvent(new ErrorEvent('error', { message: 'x'.repeat(1 << 20), filename: 'https://a.example/' + 'y'.repeat(1 << 20) }))",
            contentWorld: .page
        )
        #expect(await waitUntil(10) { !recorder.errors.isEmpty })
        let error = try #require(recorder.errors.first)
        #expect((error["text"] as? String)?.count == 4096)
        #expect((error["source"] as? String)?.count == 2048)
    }

    /// A tab agents use, sent to one of Lithium's own pages: the page finds no console handler,
    /// its console stays its own, and nothing it logs is kept.
    @Test func lithiumsOwnPagesStayOutOfTheConsole() async throws {
        try await withAgent { client, base in
            let id = try await open(client, base.appending(path: "plain"))
            let tab = try #require(client.tab(id))
            let capture = try #require(client.hub.tabs[tab.id]?.capture)
            let probe = "typeof webkit.messageHandlers.lithiumAgentConsole + ' ' + (Function.prototype.toString.call(console.log) === Function.prototype.toString.call(console.clear).replace('clear', 'log'))"
            #expect(try await tab.webView.evaluateJavaScript(probe) as? String == "object true")

            tab.load(Internal.settingsURL)
            #expect(await waitUntil(10) { tab.webView.url == Internal.settingsURL && !tab.isLoading })
            let before = capture.messages.count
            #expect(try await tab.webView.evaluateJavaScript(probe) as? String == "undefined true")
            _ = try await tab.webView.evaluateJavaScript("console.log('from settings'); setTimeout(() => { throw new Error('settings boom') }); 0")
            try await Task.sleep(for: .milliseconds(300))
            #expect(capture.messages.count == before, "\(capture.messages.map(\.text))")
        }
    }

    // MARK: Secrets and cost

    @Test func secretsNeverReachResultsOrTheLog() async throws {
        let secrets = [
            "hdr-secret-token", "hdr-secret-key", "hdr-secret-query", "hdr-secret-header", "hdr-secret-set-cookie", "hdr-secret-cookie-value",
            "hdr-secret-password", "4242424242424242", "4242 4242 4242 4242", "hdr-secret-nested", "hdr-secret-jwt", "hdr-secret-echo",
            "hdr-secret-form", "hdr-secret-session", "hdr-secret-csrf", "hdr-secret-prefill", "hdr-secret-console",
        ]
        let pages = Self.pages.merging([
            "/secret": ("\(Self.html)\r\nSet-Cookie: sid=hdr-secret-cookie-value; Path=/", """
                <title>Secret</title>
                <form><input type=hidden name=csrf value="hdr-secret-csrf"><input type=password name=pw value="hdr-secret-prefill"></form>
                <script>
                  console.log('Bearer hdr-secret-console');
                  console.log(document.cookie);
                  console.log('card 4242 4242 4242 4242');
                  fetch('/api/secret?token=hdr-secret-query&page=1', { headers: {"Authorization": "Bearer hdr-secret-token", "X-Api-Key": "hdr-secret-key"} });
                  const xhr = new XMLHttpRequest();
                  xhr.open('GET', '/api/form');
                  xhr.send();
                </script>
                """),
            "/api/secret?token=hdr-secret-query&page=1": ("\(Self.json)\r\nX-Session-Token: hdr-secret-header\r\nSet-Cookie: other=hdr-secret-set-cookie; Path=/", """
                {"note":"visible-note","password":"hdr-secret-password","card":"4242424242424242","nested":{"api_key":"hdr-secret-nested"},"jwt":"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJoZHIifQ.hdr-secret-jwt-sig","echo":"Authorization: Bearer hdr-secret-echo"}
                """),
            "/api/form": ("Content-Type: application/x-www-form-urlencoded", "user=ann&password=hdr-secret-form&session_id=hdr-secret-session"),
        ]) { $1 }
        UserDefaults.standard.set(true, forKey: Preference.agentCaptureBodies)
        defer { UserDefaults.standard.removeObject(forKey: Preference.agentCaptureBodies) }
        try await withAgent(pages) { client, base in
            let id = try await open(client, base.appending(path: "secret"))
            #expect((await client.call("wait_for", ["tab": .string(id), "networkIdle": 300]))["met"] == true)
            let tab = try #require(client.tab(id))
            #expect(await waitUntil(5) { client.hub.tabs[tab.id]?.capture?.entries.filter { $0.body != nil }.count == 2 })
            #expect(await waitUntil(5) { client.hub.tabs[tab.id]?.capture?.messages.count == 3 })
            var results = [await client.call("network_log", ["tab": .string(id), "headers": true]), await client.call("console_log", ["tab": .string(id)])]
            for item in entries(results[0]) where item["body"] == true || item["type"] == "document" {
                let body = await client.call("network_body", ["tab": .string(id), "id": item["id"] ?? .null])
                #expect(!body.isError, "\(item): \(body.content)")
                results.append(body)
            }
            #expect(results.count == 5)
            let shown = results.map { String(decoding: ($0.result ?? .null).encoded(), as: UTF8.self) }.joined(separator: "\n")
            // What isn't secret comes through, so the bodies and messages were read.
            for visible in ["visible-note", "user=ann", "X-Session-Token", "[redacted]", "[card]", "Secret"] {
                #expect(shown.contains(visible), "\(visible) missing")
            }
            for secret in secrets {
                #expect(!shown.contains(secret), "\(secret) in a result")
            }
            let logged = String(decoding: await client.hub.log.export(), as: UTF8.self)
            #expect(logged.contains("network_body"))
            for secret in secrets {
                #expect(!logged.contains(secret), "\(secret) in the log")
            }
        }
    }

    /// With access off, or on while no agent named the tab, nothing of the network log or the
    /// console is in it: no delegate, no script, no handler the page could find.
    @Test func nothingIsInstalledUntilAnAgentUsesTheTab() async throws {
        UserDefaults.standard.removeObject(forKey: Preference.agentAccess)
        let (listener, base) = try await LocalHTTP.serve(Self.pages)
        defer { listener.cancel() }
        let browser = Browser()
        await browser.privacy.waitUntilReady()
        await browser.extensions.waitUntilLoaded()
        let tab = browser.newTab(url: base.appending(path: "plain"), selecting: false)
        let probe = "typeof webkit.messageHandlers.lithiumAgentConsole + ' ' + (Function.prototype.toString.call(console.log) === Function.prototype.toString.call(console.clear).replace('clear', 'log'))"
        let untouched = { () async throws -> Void in
            #expect(await waitUntil(30) { !tab.isLoading && tab.title == "Plain" })
            #expect(ResourceLoadSpy.delegate(of: tab.webView) == nil)
            #expect(!tab.webView.configuration.userContentController.userScripts.contains { $0.source.contains("lithiumAgentConsole") })
            #expect(try await tab.webView.evaluateJavaScript(probe) as? String == "undefined true")
        }
        try await untouched()
        await browser.setAgentAccess(true)
        defer { browser.tabs.forEach(browser.close) }
        browser.navigate(tab, .reload)
        try await untouched()
        #expect(browser.agent?.tabs[tab.id]?.capture == nil)

        // An agent names the tab: the page shown gets everything at once.
        let client = try await Client(browser: browser)
        let id = client.hub.id(for: tab)
        #expect(entries(await client.call("network_log", ["tab": .string(id)])).isEmpty)
        let capture = try #require(client.hub.tabs[tab.id]?.capture)
        #expect(ResourceLoadSpy.delegate(of: tab.webView) === capture.spy)
        #expect(try await tab.webView.evaluateJavaScript(probe) as? String == "object true")
        _ = try await tab.webView.evaluateJavaScript("console.log('after the start'); 0")
        #expect(await waitUntil(5) { capture.messages.contains { $0.text == "after the start" } })
        await browser.setAgentAccess(false)
        #expect(ResourceLoadSpy.delegate(of: tab.webView) == nil)
    }

    /// Without the resource load delegate, each frame's performance timeline stands in, and
    /// says so; network idle waits can't tell requests in flight.
    @Test func fallsBackOnThePerformanceTimeline() async throws {
        try await withAgent { client, base in
            client.hub.usesResourceLoadDelegate = false
            let id = try await open(client, base.appending(path: "net"))
            let tab = try #require(client.tab(id))
            #expect(ResourceLoadSpy.delegate(of: tab.webView) == nil)
            #expect(await waitUntil(10) { client.hub.tabs[tab.id]?.capture?.messages.contains { $0.text == "from the frame" } == true })
            let log = await client.call("network_log", ["tab": .string(id)])
            #expect(log["source"] == "performance-timeline", "\(log.content)")
            let all = entries(log)
            #expect(entry(all, endingWith: "/net")?["type"] == "document")
            #expect(entry(all, endingWith: "/api/data")?["type"] == "fetch")
            #expect(entry(all, endingWith: "/api/frame")?["frame"]?.string?.wholeMatch(of: /f\d+/) != nil)
            #expect((await client.call("network_log", ["tab": .string(id), "since": 1])).code == "unsupported")
            #expect((await client.call("wait_for", ["tab": .string(id), "networkIdle": 300])).code == "unsupported")
            #expect((await client.call("navigate", ["tab": .string(id), "url": .string(base.appending(path: "plain").absoluteString), "wait": "networkidle"])).code == "unsupported")
        }
    }
}

/// The errors `agent-errors.js` posts, as the page sent them.
@MainActor
private final class ErrorRecorder: NSObject, WKScriptMessageHandler {
    private(set) var errors: [[String: Any]] = []

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let error = (message.body as? [String: Any])?["console"] as? [String: Any] { errors.append(error) }
    }
}

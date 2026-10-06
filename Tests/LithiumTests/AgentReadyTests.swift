import Foundation
import Network
import Testing
import WebKit
@testable import Lithium

/// Steps act on a page that is ready (PR 12): `batch {url}` and `tab_open {steps}` wait for the
/// page's `load` (10 s at most), reload once a page whose own script failed, and a step after one
/// that loaded a page waits the same way. On a whole Browser through the hub, pages from 127.0.0.1.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct AgentReadyTests {
    typealias Client = AgentTabsTests.Client

    private static let html = "Content-Type: text/html; charset=utf-8"
    private static let style = "<style>body { margin: 0 } button { position: absolute; left: 10px; top: 10px; width: 100px; height: 40px }</style>"

    /// A Start button whose handler the page attaches on `load`, held back by an image.
    private static func held(_ image: URL) -> String {
        """
        <title>Held</title>\(style)<button>Start</button><p id="out"></p><img src="\(image.absoluteString)">
        <script>addEventListener('load', () => { document.querySelector('button').onclick = () => { out.textContent = 'Clicked' } })</script>
        """
    }

    /// A Start button whose handler comes from `/app.js`.
    private static let scripted = """
        <title>Scripted</title>\(style)<button>Start</button><p id="out"></p><script src="/app.js"></script>
        """
    private static let app = "document.querySelector('button').onclick = () => { out.textContent = 'Clicked' }"

    private static let clickAndWait: JSONValue = [
        ["tool": "click", "args": ["x": 60, "y": 30]],
        ["tool": "wait_for", "args": ["text": "Clicked", "timeoutMs": 2000]],
    ]

    /// Counts the requests for one path, from Network's queue.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.withLock { count += 1; return count } }
        var value: Int { lock.withLock { count } }
    }

    private func withAgent(_ body: (Client) async throws -> Void) async throws {
        UserDefaults.standard.removeObject(forKey: Preference.agentAccess)
        let browser = Browser()
        await browser.privacy.waitUntilReady()
        await browser.extensions.waitUntilLoaded()
        await browser.setAgentAccess(true)
        var failure: (any Error)?
        do { try await body(try await Client(browser: browser)) } catch { failure = error }
        browser.tabs.forEach(browser.close)
        await browser.setAgentAccess(false)
        if let failure { throw failure }
    }

    /// `app.js` answers 503 for its first `failures` requests (all of them when nil), then the script.
    private func serveScripted(failures: Int?, requests: Counter) async throws -> (NWListener, URL) {
        let app = Data(Self.app.utf8)
        return try await LocalHTTP.serve(["/": (Self.html, Data(Self.scripted.utf8))], answer: { path in
            guard path == "/app.js" else { return nil }
            let count = requests.next()
            if failures.map({ count <= $0 }) ?? true {
                return ("HTTP/1.1 503 Service Unavailable\r\nContent-Type: text/plain\r\nCache-Control: no-store", Data("busy".utf8))
            }
            return ("Content-Type: text/javascript\r\nCache-Control: no-store", app)
        })
    }

    // MARK: Load

    /// The page's handler comes with `load`, 3 s after DOMContentLoaded: the click works the first time.
    @Test func stepsWaitForThePagesLoad() async throws {
        let (image, imageBase) = try await LocalHTTP.serve(["/held.png": ("Content-Type: image/png", "")], delay: 3)
        defer { image.cancel() }
        let (listener, base) = try await LocalHTTP.serve(["/": (Self.html, Self.held(imageBase.appending(path: "held.png")))])
        defer { listener.cancel() }
        try await withAgent { client in
            for tool in ["batch", "tab_open"] {
                var arguments: [String: JSONValue] = ["url": .string(base.absoluteString), "steps": Self.clickAndWait]
                if tool == "batch" { arguments["close"] = true }
                let result = await client.call(tool, .object(arguments))
                #expect(!result.isError && result["ok"] == 2, "\(tool): \(result.content)")
                #expect(result["note"] == nil && result["reloaded"] == nil, "\(tool): \(result.content)")
                if tool == "tab_open" { #expect(result["state"] == "load", "\(result.content)") }
            }
        }
    }

    /// A load held 20 s: the steps run after 10 s, and the result says the page was still loading.
    @Test func stepsRunAfterTenSecondsOfLoading() async throws {
        let (image, imageBase) = try await LocalHTTP.serve(["/held.png": ("Content-Type: image/png", "")], delay: 20)
        defer { image.cancel() }
        let (listener, base) = try await LocalHTTP.serve(["/": (Self.html, Self.held(imageBase.appending(path: "held.png")))])
        defer { listener.cancel() }
        try await withAgent { client in
            let started = ContinuousClock.now
            let result = await client.call("batch", ["url": .string(base.absoluteString), "close": true, "steps": [["tool": "find_text", "args": ["text": "Start"]]]])
            let elapsed = ContinuousClock.now - started
            #expect(!result.isError && result["ok"] == 1, "\(result.content)")
            #expect(result["note"] == "page still loading after 10 s", "\(result.content)")
            #expect(elapsed >= .seconds(10) && elapsed < .seconds(18), "\(elapsed)")
        }
    }

    /// A link to the held page, then a click on it: the click waits for the new page's load.
    @Test func aStepAfterANavigationWaitsForTheNewPagesLoad() async throws {
        let (image, imageBase) = try await LocalHTTP.serve(["/held.png": ("Content-Type: image/png", "")], delay: 3)
        defer { image.cancel() }
        let (listener, base) = try await LocalHTTP.serve([
            "/": (Self.html, "<title>Home</title>\(Self.style)<a href=\"/held\" style=\"display: block; height: 100vh\">Onward</a>"),
            "/held": (Self.html, Self.held(imageBase.appending(path: "held.png"))),
        ])
        defer { listener.cancel() }
        try await withAgent { client in
            let result = await client.call("batch", ["url": .string(base.absoluteString), "close": true, "steps": [
                ["tool": "click", "args": ["x": 200, "y": 200]],
                ["tool": "click", "args": ["x": 60, "y": 30]],
                ["tool": "wait_for", "args": ["text": "Clicked", "timeoutMs": 2000]],
            ]])
            #expect(!result.isError && result["ok"] == 3, "\(result.content)")
            #expect(result["title"] == "Held", "\(result.content)")
        }
    }

    // MARK: Failed scripts

    /// The page's script answers 503 once: the batch reloads the page, and the click then works.
    @Test func aPageWhoseScriptFailedIsReloadedOnce() async throws {
        let requests = Counter()
        let (server, base) = try await serveScripted(failures: 1, requests: requests)
        defer { server.cancel() }
        try await withAgent { client in
            let result = await client.call("batch", ["url": .string(base.absoluteString), "close": true, "steps": Self.clickAndWait])
            #expect(!result.isError && result["ok"] == 2, "\(result.content)")
            #expect(result["reloaded"]?.string == "script failed: \(base.appending(path: "app.js").absoluteString) 503", "\(result.content)")
            #expect(result["failedScripts"] == nil, "\(result.content)")
            #expect(requests.value == 2)
        }
    }

    /// A script that always fails: one reload only, and the results list it.
    @Test func aScriptThatAlwaysFailsIsListed() async throws {
        let requests = Counter()
        let (server, base) = try await serveScripted(failures: nil, requests: requests)
        defer { server.cancel() }
        let script = JSONValue.string(base.appending(path: "app.js").absoluteString)
        try await withAgent { client in
            let result = await client.call("tab_open", ["url": .string(base.absoluteString), "steps": [["tool": "find_text", "args": ["text": "Start"]]]])
            #expect(!result.isError && result["ok"] == 1, "\(result.content)")
            #expect(result["reloaded"]?.string?.hasPrefix("script failed: ") == true, "\(result.content)")
            #expect(result["failedScripts"] == [["url": script, "status": 503]], "\(result.content)")
            #expect(requests.value == 2)

            let id = try #require(result["tab"]?.string)
            let snapshot = await client.call("snapshot", ["tab": .string(id)])
            #expect(snapshot["failedScripts"] == [["url": script, "status": 503]], "\(snapshot.content)")
            #expect(snapshot["text"]?.string?.hasSuffix("failed scripts: \(base.appending(path: "app.js").absoluteString) 503") == true, "\(snapshot.content)")
        }
    }

    /// The reload after a failed script opens an alert, which fails it: the steps still run on
    /// the page, and the tab's id comes back.
    @Test func aReloadThatFailsLeavesThePageToTheSteps() async throws {
        let pages = Counter()
        let page = Data(Self.scripted.utf8)
        let html = Self.html
        let (server, base) = try await LocalHTTP.serve([:], answer: { path in
            switch path {
            case "/": (html,pages.next() == 1 ? page : page + Data("<script>alert('Busy')</script>".utf8))
            case "/app.js": ("HTTP/1.1 503 Service Unavailable\r\nContent-Type: text/plain\r\nCache-Control: no-store", Data("busy".utf8))
            default: nil
            }
        })
        defer { server.cancel() }
        try await withAgent { client in
            let result = await client.call("tab_open", ["url": .string(base.absoluteString), "steps": [["tool": "find_text", "args": ["text": "Start"]]]])
            #expect(!result.isError && result["tab"]?.string != nil, "\(result.content)")
            #expect(result["reloaded"] == .null, "\(result.content)")
            #expect(result["note"]?.string?.contains("; reload failed: ") == true, "\(result.content)")
            guard case .array(let steps)? = result["steps"] else { Issue.record("no steps: \(result.content)"); return }
            #expect(steps.count == 1, "\(result.content)")
            #expect(pages.value == 2)
        }
    }

    /// The page's own script, refused by a content rule: WebKit doesn't tell the resource load
    /// delegate of it, so it is no failure and the page isn't reloaded.
    @Test func aScriptTheBlockerRefusedIsNoFailure() async throws {
        let rules = #"[{"trigger": {"url-filter": "ads\\.js"}, "action": {"type": "block"}}]"#
        let store = try #require(WKContentRuleListStore(url: FileManager.default.temporaryDirectory.appending(path: "agent-ready-rules-\(UUID().uuidString)")))
        let list = try #require(try await store.compileContentRuleList(forIdentifier: "ads", encodedContentRuleList: rules))
        let pages = Counter()
        let scripts = Counter()
        let (server, base) = try await LocalHTTP.serve(
            ["/": (Self.html, Data("<title>Ads</title><p>Start</p><script src=\"/ads.js\"></script>".utf8)), "/ads.js": ("Content-Type: text/javascript", Data())],
            requested: { path in
                if path == "/" { _ = pages.next() }
                if path == "/ads.js" { _ = scripts.next() }
            }
        )
        defer { server.cancel() }
        try await withAgent { client in
            let rules = client.browser.privacy.ruleLists
            client.browser.privacy.ruleLists = [list]
            defer { client.browser.privacy.ruleLists = rules }
            let result = await client.call("tab_open", ["url": .string(base.absoluteString), "steps": [["tool": "find_text", "args": ["text": "Start"]]]])
            #expect(!result.isError && result["ok"] == 1, "\(result.content)")
            #expect(result["reloaded"] == nil && result["failedScripts"] == nil, "\(result.content)")
            #expect(pages.value == 1 && scripts.value == 0)
        }
    }

    /// The failures of the page before are not the next page's, even before it says hello.
    @Test func aNewPageDoesNotListThePageBeforesFailures() async throws {
        let (server, base) = try await serveScripted(failures: nil, requests: Counter())
        defer { server.cancel() }
        try await withAgent { client in
            let opened = await client.call("tab_open", ["url": .string(base.absoluteString), "wait": "load"])
            #expect(opened["failedScripts"] != nil, "\(opened.content)")
            let id = try #require(opened["tab"]?.string)
            let result = await client.call("navigate", ["tab": .string(id), "url": .string(base.appending(path: "b").absoluteString), "wait": "commit"])
            #expect(!result.isError, "\(result.content)")
            #expect(result["failedScripts"] == nil, "\(result.content)")
        }
    }
}

import Foundation
import Testing
import WebKit
@testable import Lithium

/// `evaluate` on a whole Browser through the hub, on pages served from 127.0.0.1: the switch, the
/// prompt and the site grant, benchmark mode, the two worlds, no script while a password or card value is on the
/// page, card and cookie values kept out of results and the log, the pages it never runs on, and
/// a script that never ends. Prompts are answered through
/// `AgentConfirmations`, never through UI.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct AgentEvaluateTests {
    typealias Client = AgentTabsTests.Client

    private static let html = "Content-Type: text/html; charset=utf-8"
    /// Unique per run, so nothing left in the throwaway home answers for this one.
    private static let password = "Pw-\(UInt32.random(in: 1...UInt32.max))"
    private static let cookie = "sid\(UInt32.random(in: 1...UInt32.max))value"

    private static let pages: [String: (headers: String, body: String)] = [
        "/page": (html, "<title>Page</title><h1 id='greeting'>Hello</h1><script>window.pageGlobal = 'from the page'</script>"),
        "/login": (html, """
            <title>Sign in</title>
            <form><input id="user" name="user" value="ann"><input type="password" id="pw" name="pw"></form>
            <script>pw.value = '\(password)'</script>
            """),
        "/signin": (html, "<title>Sign in</title><form><input id='user' name='user'><input type='password' id='pw' name='pw'></form>"),
        "/framed": (html, "<title>Framed</title><iframe src='/login'></iframe>"),
        "/account": ("\(html)\r\nSet-Cookie: session=\(cookie); Path=/", "<title>Account</title><p id='note'>Card on file 4242 4242 4242 4242</p>"),
        "/checkout": (html, "<title>Checkout</title><label>Card number <input id='cc' autocomplete='cc-number'></label>"),
        "/provider": (html, """
            <title>Provider</title><body>
            <script>document.body.append(Object.assign(document.createElement('iframe'), { src: location.protocol + '//localhost:' + location.port + '/page' }))</script>
            """),
        "/report.csv": ("Content-Type: text/csv\r\nContent-Disposition: attachment; filename=report.csv", "a,b"),
    ]

    private func withAgent(scripts: Bool = true, benchmarkUntil: Date? = nil, _ body: (Client, URL) async throws -> Void) async throws {
        UserDefaults.standard.removeObject(forKey: Preference.agentAccess)
        UserDefaults.standard.set(scripts, forKey: Preference.agentRunScripts)
        UserDefaults.standard.set(benchmarkUntil, forKey: Preference.agentScriptsAutoAllowUntil)
        defer {
            UserDefaults.standard.removeObject(forKey: Preference.agentRunScripts)
            UserDefaults.standard.removeObject(forKey: Preference.agentScriptsAutoAllowUntil)
        }
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

    private func open(_ client: Client, _ url: URL) async throws -> String {
        let opened = await client.call("tab_open", ["url": .string(url.absoluteString), "wait": "load"])
        #expect(!opened.isError, "\(opened.content)")
        return try #require(opened["tab"]?.string)
    }

    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// Runs `function` in `tab`, answering the prompt with `answer` when one comes; a site grant
    /// already given means none does.
    private func evaluate(_ client: Client, _ tab: String, _ function: String, _ extra: [String: JSONValue] = [:], answering answer: ConfirmationAnswer? = .allowOnce) async -> AgentTabsTests.ToolResult {
        var arguments: [String: JSONValue] = ["tab": .string(tab), "function": .string(function)]
        arguments.merge(extra) { $1 }
        let confirmations = client.hub.confirmations
        let task = Task { await client.call("evaluate", .object(arguments)) }
        if let answer {
            if await waitUntil(20, { !confirmations.pending.isEmpty }), let asked = confirmations.pending.first {
                #expect(asked.kind == .script)
                confirmations.answer(asked.id, answer)
            } else {
                Issue.record("evaluate asked nothing")
            }
        }
        return await task.value
    }

    // MARK: The switch

    @Test func isListedOnlyWhileTheUserLetsAgentsRunScripts() async throws {
        try await withAgent(scripts: false) { client, base in
            let names = { () async in
                let reply = await client.hub.handle(.message(["jsonrpc": "2.0", "id": 2, "method": "tools/list"], session: client.session, protocolVersion: nil))
                return (reply.body?["result"]?["tools"]?.items ?? []).compactMap { $0["name"]?.string }
            }
            #expect(await !names().contains("evaluate"))
            let id = try await open(client, base.appending(path: "page"))
            let refused = await client.call("evaluate", ["tab": .string(id), "function": "() => 1"])
            #expect(refused.code == "unsupported", "\(refused.content)")
            #expect(client.hub.confirmations.pending.isEmpty)

            UserDefaults.standard.set(true, forKey: Preference.agentRunScripts)
            #expect(await names().contains("evaluate"))
        }
    }

    // MARK: The prompt

    @Test func asksBeforeTheFirstScriptOnASiteThenTheGrantCovers() async throws {
        try await withAgent { client, base in
            let id = try await open(client, base.appending(path: "page"))
            let denied = await evaluate(client, id, "() => document.title", answering: .deny)
            #expect(denied.code == "denied_by_user", "\(denied.content)")

            let once = await evaluate(client, id, "() => document.title", answering: .allowOnce)
            #expect(once["result"] == "Page", "\(once.content)")
            #expect(once["grant"] == "once")

            let site = await evaluate(client, id, "() => 1 + 1", answering: .allowOnSite)
            #expect(site["result"] == 2, "\(site.content)")
            let covered = await evaluate(client, id, "async () => { await new Promise((done) => setTimeout(done, 10)); return [1, 'two', null] }", answering: nil)
            #expect(covered["result"] == [1, "two", .null], "\(covered.content)")
            #expect(covered["grant"] == "site")
            #expect(client.hub.confirmations.grants.map(\.kind) == [.script])
        }
    }

    // MARK: Benchmark mode

    private func lastConfirmation() -> JSONValue? {
        let log = (try? String(contentsOf: AgentLog.folder.appending(path: AgentLog.fileName(for: Date())), encoding: .utf8)) ?? ""
        return log.split(separator: "\n").compactMap { try? JSONValue.decode(Data($0.utf8)) }.last { $0["event"] == "confirmation" }
    }

    @Test func benchmarkModeAllowsScriptsUnaskedAndNothingElse() async throws {
        let until = Date().addingTimeInterval(10 * 60)
        try await withAgent(benchmarkUntil: until) { client, base in
            let shown = try #require(client.hub.scriptsAutoAllowedUntil())
            #expect(abs(shown.timeIntervalSince(until)) < 1)
            #expect(AgentStatus.benchmarkMode(client.hub)?.hasPrefix("Benchmark mode: scripts auto-allowed until ") == true)

            let id = try await open(client, base.appending(path: "page"))
            let ran = await evaluate(client, id, "() => document.title", answering: nil)
            #expect(ran["result"] == "Page", "\(ran.content)")
            #expect(ran["grant"] == "once")
            #expect(client.hub.confirmations.pending.isEmpty)
            #expect(client.hub.confirmations.grants.isEmpty)
            #expect(client.hub.recentLog.last { $0.tool.hasPrefix("confirm") }?.tool == "confirm script (benchmark mode)")
            #expect(await waitUntil(5) { lastConfirmation()?["confirmation"]?["allowedBy"] == "benchmark mode" })

            // A download still asks.
            let report = base.appending(path: "report.csv").absoluteString
            let download = Task { await client.call("navigate", ["tab": .string(id), "url": .string(report)]) }
            #expect(await waitUntil(20) { !client.hub.confirmations.pending.isEmpty })
            let asked = try #require(client.hub.confirmations.pending.first)
            #expect(asked.kind == .download)
            client.hub.confirmations.answer(asked.id, .deny)
            let denied = await download.value
            #expect(denied.code == "denied_by_user", "\(denied.content)")

            // A password value still keeps every script from running.
            let login = try await open(client, base.appending(path: "login"))
            let refused = await evaluate(client, login, "() => document.querySelector('#pw').value", answering: nil)
            #expect(refused.code == "blocked", "\(refused.content)")
            #expect(refused.message.contains("a password or card field holds a value on this page"), "\(refused.content)")
        }
    }

    @Test func anExpiredOrDistantBenchmarkDateAsksAsUsual() async throws {
        try await withAgent(benchmarkUntil: Date().addingTimeInterval(-60)) { client, base in
            let id = try await open(client, base.appending(path: "page"))
            let expired = await evaluate(client, id, "() => 1", answering: .allowOnce)
            #expect(expired["result"] == 1, "\(expired.content)")
            #expect(UserDefaults.standard.object(forKey: Preference.agentScriptsAutoAllowUntil) == nil)
            #expect(AgentStatus.benchmarkMode(client.hub) == nil)

            UserDefaults.standard.set(Date().addingTimeInterval(3 * 60 * 60), forKey: Preference.agentScriptsAutoAllowUntil)
            let distant = await evaluate(client, id, "() => 2", answering: .allowOnce)
            #expect(distant["result"] == 2, "\(distant.content)")
            #expect(AgentStatus.benchmarkMode(client.hub) == nil)
        }
    }

    @Test func benchmarkModeNeedsTheScriptsSwitch() async throws {
        try await withAgent(scripts: false, benchmarkUntil: Date().addingTimeInterval(10 * 60)) { client, base in
            let reply = await client.hub.handle(.message(["jsonrpc": "2.0", "id": 2, "method": "tools/list"], session: client.session, protocolVersion: nil))
            let names = (reply.body?["result"]?["tools"]?.items ?? []).compactMap { $0["name"]?.string }
            #expect(!names.contains("evaluate"))
            let id = try await open(client, base.appending(path: "page"))
            let refused = await client.call("evaluate", ["tab": .string(id), "function": "() => 1"])
            #expect(refused.code == "unsupported", "\(refused.content)")
            #expect(AgentStatus.benchmarkMode(client.hub) == nil)
        }
    }

    // MARK: Worlds

    @Test func theIsolatedWorldReadsTheDOMButNotThePagesGlobals() async throws {
        try await withAgent { client, base in
            let id = try await open(client, base.appending(path: "page"))
            let isolated = await evaluate(client, id, "() => [typeof window.pageGlobal, document.querySelector('#greeting').textContent]", answering: .allowOnSite)
            #expect(isolated["result"] == ["undefined", "Hello"], "\(isolated.content)")
            #expect(isolated["world"] == "isolated")
            let page = await evaluate(client, id, "() => window.pageGlobal", ["world": "page"], answering: nil)
            #expect(page["result"] == "from the page", "\(page.content)")

            // A ref is the function's first argument, args its second.
            let snapshot = await client.call("snapshot", ["tab": .string(id), "format": "json"])
            let heading = try #require(snapshot["nodes"]?.items?.first { $0["role"] == "heading" }?["ref"])
            let element = await evaluate(client, id, "(element, args) => element.textContent + args.mark", ["ref": heading, "args": ["mark": "!"]], answering: nil)
            #expect(element["result"] == "Hello!", "\(element.content)")
            let thrown = await evaluate(client, id, "() => { throw new TypeError('nope') }", answering: nil)
            #expect(thrown.code == "script_error", "\(thrown.content)")
            #expect(thrown.message.contains("TypeError: nope"))
            let undefined = await evaluate(client, id, "() => { document.title = 'Changed' }", answering: nil)
            #expect(undefined["undefined"] == true, "\(undefined.content)")
            #expect(client.tab(id)?.title == "Changed")
        }
    }

    // MARK: Secrets

    @Test func aPasswordValueOnThePageKeepsEveryScriptFromRunning() async throws {
        try await withAgent { client, base in
            let id = try await open(client, base.appending(path: "login"))
            // The ways around the first design's blank getters: none of them runs at all.
            let attempts: [(String, [String: JSONValue])] = [
                ("() => document.querySelector('#pw').value", [:]),
                ("() => document.querySelector('#pw').value", ["world": "page"]),
                ("document.title = btoa(document.querySelector('#pw').value)", [:]),
                ("document.title = btoa(document.querySelector('#pw').value)", ["world": "page"]),
                ("() => { setTimeout(() => { document.title = btoa(document.querySelector('#pw').value) }) }", [:]),
            ]
            for (function, extra) in attempts {
                let refused = await evaluate(client, id, function, extra, answering: nil)
                #expect(refused.code == "blocked", "\(function): \(refused.content)")
                #expect(refused.message.contains("a password or card field holds a value on this page"), "\(refused.content)")
            }
            #expect(client.hub.confirmations.pending.isEmpty)
            try await Task.sleep(for: .milliseconds(200))
            #expect(client.tab(id)?.title == "Sign in")

            // A same-origin frame's password counts: the script could reach it.
            let framed = try await open(client, base.appending(path: "framed"))
            #expect(await waitUntil(20) { client.tab(framed)?.isLoading == false })
            for world: JSONValue in ["isolated", "page"] {
                let refused = await evaluate(client, framed, "() => document.querySelector('iframe').contentDocument.querySelector('#pw').value", ["world": world], answering: nil)
                #expect(refused.code == "blocked", "\(world): \(refused.content)")
            }
        }
    }

    @Test func anEmptyPasswordFieldLeavesThePageOpenUntilItHoldsAValue() async throws {
        try await withAgent { client, base in
            let id = try await open(client, base.appending(path: "signin"))
            let empty = await evaluate(client, id, "() => [document.title, document.querySelector('#pw').value]", answering: .allowOnSite)
            #expect(empty["result"] == ["Sign in", ""], "\(empty.content)")
            _ = try await client.tab(id)?.webView.callAsyncJavaScript("document.querySelector('#pw').value = 'typed by the user'", contentWorld: .page)
            let filled = await evaluate(client, id, "() => document.querySelector('#pw').value", answering: nil)
            #expect(filled.code == "blocked", "\(filled.content)")
        }
    }

    @Test func cardAndCookieValuesNeverComeBack() async throws {
        try await withAgent { client, base in
            let id = try await open(client, base.appending(path: "account"))
            for (world, answer): (JSONValue, ConfirmationAnswer?) in [("isolated", .allowOnSite), ("page", nil)] {
                let result = await evaluate(client, id, "() => [document.querySelector('#note').textContent, document.cookie, JSON.stringify({ c: document.cookie })]", ["world": world], answering: answer)
                let text = String(decoding: result.content.encoded(), as: UTF8.self)
                #expect(!text.contains(Self.cookie), "\(world): \(text)")
                #expect(!text.contains("4242"), "\(world): \(text)")
                #expect(result["result"]?.items?.prefix(2) == ["Card on file [card]", "session=[redacted]"], "\(world): \(text)")
            }
        }
    }

    @Test func scrubsValuesAsWrittenAndAsJSONWritesThem() {
        let text = #"{"a":"x\"y\\z","b":"abcdefg","c":"ab","d":"tok123456"}"#
        let scrubbed = AgentHub.scrubbed(text, secrets: [#"x"y\z"#, "abcdefg", "ab"], cookies: ["tok123456", "short"])
        #expect(scrubbed == #"{"a":"[redacted]","b":"[redacted]","c":"ab","d":"[redacted]"}"#)
    }

    // MARK: Where it never runs

    @Test func neverRunsOnLithiumLocalOrPaymentPages() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "agent-evaluate-\(UUID().uuidString).html")
        try "<title>Local</title>".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        try await withAgent { client, base in
            let browser = client.browser
            let settings = browser.newTab()
            settings.load(URL(string: "lithium://settings")!)
            let local = browser.newTab()
            local.load(file)
            #expect(await waitUntil(20) { settings.url?.scheme == "lithium" && local.url?.isFileURL == true && !local.isLoading })
            for (tab, what) in [(settings, "Lithium’s page"), (local, "local file")] {
                let refused = await evaluate(client, client.hub.id(for: tab), "() => 1", answering: nil)
                #expect(refused.code == "blocked_page", "\(what): \(refused.content)")
            }

            let checkout = try await open(client, base.appending(path: "checkout"))
            // An empty card field nobody is in leaves the page open to scripts.
            let empty = await evaluate(client, checkout, "() => document.title", answering: .allowOnSite)
            #expect(empty["result"] == "Checkout", "\(empty.content)")
            _ = try await client.tab(checkout)?.webView.callAsyncJavaScript("document.querySelector('#cc').value = '4242 4242 4242 4242'", contentWorld: .page)
            let filled = await evaluate(client, checkout, "() => document.querySelector('#cc').value", answering: nil)
            #expect(filled.code == "blocked", "\(filled.content)")
            #expect(filled.message.contains("a password or card field holds a value on this page"), "\(filled.content)")

            client.hub.paymentProviders = PaymentProviders(hosts: ["localhost"])
            let provider = try await open(client, base.appending(path: "provider"))
            #expect(await waitUntil(20) { client.tab(provider)?.isLoading == false })
            let framed = await evaluate(client, provider, "() => 1", answering: nil)
            #expect(framed.code == "blocked", "\(framed.content)")
            #expect(client.hub.confirmations.pending.isEmpty)
        }
    }

    // MARK: Time

    @Test func aScriptThatNeverEndsEndsTheCallOnTime() async throws {
        try await withAgent { client, base in
            let id = try await open(client, base.appending(path: "page"))
            _ = await evaluate(client, id, "() => 0", answering: .allowOnSite)
            // Kept reachable: WebKit fails a promise nothing can settle any more on its own.
            let started = ContinuousClock.now
            let stuck = await evaluate(client, id, "() => new Promise((settle) => { window.neverSettled = settle })", ["timeoutMs": 300], answering: nil)
            #expect(stuck.code == "timeout", "\(stuck.content)")
            #expect(ContinuousClock.now - started < .seconds(3))
            let next = await evaluate(client, id, "() => 'free'", answering: nil)
            #expect(next["result"] == "free", "\(next.content)")
        }
    }

    @Test func timeoutMsCountsTheScriptAlone() async throws {
        try await withAgent { client, base in
            let id = try await open(client, base.appending(path: "page"))
            let quick = await evaluate(client, id, "() => 1", ["timeoutMs": 100], answering: .allowOnSite)
            #expect(quick["result"] == 1, "\(quick.content)")
            let short = await evaluate(client, id, "() => 1", ["timeoutMs": 99], answering: nil)
            #expect(short.code == "invalid_params", "\(short.content)")
        }
    }

    // MARK: Log

    @Test func theLogLineMasksSecretsAndCutsTheFunction() async throws {
        try await withAgent { client, base in
            let id = try await open(client, base.appending(path: "login"))
            let padding = String(repeating: " ", count: 400)
            let function = "() => '\(Self.password)' === document.title\(padding)"
            let result = await evaluate(client, id, function, ["world": "page"], answering: nil)
            #expect(result.code == "blocked", "\(result.content)")
            let log = try String(contentsOf: AgentLog.folder.appending(path: AgentLog.fileName(for: Date())), encoding: .utf8)
            #expect(!log.contains(Self.password))
            let line = try #require(log.split(separator: "\n").last { $0.contains("\"evaluate\"") }.map { try JSONValue.decode(Data($0.utf8)) })
            let logged = try #require(line["params"]?["function"]?.string)
            #expect(logged.hasPrefix("() => '[redacted]' === document.title"), "\(logged)")
            #expect(logged.count == CallNotes.loggedScriptLength + 1)
            #expect(line["params"]?["world"] == "page")
            #expect(line["result"]?["ok"] == false)
            #expect(line["ms"]?.int != nil)
        }
    }
}

private extension JSONValue {
    var items: [JSONValue]? {
        if case .array(let items) = self { items } else { nil }
    }

    var int: Int? {
        if case .int(let value) = self { value } else { nil }
    }
}

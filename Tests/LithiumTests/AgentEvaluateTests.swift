import Foundation
import Testing
import WebKit
@testable import Lithium

/// `evaluate` on a whole Browser through the hub, on pages served from 127.0.0.1: the one switch
/// and no prompt, in the user's tabs too and inside `batch`, the two worlds, no script while a
/// password or card value is on the page, card and cookie values kept out of results and the
/// log, the pages it never runs on, and a script that never ends.
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

    /// PR 10's benchmark mode, removed in PR 11: its key must change nothing.
    private static let oldBenchmarkKey = "agentScriptsAutoAllowUntil"

    private func withAgent(scripts: Bool = true, _ body: (Client, URL) async throws -> Void) async throws {
        UserDefaults.standard.removeObject(forKey: Preference.agentAccess)
        UserDefaults.standard.set(scripts, forKey: Preference.agentRunScripts)
        defer {
            UserDefaults.standard.removeObject(forKey: Preference.agentRunScripts)
            UserDefaults.standard.removeObject(forKey: Self.oldBenchmarkKey)
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

    /// Runs `function` in `tab`. Nothing ever asks the user.
    private func evaluate(_ client: Client, _ tab: String, _ function: String, _ extra: [String: JSONValue] = [:]) async -> AgentTabsTests.ToolResult {
        var arguments: [String: JSONValue] = ["tab": .string(tab), "function": .string(function)]
        arguments.merge(extra) { $1 }
        let result = await client.call("evaluate", .object(arguments))
        #expect(client.hub.confirmations.pending.isEmpty && client.hub.confirmations.grants.isEmpty)
        return result
    }

    private func toolNames(_ client: Client) async -> [String] {
        let reply = await client.hub.handle(.message(["jsonrpc": "2.0", "id": 2, "method": "tools/list"], session: client.session, protocolVersion: nil))
        return (reply.body?["result"]?["tools"]?.items ?? []).compactMap { $0["name"]?.string }
    }

    // MARK: The switch

    /// Off: not listed, refused alone and inside a batch, before any step runs. PR 10's
    /// benchmark-mode date, still set, changes none of it.
    @Test func offItIsUnlistedAndRefusedEvenInABatch() async throws {
        try await withAgent(scripts: false) { client, base in
            UserDefaults.standard.set(Date().addingTimeInterval(10 * 60), forKey: Self.oldBenchmarkKey)
            #expect(await !toolNames(client).contains("evaluate"))
            let id = try await open(client, base.appending(path: "page"))
            let refused = await client.call("evaluate", ["tab": .string(id), "function": "() => 1"])
            #expect(refused.code == "unsupported", "\(refused.content)")
            let batch = await client.call("batch", ["tab": .string(id), "steps": [
                ["tool": "wait_for", "args": ["text": "Hello"]],
                ["tool": "evaluate", "args": ["function": "() => { document.title = 'Ran' }"]],
            ]])
            #expect(batch.code == "unsupported", "\(batch.content)")
            #expect(client.tab(id)?.title == "Page")
            #expect(client.hub.confirmations.pending.isEmpty)

            UserDefaults.standard.set(true, forKey: Preference.agentRunScripts)
            #expect(await toolNames(client).contains("evaluate"))
        }
    }

    /// On: in the user's own tab as in the agent's, with no banner and no site grant, and the
    /// benchmark-mode key adds nothing.
    @Test func onItRunsInTheUsersTabWithoutAsking() async throws {
        try await withAgent { client, base in
            UserDefaults.standard.set(Date().addingTimeInterval(10 * 60), forKey: Self.oldBenchmarkKey)
            let browser = client.browser
            let mine = browser.newTab()
            mine.load(base.appending(path: "page"))
            #expect(await waitUntil(20) { mine.title == "Page" && !mine.isLoading })
            #expect(!mine.isInAgentGroup)
            let ran = await evaluate(client, client.hub.id(for: mine), "() => document.querySelector('#greeting').textContent")
            #expect(ran["result"] == "Hello", "\(ran.content)")
            #expect(ran["grant"] == nil)
            let id = try await open(client, base.appending(path: "page"))
            let again = await evaluate(client, id, "async () => { await new Promise((done) => setTimeout(done, 10)); return [1, 'two', null] }")
            #expect(again["result"] == [1, "two", .null], "\(again.content)")
            #expect(!client.hub.recentLog.contains { $0.tool.hasPrefix("confirm") })
        }
    }

    /// A step of its own in a batch, with its own log line; the secret check holds there too.
    @Test func inABatchItIsAStepWithItsOwnLogLine() async throws {
        try await withAgent { client, base in
            let batch = await client.call("batch", ["url": .string(base.appending(path: "page").absoluteString), "close": true, "steps": [
                ["tool": "evaluate", "args": ["function": "() => document.querySelector('#greeting').textContent"]],
            ]])
            #expect(!batch.isError, "\(batch.content)")
            #expect(batch["steps"]?.items?.first?["result"] == "Hello", "\(batch.content)")
            let logged = await client.hub.log.entries(limit: 2)
            #expect(logged.map { $0["tool"]?.string ?? "" } == ["batch", "evaluate"], "\(logged)")

            let login = try await open(client, base.appending(path: "login"))
            let refused = await client.call("batch", ["tab": .string(login), "steps": [
                ["tool": "evaluate", "args": ["function": "() => document.querySelector('#pw').value"]],
            ]])
            let step = refused["steps"]?.items?.first
            #expect(step?["code"] == "blocked", "\(refused.content)")
            #expect(step?["message"]?.string?.contains("a password or card field holds a value on this page") == true, "\(refused.content)")
            #expect(!String(decoding: refused.content.encoded(), as: UTF8.self).contains(Self.password))
        }
    }

    /// `tab_open`'s line names its steps' tools alone, as `batch`'s does: the values typed, the
    /// form's and the script's are each in their step's own line, redacted there, or nowhere.
    @Test func tabOpenLogsItsStepsToolsAlone() async throws {
        try await withAgent { client, base in
            let opened = await client.call("tab_open", ["url": .string(base.appending(path: "signin").absoluteString), "steps": [
                ["tool": "evaluate", "args": ["function": "(a) => 'fn-secret' + a", "args": ["arg-secret"]]],
                ["tool": "type", "args": ["ref": "e9999", "text": "typed-secret"]],
                ["tool": "fill_form", "args": ["fields": [["ref": "e9999", "value": "form-secret"]]]],
            ]])
            #expect(opened["steps"]?.items?.map { $0["ok"] ?? .null } == [true, false, .null], "\(opened.content)")
            let logged = await client.hub.log.entries(limit: 3)
            #expect(logged.map { $0["tool"]?.string ?? "" } == ["tab_open", "type", "evaluate"], "\(logged)")
            let line = try #require(logged.first)
            #expect(line["params"]?["steps"] == [["tool": "evaluate"], ["tool": "type"], ["tool": "fill_form"]], "\(line)")
            let text = String(decoding: line.encoded(), as: UTF8.self)
            for secret in ["fn-secret", "arg-secret", "typed-secret", "form-secret"] { #expect(!text.contains(secret), "\(text)") }
            #expect(logged.dropFirst().first?["params"]?["text"] == "[redacted]", "\(logged)")
        }
    }

    // MARK: Worlds

    @Test func theIsolatedWorldReadsTheDOMButNotThePagesGlobals() async throws {
        try await withAgent { client, base in
            let id = try await open(client, base.appending(path: "page"))
            let isolated = await evaluate(client, id, "() => [typeof window.pageGlobal, document.querySelector('#greeting').textContent]")
            #expect(isolated["result"] == ["undefined", "Hello"], "\(isolated.content)")
            #expect(isolated["world"] == "isolated")
            let page = await evaluate(client, id, "() => window.pageGlobal", ["world": "page"])
            #expect(page["result"] == "from the page", "\(page.content)")

            // A ref is the function's first argument, args its second.
            let snapshot = await client.call("snapshot", ["tab": .string(id), "format": "json"])
            let heading = try #require(snapshot["nodes"]?.items?.first { $0["role"] == "heading" }?["ref"])
            let element = await evaluate(client, id, "(element, args) => element.textContent + args.mark", ["ref": heading, "args": ["mark": "!"]])
            #expect(element["result"] == "Hello!", "\(element.content)")
            let thrown = await evaluate(client, id, "() => { throw new TypeError('nope') }")
            #expect(thrown.code == "script_error", "\(thrown.content)")
            #expect(thrown.message.contains("TypeError: nope"))
            let undefined = await evaluate(client, id, "() => { document.title = 'Changed' }")
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
                let refused = await evaluate(client, id, function, extra)
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
                let refused = await evaluate(client, framed, "() => document.querySelector('iframe').contentDocument.querySelector('#pw').value", ["world": world])
                #expect(refused.code == "blocked", "\(world): \(refused.content)")
            }
        }
    }

    @Test func anEmptyPasswordFieldLeavesThePageOpenUntilItHoldsAValue() async throws {
        try await withAgent { client, base in
            let id = try await open(client, base.appending(path: "signin"))
            let empty = await evaluate(client, id, "() => [document.title, document.querySelector('#pw').value]")
            #expect(empty["result"] == ["Sign in", ""], "\(empty.content)")
            _ = try await client.tab(id)?.webView.callAsyncJavaScript("document.querySelector('#pw').value = 'typed by the user'", contentWorld: .page)
            let filled = await evaluate(client, id, "() => document.querySelector('#pw').value")
            #expect(filled.code == "blocked", "\(filled.content)")
        }
    }

    @Test func cardAndCookieValuesNeverComeBack() async throws {
        try await withAgent { client, base in
            let id = try await open(client, base.appending(path: "account"))
            for world: JSONValue in ["isolated", "page"] {
                let result = await evaluate(client, id, "() => [document.querySelector('#note').textContent, document.cookie, JSON.stringify({ c: document.cookie })]", ["world": world])
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

    /// A result of up to a megabyte is scrubbed, cut and decoded off the main actor: here from
    /// a detached task, which only a nonisolated function allows.
    @Test func scriptResultsAreShownOffTheMainActor() async {
        let whole = await Task.detached { AgentHub.shown(#"{"a":"abcdefg","n":1}"#, cut: false, secrets: ["abcdefg"], cookies: []) }.value
        #expect(whole.result == ["a": "[redacted]", "n": 1])
        #expect(!whole.truncated)
        let long = "\"" + String(repeating: "x", count: AgentHub.maxScriptResult + 10) + "\""
        let cut = await Task.detached { AgentHub.shown(long, cut: false, secrets: [], cookies: []) }.value
        #expect(cut.truncated && cut.text.count == AgentHub.maxScriptResult && cut.result == .string(cut.text))
        #expect(await Task.detached { AgentHub.shown("1", cut: true, secrets: [], cookies: []) }.value.truncated)
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
                let refused = await evaluate(client, client.hub.id(for: tab), "() => 1")
                #expect(refused.code == "blocked_page", "\(what): \(refused.content)")
            }

            let checkout = try await open(client, base.appending(path: "checkout"))
            // An empty card field nobody is in leaves the page open to scripts.
            let empty = await evaluate(client, checkout, "() => document.title")
            #expect(empty["result"] == "Checkout", "\(empty.content)")
            _ = try await client.tab(checkout)?.webView.callAsyncJavaScript("document.querySelector('#cc').value = '4242 4242 4242 4242'", contentWorld: .page)
            let filled = await evaluate(client, checkout, "() => document.querySelector('#cc').value")
            #expect(filled.code == "blocked", "\(filled.content)")
            #expect(filled.message.contains("a password or card field holds a value on this page"), "\(filled.content)")

            client.hub.paymentProviders = PaymentProviders(hosts: ["localhost"])
            let provider = try await open(client, base.appending(path: "provider"))
            #expect(await waitUntil(20) { client.tab(provider)?.isLoading == false })
            let framed = await evaluate(client, provider, "() => 1")
            #expect(framed.code == "blocked", "\(framed.content)")
            #expect(client.hub.confirmations.pending.isEmpty)
        }
    }

    /// A result cut inside an emoji, or holding half of one, still comes back: neither makes the
    /// answer one Swift's JSON decoder refuses ("page changed while the script ran").
    @Test func emojiAndLoneSurrogatesInAResultComeBack() async throws {
        try await withAgent { client, base in
            let id = try await open(client, base.appending(path: "page"))
            let lone = await evaluate(client, id, "() => ({ text: 'a\\uD83Db', [String.fromCharCode(0xDE00)]: 1 })")
            #expect(lone["result"] == ["text": "a\u{FFFD}b", "\u{FFFD}": 1], "\(lone.content)")
            // As JSON, a quote and then pairs: the cap's last unit is the first half of one.
            let cut = await evaluate(client, id, "() => '😀'.repeat(\(AgentHub.maxScriptResult * 6))")
            #expect(!cut.isError, "\(cut.content)")
            #expect(cut["truncated"] == true, "\(cut.content)")
            #expect(cut["result"]?.string?.hasPrefix("\"😀😀") == true)
        }
    }

    // MARK: Time

    @Test func aScriptThatNeverEndsEndsTheCallOnTime() async throws {
        try await withAgent { client, base in
            let id = try await open(client, base.appending(path: "page"))
            // Kept reachable: WebKit fails a promise nothing can settle any more on its own.
            let started = ContinuousClock.now
            let stuck = await evaluate(client, id, "() => new Promise((settle) => { window.neverSettled = settle })", ["timeoutMs": 300])
            #expect(stuck.code == "timeout", "\(stuck.content)")
            #expect(ContinuousClock.now - started < .seconds(3))
            let next = await evaluate(client, id, "() => 'free'")
            #expect(next["result"] == "free", "\(next.content)")
        }
    }

    @Test func timeoutMsCountsTheScriptAlone() async throws {
        try await withAgent { client, base in
            let id = try await open(client, base.appending(path: "page"))
            let quick = await evaluate(client, id, "() => 1", ["timeoutMs": 100])
            #expect(quick["result"] == 1, "\(quick.content)")
            let short = await evaluate(client, id, "() => 1", ["timeoutMs": 99])
            #expect(short.code == "invalid_params", "\(short.content)")
        }
    }

    // MARK: Log

    @Test func theLogLineMasksSecretsAndCutsTheFunction() async throws {
        try await withAgent { client, base in
            let id = try await open(client, base.appending(path: "login"))
            let padding = String(repeating: " ", count: 400)
            let function = "() => '\(Self.password)' === document.title\(padding)"
            let result = await evaluate(client, id, function, ["world": "page"])
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

import Foundation
import Testing
import WebKit
@testable import Lithium

/// `evaluate` on a whole Browser through the hub, on pages served from 127.0.0.1: the switch, the
/// prompt and the site grant, the two worlds, secrets kept out of results and the log, the pages
/// it never runs on, and a script that never ends. Prompts are answered through
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
        "/login": ("\(html)\r\nSet-Cookie: session=\(cookie); Path=/", """
            <title>Sign in</title>
            <form><input id="user" name="user" value="ann"><input type="password" id="pw" name="pw"></form>
            <p id="note">Card on file 4242 4242 4242 4242</p>
            <script>pw.value = '\(password)'</script>
            """),
        "/checkout": (html, "<title>Checkout</title><label>Card number <input id='cc' autocomplete='cc-number'></label>"),
        "/provider": (html, """
            <title>Provider</title><body>
            <script>document.body.append(Object.assign(document.createElement('iframe'), { src: location.protocol + '//localhost:' + location.port + '/page' }))</script>
            """),
    ]

    private func withAgent(scripts: Bool = true, _ body: (Client, URL) async throws -> Void) async throws {
        UserDefaults.standard.removeObject(forKey: Preference.agentAccess)
        UserDefaults.standard.set(scripts, forKey: Preference.agentRunScripts)
        defer { UserDefaults.standard.removeObject(forKey: Preference.agentRunScripts) }
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

    @Test func passwordCardAndCookieValuesNeverComeBack() async throws {
        try await withAgent { client, base in
            let id = try await open(client, base.appending(path: "login"))
            let isolated = await evaluate(client, id, """
                () => ({
                  value: document.querySelector('#pw').value,
                  attribute: document.querySelector('#pw').getAttribute('value'),
                  form: [...new FormData(document.querySelector('form')).keys()],
                  user: document.querySelector('#user').value,
                  note: document.querySelector('#note').textContent,
                })
                """, answering: .allowOnSite)
            #expect(isolated["result"] == ["value": "", "attribute": .null, "form": ["user"], "user": "ann", "note": "Card on file [card]"], "\(isolated.content)")
            // A getter from a fresh frame's realm gets past the blank one; the scrub still holds.
            let around = await evaluate(client, id, """
                () => {
                  const frame = document.body.appendChild(document.createElement('iframe'));
                  return Object.getOwnPropertyDescriptor(frame.contentWindow.HTMLInputElement.prototype, 'value').get.call(document.querySelector('#pw'));
                }
                """, answering: nil)
            #expect(around["result"] == "[redacted]", "\(around.content)")

            // The page's world can't be blinded: what comes back is scrubbed instead, as written
            // and inside JSON strings.
            let page = await evaluate(client, id, "() => [document.querySelector('#pw').value, JSON.stringify({ pw: document.querySelector('#pw').value }), document.cookie]", ["world": "page"], answering: nil)
            let text = String(decoding: page.content.encoded(), as: UTF8.self)
            #expect(!text.contains(Self.password), "\(text)")
            #expect(!text.contains(Self.cookie), "\(text)")
            #expect(!text.contains("4242"))
            #expect(page["result"]?.items?.first == "[redacted]", "\(text)")
            #expect(page["result"]?.items?.last == "session=[redacted]", "\(text)")
            // The getter is back as it was once the script ended.
            let after = try await client.tab(id)?.webView.callAsyncJavaScript("return document.querySelector('#pw').value", contentWorld: AgentHub.scriptWorld) as? String
            #expect(after == Self.password)
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
            #expect(filled.code == "blocked_payment", "\(filled.content)")

            client.hub.paymentProviders = PaymentProviders(hosts: ["localhost"])
            let provider = try await open(client, base.appending(path: "provider"))
            #expect(await waitUntil(20) { client.tab(provider)?.isLoading == false })
            let framed = await evaluate(client, provider, "() => 1", answering: nil)
            #expect(framed.code == "blocked_payment", "\(framed.content)")
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

    // MARK: Log

    @Test func theLogLineMasksSecretsAndCutsTheFunction() async throws {
        try await withAgent { client, base in
            let id = try await open(client, base.appending(path: "login"))
            let padding = String(repeating: " ", count: 400)
            let function = "() => '\(Self.password)' === document.title\(padding)"
            let result = await evaluate(client, id, function, ["world": "page"], answering: .allowOnce)
            #expect(result["result"] == false, "\(result.content)")
            let log = try String(contentsOf: AgentLog.folder.appending(path: AgentLog.fileName(for: Date())), encoding: .utf8)
            #expect(!log.contains(Self.password))
            let line = try #require(log.split(separator: "\n").last { $0.contains("\"evaluate\"") }.map { try JSONValue.decode(Data($0.utf8)) })
            let logged = try #require(line["params"]?["function"]?.string)
            #expect(logged.hasPrefix("() => '[redacted]' === document.title"), "\(logged)")
            #expect(logged.count == CallNotes.loggedScriptLength + 1)
            #expect(line["params"]?["world"] == "page")
            #expect(line["result"]?["ok"] == true)
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

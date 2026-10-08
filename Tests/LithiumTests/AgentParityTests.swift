import Foundation
import Testing
import WebKit
@testable import Lithium

/// Private tabs, `fill_form`, `resize`, `wait_for` time and textGone, tool annotations and the
/// server's instructions, on a whole Browser through the hub, on pages served from 127.0.0.1.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct AgentParityTests {
    typealias Client = AgentTabsTests.Client

    private static let html = "Content-Type: text/html; charset=utf-8"
    /// Unique per run, so no cookie left in the throwaway home answers for this one.
    private static let cookie = "pr8probe\(UInt32.random(in: 1...UInt32.max))"

    private static let pages: [String: (headers: String, body: String)] = [
        "/set": ("\(html)\r\nSet-Cookie: \(cookie)=private-value; Path=/", "<title>Set</title>"),
        "/set-user": ("\(html)\r\nSet-Cookie: \(cookie)user=user-value; Path=/", "<title>Set user</title>"),
        "/filter": (html, """
            <title>Filter</title><style>body { margin: 0; font: 16px sans-serif } input, select { display: block; margin: 8px }</style>
            <input aria-label="Search" id="q">
            <input type="checkbox" aria-label="Open now" id="openNow">
            <select aria-label="Sort" id="sort"><option value="new">Newest</option><option value="near">Nearest</option></select>
            <script>
            const show = () => { document.title = [q.value, openNow.checked, sort.value].join('|') };
            q.addEventListener('input', () => { history.replaceState(null, '', '?q=' + encodeURIComponent(q.value)); show() });
            openNow.addEventListener('change', () => { location.hash = 'open=' + openNow.checked; show() });
            sort.addEventListener('change', () => { history.pushState(null, '', '?sort=' + sort.value); show() });
            </script>
            """),
        "/jump": (html, """
            <title>Jump</title><style>body { margin: 0; font: 16px sans-serif } input, select { display: block; margin: 8px }</style>
            <select aria-label="Go to" onchange="location = '/show'"><option value="">Choose</option><option>Show</option></select>
            <input aria-label="Note">
            """),
        "/show": (html, "<title>Show</title><script>document.title = 'cookies:' + document.cookie</script>"),
        "/form": (html, """
            <title>Form</title><style>body { margin: 0; font: 16px sans-serif } input, select { display: block; margin: 8px }</style>
            <input aria-label="Name" id="fullname">
            <select aria-label="Country" id="country"><option value="">Choose</option><option value="fr">France</option><option value="es">Spain</option></select>
            <label><input type="checkbox" id="news"> Newsletter</label>
            <label><input type="radio" name="size" value="s"> Small</label>
            <label><input type="radio" name="size" value="l" id="large"> Large</label>
            <script>
            const show = () => { document.title = [fullname.value, country.value, news.checked, large.checked].join('|') };
            document.addEventListener('input', show); document.addEventListener('change', show);
            </script>
            """),
        // A field that takes 200 characters, on a page that takes its time over every key.
        "/capped": (html, """
            <title>Capped</title><style>body { margin: 0; font: 16px sans-serif } textarea { display: block; margin: 8px; width: 400px; height: 60px }</style>
            <textarea aria-label="Pitch" id="pitch" maxlength="200"></textarea>
            <textarea aria-label="Team" id="team"></textarea>
            <script>pitch.addEventListener('keydown', () => { const end = Date.now() + 10; while (Date.now() < end) {} });</script>
            """),
        "/vanish": (html, "<title>Vanish</title><p id='note'>Saving…</p><script>setTimeout(() => note.remove(), 300)</script>"),
        "/wide": (html, "<title>Wide</title><style>body { margin: 0 } button { position: absolute; left: 1450px; top: 900px }</style><button onclick=\"document.title = 'clicked ' + innerWidth\">Far</button>"),
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

    private func open(_ client: Client, _ url: URL, ephemeral: Bool = false) async throws -> String {
        let opened = await client.call("tab_open", ["url": .string(url.absoluteString), "wait": "load", "ephemeral": .bool(ephemeral)])
        #expect(!opened.isError, "\(opened.content)")
        return try #require(opened["tab"]?.string)
    }

    private func title(_ client: Client, _ id: String, after url: URL) async throws -> String {
        let shown = await client.call("navigate", ["tab": .string(id), "url": .string(url.absoluteString), "diff": false])
        #expect(!shown.isError, "\(shown.content)")
        return try #require(shown["title"]?.string)
    }

    /// The ref of the snapshot node with that name.
    private func ref(_ client: Client, _ id: String, _ name: String) async throws -> String {
        let snapshot = await client.call("snapshot", ["tab": .string(id), "format": "json"])
        let nodes = snapshot["nodes"]?.items ?? []
        return try #require(nodes.first { $0["name"]?.string == name }?["ref"]?.string, "\(name) in \(snapshot.content)")
    }

    // MARK: Private tabs

    @Test func privateTabsKeepTheirOwnCookiesAndLeaveNoTrace() async throws {
        // History is shared by every test in the process and ports get reused: only this test's
        // own visits to /set can say whether the private tab left a trace.
        let started = Date()
        try await withAgent { client, base in
            let browser = client.browser
            let id = try await open(client, base.appending(path: "set"), ephemeral: true)
            let tab = try #require(client.tab(id))
            #expect(tab.isEphemeral)
            #expect(tab.isInAgentGroup)
            let listed = await client.call("tabs_list")
            #expect(listed["tabs"]?.items?.first { $0["tab"]?.string == id }?["ephemeral"] == true)

            let show = base.appending(path: "show")
            #expect(try await title(client, id, after: show).contains("\(Self.cookie)=private-value"))
            let ordinary = try await open(client, show)
            #expect(client.tab(ordinary)?.title.contains(Self.cookie) == false, "the user's store has none of it")
            let other = try await open(client, show, ephemeral: true)
            #expect(client.tab(other)?.title.contains(Self.cookie) == false, "each private tab has its own store")

            // Asleep and awake again, the page keeps its store and its cookie.
            tab.sleep(configuration: browser.makeConfiguration(for: tab.url))
            #expect(tab.isAsleep)
            let woken = await client.call("reload", ["tab": .string(id), "diff": false])
            #expect(!woken.isError, "\(woken.content)")
            #expect(tab.webView.configuration.websiteDataStore === tab.privateStore)
            #expect(tab.title.contains("\(Self.cookie)=private-value"))

            // Nothing saved: no visit, no session entry, no favorite, no reopening.
            #expect(!browser.history.visits(matching: "set").contains { $0.url.port == base.port && $0.url.lastPathComponent == "set" && $0.date >= started })
            browser.pin(tab)
            #expect(tab.pinID == nil)
            await Task.yield()
            #expect(!SessionStore.load().tabs.contains { $0.url.lastPathComponent == "set" && $0.url.port == base.port })
            let reopenable = browser.canReopenClosedTab
            browser.close(tab)
            #expect(browser.canReopenClosedTab == reopenable)
            #expect((await client.call("tab_open", ["ephemeral": "yes"])).code == "invalid_params")
        }
    }

    @Test func aCopyOfAPrivateTabSharesItsStore() async throws {
        try await withAgent { client, base in
            let browser = client.browser
            let id = try await open(client, base.appending(path: "set"), ephemeral: true)
            let tab = try #require(client.tab(id))
            browser.duplicate(tab)
            let copy = try #require(browser.selectedTab)
            #expect(copy !== tab)
            #expect(copy.privateStore === tab.privateStore)
            #expect(copy.isInTabList, "the user's copy goes to the tab list, still private")
            browser.close(tab)
            #expect(copy.privateStore != nil)
        }
    }

    // MARK: fill_form

    @Test func fillsAFormFieldByField() async throws {
        try await withAgent { client, base in
            let id = try await open(client, base.appending(path: "form"))
            let fields: JSONValue = [
                ["ref": .string(try await ref(client, id, "Name")), "type": "textbox", "value": "Ann Lee"],
                ["ref": .string(try await ref(client, id, "Country")), "type": "combobox", "value": "Spain"],
                ["ref": .string(try await ref(client, id, "Newsletter")), "type": "checkbox", "value": true],
                ["ref": .string(try await ref(client, id, "Large")), "type": "radio", "value": "true"],
            ]
            let filled = await client.call("fill_form", ["tab": .string(id), "fields": fields])
            #expect(!filled.isError, "\(filled.content)")
            #expect(filled["filled"]?.items?.count == 4)
            #expect(filled["diff"] != nil)
            #expect(client.tab(id)?.title == "Ann Lee|es|true|true", "\(filled.content)")

            // Checked before anything is typed.
            let wrong = await client.call("fill_form", ["tab": .string(id), "fields": [["ref": "e1", "type": "slider", "value": "3"]]])
            #expect(wrong.code == "invalid_params", "\(wrong.content)")
            // A field that fails names itself; the ones before it stay filled.
            let stale = await client.call("fill_form", ["tab": .string(id), "fields": [
                ["ref": .string(try await ref(client, id, "Name")), "type": "textbox", "value": "Bo"],
                ["ref": "e9999", "type": "textbox", "value": "x"],
            ]])
            #expect(stale.isError)
            #expect(stale.message.hasPrefix("Field 2 of 2 (e9999)"), "\(stale.content)")
            #expect(client.tab(id)?.title.hasPrefix("Bo|") == true)

            let logged = await client.hub.log.entries(limit: 20).filter { $0["tool"] == "fill_form" }
            #expect(!logged.isEmpty)
            let text = logged.map { String(decoding: $0.encoded(), as: UTF8.self) }.joined()
            #expect(!text.contains("Ann Lee") && !text.contains("Spain") && !text.contains("\"Bo\""), "\(text)")
        }
    }

    /// A filter form writing its state in the address (replaceState, pushState, a hash) stays the
    /// same document: every field is filled. A field that loads another page stops the rest.
    @Test func fillsAFormThatWritesTheAddressButStopsAtANewPage() async throws {
        try await withAgent { client, base in
            let id = try await open(client, base.appending(path: "filter"))
            let filled = await client.call("fill_form", ["tab": .string(id), "fields": [
                ["ref": .string(try await ref(client, id, "Search")), "type": "textbox", "value": "cafe"],
                ["ref": .string(try await ref(client, id, "Open now")), "type": "checkbox", "value": true],
                ["ref": .string(try await ref(client, id, "Sort")), "type": "combobox", "value": "Nearest"],
            ]])
            #expect(!filled.isError, "\(filled.content)")
            #expect(filled["filled"]?.items?.count == 3)
            #expect(client.tab(id)?.title == "cafe|true|near", "\(filled.content)")
            #expect(client.tab(id)?.url?.query() == "sort=near", "\(client.tab(id)?.url?.absoluteString ?? "")")

            let jump = try await open(client, base.appending(path: "jump"))
            let goTo = try await ref(client, jump, "Go to")
            let stopped = await client.call("fill_form", ["tab": .string(jump), "fields": [
                ["ref": .string(goTo), "type": "combobox", "value": "Show"],
                ["ref": .string(try await ref(client, jump, "Note")), "type": "textbox", "value": "x"],
            ]])
            #expect(stopped.code == "navigation_failed", "\(stopped.content)")
            #expect(stopped.message == "Field 1 of 2 (\(goTo)) made \(jump) load another page: the fields after it weren’t filled.", "\(stopped.content)")
        }
    }

    /// More than a field takes, on a page slow to handle each key: the field keeps what it takes,
    /// and none of the rest reaches the next field, which the next click focuses.
    @Test func aFieldThatTakesLessKeepsTheRestOutOfTheNextField() async throws {
        try await withAgent { client, base in
            let id = try await open(client, base.appending(path: "capped"))
            let long = String(repeating: "abcdefghij", count: 26)
            let filled = await client.call("fill_form", ["tab": .string(id), "fields": [
                ["ref": .string(try await ref(client, id, "Pitch")), "type": "textbox", "value": .string(long)],
                ["ref": .string(try await ref(client, id, "Team")), "type": "textbox", "value": "two"],
            ]])
            #expect(!filled.isError, "\(filled.content)")
            let webView = try #require(client.tab(id)?.webView)
            #expect(try await webView.callAsyncJavaScript("return pitch.value", contentWorld: .page) as? String == String(long.prefix(200)))
            #expect(try await webView.callAsyncJavaScript("return team.value", contentWorld: .page) as? String == "two")
        }
    }

    // MARK: Site info

    /// The lock's panel on a private tab counts and clears the private store's cookies; the
    /// user's own cookie for the same site stays.
    @Test func siteInfoOfAPrivateTabUsesItsOwnStore() async throws {
        // The user's cookie lands in the shared default store (cookies ignore the port): remove it
        // before and after, so other tests that expect that store clean pass in any order.
        let removeUserCookies = {
            let store = WKWebsiteDataStore.default().httpCookieStore
            for cookie in await store.allCookies() where cookie.name.hasPrefix(Self.cookie) { await store.deleteCookie(cookie) }
        }
        await removeUserCookies()
        try await withAgent { client, base in
            let id = try await open(client, base.appending(path: "set"), ephemeral: true)
            _ = try await open(client, base.appending(path: "set-user"))
            let tab = try #require(client.tab(id))
            let names = { (store: WKWebsiteDataStore) in await store.httpCookieStore.allCookies().map(\.name).filter { $0.hasPrefix(Self.cookie) } }
            #expect(await names(.default()) == ["\(Self.cookie)user"])
            #expect(await names(tab.dataStore) == [Self.cookie])

            let info = SiteInfo(url: try #require(tab.url), loadError: tab.loadError, store: tab.dataStore)
            await info.load()
            #expect(info.cookieCount == 1)
            #expect(info.hasData)
            await info.clear()
            #expect(info.cookieCount == 0)
            #expect(await names(tab.dataStore) == [])
            #expect(await names(.default()) == ["\(Self.cookie)user"], "the user's cookie stays")
        }
        await removeUserCookies()
    }

    // MARK: resize

    @Test func resizesAPageOutOfTheUsersWindow() async throws {
        try await withAgent { client, base in
            let id = try await open(client, base.appending(path: "wide"))
            let small = await client.call("resize", ["tab": .string(id), "width": 600, "height": 400])
            #expect(!small.isError, "\(small.content)")
            #expect(small["width"] == 600 && small["height"] == 400)
            let snapshot = await client.call("snapshot", ["tab": .string(id), "format": "json"])
            #expect(snapshot["viewport"]?["w"] == 600 && snapshot["viewport"]?["h"] == 400, "\(snapshot["viewport"] ?? .null)")

            // Larger than the stage: the page lays out and takes clicks at that size.
            let large = await client.call("resize", ["tab": .string(id), "width": 1600, "height": 1000])
            #expect(large["width"] == 1600, "\(large.content)")
            let view = try #require(client.tab(id)?.loadedWebView)
            #expect(view.frame.size == CGSize(width: 1600, height: 1000), "\(view.frame) in \(String(describing: view.superview?.frame)), mask \(view.autoresizingMask.rawValue)")
            #expect(large["viewport"] == ["w": 1600, "h": 1000], "\(large.content)")
            let again = await client.call("snapshot", ["tab": .string(id), "format": "json"])
            #expect(again["viewport"]?["w"] == 1600, "\(again["viewport"] ?? .null)")
            let clicked = await client.call("click", ["tab": .string(id), "ref": .string(try await ref(client, id, "Far")), "diff": false])
            #expect(!clicked.isError, "\(clicked.content)")
            #expect(client.tab(id)?.title == "clicked 1600")

            #expect((await client.call("resize", ["tab": .string(id), "width": 50, "height": 400])).code == "invalid_params")
            let tab = try #require(client.tab(id))
            tab.didComeIntoView()
            #expect(client.hub.tabs[tab.id]?.viewport == nil, "the user's window gives the page its size again")
        }
    }

    // MARK: wait_for

    @Test func waitsForATimeAndForTextToGo() async throws {
        try await withAgent { client, base in
            let id = try await open(client, base.appending(path: "vanish"))
            let gone = await client.call("wait_for", ["tab": .string(id), "textGone": "Saving", "diff": false])
            #expect(gone["met"] == true, "\(gone.content)")
            let started = ContinuousClock.now
            let waited = await client.call("wait_for", ["tab": .string(id), "time": 250, "diff": false])
            #expect(waited["met"] == true, "\(waited.content)")
            #expect(ContinuousClock.now - started >= .milliseconds(250))
            #expect((await client.call("wait_for", ["tab": .string(id), "time": 2000, "timeoutMs": 1000])).code == "invalid_params")
            #expect((await client.call("wait_for", ["tab": .string(id), "textGone": "x", "present": true])).code == "invalid_params")
            #expect((await client.call("wait_for", ["tab": .string(id), "time": 100, "text": "x"])).code == "invalid_params")

            // Closing the tab ends a time wait at once.
            let tab = try #require(client.tab(id))
            let long = Task { await client.call("wait_for", ["tab": .string(id), "time": 30000]) }
            while client.hub.tabs[tab.id]?.isBusy != true { await Task.yield() }
            client.browser.close(tab)
            #expect(await long.value.code == "tab_closed")
        }
    }

    // MARK: Listing

    @Test func listsToolsWithHintsAndGivesInstructions() async throws {
        try await withAgent { client, _ in
            let reply = await client.hub.handle(.message(["jsonrpc": "2.0", "id": 2, "method": "tools/list"], session: client.session, protocolVersion: nil))
            let tools = try #require(reply.body?["result"]?["tools"]?.items)
            #expect(tools.allSatisfy { $0["annotations"]?["title"]?.string != nil }, "every tool has a title and hints")
            let byName = Dictionary(uniqueKeysWithValues: tools.compactMap { tool in tool["name"]?.string.map { ($0, tool["annotations"] ?? .null) } })
            #expect(byName["snapshot"]?["readOnlyHint"] == true)
            #expect(byName["snapshot"]?["destructiveHint"] == nil)
            // MCP's defaults (not read-only, destructive) go without saying.
            #expect(byName["click"]?["readOnlyHint"] == nil && byName["click"]?["destructiveHint"] == nil)
            #expect(byName["scroll"]?["destructiveHint"] == false)
            #expect(byName["lithium_status"]?["openWorldHint"] == false)
            #expect(byName["fill_form"] != nil && byName["resize"] != nil)

            let initialized = await client.hub.handle(.message(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "other", "version": "1"]]], session: nil, protocolVersion: nil))
            let instructions = try #require(initialized.body?["result"]?["instructions"]?.string)
            #expect(instructions.contains("snapshot") && instructions.contains("ephemeral") && instructions.contains("untrusted"))
        }
    }
}

private extension JSONValue {
    var items: [JSONValue]? {
        if case .array(let items) = self { items } else { nil }
    }
}

import Foundation
import Network
import SwiftUI
import Testing
import WebKit
@testable import Lithium

/// What agents may open, and how the log writes addresses. No browser needed.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AgentURLsTests {
    @Test func opensOnlyTheWeb() {
        #expect(AgentURLs.verdict(for: URL(string: "https://example.com/a")!) == .allowed)
        #expect(AgentURLs.verdict(for: URL(string: "http://127.0.0.1:8080/")!) == .allowed)
        #expect(AgentURLs.verdict(for: URL(string: "about:blank")!) == .allowed)
        #expect(AgentURLs.verdict(for: URL(string: "file:///Users/me/notes.html")!) == .needsConfirmation)
        for blocked in ["lithium://settings", "webkit-extension://abc/popup.html", "javascript:alert(1)", "data:text/html,hi", "blob:https://example.com/1", "about:config", "mailto:a@b.c", "https:///nohost"] {
            guard case .blocked = AgentURLs.verdict(for: URL(string: blocked)!) else {
                Issue.record("\(blocked) should be blocked")
                continue
            }
        }
    }

    @Test func redactsSecretsFromLoggedAddresses() {
        #expect(AgentURLs.redacted("https://ann:hunter2@example.com/cb?token=abc&page=2&X-Amz-Signature=f00#access_token=xyz&state=1")
            == "https://example.com/cb?token=[redacted]&page=2&X-Amz-Signature=[redacted]#access_token=[redacted]&state=1")
        #expect(AgentURLs.redacted("https://example.com/plain") == "https://example.com/plain")
        #expect(AgentURLs.redacted("not a url") == "not a url")
        #expect(AgentURLs.redacted(["tab": "t1", "url": "https://x.com/?session=s3cret"]) == ["tab": "t1", "url": "https://x.com/?session=[redacted]"])
    }

    @Test func matchesGlobsOnly() throws {
        let glob = try #require(AgentURLs.matcher(for: "https://example.com/done*"))
        #expect(glob("https://example.com/done?id=1"))
        #expect(!glob("https://example.com/pending"))
        let one = try #require(AgentURLs.matcher(for: "https://ex?mple.com/"))
        #expect(one("https://example.com/"))
        #expect(!one("https://exmple.com/"))
        let two = try #require(AgentURLs.matcher(for: "*/order/*/edit"))
        #expect(two("https://shop.example/order/42/edit"))
        #expect(!two("https://shop.example/order/42/edit/x"))
        let literal = try #require(AgentURLs.matcher(for: "a.b[1]"))
        #expect(literal("a.b[1]"))
        #expect(!literal("axb1"))
        #expect(AgentURLs.matcher(for: "/order/[0-9]+$/") == nil)
        #expect(AgentURLs.matcher(for: "/") != nil)
    }

    @Test func aPathologicalGlobStaysFast() throws {
        let matches = try #require(AgentURLs.matcher(for: "*a*a*a*a*a*a*a*b"))
        let url = "https://example.com/" + String(repeating: "a", count: 2_000)
        let started = ContinuousClock.now
        let matched = matches(url)
        let elapsed = ContinuousClock.now - started
        #expect(!matched)
        #expect(elapsed < .milliseconds(50))
    }

    @Test func tellsAnchorsFromOtherDocuments() {
        let page = URL(string: "https://example.com/a?q=1#top")!
        #expect(AgentURLs.isMoveWithinPage(from: page, to: URL(string: "https://example.com/a?q=1#section")!))
        #expect(!AgentURLs.isMoveWithinPage(from: page, to: URL(string: "https://example.com/a?q=1")!))
        #expect(!AgentURLs.isMoveWithinPage(from: page, to: URL(string: "https://example.com/b#section")!))
        #expect(!AgentURLs.isMoveWithinPage(from: nil, to: URL(string: "https://example.com/a#section")!))
        #expect(AgentURLs.sameOrigin(page, URL(string: "HTTPS://Example.com/other")!))
        #expect(!AgentURLs.sameOrigin(page, URL(string: "https://example.com:8443/a")!))
    }
}

/// The tab tools on a whole Browser, called through the hub as an MCP client calls them, on
/// pages served from 127.0.0.1. It keeps its data in the home folder, so it only runs in a
/// throwaway one, as `scripts/test` gives.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct AgentTabsTests {
    struct ToolResult {
        let isError: Bool
        let content: JSONValue
        /// The whole MCP result, with its content items (images, resources).
        var result: JSONValue?
        var code: String? { isError ? content["code"]?.string : nil }
        var message: String { content["message"]?.string ?? "" }
        subscript(key: String) -> JSONValue? { content[key] }
    }

    /// One MCP session on the browser's hub.
    @MainActor
    final class Client {
        let browser: Browser
        let hub: AgentHub
        let session: String
        private var nextID = 10

        init(browser: Browser) async throws {
            self.browser = browser
            hub = try #require(browser.agent)
            let reply = await hub.handle(.message(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
                "protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "test-agent", "version": "1"],
            ]], session: nil, protocolVersion: nil))
            session = try #require(reply.sessionID)
        }

        /// Navigations get a minute unless the test says otherwise, so a slow machine fails a
        /// test on what it checks rather than on a timeout.
        func call(_ tool: String, _ arguments: JSONValue = [:]) async -> ToolResult {
            var arguments = arguments
            if ["tab_open", "navigate", "go_back", "go_forward", "reload"].contains(tool), arguments["timeoutMs"] == nil, var fields = arguments.object {
                fields["timeoutMs"] = 60000
                arguments = .object(fields)
            }
            nextID += 1
            let reply = await hub.handle(.message([
                "jsonrpc": "2.0", "id": .int(nextID), "method": "tools/call", "params": ["name": .string(tool), "arguments": arguments],
            ], session: session, protocolVersion: nil))
            let result = reply.body?["result"]
            return ToolResult(isError: result?["isError"] == true, content: result?["structuredContent"] ?? reply.body?["error"] ?? .null, result: result)
        }

        /// Looked up as the tools do, without giving ids to the tabs it passes.
        func tab(_ id: String) -> Lithium.Tab? {
            try? hub.tab(named: id).tab
        }
    }

    private static let pages: [String: (headers: String, body: String)] = [
        "/one": ("Content-Type: text/html", "<title>One</title><p>one</p>"),
        "/two": ("Content-Type: text/html", "<title>Two</title><p>two</p>"),
        "/three": ("Content-Type: text/html", "<title>Three</title><p>three</p>"),
        "/secret?token=abc123&page=2": ("Content-Type: text/html", "<title>Secret</title>"),
        "/app": ("Content-Type: text/html", "<title>App</title>"),
        "/ticking": ("Content-Type: text/html", "<title>Ticking</title><script>let n = 0; setInterval(() => { location.hash = 'tick' + (++n) }, 20)</script>"),
        "/busy": ("Content-Type: text/html", busy),
        "/busy?again": ("Content-Type: text/html", busy),
    ]
    /// Its script keeps the page busy for 3 seconds before the document is parsed.
    private static let busy = "<title>Busy</title><script>const end = Date.now() + 3000; while (Date.now() < end) {}</script><p>done</p>"

    /// A browser with agent access on and one session. Afterwards its tabs close, so a dozen
    /// tests' web processes don't slow the next ones down, and access goes off, so the next
    /// suite's `Browser()` doesn't start a server.
    private func withAgent(_ body: (Client, URL) async throws -> Void) async throws {
        UserDefaults.standard.removeObject(forKey: Preference.agentAccess)
        let (listener, base) = try await LocalHTTP.serve(Self.pages)
        defer { listener.cancel() }
        let browser = Browser()
        // Every navigation waits for these; in a fresh home the content blockers take longer to
        // compile than a navigation's timeout.
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

    /// The user, saying Deny to every prompt as it shows.
    private func denyEveryConfirmation(_ hub: AgentHub) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                hub.confirmations.pending.forEach { hub.confirmations.answer($0.id, .deny) }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    // MARK: Tabs

    @Test func tabOpenLandsInTheAgentGroupWithoutTouchingTheSelection() async throws {
        try await withAgent { client, base in
            let browser = client.browser
            let mine = browser.newTab(url: base.appending(path: "one"))
            let selected = browser.selectedTabID
            #expect(selected == mine.id)

            let opened = await client.call("tab_open", ["url": .string(base.appending(path: "two").absoluteString), "wait": "load"])
            #expect(!opened.isError, "\(opened.message)")
            #expect(opened["title"] == "Two")
            #expect(opened["state"] == "load")
            #expect(opened["status"] == 200)
            #expect(opened["url"] == .string(base.appending(path: "two").absoluteString))
            let tab = try #require(client.tab(opened["tab"]?.string ?? ""))
            #expect(browser.selectedTabID == selected)
            #expect(browser.agentTabs.map(\.id) == [tab.id])
            #expect(!browser.regularTabs.contains { $0 === tab })
            #expect(browser.navigationOrder.last === tab)
            #expect(tab.openedByAgent == "s1")
            #expect(client.hub.isTouched(tab))
            #expect(!client.hub.isTouched(mine))
            #expect(tab.loadedWebView?.window == nil)

            browser.keep(tab)
            #expect(browser.agentTabs.isEmpty)
            #expect(browser.regularTabs.contains { $0 === tab })
        }
    }

    @Test func aTabDroppedOnTheTabListJoinsItWhereDroppedAndAmongTheAgentGroupStays() throws {
        let browser = Browser()
        defer { browser.tabs.forEach(browser.close) }
        let first = browser.newAgentTab(session: "s1")
        let second = browser.newAgentTab(session: "s1")
        // Opened after the agent's tabs, so they come after them in `tabs`.
        let older = browser.newTab(selecting: false)
        _ = browser.newTab(selecting: false)
        var expected = browser.regularTabs.map(\.id)
        let place = try #require(expected.firstIndex(of: older.id))

        #expect(!browser.dropTab([first.id.uuidString], on: .agentGroup))
        #expect(browser.agentTabs.map(\.id) == [first.id, second.id])
        #expect(first.openedByAgent == "s1")

        #expect(browser.dropTab([first.id.uuidString], on: .tabList(place)))
        expected.insert(first.id, at: place)
        #expect(browser.regularTabs.map(\.id) == expected)
        #expect(browser.agentTabs.map(\.id) == [second.id])

        // Move to Tab List: at its end, below the tabs the user opened after it.
        browser.keep(second)
        expected.append(second.id)
        #expect(browser.regularTabs.map(\.id) == expected)
        #expect(browser.agentTabs.isEmpty)

        // The user's own tabs and favorites dropped on the list change nothing.
        #expect(!browser.dropTab([older.id.uuidString], on: .tabList(0)))
        #expect(!browser.dropTab(["pin:" + UUID().uuidString], on: .tabList(0)))
        #expect(browser.regularTabs.map(\.id) == expected)
    }

    @Test func tabsListNamesEveryTabWithIDsThatStay() async throws {
        try await withAgent { client, base in
            let browser = client.browser
            let mine = browser.newTab(url: base.appending(path: "one"))
            #expect(await waitUntil(30) { !mine.isLoading && mine.title == "One" })
            let first = await client.call("tabs_list")
            let tabs = first["tabs"]?.list ?? []
            #expect(tabs.count == browser.navigationOrder.count)
            #expect(first["window"]?["id"] == "w1")
            let entry = try #require(tabs.first { $0["url"]?.string == base.appending(path: "one").absoluteString })
            #expect(entry["title"] == "One")
            #expect(entry["selected"] == true)
            #expect(entry["agentTouched"] == false)
            #expect(entry["agentGroup"] == false)
            let ids = tabs.compactMap { $0["tab"]?.string }
            #expect(Set(ids).count == ids.count)
            #expect(ids.allSatisfy { $0.hasPrefix("t") })
            #expect((await client.call("tabs_list"))["tabs"]?.list?.compactMap { $0["tab"]?.string } == ids)
        }
    }

    @Test func idsSurviveSleepAndAreNeverReused() async throws {
        try await withAgent { client, base in
            let opened = await client.call("tab_open", ["url": .string(base.appending(path: "one").absoluteString), "wait": "load"])
            let id = try #require(opened["tab"]?.string)
            let tab = try #require(client.tab(id))
            tab.sleep(configuration: client.browser.makeConfiguration())
            let listed = await client.call("tabs_list")
            let entry = listed["tabs"]?.list?.first { $0["tab"]?.string == id }
            #expect(entry?["asleep"] == true)

            let navigated = await client.call("navigate", ["tab": .string(id), "url": .string(base.appending(path: "two").absoluteString)])
            #expect(!navigated.isError, "\(navigated.message)")
            #expect(navigated["tab"] == .string(id))
            #expect(navigated["title"] == "Two")
            #expect(!tab.isAsleep)
            // Woken with its history: the page it slept on is one Back away.
            let back = await client.call("go_back", ["tab": .string(id)])
            #expect(back["url"] == .string(base.appending(path: "one").absoluteString))

            #expect(!(await client.call("tab_close", ["tab": .string(id)])).isError)
            let closed = await client.call("navigate", ["tab": .string(id), "url": .string(base.appending(path: "one").absoluteString)])
            #expect(closed.code == "tab_closed")
            #expect(closed.message.hasPrefix("\(id) was closed at "))
            let next = await client.call("tab_open")
            #expect(next["tab"] != nil)
            #expect(next["tab"] != .string(id))
        }
    }

    /// A tab from the last session sleeps without its history: it wakes onto its old page first,
    /// and the navigation answers with the page it was sent to, not that one.
    @Test func navigatingATabRestoredAsleepAnswersWithTheTarget() async throws {
        try await withAgent { client, base in
            let two = base.appending(path: "two")
            for wait: JSONValue in ["commit", "domcontentloaded"] {
                let tab = client.browser.newTab(selecting: false)
                tab.restore(url: base.appending(path: "one"), title: "One")
                #expect(tab.isAsleep)
                let id = client.hub.id(for: tab)
                let result = await client.call("navigate", ["tab": .string(id), "url": .string(two.absoluteString), "wait": wait])
                #expect(!result.isError, "\(wait): \(result.message)")
                #expect(result["url"] == .string(two.absoluteString), "\(wait)")
                #expect(result["state"] == wait)
                if wait == "domcontentloaded" {
                    let shown = try await tab.webView.evaluateJavaScript("location.pathname") as? String
                    #expect(shown == "/two")
                }
                // Its old page is still one Back away.
                #expect((await client.call("go_back", ["tab": .string(id)]))["url"] == .string(base.appending(path: "one").absoluteString))
            }
        }
    }

    @Test func tabSelectShowsAndWakesTheTab() async throws {
        try await withAgent { client, base in
            let opened = await client.call("tab_open", ["url": .string(base.appending(path: "one").absoluteString), "wait": "load"])
            let id = try #require(opened["tab"]?.string)
            let tab = try #require(client.tab(id))
            tab.sleep(configuration: client.browser.makeConfiguration())
            let selected = await client.call("tab_select", ["tab": .string(id)])
            #expect(!selected.isError)
            #expect(client.browser.selectedTabID == tab.id)
            #expect(!tab.isAsleep)
        }
    }

    @Test func tabCloseIsReopenable() async throws {
        try await withAgent { client, base in
            let opened = await client.call("tab_open", ["url": .string(base.appending(path: "three").absoluteString), "wait": "load"])
            let id = try #require(opened["tab"]?.string)
            let closed = await client.call("tab_close", ["tab": .string(id)])
            #expect(closed.content == ["closed": .string(id)])
            #expect(client.tab(id) == nil)
            #expect(client.browser.canReopenClosedTab)
            client.browser.reopenClosedTab()
            #expect(client.browser.selectedTab?.url == base.appending(path: "three"))
            #expect(client.browser.selectedTab?.openedByAgent == nil)
        }
    }

    // MARK: Navigation

    @Test func navigatesBackForwardReloadsAndStops() async throws {
        try await withAgent { client, base in
            let id = try #require((await client.call("tab_open", ["url": .string(base.appending(path: "one").absoluteString), "wait": "load"]))["tab"]?.string)
            let tab: JSONValue = .string(id)
            let two = await client.call("navigate", ["tab": tab, "url": .string(base.appending(path: "two").absoluteString)])
            #expect(two["title"] == "Two")
            #expect(two["state"] == "load")
            #expect(two["loading"] == false)
            let committed = await client.call("navigate", ["tab": tab, "url": .string(base.appending(path: "three").absoluteString), "wait": "commit"])
            #expect(committed["state"] == "commit")
            #expect(committed["url"] == .string(base.appending(path: "three").absoluteString))
            #expect(!(await client.call("wait_for", ["tab": tab, "load": "load"])).isError)

            #expect((await client.call("go_back", ["tab": tab]))["title"] == "Two")
            #expect((await client.call("go_back", ["tab": tab, "wait": "domcontentloaded"]))["url"] == .string(base.appending(path: "one").absoluteString))
            #expect((await client.call("go_forward", ["tab": tab]))["title"] == "Two")
            let reloaded = await client.call("reload", ["tab": tab])
            #expect(reloaded["state"] == "load")
            #expect(reloaded["title"] == "Two")
            let stopped = await client.call("stop", ["tab": tab])
            #expect(stopped["loading"] == false)
            #expect((await client.call("go_forward", ["tab": tab]))["title"] == "Three")
            let none = await client.call("go_forward", ["tab": tab])
            #expect(none.code == "navigation_failed")
        }
    }

    /// WebKit commits nothing for these, and their document has long loaded.
    @Test func movesWithinThePageAnswerAtOnce() async throws {
        try await withAgent { client, base in
            let one = base.appending(path: "one").absoluteString
            let id = try #require((await client.call("tab_open", ["url": .string(one), "wait": "load"]))["tab"]?.string)
            let tab: JSONValue = .string(id)
            var started = ContinuousClock.now
            let anchor = await client.call("navigate", ["tab": tab, "url": .string(one + "#section")])
            #expect(!anchor.isError, "\(anchor.message)")
            #expect(anchor["url"] == .string(one + "#section"))
            #expect(anchor["state"] == "load")
            #expect(ContinuousClock.now - started < .seconds(5))

            #expect(!(await client.call("navigate", ["tab": tab, "url": .string(base.appending(path: "app").absoluteString)])).isError)
            // As a click in a web app would. WebKit's Back skips an entry the page added on its own.
            _ = try await client.tab(id)?.webView.evaluateJavaScript("history.pushState({}, '', '/app/inbox'); 0")
            #expect((await client.call("wait_for", ["tab": tab, "url": "*/app/inbox"]))["met"] == true)
            started = ContinuousClock.now
            let back = await client.call("go_back", ["tab": tab])
            #expect(!back.isError, "\(back.message)")
            #expect(back["url"] == .string(base.appending(path: "app").absoluteString))
            let forward = await client.call("go_forward", ["tab": tab, "wait": "domcontentloaded"])
            #expect(forward["url"] == .string(base.appending(path: "app/inbox").absoluteString))
            #expect(ContinuousClock.now - started < .seconds(5))
        }
    }

    /// The page on its way out moving to its own anchors isn't the page the agent was sent to.
    /// WebKit drops the load when that happens, so the call answers `navigation_cancelled` at
    /// once: it never answers for the page shown as if the load had completed.
    @Test func theOldPagesOwnAnchorMovesDontAnswerForTheNextPage() async throws {
        let (listener, slow) = try await LocalHTTP.serve(["/late": ("Content-Type: text/html", "<title>Late</title>")], delay: 1)
        defer { listener.cancel() }
        try await withAgent { client, base in
            let ticking = base.appending(path: "ticking").absoluteString
            let id = try #require((await client.call("tab_open", ["url": .string(ticking), "wait": "load"]))["tab"]?.string)
            let tab: JSONValue = .string(id)
            let late = slow.appending(path: "late").absoluteString
            let dropped = await client.call("navigate", ["tab": tab, "url": .string(late), "timeoutMs": 3000])
            #expect(dropped.code == "navigation_cancelled", "\(dropped.content)")
            #expect(dropped.message.hasPrefix("\(id)’s load stopped before it showed a page"), "\(dropped.message)")
            #expect(client.tab(id)?.url?.absoluteString.hasPrefix(ticking + "#tick") == true)

            // From a page that keeps still, the same address loads.
            let still = try #require((await client.call("tab_open", ["url": .string(base.appending(path: "one").absoluteString), "wait": "load"]))["tab"]?.string)
            let loaded = await client.call("navigate", ["tab": .string(still), "url": .string(late)])
            #expect(loaded["url"] == .string(late), "\(loaded.content)")
            #expect(loaded["title"] == "Late")
            #expect(loaded["state"] == "load")

            // An anchor the agent asks for still answers while the page moves to its own.
            let anchor = await client.call("navigate", ["tab": tab, "url": .string(ticking + "#section")])
            #expect(anchor["url"] == .string(ticking + "#section"), "\(anchor.content)")
        }
    }

    /// Back, Forward, Reload and waking load a page the agent didn't name: it must be one the
    /// agent may open, as `navigate` checks.
    @Test func historyReloadAndWakingReachOnlyPagesAgentsMayOpen() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "agent-notes-\(UUID().uuidString).html")
        try "<title>Notes</title><p>private</p>".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        try await withAgent { client, base in
            let browser = client.browser
            let one = base.appending(path: "one")
            let denying = denyEveryConfirmation(client.hub)
            defer { denying.cancel() }
            for start in [file, URL(string: "data:text/html,%3Ctitle%3EData%3C/title%3E")!] {
                let tab = browser.newTab(url: start, selecting: false)
                #expect(await waitUntil(30) { !tab.isLoading && tab.webView.backForwardList.currentItem != nil })
                tab.load(one)
                #expect(await waitUntil(30) { !tab.isLoading && tab.title == "One" })
                let id: JSONValue = .string(client.hub.id(for: tab))
                let back = await client.call("go_back", ["tab": id])
                #expect(back.code == (start.isFileURL ? "denied_by_user" : "blocked_page"), "\(start): \(back.content)")
                #expect(tab.url == one)

                tab.webView.goBack()
                #expect(await waitUntil(30) { !tab.isLoading && tab.url?.scheme == start.scheme })
                #expect((await client.call("reload", ["tab": id])).code == (start.isFileURL ? "denied_by_user" : "blocked_page"))
                #expect((await client.call("go_forward", ["tab": id]))["title"] == "One")
            }

            let selected = browser.selectedTabID
            let asleep = browser.newTab(selecting: false)
            asleep.restore(url: file, title: "Notes")
            let id: JSONValue = .string(client.hub.id(for: asleep))
            #expect((await client.call("tab_select", ["tab": id])).code == "denied_by_user")
            #expect((await client.call("wait_for", ["tab": id, "load": "load"])).code == "denied_by_user")
            #expect((await client.call("reload", ["tab": id])).code == "denied_by_user")
            #expect((await client.call("go_back", ["tab": id])).code == "denied_by_user")
            #expect(asleep.isAsleep)
            #expect(browser.selectedTabID == selected)
            // Sent elsewhere, it goes straight there without showing the file on the way.
            let two = base.appending(path: "two")
            let navigated = await client.call("navigate", ["tab": id, "url": .string(two.absoluteString)])
            #expect(navigated["title"] == "Two", "\(navigated.content)")
            #expect(asleep.webView.backForwardList.backList.isEmpty)
        }
    }

    @Test func waitingOnASleepingTabWakesIt() async throws {
        try await withAgent { client, base in
            let opened = await client.call("tab_open", ["url": .string(base.appending(path: "one").absoluteString), "wait": "load"])
            let id = try #require(opened["tab"]?.string)
            let tab = try #require(client.tab(id))
            for (key, value) in [("load", "load"), ("load", "domcontentloaded"), ("url", "*/one")] {
                tab.sleep(configuration: client.browser.makeConfiguration())
                let waited = await client.call("wait_for", .object(["tab": .string(id), key: .string(value), "timeoutMs": 30_000]))
                #expect(waited["met"] == true, "\(key) \(value): \(waited.message)")
                #expect(!tab.isAsleep)
            }
            #expect(await waitUntil(30) { tab.title == "One" && !tab.isLoading })
        }
    }

    /// The page on its way out is long since ready; the one coming hasn't arrived.
    @Test func domContentLoadedWaitsForTheNextDocument() async throws {
        let hanging = try await HangingHTTP()
        defer { hanging.stop() }
        try await withAgent { client, base in
            let id = try #require((await client.call("tab_open", ["url": .string(base.appending(path: "one").absoluteString), "wait": "load"]))["tab"]?.string)
            #expect((await client.call("navigate", ["tab": .string(id), "url": .string(hanging.url.absoluteString), "wait": "none"]))["state"] == "started")
            let waited = await client.call("wait_for", ["tab": .string(id), "load": "domcontentloaded", "timeoutMs": 500])
            #expect(waited.code == "timeout", "\(waited.content)")
        }
    }

    @Test func waitForRejectsRegexes() async throws {
        try await withAgent { client, base in
            let id = try #require((await client.call("tab_open", ["url": .string(base.appending(path: "one").absoluteString), "wait": "load"]))["tab"]?.string)
            let waited = await client.call("wait_for", ["tab": .string(id), "url": "/^(a+)+$/", "timeoutMs": 500])
            #expect(waited.code == "invalid_params", "\(waited.content)")
            #expect(waited.message.contains("glob"))
        }
    }

    /// Lithium putting the tab to sleep mid-wait fails the wait, and the wait doesn't hand the
    /// sleeping tab a new, empty page.
    @Test func sleepingDuringDomContentLoadedLeavesNoPage() async throws {
        try await withAgent { client, base in
            let id = try #require((await client.call("tab_open"))["tab"]?.string)
            let named = try #require(client.tab(id))
            #expect(!(await client.call("navigate", ["tab": .string(id), "url": .string(base.appending(path: "busy").absoluteString), "wait": "commit"])).isError)
            let waiting = Task { await client.call("wait_for", ["tab": .string(id), "load": "domcontentloaded", "timeoutMs": 20_000]) }
            try await Task.sleep(for: .milliseconds(300))
            named.sleep(configuration: client.browser.makeConfiguration())
            let waited = await waiting.value
            #expect(waited.code == "navigation_failed", "\(waited.content)")
            #expect(waited.message.contains("went to sleep"))
            try await Task.sleep(for: .milliseconds(200))
            #expect(named.isAsleep)
            #expect(named.loadedWebView == nil)
        }
    }

    /// A page whose script keeps it busy can't answer whether its document is ready; the
    /// deadline and Stop end the wait all the same.
    @Test func aBusyPageDoesntHoldUpDomContentLoaded() async throws {
        try await withAgent { client, base in
            let id = try #require((await client.call("tab_open"))["tab"]?.string)
            let tab: JSONValue = .string(id)
            #expect(!(await client.call("navigate", ["tab": tab, "url": .string(base.appending(path: "busy").absoluteString), "wait": "commit"])).isError)
            var started = ContinuousClock.now
            let waited = await client.call("wait_for", ["tab": tab, "load": "domcontentloaded", "timeoutMs": 500])
            #expect(waited.code == "timeout", "\(waited.content)")
            #expect(ContinuousClock.now - started < .milliseconds(1500))

            let again = base.appending(path: "busy").absoluteString + "?again"
            #expect(!(await client.call("navigate", ["tab": tab, "url": .string(again), "wait": "commit"])).isError)
            let waiting = Task { await client.call("wait_for", ["tab": tab, "load": "domcontentloaded", "timeoutMs": 20_000]) }
            try await Task.sleep(for: .milliseconds(300))
            started = ContinuousClock.now
            #expect(!(await client.call("stop", ["tab": tab])).isError)
            let stopped = await waiting.value
            #expect(stopped.code == "stopped", "\(stopped.content)")
            #expect(ContinuousClock.now - started < .milliseconds(1500))
        }
    }

    @Test func refusesBlockedAddressesAndPages() async throws {
        try await withAgent { client, base in
            let browser = client.browser
            let id = try #require((await client.call("tab_open", ["url": .string(base.appending(path: "one").absoluteString), "wait": "load"]))["tab"]?.string)
            for url in ["lithium://settings", "webkit-extension://abc/popup.html", "javascript:alert(1)", "data:text/html,<b>hi</b>"] {
                let result = await client.call("navigate", ["tab": .string(id), "url": .string(url)])
                #expect(result.code == "blocked_page", "\(url): \(result.code ?? "allowed")")
            }
            let groupSize = browser.agentTabs.count
            #expect((await client.call("tab_open", ["url": "lithium://history"])).code == "blocked_page")
            let denying = denyEveryConfirmation(client.hub)
            defer { denying.cancel() }
            let file = await client.call("tab_open", ["url": "file:///tmp/notes.html"])
            #expect(file.code == "denied_by_user")
            #expect(file.message.contains("notes.html"))
            #expect((await client.call("navigate", ["tab": .string(id), "url": "file:///tmp/notes.html"])).code == "denied_by_user")
            #expect(browser.agentTabs.count == groupSize)
            #expect(client.tab(id)?.url == base.appending(path: "one"))

            browser.openSettings()
            let settings = try #require(browser.selectedTab)
            let settingsID = client.hub.id(for: settings)
            #expect((await client.call("navigate", ["tab": .string(settingsID), "url": .string(base.absoluteString)])).code == "blocked_page")
            #expect((await client.call("reload", ["tab": .string(settingsID)])).code == "blocked_page")
            #expect(settings.url == Internal.settingsURL)
        }
    }

    @Test func checksArguments() async throws {
        try await withAgent { client, base in
            #expect((await client.call("navigate", ["tab": "t999", "url": "https://example.com"])).code == "unknown_tab")
            #expect((await client.call("navigate", ["url": "https://example.com"])).code == "invalid_params")
            let id = try #require((await client.call("tab_open"))["tab"]?.string)
            #expect((await client.call("navigate", ["tab": .string(id), "url": .string(base.absoluteString), "wait": "idle"])).code == "invalid_params")
            #expect((await client.call("navigate", ["tab": .string(id), "url": .string(base.absoluteString), "timeoutMs": 0])).code == "invalid_params")
            #expect((await client.call("wait_for", ["tab": .string(id)])).code == "invalid_params")
            #expect((await client.call("wait_for", ["tab": .string(id), "networkIdle": -1])).code == "invalid_params")
            #expect((await client.call("tab_open", ["ephemeral": true])).code == "unsupported")
        }
    }

    // MARK: Waiting

    @Test func waitsForTheAddressAndTheLoad() async throws {
        try await withAgent { client, base in
            let id = try #require((await client.call("tab_open", ["url": .string(base.appending(path: "one").absoluteString), "wait": "load"]))["tab"]?.string)
            let tab: JSONValue = .string(id)
            let started = await client.call("navigate", ["tab": tab, "url": .string(base.appending(path: "two").absoluteString), "wait": "none"])
            #expect(started["state"] == "started")
            let url = await client.call("wait_for", ["tab": tab, "url": "*/two"])
            #expect(url["met"] == true, "\(url.message)")
            let load = await client.call("wait_for", ["tab": tab, "load": "load"])
            #expect(load["met"] == true)
            #expect(load["title"] == "Two")
            #expect((await client.call("wait_for", ["tab": tab, "url": "http://127.0.0.1:*/tw?"]))["met"] == true)

            let timeout = await client.call("wait_for", ["tab": tab, "url": "*/never", "timeoutMs": 300])
            #expect(timeout.code == "timeout")
            #expect(timeout.message.contains("doesn’t match */never"))
        }
    }

    @Test func navigationToAPageThatNeverAnswersTimesOut() async throws {
        let hanging = try await HangingHTTP()
        defer { hanging.stop() }
        try await withAgent { client, _ in
            let id = try #require((await client.call("tab_open"))["tab"]?.string)
            let result = await client.call("navigate", ["tab": .string(id), "url": .string(hanging.url.absoluteString), "timeoutMs": 400])
            #expect(result.code == "timeout")
            #expect(result.message == "\(id) after 400 ms: no page had started to show.")
        }
    }

    // MARK: The user wins

    /// Starts a navigation to a page that never answers and waits until the call is in flight.
    private func pendingNavigation(_ client: Client, to url: URL) async throws -> (Lithium.Tab, Task<ToolResult, Never>) {
        let id = try #require((await client.call("tab_open"))["tab"]?.string)
        let tab = try #require(client.tab(id))
        let call = Task { await client.call("navigate", ["tab": .string(id), "url": .string(url.absoluteString), "timeoutMs": 20_000]) }
        #expect(await waitUntil(10) { client.hub.isBusy(tab) })
        return (tab, call)
    }

    @Test func userClosingTheTabEndsTheWait() async throws {
        let hanging = try await HangingHTTP()
        defer { hanging.stop() }
        try await withAgent { client, _ in
            let (tab, call) = try await pendingNavigation(client, to: hanging.url)
            client.browser.close(tab)
            let result = await call.value
            #expect(result.code == "tab_closed")
            #expect(!client.hub.tabs.values.contains { $0.isBusy })
        }
    }

    @Test func userNavigatingTheTabEndsTheWait() async throws {
        let hanging = try await HangingHTTP()
        defer { hanging.stop() }
        try await withAgent { client, _ in
            let (tab, call) = try await pendingNavigation(client, to: hanging.url)
            client.browser.navigate(tab, .stop)
            let result = await call.value
            #expect(result.code == "user_interrupted")
            // Over: the user's next navigation doesn't count against the agent's next call.
            #expect(!client.hub.tabs.values.contains { $0.interruption != nil })
        }
    }

    /// Reloads the user asks for from a site's settings are the user's navigation too: the agent's
    /// load doesn't answer for them.
    @Test func reloadsTheUserAsksForEndTheWait() async throws {
        let hanging = try await HangingHTTP()
        defer { hanging.stop() }
        // Shown at once, but never done loading: its image never comes.
        let (listener, slow) = try await LocalHTTP.serve(["/slow": ("Content-Type: text/html", "<title>Slow</title><img src=\"\(hanging.url.absoluteString)\">")])
        defer { listener.cancel() }
        try await withAgent { client, _ in
            let browser = client.browser
            let page = slow.appending(path: "slow")
            defer { browser.privacy.setEnabled(true, for: page) }
            let settings = browser.newTab(url: Internal.settingsURL, selecting: false)
            #expect(await poll(30) { (try? await settings.webView.evaluateJavaScript("typeof call", in: nil, contentWorld: .page) as? String) == "function" })
            let reloads: [(String, (Lithium.Tab) async throws -> Void)] = [
                ("protections", { browser.setProtections(false, for: $0) }),
                ("site data", { _ in _ = try await settings.webView.callAsyncJavaScript("return await call('clearSiteData', '127.0.0.1')", contentWorld: .page) }),
            ]
            for (name, reload) in reloads {
                let (tab, call) = try await pendingNavigation(client, to: page)
                #expect(await waitUntil(15) { tab.title == "Slow" && tab.isLoading }, "\(name)")
                try await reload(tab)
                let result = await call.value
                #expect(result.code == "user_interrupted", "\(name): \(result.content)")
            }
        }
    }

    /// The tab stays, showing the error, and the agent is told which it is.
    @Test func aTabWhosePageFailsToOpenStaysAndIsNamed() async throws {
        let (closed, refusing) = try await LocalHTTP.serve([:])
        closed.cancel()
        try await withAgent { client, base in
            let failed = await client.call("tab_open", ["url": .string(refusing.appending(path: "gone").absoluteString), "wait": "load"])
            #expect(failed.code == "navigation_failed", "\(failed.content)")
            let id = try #require(failed["tab"]?.string)
            let tab = try #require(client.tab(id))
            #expect(client.browser.agentTabs.contains { $0 === tab })
            #expect(tab.loadError != nil)
            #expect(client.hub.recentLog.last?.tab == id)
            #expect(client.hub.recentLog.last?.error == "navigation_failed")
            let log = try String(contentsOf: AgentLog.folder.appending(path: AgentLog.fileName(for: Date())), encoding: .utf8)
            let last = try #require(log.split(separator: "\n").last.map { try JSONValue.decode(Data($0.utf8)) })
            #expect(last["tab"]?["id"] == .string(id))

            let retried = await client.call("navigate", ["tab": .string(id), "url": .string(base.appending(path: "one").absoluteString)])
            #expect(retried["title"] == "One", "\(retried.content)")
        }
    }

    /// Lithium's error page is a document like any other: committing it is no success, at any
    /// wait, and `none` claims nothing.
    @Test func aPageThatFailsToOpenFailsAtEveryWait() async throws {
        let (closed, refusing) = try await LocalHTTP.serve([:])
        closed.cancel()
        let gone = refusing.appending(path: "gone").absoluteString
        try await withAgent { client, base in
            let opened = await client.call("tab_open", ["url": .string(gone)])
            #expect(opened.code == "navigation_failed", "\(opened.content)")
            let id = try #require(opened["tab"]?.string)
            #expect(opened.message.hasPrefix("\(id) couldn’t open its page"), "\(opened.message)")
            let tab: JSONValue = .string(id)

            for wait in ["commit", "domcontentloaded"] {
                let failed = await client.call("navigate", ["tab": tab, "url": .string(gone + "?" + wait), "wait": .string(wait)])
                #expect(failed.code == "navigation_failed", "\(wait): \(failed.content)")
                #expect(failed["tab"] == tab, "\(wait)")
            }
            let reloaded = await client.call("reload", ["tab": tab, "wait": "commit"])
            #expect(reloaded.code == "navigation_failed", "\(reloaded.content)")

            let started = await client.call("navigate", ["tab": tab, "url": .string(gone + "?none"), "wait": "none"])
            #expect(!started.isError, "\(started.content)")
            #expect(started["state"] == "started")
            let waited = await client.call("wait_for", ["tab": tab, "load": "load"])
            #expect(waited.code == "navigation_failed", "\(waited.content)")

            // The error page still shown is the load before's, not this one's.
            let committed = await client.call("navigate", ["tab": tab, "url": .string(base.appending(path: "one").absoluteString), "wait": "commit"])
            #expect(!committed.isError, "\(committed.content)")
            #expect(committed["state"] == "commit")
            #expect(client.tab(id)?.loadError == nil)
        }
    }

    /// A load that ends without a page answers at once. Downloads, which ask the user first, are
    /// in `AgentConfirmationsTests`.
    @Test func aLoadThatShowsNoPageAnswersAtOnce() async throws {
        let (listener, files) = try await LocalHTTP.serve([
            "/mail": ("HTTP/1.1 302 Found\r\nLocation: mailto:x@example.com", ""),
        ])
        defer { listener.cancel() }
        try await withAgent { client, base in
            let opened = await client.call("tab_open", ["url": .string(base.appending(path: "one").absoluteString)])
            let tab = try #require(opened["tab"])
            let started = ContinuousClock.now
            let result = await client.call("navigate", ["tab": tab, "url": .string(files.appending(path: "mail").absoluteString)])
            #expect(ContinuousClock.now - started < .seconds(2))
            #expect(result.code == "navigation_cancelled", "\(result.content)")
            #expect(result.message.contains("mailto:"), "\(result.message)")
            let id = try #require(result["tab"]?.string)
            #expect(result.message.hasPrefix(id), "\(result.message)")
            #expect(client.tab(id)?.title == "One", "the page before stays")
        }
    }

    /// Wrong arguments don't wait their turn behind the call running in the tab.
    @Test func argumentsAreCheckedBeforeWaitingInLine() async throws {
        let hanging = try await HangingHTTP()
        defer { hanging.stop() }
        try await withAgent { client, _ in
            let (tab, call) = try await pendingNavigation(client, to: hanging.url)
            let id = client.hub.id(for: tab)
            let started = ContinuousClock.now
            let waited = await client.call("wait_for", ["tab": .string(id), "load": "commit", "timeoutMs": 5_000])
            #expect(waited.code == "invalid_params", "\(waited.content)")
            #expect(ContinuousClock.now - started < .milliseconds(1000))
            #expect(client.hub.isBusy(tab))
            #expect(!(await client.call("stop", ["tab": .string(id)])).isError)
            #expect((await call.value).code == "stopped")
        }
    }

    @Test func stopEndsAWaitingCall() async throws {
        let hanging = try await HangingHTTP()
        defer { hanging.stop() }
        try await withAgent { client, _ in
            let (_, call) = try await pendingNavigation(client, to: hanging.url)
            client.hub.stop()
            let result = await call.value
            #expect(result.code == "agent_stopped")
            #expect(!client.hub.tabs.values.contains { $0.isBusy })
            client.hub.allowAgain()
        }
    }

    @Test func closingATabKeepsItsIDInEveryAnswer() async throws {
        try await withAgent { client, base in
            let id = try #require((await client.call("tab_open", ["url": .string(base.appending(path: "one").absoluteString), "wait": "load"]))["tab"]?.string)
            let number = try #require(Int(id.dropFirst()))
            let tab = try #require(client.tab(id))
            let waiting = Task { await client.call("wait_for", ["tab": .string(id), "url": "*/never", "timeoutMs": 20_000]) }
            #expect(await waitUntil(10) { client.hub.isBusy(tab) })
            let queued = Task { await client.call("reload", ["tab": .string(id), "timeoutMs": 20_000]) }
            try await Task.sleep(for: .milliseconds(100))
            client.browser.close(tab)

            let waited = await waiting.value
            #expect(waited.code == "tab_closed")
            #expect(waited.message == "\(id) was closed while the agent waited on it.")
            let reloaded = await queued.value
            #expect(reloaded.code == "tab_closed")
            #expect(reloaded.message == "\(id) was closed while the agent waited on it.")
            let stopped = await client.call("stop", ["tab": .string(id)])
            #expect(stopped.code == "tab_closed")
            #expect(stopped.message.hasPrefix("\(id) was closed at "))
            #expect([waited, reloaded, stopped].allSatisfy { $0["tab"] == .string(id) })
            #expect(!client.hub.isTouched(tab))
            #expect(!client.hub.holds(tab))
            // No id was given to the closed tab: the next one is the next number.
            #expect((await client.call("tab_open"))["tab"] == .string("t\(number + 1)"))
        }
    }

    @Test func stopDoesntWaitItsTurnAndEndsTheCallInFlight() async throws {
        let hanging = try await HangingHTTP()
        defer { hanging.stop() }
        // Shown at once, but never done loading: its image never comes.
        let (listener, slow) = try await LocalHTTP.serve(["/slow": ("Content-Type: text/html", "<title>Slow</title><img src=\"\(hanging.url.absoluteString)\">")])
        defer { listener.cancel() }
        try await withAgent { client, _ in
            let id = try #require((await client.call("tab_open"))["tab"]?.string)
            let tab = try #require(client.tab(id))
            let navigating = Task { await client.call("navigate", ["tab": .string(id), "url": .string(slow.appending(path: "slow").absoluteString), "wait": "load", "timeoutMs": 20_000]) }
            #expect(await waitUntil(15) { tab.title == "Slow" && tab.isLoading })
            #expect(client.hub.isBusy(tab))

            let started = ContinuousClock.now
            let stopped = await client.call("stop", ["tab": .string(id)])
            #expect(!stopped.isError, "\(stopped.message)")
            #expect(stopped["tab"] == .string(id))
            let navigated = await navigating.value
            #expect(navigated.code == "stopped")
            #expect(navigated.message == "A stop call stopped \(id) while this call waited on it.")
            #expect(ContinuousClock.now - started < .seconds(5))
            #expect(!client.hub.tabs.values.contains { $0.interruption != nil })
            #expect(!client.hub.tabs.values.contains { $0.isBusy })
        }
    }

    @Test func aQueuedCallTimesOutWaitingItsTurn() async throws {
        try await withAgent { client, base in
            let id = try #require((await client.call("tab_open", ["url": .string(base.appending(path: "one").absoluteString), "wait": "load"]))["tab"]?.string)
            let tab = try #require(client.tab(id))
            let waiting = Task { await client.call("wait_for", ["tab": .string(id), "url": "*/never", "timeoutMs": 30_000]) }
            #expect(await waitUntil(10) { client.hub.isBusy(tab) })

            let started = ContinuousClock.now
            let reloaded = await client.call("reload", ["tab": .string(id), "timeoutMs": 300])
            #expect(reloaded.code == "timeout")
            #expect(reloaded.message == "\(id) after 300 ms: another agent call was still running in it.")
            #expect(ContinuousClock.now - started < .seconds(5))

            #expect(!(await client.call("stop", ["tab": .string(id)])).isError)
            #expect((await waiting.value).code == "stopped")
        }
    }

    @Test func tabsAnAgentWorksInDontSleep() async throws {
        defer { UserDefaults.standard.removeObject(forKey: "tabIdleSeconds") }
        try await withAgent { client, base in
            let browser = client.browser
            let mine = browser.newTab(url: base.appending(path: "one"), selecting: false)
            let opened = await client.call("tab_open", ["url": .string(base.appending(path: "two").absoluteString), "wait": "load"])
            let id = try #require(opened["tab"]?.string, "\(opened.message)")
            let agents = try #require(client.tab(id))
            #expect(await waitUntil(30) { !mine.isLoading && mine.loadedWebView?.url != nil })
            UserDefaults.standard.set(0.002, forKey: "tabIdleSeconds")
            try await Task.sleep(for: .milliseconds(20))
            browser.relieveMemoryPressure(critical: false)
            #expect(mine.isAsleep)
            #expect(!agents.isAsleep)
        }
    }

    // MARK: Log

    @Test func logKeepsNoSecretsAndThePageShowsExportsAndClearsIt() async throws {
        try await withAgent { client, base in
            var secret = URLComponents(url: base.appending(path: "secret"), resolvingAgainstBaseURL: false)!
            secret.percentEncodedQuery = "token=abc123&page=2"
            let opened = await client.call("tab_open", ["url": .string(secret.url!.absoluteString), "wait": "load"])
            #expect(opened["title"] == "Secret", "\(opened.message)")
            let log = try String(contentsOf: AgentLog.folder.appending(path: AgentLog.fileName(for: Date())), encoding: .utf8)
            #expect(!log.contains("abc123"))
            #expect(log.contains("token=[redacted]&page=2"))
            let last = try #require(log.split(separator: "\n").last.map { try JSONValue.decode(Data($0.utf8)) })
            #expect(last["tool"] == "tab_open")
            #expect(last["tab"]?["id"] == opened["tab"])
            #expect(last["tab"]?["host"] == "127.0.0.1")
            #expect(client.hub.recentLog.last?.tool == "tab_open")
            #expect(client.hub.recentLog.last?.host == "127.0.0.1")

            let exported = String(decoding: await client.hub.log.export(), as: UTF8.self)
            #expect(exported == log)

            client.browser.openAgentLog()
            let page = try #require(client.browser.selectedTab)
            #expect(page.url == Internal.agentsURL)
            let world = WKContentWorld.page
            let entries = { try? await page.webView.evaluateJavaScript("document.querySelectorAll('.entry').length", in: nil, contentWorld: world) as? Int }
            #expect(await poll(30) { (await entries() ?? 0) > 0 })
            let text = try await page.webView.evaluateJavaScript("document.querySelector('#list').textContent", in: nil, contentWorld: world) as? String
            #expect(text?.contains("tab_open") == true)
            #expect(text?.contains("abc123") == false)

            _ = try await page.webView.callAsyncJavaScript("return await call('clearAgentLog')", contentWorld: world)
            #expect(String(decoding: await client.hub.log.export(), as: UTF8.self).isEmpty)
            #expect(client.hub.recentLog.isEmpty)
            page.reload()
            #expect(await poll(30) {
                (try? await page.webView.evaluateJavaScript("document.querySelector('.empty')?.textContent ?? ''", in: nil, contentWorld: world) as? String) == "No agent actions yet."
            })
        }
    }

    private func poll(_ seconds: Double, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return await condition()
    }

    // MARK: Session

    @Test func agentTabsComeBackAsOrdinaryTabs() async throws {
        try await withAgent { client, base in
            let url = base.appending(path: "three")
            let opened = await client.call("tab_open", ["url": .string(url.absoluteString), "wait": "load"])
            #expect(!opened.isError, "\(opened.message)")
            #expect(await waitUntil(10) { SessionStore.load().tabs.contains { $0.url == url } })
            let relaunched = Browser()
            let restored = try #require(relaunched.tabs.first { $0.url == url })
            #expect(restored.openedByAgent == nil)
            #expect(relaunched.regularTabs.contains { $0 === restored })
            #expect(relaunched.agentTabs.isEmpty)
        }
    }

    // MARK: Snapshots

    /// The sidebar with an Agent group and a badged tab, the hover card's agent line, and the
    /// log page: `LITHIUM_SNAPSHOT_DIR=/tmp/shots ./scripts/test --filter AgentTabsTests/snapshots`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHIUM_SNAPSHOT_DIR"] != nil))
    func snapshots() async throws {
        let directory = URL(filePath: ProcessInfo.processInfo.environment["LITHIUM_SNAPSHOT_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Theme.registerFonts()
        let pages: [String: (headers: String, body: String)] = [
            "/docs": ("Content-Type: text/html; charset=utf-8", "<title>Swift Documentation</title>"),
            "/mail": ("Content-Type: text/html; charset=utf-8", "<title>Inbox — Mail</title>"),
            "/flights": ("Content-Type: text/html; charset=utf-8", "<title>Flights to Lisbon</title>"),
            "/hotels": ("Content-Type: text/html; charset=utf-8", "<title>Hotels in Lisbon</title>"),
        ]
        let (listener, base) = try await LocalHTTP.serve(pages)
        defer { listener.cancel() }
        UserDefaults.standard.removeObject(forKey: Preference.agentAccess)
        let browser = Browser()
        browser.regularTabs.forEach(browser.close)
        await browser.privacy.waitUntilReady()
        await browser.extensions.waitUntilLoaded()
        await browser.setAgentAccess(true)
        let client = try await Client(browser: browser)
        let docs = browser.newTab(url: base.appending(path: "docs"))
        let mail = browser.newTab(url: base.appending(path: "mail"), selecting: false)
        #expect(await waitUntil(120) { docs.title == "Swift Documentation" && mail.title == "Inbox — Mail" })
        _ = await client.call("navigate", ["tab": .string(client.hub.id(for: docs)), "url": .string(base.appending(path: "docs").absoluteString)])
        _ = await client.call("tab_open", ["url": .string(base.appending(path: "flights").absoluteString), "wait": "load"])
        _ = await client.call("tab_open", ["url": .string(base.appending(path: "hotels").absoluteString), "wait": "load"])

        for isDark in [false, true] {
            let hex = isDark ? "#25272F" : Theme.defaultSidebarHex
            let palette = SidebarPalette(style: .solid, colorHex: hex, scheme: isDark ? .dark : .light)
            let sidebar = SidebarView()
                .frame(width: Layout.sidebarWidth, height: 420)
                .background(Color(hex: hex))
                .foregroundStyle(palette.ink)
                .font(Theme.font(13))
                .environment(browser)
                .environment(TabHover())
                .environment(\.sidebarPalette, palette)
                .environment(\.colorScheme, isDark ? .dark : .light)
            try writeHosted(sidebar, isDark: isDark, to: directory.appending(path: "agent-sidebar-\(isDark ? "dark" : "light").png"))

            let card = TabHoverCard(title: "Flights to Lisbon", host: "127.0.0.1", usage: .live(footprint: 182 * 1_048_576, cpu: 1.4, sharedWith: 0), agent: "Opened by an agent")
                .padding(20)
                .background(Color(hex: hex))
                .environment(\.sidebarPalette, palette)
                .environment(\.colorScheme, isDark ? .dark : .light)
            try write(card, to: directory.appending(path: "agent-hover-card-\(isDark ? "dark" : "light").png"))
        }

        let configuration = WKWebViewConfiguration()
        InternalSchemeHandler.shared.install(on: configuration)
        configuration.userContentController.addScriptMessageHandler(browser.internalBridge, contentWorld: .page, name: InternalBridge.name)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 640), configuration: configuration)
        let window = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: 960, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        defer { window.contentView = nil }
        webView.load(URLRequest(url: Internal.agentsURL))
        #expect(await poll(15) { ((try? await webView.evaluateJavaScript("document.querySelectorAll('.entry').length")) as? Int ?? 0) > 0 })
        // A window never shown doesn't run the page's entrance animation, which starts transparent.
        _ = try await webView.evaluateJavaScript("document.head.append(Object.assign(document.createElement('style'), { textContent: '*, *::after { animation: none !important; transition: none !important }' })); 0")
        for isDark in [false, true] {
            window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
            try await Task.sleep(for: .milliseconds(400))
            let image = try await webView.takeSnapshot(configuration: nil)
            let png = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]))
            try png.write(to: directory.appending(path: "agent-log-page-\(isDark ? "dark" : "light").png"))
        }
        await browser.setAgentAccess(false)
    }

    /// Through an off-screen window: ImageRenderer draws scroll views and drop targets as a placeholder.
    private func writeHosted(_ view: some View, isDark: Bool, to url: URL) throws {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let window = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: hosting.frame.width, height: hosting.frame.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        defer { window.contentView = nil }
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    private func write(_ view: some View, to url: URL) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let png = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }
}

/// A server on 127.0.0.1 that accepts connections and never answers, so a navigation to it
/// stays in flight until something ends it.
final class HangingHTTP: @unchecked Sendable {
    /// Kept open, and only touched on `queue`: a connection let go would close and fail the navigation at once.
    private final class Connections: @unchecked Sendable {
        var all: [NWConnection] = []
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "hanging-http")
    private let connections = Connections()
    let url: URL

    init() async throws {
        listener = try NWListener(using: .tcp, on: .any)
        let queue = queue
        let connections = connections
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connections.all.append(connection)
        }
        listener.start(queue: queue)
        for _ in 0..<500 {
            if let port = listener.port, listener.state == .ready {
                url = URL(string: "http://127.0.0.1:\(port.rawValue)/hang")!
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        listener.cancel()
        throw URLError(.cannotConnectToHost)
    }

    func stop() {
        queue.sync {
            connections.all.forEach { $0.cancel() }
            connections.all = []
        }
        listener.cancel()
    }
}

private extension JSONValue {
    var list: [JSONValue]? {
        if case .array(let items) = self { items } else { nil }
    }
}

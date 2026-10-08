import AppKit
import Foundation
import Testing
import WebKit
@testable import Lithium

/// Confirmations, downloads, file choosers, dialogs and payment marks on a whole Browser, through
/// the hub as an MCP client calls it, on pages served from 127.0.0.1 and, for a second origin,
/// localhost. The test answers prompts through `AgentConfirmations`, never through the UI.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct AgentConfirmationsTests {
    typealias Client = AgentTabsTests.Client

    private static let html = "Content-Type: text/html; charset=utf-8"
    private static let otherOrigin = "location.protocol + '//' + (location.hostname === 'localhost' ? '127.0.0.1' : 'localhost') + ':' + location.port"

    private static let pages: [String: (headers: String, body: String)] = [
        "/one": (html, "<title>One</title><p>one</p>"),
        "/report.csv": ("Content-Type: text/csv\r\nContent-Disposition: attachment; filename=report.csv", "a,b"),
        "/mail": ("HTTP/1.1 302 Found\r\nLocation: mailto:x@example.com", ""),
        "/alert": (html, "<title>Before</title><script>alert('Saved'); document.title = 'After alert'</script>"),
        "/confirm": (html, "<title>Before</title><script>document.title = confirm('Leave this page?') ? 'yes' : 'no'</script>"),
        "/prompt": (html, "<title>Before</title><script>document.title = prompt('Name?', 'Ann') ?? 'none'</script>"),
        "/checkout": (html, """
            <title>Checkout</title><style>body { margin: 0; font: 16px sans-serif } iframe { border: 0; width: 300px; height: 120px }</style>
            <a href="/help">Help</a>
            <button>Place order</button>
            <apple-pay-button style="display: block; width: 200px; height: 40px"></apple-pay-button>
            <iframe id="card"></iframe>
            <script>document.getElementById('card').src = \(otherOrigin) + '/card-frame'</script>
            """),
        "/card-frame": (html, "<input aria-label='Postcode'><button>Use this card</button>"),
        "/products": (html, "<title>Products</title><button>Buy</button><button>Pay €42.00</button><button>Place order</button>"),
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

    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// Starts a call, waits for the prompt it raises, and answers it as the user would.
    private func call(_ client: Client, _ tool: String, _ arguments: JSONValue, answering answer: ConfirmationAnswer, expecting kind: ConfirmationKind) async throws -> (AgentTabsTests.ToolResult, AgentConfirmation) {
        let confirmations = client.hub.confirmations
        let task = Task { await client.call(tool, arguments) }
        guard await waitUntil(20, { !confirmations.pending.isEmpty }), let asked = confirmations.pending.first else {
            Issue.record("\(tool) asked nothing: \(await task.value.content)")
            throw CancellationError()
        }
        #expect(asked.kind == kind)
        confirmations.answer(asked.id, answer)
        return (await task.value, asked)
    }

    private func open(_ client: Client, _ url: URL) async throws -> String {
        let opened = await client.call("tab_open", ["url": .string(url.absoluteString), "wait": "load"])
        #expect(!opened.isError, "\(opened.content)")
        return try #require(opened["tab"]?.string)
    }

    // MARK: file: addresses

    @Test func fileAddressesAskEveryTime() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "agent-notes-\(UUID().uuidString).html")
        try "<title>Notes</title><p>private</p>".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        try await withAgent { client, base in
            let browser = client.browser
            let (opened, asked) = try await call(client, "tab_open", ["url": .string(file.absoluteString), "wait": "load"], answering: .allowOnce, expecting: .file)
            #expect(!opened.isError, "\(opened.content)")
            #expect(opened["title"] == "Notes")
            #expect(asked.tabID == nil)
            #expect(asked.site == nil)
            #expect(!asked.offersSiteGrant)
            #expect(asked.action.contains(file.lastPathComponent))
            let id = try #require(opened["tab"]?.string)

            // Allowed once is once: the next visit asks again, and Deny keeps the tab where it was.
            let one = base.appending(path: "one")
            #expect(!(await client.call("navigate", ["tab": .string(id), "url": .string(one.absoluteString)])).isError)
            let (denied, _) = try await call(client, "navigate", ["tab": .string(id), "url": .string(file.absoluteString)], answering: .deny, expecting: .file)
            #expect(denied.code == "denied_by_user", "\(denied.content)")
            #expect(client.tab(id)?.url == one)
            let (back, _) = try await call(client, "go_back", ["tab": .string(id)], answering: .allowOnSite, expecting: .file)
            #expect(back["title"] == "Notes", "\(back.content)")
            #expect(client.hub.confirmations.grants.isEmpty)

            // Unanswered, a tab_open leaves no tab.
            let group = browser.agentTabs.count
            let late = await client.call("tab_open", ["url": .string(file.absoluteString), "timeoutMs": 300])
            #expect(late.code == "confirmation_timeout", "\(late.content)")
            #expect(browser.agentTabs.count == group)
            #expect(client.hub.confirmations.pending.isEmpty)

            let entries = await client.hub.log.entries(limit: 50).filter { $0["event"] == "confirmation" }
            #expect(entries.compactMap { $0["confirmation"]?["answer"]?.string }.sorted() == ["allow", "allow", "deny", "timeout"])
            #expect(entries.allSatisfy { $0["confirmation"]?["kind"] == "file" && $0["subject"]?.string?.hasPrefix("file://") == true })
        }
    }

    @Test func theUserNavigatingTheTabCancelsItsPrompt() async throws {
        try await withAgent { client, base in
            let id = try await open(client, base.appending(path: "one"))
            let tab = try #require(client.tab(id))
            let task = Task { await client.call("navigate", ["tab": .string(id), "url": "file:///tmp/agent-elsewhere.html"]) }
            #expect(await waitUntil(20) { client.hub.confirmations.front(selected: nil)?.tabID == tab.id })
            client.browser.navigate(tab, .reload)
            let result = await task.value
            #expect(result.code == "user_interrupted", "\(result.content)")
            #expect(client.hub.confirmations.pending.isEmpty)
        }
    }

    /// Back or Forward with no page to go to (⌘[ and ⌘] reach it from the menu) does nothing, so
    /// the agent's prompt stays.
    @Test func backWithNowhereToGoLeavesThePrompt() async throws {
        try await withAgent { client, base in
            let id = try await open(client, base.appending(path: "one"))
            let tab = try #require(client.tab(id))
            #expect(!tab.canGoBack && !tab.canGoForward)
            let task = Task { await client.call("navigate", ["tab": .string(id), "url": "file:///tmp/agent-elsewhere.html"]) }
            #expect(await waitUntil(20) { client.hub.confirmations.front(selected: nil)?.tabID == tab.id })
            client.browser.navigate(tab, .back)
            client.browser.navigate(tab, .forward)
            let asked = try #require(client.hub.confirmations.pending.first)
            #expect(asked.tabID == tab.id)
            client.hub.confirmations.answer(asked.id, .deny)
            let result = await task.value
            #expect(result.code == "denied_by_user", "\(result.content)")
        }
    }

    // MARK: Downloads

    @Test func downloadsTheAgentStartsAsk() async throws {
        try await withAgent { client, base in
            let report = base.appending(path: "report.csv").absoluteString
            let id = try await open(client, base.appending(path: "one"))
            let tab: JSONValue = .string(id)

            let (allowed, asked) = try await call(client, "navigate", ["tab": tab, "url": .string(report)], answering: .allowOnce, expecting: .download)
            #expect(allowed["download"] == ["file": "report.csv", "grant": "once"], "\(allowed.content)")
            #expect(allowed["state"] == nil)
            #expect(asked.action.contains("report.csv"))
            #expect(asked.offersSiteGrant)
            #expect(client.tab(id)?.title == "One", "the page before stays")

            let (denied, _) = try await call(client, "navigate", ["tab": tab, "url": .string(report)], answering: .deny, expecting: .download)
            #expect(denied.code == "denied_by_user", "\(denied.content)")

            let started = ContinuousClock.now
            let late = await client.call("navigate", ["tab": tab, "url": .string(report), "timeoutMs": 500])
            #expect(late.code == "confirmation_timeout", "\(late.content)")
            #expect(ContinuousClock.now - started < .seconds(3))
            #expect(await waitUntil(5) { client.hub.confirmations.pending.isEmpty })

            // On the site until the agent stops, for this session only.
            let (granted, _) = try await call(client, "navigate", ["tab": tab, "url": .string(report)], answering: .allowOnSite, expecting: .download)
            #expect(granted["download"]?["grant"] == "site", "\(granted.content)")
            let again = await client.call("navigate", ["tab": tab, "url": .string(report)])
            #expect(again["download"]?["grant"] == "site", "\(again.content)")
            let other = try await Client(browser: client.browser)
            let (otherDenied, _) = try await call(other, "navigate", ["tab": tab, "url": .string(report)], answering: .deny, expecting: .download)
            #expect(otherDenied.code == "denied_by_user")
            #expect(client.hub.confirmations.grants.count == 1)

            // A tab opened just for the file closes as its download starts.
            let (fromNewTab, _) = try await call(other, "tab_open", ["url": .string(report)], answering: .allowOnce, expecting: .download)
            #expect(fromNewTab["download"]?["file"] == "report.csv", "\(fromNewTab.content)")
            #expect(client.tab(fromNewTab["tab"]?.string ?? "") == nil)

            client.hub.stop()
            #expect(client.hub.confirmations.grants.isEmpty)
            client.hub.allowAgain()
        }
    }

    /// A private tab saves nothing: its calls and its download's prompt are logged, marked, but
    /// never with the addresses, host or site it went to.
    @Test func aPrivateTabsCallsAreLoggedWithoutItsAddresses() async throws {
        try await withAgent { client, base in
            let opened = await client.call("tab_open", ["url": .string(base.appending(path: "one").absoluteString), "ephemeral": true, "wait": "load"])
            #expect(!opened.isError, "\(opened.content)")
            let id = try #require(opened["tab"]?.string)
            let report = base.appending(path: "report.csv").absoluteString
            let (allowed, _) = try await call(client, "navigate", ["tab": .string(id), "url": .string(report)], answering: .allowOnce, expecting: .download)
            #expect(allowed["download"]?["file"] == "report.csv", "\(allowed.content)")

            var entries: [JSONValue] = []
            for _ in 0..<100 where !entries.contains(where: { $0["event"] == "confirmation" }) {
                entries = await client.hub.log.entries(limit: 3)
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(Set(entries.compactMap { $0["tool"]?.string ?? $0["event"]?.string }) == ["tab_open", "navigate", "confirmation"])
            for entry in entries {
                #expect(entry["ephemeral"] == true)
                #expect(entry["params"] == nil && entry["subject"] == nil && entry["site"] == nil)
                #expect(entry["tab"] == ["id": .string(id)])
                let text = String(decoding: entry.encoded(), as: UTF8.self)
                #expect(!text.contains("127.0.0.1") && !text.contains("report.csv") && !text.contains("/one"), "\(text)")
            }
        }
    }

    /// A private tab's `file:` address is asked before the tab exists: its prompt is still
    /// logged without the path.
    @Test func aPrivateTabOpenOfAFileIsLoggedWithoutItsPath() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "agent-private-\(UUID().uuidString).html")
        try "<title>Notes</title>".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        try await withAgent { client, _ in
            let (opened, _) = try await call(client, "tab_open", ["url": .string(file.absoluteString), "ephemeral": true, "wait": "load"], answering: .allowOnce, expecting: .file)
            #expect(!opened.isError, "\(opened.content)")

            var entries: [JSONValue] = []
            for _ in 0..<100 where !entries.contains(where: { $0["event"] == "confirmation" }) {
                entries = await client.hub.log.entries(limit: 2)
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(Set(entries.compactMap { $0["tool"]?.string ?? $0["event"]?.string }) == ["tab_open", "confirmation"])
            for entry in entries {
                #expect(entry["ephemeral"] == true)
                #expect(entry["params"] == nil && entry["subject"] == nil)
                let text = String(decoding: entry.encoded(), as: UTF8.self)
                #expect(!text.contains(file.lastPathComponent), "\(text)")
            }
        }
    }

    /// Two alike downloads during one action of the agent (a double click on a download link)
    /// each ask and are each logged: the Allow the first got never answers the second.
    @Test func eachDownloadDuringAnActionAsks() async throws {
        try await withAgent { client, base in
            let id = try await open(client, base.appending(path: "one"))
            let tab = try #require(client.tab(id))
            let hub = client.hub
            let session = try #require(hub.sessions.first)
            hub.tabs[tab.id]?.acting = AgentActing(session: session.id, caption: "Clicking")
            defer { hub.tabs[tab.id]?.acting = nil }
            let report = base.appending(path: "report.csv").absoluteString
            for (kind, answer) in [(ConfirmationKind.download, ConfirmationAnswer.allowOnce), (.download, .deny), (.file, .allowOnce), (.file, .deny)] {
                let asking = Task {
                    try await hub.confirm(kind, "open “report.csv”", subject: report, site: nil, in: NamedTab(tab: tab, id: id), session: session, until: .now + .seconds(20))
                }
                #expect(await waitUntil(20) { !hub.confirmations.pending.isEmpty }, "\(kind) asked again")
                hub.confirmations.pending.forEach { hub.confirmations.answer($0.id, answer) }
                _ = await asking.result
            }
            var kinds: [String] = []
            for _ in 0..<100 where kinds.count < 4 {
                kinds = await hub.log.entries(limit: 50).filter { $0["event"] == "confirmation" && $0["subject"] == .string(report) }.compactMap { $0["confirmation"]?["kind"]?.string }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(kinds.sorted() == ["download", "download", "file", "file"])
        }
    }

    @Test func stopDeniesThePromptAndEndsTheCall() async throws {
        try await withAgent { client, base in
            let id = try await open(client, base.appending(path: "one"))
            let task = Task { await client.call("navigate", ["tab": .string(id), "url": .string(base.appending(path: "report.csv").absoluteString)]) }
            #expect(await waitUntil(20) { !client.hub.confirmations.pending.isEmpty })
            client.hub.stop()
            #expect((await task.value).code == "agent_stopped")
            #expect(client.hub.confirmations.pending.isEmpty)
            client.hub.allowAgain()
        }
    }

    /// A download the user starts in the tab: nil when Lithium takes it as the user's own. A
    /// prompt raised for it is denied, so a wrong answer fails at once rather than in 2 minutes.
    private func userDownload(_ client: Client, in tab: Tab, from url: URL) async -> Bool? {
        let hub = client.hub
        let asking = Task { await hub.confirmDownload(in: tab, fileName: "report.csv", size: nil, from: url) }
        if await waitUntil(1, { !hub.confirmations.pending.isEmpty }) {
            hub.confirmations.pending.forEach { hub.confirmations.answer($0.id, .deny) }
        }
        return await asking.value
    }

    /// Whatever the agent's navigation ends with, the tab is the user's again afterwards.
    @Test func theAgentsClaimEndsWithItsNavigation() async throws {
        try await withAgent { client, base in
            let one = base.appending(path: "one")
            let report = base.appending(path: "report.csv")
            let id = try await open(client, one)
            let tab = try #require(client.tab(id))

            let anchor = await client.call("navigate", ["tab": .string(id), "url": .string(one.absoluteString + "#part")])
            #expect(anchor["state"] == "load", "\(anchor.content)")
            #expect(await userDownload(client, in: tab, from: report) == nil, "after a move within the page")

            let refused = await client.call("navigate", ["tab": .string(id), "url": .string(base.appending(path: "mail").absoluteString)])
            #expect(refused.code == "navigation_cancelled", "\(refused.content)")
            #expect(await userDownload(client, in: tab, from: report) == nil, "after a refused scheme")

            let (downloaded, _) = try await call(client, "navigate", ["tab": .string(id), "url": .string(report.absoluteString)], answering: .allowOnce, expecting: .download)
            #expect(downloaded["download"]?["file"] == "report.csv", "\(downloaded.content)")
            #expect(client.hub.openPanel(for: tab) == nil, "the user's file chooser after the agent's download")
            #expect(await userDownload(client, in: tab, from: report) == nil, "after the agent's download")
        }
    }

    /// Stop ends the session's load still on its way after `wait: none`: it never becomes a
    /// download, asked or not.
    @Test func stopCancelsTheAgentsLoadOnItsWay() async throws {
        let (slow, slowBase) = try await LocalHTTP.serve(["/report.csv": Self.pages["/report.csv"]!], delay: 1)
        defer { slow.cancel() }
        try await withAgent { client, base in
            let id = try await open(client, base.appending(path: "one"))
            let tab = try #require(client.tab(id))
            let unshown = tab.unshownLoads
            let started = await client.call("navigate", ["tab": .string(id), "url": .string(slowBase.appending(path: "report.csv").absoluteString), "wait": "none"])
            #expect(started["state"] == "started", "\(started.content)")
            client.hub.stop()
            #expect(!(await waitUntil(2.5) { !client.hub.confirmations.pending.isEmpty }), "no prompt for a stopped session")
            #expect(tab.unshownLoads == unshown, "no download")
            #expect(client.hub.tabs[tab.id]?.drive == nil)
            client.hub.allowAgain()
        }
    }

    @Test func uploadsAnswerTheChooserOnlyWithAllowedFiles() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "agent-upload-\(UUID().uuidString).txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        try await withAgent { client, base in
            let hub = client.hub
            let id = try await open(client, base.appending(path: "one"))
            let named = try hub.tab(named: id)
            let session = try #require(hub.sessions.first)
            let state = try #require(hub.agentTab(for: named.tab))
            #expect(hub.openPanel(for: named.tab) == nil, "the user's own chooser")

            state.isBusy = true
            #expect(hub.openPanel(for: named.tab) == .cancelled, "the agent's chooser, unarmed")
            #expect(state.fileChoosersCancelled == 1)
            state.isBusy = false

            await #expect(throws: AgentToolError.self) {
                try await hub.confirmUpload([file.appending(path: "missing")], in: named, session: session, until: .now + .seconds(5))
            }
            let asking = Task { try await hub.confirmUpload([file], in: named, session: session, until: .now + .seconds(20)) }
            #expect(await waitUntil(20) { !hub.confirmations.pending.isEmpty })
            let asked = try #require(hub.confirmations.pending.first)
            #expect(asked.kind == .upload)
            #expect(asked.action.contains(file.lastPathComponent))
            #expect(asked.action.contains(file.deletingLastPathComponent().path(percentEncoded: false)))
            #expect(asked.action.hasSuffix("to 127.0.0.1"))
            hub.confirmations.answer(asked.id, .allowOnce)
            #expect(try await asking.value == .once)
            #expect(hub.openPanel(for: named.tab) == .files([file]))
            #expect(hub.openPanel(for: named.tab) == nil, "one use")
        }
    }

    // MARK: Dialogs

    @Test func dialogsInTheAgentsTabsGoToTheAgent() async throws {
        try await withAgent { client, base in
            let opened = await client.call("tab_open", ["url": .string(base.appending(path: "alert").absoluteString), "wait": "load"])
            #expect(opened.code == "dialog_open", "\(opened.content)")
            #expect(opened.message.contains("alert from 127.0.0.1 \"Saved\""), "\(opened.message)")
            let id = try #require(opened["tab"]?.string)
            let tab: JSONValue = .string(id)

            let listed = await client.call("tabs_list")
            let row = listed["tabs"]?.items?.first { $0["tab"] == tab }
            #expect(row?["dialog"] == ["type": "alert", "message": "Saved", "default": .null, "from": "127.0.0.1"])
            let snapshot = await client.call("snapshot", ["tab": tab])
            #expect(snapshot["dialog"]?["type"] == "alert", "\(snapshot.content)")
            #expect(snapshot["nodes"] == [])
            #expect(snapshot.result?["content"]?.items?.first?["text"]?.string?.contains("dialog alert from 127.0.0.1 \"Saved\": answer it with dialog_respond") == true)
            #expect((await client.call("read_text", ["tab": tab])).code == "dialog_open")
            #expect((await client.call("dialog_respond", ["tab": tab, "accept": true, "text": "x"])).code == "invalid_params")
            #expect((await client.call("dialog_respond", ["tab": tab])).code == "invalid_params")

            let answered = await client.call("dialog_respond", ["tab": tab, "accept": true])
            #expect(answered["answered"]?["type"] == "alert", "\(answered.content)")
            #expect((await client.call("wait_for", ["tab": tab, "load": "load"]))["title"] == "After alert")
            #expect((await client.call("dialog_respond", ["tab": tab, "accept": true])).code == "no_dialog")

            let cases: [(page: String, accept: Bool, text: String?, title: String)] = [
                ("confirm", true, nil, "yes"), ("confirm", false, nil, "no"),
                ("prompt", true, "Bob", "Bob"), ("prompt", true, nil, "Ann"), ("prompt", false, nil, "none"),
            ]
            for test in cases {
                let navigated = await client.call("navigate", ["tab": tab, "url": .string(base.appending(path: test.page).absoluteString)])
                #expect(navigated.code == "dialog_open", "\(test.page): \(navigated.content)")
                var answer: [String: JSONValue] = ["tab": tab, "accept": .bool(test.accept)]
                if let text = test.text { answer["text"] = .string(text) }
                #expect(!(await client.call("dialog_respond", .object(answer))).isError)
                let loaded = await client.call("wait_for", ["tab": tab, "load": "load"])
                #expect(loaded["title"] == .string(test.title), "\(test): \(loaded.content)")
            }
        }
    }

    @Test func stopAnswersDialogsWithTheirSafeDefault() async throws {
        try await withAgent { client, base in
            let opened = await client.call("tab_open", ["url": .string(base.appending(path: "confirm").absoluteString), "wait": "load"])
            #expect(opened.code == "dialog_open", "\(opened.content)")
            let tab = try #require(client.tab(opened["tab"]?.string ?? ""))
            client.hub.stop()
            #expect(await waitUntil(10) { tab.title == "no" })
            #expect(client.hub.tabs[tab.id]?.dialog == nil)
            client.hub.allowAgain()
        }
    }

    /// A tab that sleeps, or whose page's process dies, takes the agent's dialog along.
    @Test func aPageGoneTakesItsDialogAlong() async throws {
        try await withAgent { client, base in
            let one = base.appending(path: "one")
            for crash in [false, true] {
                let id = try await open(client, one)
                let tab = try #require(client.tab(id))
                _ = try await tab.webView.evaluateJavaScript("setTimeout(() => alert('Saved'), 0); 0")
                #expect(await waitUntil(10) { client.hub.tabs[tab.id]?.dialog != nil })
                if crash {
                    // The tab shown reloads rather than sleeping.
                    client.browser.select(tab)
                    tab.webViewWebContentProcessDidTerminate(tab.webView)
                    #expect(!tab.isAsleep)
                } else {
                    tab.sleep(configuration: client.browser.makeConfiguration(for: tab.url))
                }
                #expect(client.hub.tabs[tab.id]?.dialog == nil, crash ? "process died" : "asleep")
                let navigated = await client.call("navigate", ["tab": .string(id), "url": .string(one.absoluteString)])
                #expect(!navigated.isError, "\(navigated.content)")
            }
        }
    }

    /// In the tab the user looks at, the dialog is the user's: agents see it until it's answered.
    @Test func dialogsShownToTheUserStayTheirs() async throws {
        try await withAgent { client, base in
            let id = try await open(client, base.appending(path: "one"))
            let tab = try #require(client.tab(id))
            let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = tab.webView
            defer { window.contentView = nil }
            _ = try await tab.webView.evaluateJavaScript("setTimeout(() => { document.title = confirm('Sure?') ? 'yes' : 'no' }, 0); 0")
            #expect(await waitUntil(10) { client.hub.tabs[tab.id]?.dialog?.toUser == true })
            let snapshot = await client.call("snapshot", ["tab": .string(id)])
            #expect(snapshot["dialog"]?["shownToUser"] == true, "\(snapshot.content)")
            #expect((await client.call("dialog_respond", ["tab": .string(id), "accept": true])).code == "dialog_open")
            let sheet = try #require(window.attachedSheet)
            window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
            #expect(await waitUntil(10) { tab.title == "yes" })
            #expect(client.hub.tabs[tab.id]?.dialog == nil)
        }
    }

    /// Shows the tab as the user would, and answers the page's confirm on its sheet with OK.
    private func answerAsUser(_ client: Client, in tab: Tab) async throws {
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = tab.webView
        defer { window.contentView = nil }
        #expect(await waitUntil(10) { window.attachedSheet != nil && client.hub.tabs[tab.id]?.dialog?.toUser == true })
        let sheet = try #require(window.attachedSheet)
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        #expect(await waitUntil(10) { tab.title == "yes" })
        #expect(client.hub.tabs[tab.id]?.dialog == nil)
    }

    /// The session that held the tab ends: its dialog waits for the user to look at the tab, and
    /// the next one is the user's from the start.
    @Test func aSessionEndingHandsItsDialogToTheUser() async throws {
        try await withAgent { client, base in
            let id = try await open(client, base.appending(path: "one"))
            let tab = try #require(client.tab(id))
            _ = try await tab.webView.evaluateJavaScript("setTimeout(() => { document.title = confirm('Sure?') ? 'yes' : 'no' }, 0); 0")
            #expect(await waitUntil(10) { client.hub.tabs[tab.id]?.dialog?.toUser == false })

            #expect(await client.hub.handle(.endSession(client.session)).status == 200)
            #expect(client.hub.tabs[tab.id]?.dialog?.toUser == true)
            let other = try await Client(browser: client.browser)
            #expect((await other.call("dialog_respond", ["tab": .string(id), "accept": false])).code == "dialog_open")
            try await answerAsUser(client, in: tab)

            let next = await client.hub.agentReply(to: AgentDialog(.confirm, message: "Again?", host: "127.0.0.1"), in: tab)
            #expect(next == nil, "out of sight, with no session holding the tab")
        }
    }

    /// Access turned off with a dialog handed to the user in a tab out of sight: the browser has
    /// no hub any more, and the dialog still shows when the user looks at the tab.
    @Test func aDialogHandedToTheUserOutlivesAccessTurnedOff() async throws {
        try await withAgent { client, base in
            let id = try await open(client, base.appending(path: "one"))
            let tab = try #require(client.tab(id))
            _ = try await tab.webView.evaluateJavaScript("setTimeout(() => { document.title = confirm('Sure?') ? 'yes' : 'no' }, 0); 0")
            #expect(await waitUntil(10) { client.hub.tabs[tab.id]?.dialog?.toUser == false })
            #expect(await client.hub.handle(.endSession(client.session)).status == 200)
            #expect(client.hub.tabs[tab.id]?.dialog?.toUser == true)

            await client.browser.setAgentAccess(false)
            #expect(client.browser.agent == nil)
            try await answerAsUser(client, in: tab)
            #expect(tab.dialogOwner == nil)
        }
    }

    @Test func lookingAtTheTabHandsTheAgentsDialogToTheUser() async throws {
        try await withAgent { client, base in
            let id = try await open(client, base.appending(path: "one"))
            let tab = try #require(client.tab(id))
            _ = try await tab.webView.evaluateJavaScript("setTimeout(() => { document.title = confirm('Sure?') ? 'yes' : 'no' }, 0); 0")
            #expect(await waitUntil(10) { client.hub.tabs[tab.id]?.dialog?.toUser == false })
            try await answerAsUser(client, in: tab)
        }
    }

    // MARK: Payments

    @Test func theSnapshotMarksPayments() async throws {
        try await withAgent { client, base in
            client.hub.paymentProviders = PaymentProviders(hosts: ["localhost"])
            let checkout = try await open(client, base.appending(path: "checkout"))
            // The frame's first document is about:blank, until the page's script points it at its card form.
            var snapshot = await client.call("snapshot", ["tab": .string(checkout), "format": "json"])
            for _ in 0..<50 where !(snapshot["nodes"]?.items ?? []).contains(where: { $0["name"] == "Postcode" }) {
                try await Task.sleep(for: .milliseconds(100))
                snapshot = await client.call("snapshot", ["tab": .string(checkout), "format": "json"])
            }
            let nodes = snapshot["nodes"]?.items ?? []
            let guardOf = { (role: String, name: String?) in
                nodes.first { $0["role"] == .string(role) && (name == nil || $0["name"] == .string(name!)) }?["guard"]
            }
            #expect(guardOf("button", "Place order") == "payment", "\(nodes)")
            #expect(guardOf("link", "Help") == nil)
            #expect(guardOf("shadow-closed", "apple-pay-button") == "payment")
            #expect(guardOf("frame", nil) == "payment")
            #expect(guardOf("textbox", "Postcode") == "payment", "\(snapshot.content)")
            #expect(guardOf("button", "Use this card") == "payment")

            let picture = await client.call("screenshot", ["tab": .string(checkout)])
            let masked = picture["masked"]?.items ?? []
            #expect(masked.count == 1, "\(picture.content)")

            let products = try await open(client, base.appending(path: "products"))
            let grid = (await client.call("snapshot", ["tab": .string(products), "format": "json"]))["nodes"]?.items ?? []
            #expect(grid.map { $0["guard"] ?? .null } == [.null, "payment", .null], "\(grid)")
        }
    }
}

private extension JSONValue {
    var items: [JSONValue]? {
        if case .array(let items) = self { items } else { nil }
    }
}

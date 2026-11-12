import AppKit
import Foundation
import Testing
import WebKit
@testable import Lithium

/// Local files, downloads, file choosers, dialogs and payment marks on a whole Browser, through
/// the hub as an MCP client calls it, on pages served from 127.0.0.1 and, for a second origin,
/// localhost. Lithium asks the user nothing about any of them.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct AgentTransfersTests {
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
        // The throwaway home the tests run in has no Downloads folder, and a transfer into none fails.
        try FileManager.default.createDirectory(at: .downloadsDirectory, withIntermediateDirectories: true)
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
        #expect(!opened.isError, "\(opened.content)")
        return try #require(opened["tab"]?.string)
    }

    // MARK: file: addresses

    /// A local file opens like any page: Lithium asks the user nothing, and logs no prompt.
    @Test func fileAddressesOpenUnasked() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "agent-notes-\(UUID().uuidString).html")
        try "<title>Notes</title><p>private</p>".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        try await withAgent { client, base in
            let opened = await client.call("tab_open", ["url": .string(file.absoluteString), "wait": "load"])
            #expect(!opened.isError, "\(opened.content)")
            #expect(opened["title"] == "Notes")
            let id = try #require(opened["tab"]?.string)

            let one = base.appending(path: "one")
            #expect(!(await client.call("navigate", ["tab": .string(id), "url": .string(one.absoluteString)])).isError)
            let back = await client.call("go_back", ["tab": .string(id)])
            #expect(back["title"] == "Notes", "\(back.content)")
            let again = await client.call("navigate", ["tab": .string(id), "url": .string(file.absoluteString)])
            #expect(again["title"] == "Notes", "\(again.content)")

            let entries = await client.hub.log.entries(limit: 50)
            #expect(entries.allSatisfy { $0["event"] != "confirmation" && $0["confirmation"] == nil })
        }
    }

    // MARK: Downloads

    /// A download the agent starts goes ahead unasked, and its result says where the file is.
    @Test func downloadsTheAgentStartsGoAhead() async throws {
        try await withAgent { client, base in
            let report = base.appending(path: "report.csv").absoluteString
            let id = try await open(client, base.appending(path: "one"))

            let started = ContinuousClock.now
            let downloaded = await client.call("navigate", ["tab": .string(id), "url": .string(report)])
            #expect(!downloaded.isError, "\(downloaded.content)")
            #expect(ContinuousClock.now - started < .seconds(10), "nothing waited on the user")
            #expect(downloaded["download"]?["file"] == "report.csv", "\(downloaded.content)")
            #expect(downloaded["download"]?["done"] == true, "\(downloaded.content)")
            #expect(downloaded["download"]?["grant"] == nil)
            #expect(downloaded["state"] == nil)
            let path = try #require(downloaded["download"]?["path"]?.string)
            defer { try? FileManager.default.removeItem(atPath: path) }
            #expect(try String(contentsOfFile: path, encoding: .utf8) == "a,b")
            #expect(client.tab(id)?.title == "One", "the page before stays")

            // A tab opened just for the file closes as its download starts.
            let fromNewTab = await client.call("tab_open", ["url": .string(report)])
            #expect(fromNewTab["download"]?["file"] == "report.csv", "\(fromNewTab.content)")
            #expect(client.tab(fromNewTab["tab"]?.string ?? "") == nil)
            if let other = fromNewTab["download"]?["path"]?.string { try? FileManager.default.removeItem(atPath: other) }
        }
    }

    /// A private tab saves nothing: its calls are logged, marked, but never with the addresses or
    /// host it went to.
    @Test func aPrivateTabsCallsAreLoggedWithoutItsAddresses() async throws {
        try await withAgent { client, base in
            let opened = await client.call("tab_open", ["url": .string(base.appending(path: "one").absoluteString), "ephemeral": true, "wait": "load"])
            #expect(!opened.isError, "\(opened.content)")
            let id = try #require(opened["tab"]?.string)
            let report = base.appending(path: "report.csv").absoluteString
            let downloaded = await client.call("navigate", ["tab": .string(id), "url": .string(report)])
            #expect(downloaded["download"]?["file"] == "report.csv", "\(downloaded.content)")
            if let path = downloaded["download"]?["path"]?.string { try? FileManager.default.removeItem(atPath: path) }

            let entries = await client.hub.log.entries(limit: 2)
            #expect(entries.compactMap { $0["tool"]?.string }.sorted() == ["navigate", "tab_open"])
            for entry in entries {
                #expect(entry["ephemeral"] == true)
                #expect(entry["params"] == nil && entry["subject"] == nil && entry["site"] == nil)
                #expect(entry["tab"] == ["id": .string(id)])
                let text = String(decoding: entry.encoded(), as: UTF8.self)
                #expect(!text.contains("127.0.0.1") && !text.contains("report.csv") && !text.contains("/one"), "\(text)")
            }
        }
    }

    @Test func aPrivateTabOpenOfAFileIsLoggedWithoutItsPath() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "agent-private-\(UUID().uuidString).html")
        try "<title>Notes</title>".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        try await withAgent { client, _ in
            let opened = await client.call("tab_open", ["url": .string(file.absoluteString), "ephemeral": true, "wait": "load"])
            #expect(!opened.isError, "\(opened.content)")

            let entry = try #require(await client.hub.log.entries(limit: 1).first)
            #expect(entry["tool"] == "tab_open")
            #expect(entry["ephemeral"] == true)
            #expect(entry["params"] == nil && entry["subject"] == nil)
            let text = String(decoding: entry.encoded(), as: UTF8.self)
            #expect(!text.contains(file.lastPathComponent), "\(text)")
        }
    }

    /// A private batch that fails before its tab exists (here a step that isn't a tool) is still
    /// logged without its address.
    @Test func aPrivateBatchThatFailsEarlyIsLoggedWithoutItsAddress() async throws {
        try await withAgent { client, base in
            let url = base.appending(path: "account/123").absoluteString
            let failed = await client.call("batch", ["url": .string(url), "ephemeral": true, "steps": [["tool": "nope"]]])
            #expect(failed.isError, "\(failed.content)")

            let entry = try #require(await client.hub.log.entries(limit: 1).first)
            #expect(entry["tool"] == "batch")
            #expect(entry["ephemeral"] == true)
            #expect(entry["params"] == nil)
            let text = String(decoding: entry.encoded(), as: UTF8.self)
            #expect(!text.contains("127.0.0.1") && !text.contains("account"), "\(text)")
        }
    }

    /// Whatever the agent's navigation ends with, a download in the tab afterwards is the user's
    /// own again, with the prompts Lithium gives a page's download.
    @Test func theAgentsClaimEndsWithItsNavigation() async throws {
        try await withAgent { client, base in
            let one = base.appending(path: "one")
            let report = base.appending(path: "report.csv")
            let id = try await open(client, one)
            let tab = try #require(client.tab(id))
            let hub = client.hub

            let anchor = await client.call("navigate", ["tab": .string(id), "url": .string(one.absoluteString + "#part")])
            #expect(anchor["state"] == "load", "\(anchor.content)")
            #expect(!hub.startedDownload(in: tab), "after a move within the page")

            let refused = await client.call("navigate", ["tab": .string(id), "url": .string(base.appending(path: "mail").absoluteString)])
            #expect(refused.code == "navigation_cancelled", "\(refused.content)")
            #expect(!hub.startedDownload(in: tab), "after a refused scheme")

            let downloaded = await client.call("navigate", ["tab": .string(id), "url": .string(report.absoluteString)])
            #expect(downloaded["download"]?["file"] == "report.csv", "\(downloaded.content)")
            if let path = downloaded["download"]?["path"]?.string { try? FileManager.default.removeItem(atPath: path) }
            #expect(hub.openPanel(for: tab) == nil, "the user's file chooser after the agent's download")
            #expect(!hub.startedDownload(in: tab), "after the agent's download")
        }
    }

    /// Stop ends the load still on its way after `wait: none`: it never becomes a download.
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
            #expect(!(await waitUntil(2.5) { tab.unshownLoads > unshown }), "no download for a stopped agent")
            #expect(client.hub.tabs[tab.id]?.drive == nil)
            client.hub.allowAgain()
        }
    }

    /// A client that ends its own session after a `wait: none` call (a script run for one call)
    /// leaves its load going: the file still comes, unasked.
    @Test func aSessionEndingLeavesItsLoadGoing() async throws {
        let (slow, slowBase) = try await LocalHTTP.serve(["/report.csv": Self.pages["/report.csv"]!], delay: 1)
        defer { slow.cancel() }
        try await withAgent { client, base in
            let id = try await open(client, base.appending(path: "one"))
            let tab = try #require(client.tab(id))
            let unshown = tab.unshownLoads
            let started = await client.call("navigate", ["tab": .string(id), "url": .string(slowBase.appending(path: "report.csv").absoluteString), "wait": "none"])
            #expect(started["state"] == "started", "\(started.content)")
            #expect(await client.hub.handle(.endSession(client.session)).status == 200)
            #expect(await waitUntil(10) { tab.unshownLoads > unshown }, "the download started")
            #expect(await waitUntil(10) { tab.lastDownload?.state == .finished })
            if let file = tab.lastDownload?.destination { try? FileManager.default.removeItem(at: file) }
        }
    }

    @Test func uploadsAnswerTheChooserOnlyWithTheCallsFiles() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "agent-upload-\(UUID().uuidString).txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        try await withAgent { client, base in
            let hub = client.hub
            let id = try await open(client, base.appending(path: "one"))
            let named = try hub.tab(named: id)
            let state = try #require(hub.agentTab(for: named.tab))
            #expect(hub.openPanel(for: named.tab) == nil, "the user's own chooser")

            state.isBusy = true
            #expect(hub.openPanel(for: named.tab) == .cancelled, "the agent's chooser, unarmed")
            #expect(state.fileChoosersCancelled == 1)
            state.isBusy = false

            #expect(throws: AgentToolError.self) { try hub.armUpload([file.appending(path: "missing")], in: state) }
            #expect(state.armedUpload == nil)
            try hub.armUpload([file], in: state)
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

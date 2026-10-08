import Foundation
import Testing
import WebKit
@testable import Lithium

/// How a tab decides where its page goes: links opening new tabs, tracking parameters, Lithium's
/// own pages, and what extensions hear about it. Keeps its data in the home folder, like `BrowserTests`.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct NavigationTests {
    private final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]

        func record(_ path: String) { lock.withLock { counts[path, default: 0] += 1 } }
        subscript(path: String) -> Int { lock.withLock { counts[path] ?? 0 } }
    }

    /// A target=_blank link with tracking parameters opens its page, without them, in a new tab;
    /// the page with the link stays where it is.
    @Test func aNewTabsLinkLeavesItsOpenerAlone() async throws {
        let (listener, base) = try await LocalHTTP.serve([
            "/": ("Content-Type: text/html", #"<title>Opener</title><a id="open" href="/next?utm_source=test&id=1" target="_blank">Open</a>"#),
            "/next?id=1": ("Content-Type: text/html", "<title>Next</title>"),
        ])
        defer { listener.cancel() }
        let browser = Browser()
        let opener = browser.newTab(url: base)
        #expect(await waitUntil(30) { opener.webView.title == "Opener" && !opener.webView.isLoading })
        let count = browser.tabs.count
        _ = try await opener.webView.evaluateJavaScript("document.getElementById('open').click(); 0")

        #expect(await waitUntil(15) { browser.tabs.count == count + 1 })
        let popup = try #require(browser.tabs.first { $0 !== opener && $0.loadedWebView != nil })
        #expect(await waitUntil(15) { popup.webView.title == "Next" })
        #expect(popup.webView.url?.query() == "id=1")
        #expect(opener.webView.url == base)
        #expect(opener.webView.title == "Opener")
    }

    /// A site the user turned protections off for gets its tracking parameters.
    @Test func trackingParametersStayOnSitesWithoutProtections() async throws {
        let (listener, base) = try await LocalHTTP.serve([
            "/page?utm_source=test": ("Content-Type: text/html", "<title>Kept</title>"),
        ])
        defer { listener.cancel() }
        let page = try #require(URL(string: "page?utm_source=test", relativeTo: base)?.absoluteURL)
        let browser = Browser()
        browser.privacy.setEnabled(false, for: page)
        defer { browser.privacy.setEnabled(true, for: page) }
        let tab = browser.newTab(url: page)
        #expect(await waitUntil(30) { tab.webView.title == "Kept" })
        #expect(tab.webView.url == page)
    }

    /// Turning a site's protections off, or back on from Settings, reloads every open tab of that
    /// site so their blockers match the shield; tabs of other sites are left alone.
    @Test func protectionsChangeReloadsEveryTabOfTheSite() async throws {
        let requests = Requests()
        let (listener, base) = try await LocalHTTP.serve([
            "/a": ("Content-Type: text/html", Data("<title>A</title>".utf8)),
            "/b": ("Content-Type: text/html", Data("<title>B</title>".utf8)),
            "/c": ("Content-Type: text/html", Data("<title>C</title>".utf8)),
        ], requested: { requests.record($0) })
        defer { listener.cancel() }
        let other = try #require(URL(string: "http://localhost:\(base.port ?? 0)/c"))
        let browser = Browser()
        let a = browser.newTab(url: base.appending(path: "a"))
        let b = browser.newTab(url: base.appending(path: "b"), selecting: false)
        let c = browser.newTab(url: other, selecting: false)
        #expect(await waitUntil(30) { a.webView.title == "A" && b.webView.title == "B" && c.webView.title == "C" })
        let host = try #require(Privacy.siteHost(base))
        defer { browser.privacy.setEnabled(true, host: host) }

        browser.setProtections(false, for: a)
        #expect(await waitUntil(15) { requests["/a"] == 2 && requests["/b"] == 2 })
        #expect(!browser.privacy.isEnabled(for: b.url))

        browser.setProtections(true, host: host)
        #expect(await waitUntil(15) { requests["/a"] == 3 && requests["/b"] == 3 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(requests["/c"] == 1)
    }

    /// Changed from a private tab, protections reload that private session's tabs of the site
    /// only: a normal tab of the site keeps the saved setting and is left alone.
    @Test func privateProtectionsChangeReloadsOnlyItsSessionsTabs() async throws {
        let requests = Requests()
        let (listener, base) = try await LocalHTTP.serve([
            "/a": ("Content-Type: text/html", Data("<title>A</title>".utf8)),
            "/b": ("Content-Type: text/html", Data("<title>B</title>".utf8)),
            "/c": ("Content-Type: text/html", Data("<title>C</title>".utf8)),
        ], requested: { requests.record($0) })
        defer { listener.cancel() }
        let browser = Browser()
        let a = browser.newTab(url: base.appending(path: "a"), privateStore: .nonPersistent())
        let b = browser.newTab(url: base.appending(path: "b"), selecting: false, privateStore: a.privateStore)
        let c = browser.newTab(url: base.appending(path: "c"), selecting: false)
        #expect(await waitUntil(30) { a.webView.title == "A" && b.webView.title == "B" && c.webView.title == "C" })

        browser.setProtections(false, for: a)
        #expect(await waitUntil(15) { requests["/a"] == 2 && requests["/b"] == 2 })
        #expect(!browser.privacy.isEnabled(for: b.url, privateSession: b.privateSession))
        #expect(browser.privacy.isEnabled(for: c.url), "nothing saved")
        try await Task.sleep(for: .milliseconds(300))
        #expect(requests["/c"] == 1)
    }

    /// A server that sends the address back with its tracking parameters gets them: the tab
    /// strips them once, not in an endless loop of loads.
    @Test func aServerAddingTheParametersBackIsNotLoopedOn() async throws {
        let requests = Requests()
        let (listener, base) = try await LocalHTTP.serve([
            "/landing": ("HTTP/1.1 302 Found\r\nLocation: /landing?utm_source=test", Data()),
            "/landing?utm_source=test": ("Content-Type: text/html", Data("<title>Landed</title>".utf8)),
        ], requested: { requests.record($0) })
        defer { listener.cancel() }
        let page = try #require(URL(string: "landing?utm_source=test", relativeTo: base)?.absoluteURL)
        let browser = Browser()
        let tab = browser.newTab(url: page)
        #expect(await waitUntil(30) { tab.webView.title == "Landed" })
        try await Task.sleep(for: .seconds(1))
        #expect(requests["/landing"] == 1)
        #expect(tab.webView.url == page)
    }

    /// The same tracked link, followed again after Back, is stripped again: only a redirect
    /// straight back to the stripped address is let through.
    @Test func aTrackedLinkIsStrippedEveryTime() async throws {
        let requests = Requests()
        let (listener, base) = try await LocalHTTP.serve([
            "/": ("Content-Type: text/html", Data(#"<title>Results</title><a id="go" href="/a?utm_source=test">Go</a>"#.utf8)),
            "/a": ("Content-Type: text/html", Data("<title>Article</title>".utf8)),
        ], requested: { requests.record($0) })
        defer { listener.cancel() }
        let browser = Browser()
        let tab = browser.newTab(url: base)
        for visit in 1...2 {
            #expect(await waitUntil(30) { tab.webView.title == "Results" && !tab.webView.isLoading })
            _ = try await tab.webView.evaluateJavaScript("document.getElementById('go').click(); 0")
            #expect(await waitUntil(30) { tab.webView.title == "Article" && !tab.webView.isLoading })
            #expect(requests["/a"] == visit)
            tab.webView.goBack()
        }
        #expect(requests["/a?utm_source=test"] == 0)
    }

    /// Back, Forward and Reload return to a history entry with tracking parameters (put there by
    /// the page's own `replaceState`, as analytics scripts do) as it is: stripping them would
    /// load a new page in its place and wipe the forward history.
    @Test func backForwardAndReloadKeepATrackedEntry() async throws {
        let requests = Requests()
        let tracked = #"<title>Tracked</title><script>history.replaceState(null, "", "/y?utm_source=test")</script>"#
        let (listener, base) = try await LocalHTTP.serve([
            "/y": ("Content-Type: text/html", Data(tracked.utf8)),
            "/y?utm_source=test": ("Content-Type: text/html", Data(tracked.utf8)),
            "/x": ("Content-Type: text/html", Data("<title>Next</title>".utf8)),
        ], requested: { requests.record($0) })
        defer { listener.cancel() }
        let entry = try #require(URL(string: "y?utm_source=test", relativeTo: base)?.absoluteURL)
        let browser = Browser()
        let tab = browser.newTab(url: base.appending(path: "y"))
        #expect(await waitUntil(30) { tab.webView.url == entry && !tab.webView.isLoading })
        tab.load(base.appending(path: "x"))
        #expect(await waitUntil(30) { tab.webView.title == "Next" && !tab.webView.isLoading })

        browser.navigate(tab, .back)
        #expect(await waitUntil(30) { tab.webView.title == "Tracked" && !tab.webView.isLoading })
        #expect(tab.webView.url == entry)
        #expect(tab.webView.canGoForward, "the forward history is still there")
        browser.navigate(tab, .reload)
        #expect(await waitUntil(30) { requests["/y?utm_source=test"] == 1 && !tab.webView.isLoading })
        #expect(tab.webView.url == entry)
        #expect(tab.webView.canGoForward)
        browser.navigate(tab, .forward)
        #expect(await waitUntil(30) { tab.webView.title == "Next" && !tab.webView.isLoading })
        #expect(requests["/y"] == 1, "never loaded again without its parameters")
    }

    /// Back from a website returns to Lithium's page, which can still talk to the app; a
    /// website's own script still can't open one.
    @Test func backReturnsToAnInternalPage() async throws {
        let (listener, base) = try await LocalHTTP.serve(["/": ("Content-Type: text/html", "<title>Site</title>")])
        defer { listener.cancel() }
        let browser = Browser()
        let tab = browser.newTab(url: Internal.settingsURL)
        #expect(await waitUntil(30) { await bridgeAnswers(in: tab) })
        tab.load(base)
        #expect(await waitUntil(30) { tab.webView.title == "Site" && !tab.webView.isLoading })

        // The Back button, then the website's own `history.back()`.
        tab.webView.goBack()
        #expect(await waitUntil(30) { Internal.isInternal(tab.webView.url) && !tab.webView.isLoading })
        #expect(await waitUntil(10) { await bridgeAnswers(in: tab) })
        tab.webView.goForward()
        #expect(await waitUntil(30) { tab.webView.title == "Site" && !tab.webView.isLoading })
        _ = try await tab.webView.evaluateJavaScript("history.back(); 0")
        #expect(await waitUntil(30) { Internal.isInternal(tab.webView.url) && !tab.webView.isLoading })
        #expect(await waitUntil(10) { await bridgeAnswers(in: tab) })

        tab.webView.goForward()
        #expect(await waitUntil(30) { tab.webView.title == "Site" && !tab.webView.isLoading })
        _ = try await tab.webView.evaluateJavaScript("location.href = 'lithium://history'; 0")
        try await Task.sleep(for: .seconds(1))
        #expect(tab.webView.url == base)
    }

    /// A link from Lithium's page that never shows a page (a 204 here; a download or Stop alike)
    /// leaves the page its line to the app.
    @Test func anInternalPageKeepsItsBridgeWhenALoadNeverShows() async throws {
        let requests = Requests()
        let (listener, base) = try await LocalHTTP.serve([
            "/empty": ("HTTP/1.1 204 No Content\r\nContent-Type: text/plain", Data()),
        ], requested: { requests.record($0) })
        defer { listener.cancel() }
        let browser = Browser()
        let tab = browser.newTab(url: Internal.settingsURL)
        #expect(await waitUntil(30) { await bridgeAnswers(in: tab) })

        let empty = base.appending(path: "empty").absoluteString
        _ = try await tab.webView.evaluateJavaScript("location.href = '\(empty)'; 0")
        #expect(await waitUntil(15) { requests["/empty"] == 1 && !tab.webView.isLoading })
        try await Task.sleep(for: .milliseconds(500))
        #expect(Internal.isInternal(tab.webView.url))
        #expect(await bridgeAnswers(in: tab))
    }

    /// A load of another site that never shows a page (a 204 here; Stop or a download alike) gives
    /// the shown page back its own protections: its next frames once farbled with the target's seed.
    @Test func aLoadThatNeverShowsLeavesThePageItsOwnProtections() async throws {
        let requests = Requests()
        let (listener, base) = try await LocalHTTP.serve([
            "/": ("Content-Type: text/html", Data("<title>Shown</title>".utf8)),
            "/empty": ("HTTP/1.1 204 No Content\r\nContent-Type: text/plain", Data()),
        ], requested: { requests.record($0) })
        defer { listener.cancel() }
        let browser = Browser()
        let tab = browser.newTab(url: base)
        defer { browser.close(tab) }
        #expect(await waitUntil(30) { tab.webView.title == "Shown" && !tab.webView.isLoading })
        let controller = tab.webView.configuration.userContentController
        let farbling = { (url: URL) in browser.privacy.scripts(true, for: url).first?.source }
        let shown = try #require(farbling(base))
        let other = try #require(URL(string: "http://localhost:\(base.port ?? 0)/empty"))
        #expect(farbling(other) != shown)
        #expect(controller.userScripts.contains { $0.source == shown })

        _ = try await tab.webView.evaluateJavaScript("location.href = '\(other.absoluteString)'; 0")
        #expect(await waitUntil(15) { requests["/empty"] == 1 && !tab.webView.isLoading })
        try await Task.sleep(for: .milliseconds(500))
        #expect(controller.userScripts.contains { $0.source == shown })
        #expect(!controller.userScripts.contains { $0.source == farbling(other) })
        #expect(tab.webView.url == base)
    }

    /// Closing the selected tab tells extensions (`chrome.tabs.onActivated`) which tab took over.
    @Test func closingTheSelectedTabTellsExtensionsWhichIsActive() async throws {
        let id = "ppoonnmmllkkjjiihhggffeeddccbbaa"
        let browser = Browser()
        defer { Task { await browser.extensions.remove(id: id) } }
        // With host access granted at install: `tabs.get` on a website's tab would otherwise ask
        // for it in a modal alert that no one answers here, and the test would never end.
        try await browser.extensions.install(archive: try Self.archive([
            "manifest.json": #"{"manifest_version": 3, "name": "Tabs", "version": "1.0", "permissions": ["tabs"], "host_permissions": ["<all_urls>"], "options_page": "options.html"}"#,
            "options.html": #"<title>Options</title><script src="options.js"></script>"#,
            "options.js": "chrome.tabs.onActivated.addListener(({ tabId }) => chrome.tabs.get(tabId, (tab) => { document.title = 'Activated ' + tab.url; }));",
        ]), id: id)
        browser.extensions.openOptions(id: id)
        let options = try #require(browser.selectedTab)
        #expect(await waitUntil(30) { options.webView.title == "Options" && !options.webView.isLoading })

        let (listener, base) = try await LocalHTTP.serve([
            "/first": ("Content-Type: text/html", "<title>First</title>"),
            "/second": ("Content-Type: text/html", "<title>Second</title>"),
        ])
        defer { listener.cancel() }
        let first = browser.newTab(url: base.appending(path: "first"))
        let second = browser.newTab(url: base.appending(path: "second"))
        #expect(await waitUntil(30) { first.webView.title == "First" && second.webView.title == "Second" })
        _ = try await options.webView.evaluateJavaScript("document.title = 'Ready'; 0")

        browser.close(second)
        #expect(browser.selectedTab === first)
        let url = base.appending(path: "first").absoluteString
        #expect(await waitUntil(10) { options.webView.title == "Activated \(url)" }, "\(options.webView.title ?? "")")
        await browser.extensions.remove(id: id)
    }

    /// Another app's link asks first, once per site and scheme. Cancel opens nothing; "Always
    /// allow" is remembered for that site and scheme only, never from a private tab; `mailto:`
    /// and a scheme no app opens never ask. Hand-offs are only recorded in tests.
    @Test func appLinksAskOncePerSiteAndScheme() async throws {
        let links = AppLinks()
        let app = URL(fileURLWithPath: "/Applications/Example.app")
        links.appOpening = { $0.scheme == "lithium-none" ? nil : app }
        let site = "app-links-\(UUID().uuidString).example"
        defer { ["lithium-test", "lithium-other"].forEach { links.set(false, scheme: $0, host: site) } }
        let tab = UUID()
        let url = URL(string: "lithium-test:open?id=1")!

        func click(_ url: URL, from host: String = site, isPrivate: Bool = false) async -> (AppLinkRequest?, [ExternalApps.HandOff]) {
            let before = ExternalApps.recorded
            let task = Task { await links.open(url, from: host, tabID: tab, isPrivate: isPrivate) }
            _ = await waitUntil(2) { !links.pending.isEmpty || ExternalApps.recorded.count > before.count }
            let request = links.pending.first
            if request == nil { await task.value }
            return (request, Array(ExternalApps.recorded.dropFirst(before.count)))
        }

        let start = ExternalApps.recorded
        var (request, opened) = await click(url)
        var shown = try #require(request)
        #expect(opened.isEmpty)
        #expect((shown.host, shown.scheme, shown.app, shown.canRemember) == (site, "lithium-test", app, true))
        links.answer(shown, open: false)
        #expect(await waitUntil(2) { links.pending.isEmpty })
        try await Task.sleep(for: .milliseconds(100))
        #expect(ExternalApps.recorded == start, "Cancel opens nothing")

        (request, _) = await click(url)
        shown = try #require(request)
        let before = ExternalApps.recorded
        links.answer(shown, open: true, always: true)
        #expect(await waitUntil(2) { ExternalApps.recorded == before + [.open(url)] })

        (request, opened) = await click(url)
        #expect(request == nil, "allowed for this site and scheme")
        #expect(opened == [.open(url)])
        (request, _) = await click(URL(string: "lithium-other:x")!)
        #expect(request != nil, "another scheme asks")
        links.cancel(tabID: tab)
        (request, _) = await click(url, from: "other-\(site)")
        #expect(request != nil, "another site asks")
        links.cancel(tabID: tab)

        (request, _) = await click(URL(string: "lithium-other:x")!, isPrivate: true)
        shown = try #require(request)
        #expect(!shown.canRemember)
        let opening = ExternalApps.recorded
        links.answer(shown, open: true, always: true)
        #expect(await waitUntil(2) { ExternalApps.recorded == opening + [.open(URL(string: "lithium-other:x")!)] })
        #expect(links.allowed[site] == ["lithium-test"], "a private tab remembers nothing")

        let mail = URL(string: "mailto:x@example.com")!
        (request, opened) = await click(mail)
        #expect(request == nil && opened == [.open(mail)])
        (request, opened) = await click(URL(string: "lithium-none:x")!)
        #expect(request == nil && opened.isEmpty)
    }

    /// The user's own click on another app's link in a page asks, naming the site; the page's
    /// own `click()` (from a timer, with no press) does nothing.
    @Test func aClickedAppLinkAsksFirst() async throws {
        let page = #"""
            <title>Links</title><style>body { margin: 0 } a { position: absolute; left: 40px; top: 40px; width: 120px; height: 30px }</style>
            <a id="app" href="lithium-test:open">Open</a>
            <script>setTimeout(() => { document.getElementById('app').click(); document.title = 'Clicked' }, 300)</script>
            """#
        let (listener, base) = try await LocalHTTP.serve(["/": ("Content-Type: text/html", page)])
        defer { listener.cancel() }
        let browser = Browser()
        browser.appLinks.appOpening = { _ in URL(fileURLWithPath: "/Applications/Example.app") }
        let before = ExternalApps.recorded
        let tab = browser.newTab(url: base)
        defer { browser.close(tab) }
        #expect(await waitUntil(30) { tab.webView.title == "Clicked" && !tab.webView.isLoading })
        try await Task.sleep(for: .milliseconds(500))
        #expect(browser.appLinks.pending.isEmpty, "a script's click asks nothing")

        let shown = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        shown.isReleasedWhenClosed = false
        let webView = tab.webView
        webView.removeFromSuperview()
        webView.frame = shown.contentLayoutRect
        shown.contentView = webView
        defer { shown.contentView = nil }
        let point = webView.convert(CGPoint(x: 55, y: 50), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: shown.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            type == .leftMouseDown ? webView.mouseDown(with: event) : webView.mouseUp(with: event)
        }
        #expect(await waitUntil(5) { browser.appLinks.pending.contains { $0.tabID == tab.id } })
        let request = try #require(browser.appLinks.pending.first)
        #expect(request.host == base.host())
        #expect(request.url == URL(string: "lithium-test:open"))
        #expect(ExternalApps.recorded == before, "nothing opens before the answer")
        #expect(browser.dismissOverlay())
        #expect(browser.appLinks.pending.isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        #expect(ExternalApps.recorded == before, "Escape cancels")
    }

    /// The internal page's `call` reaches the app and gets its state back.
    private func bridgeAnswers(in tab: Lithium.Tab) async -> Bool {
        let answer = try? await tab.webView.callAsyncJavaScript("return typeof (await call('state'))", contentWorld: .page)
        return answer as? String == "object"
    }

    /// A direct link to an audio file shows WebKit's player, not Lithium's error page: WebKit ends
    /// the main load with its error 204 once the player takes it over. Silent, so nothing is heard.
    @Test func aDirectMediaLinkShowsItsPlayer() async throws {
        #expect(Tab.isDropped(NSError(domain: "WebKitErrorDomain", code: 204)))
        #expect(!Tab.isDropped(NSError(domain: "WebKitErrorDomain", code: 203)))
        let samples = 8_000
        var wav = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        append(UInt32(36 + samples * 2))
        wav.append(contentsOf: Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(8_000)); append(UInt32(16_000)); append(UInt16(2)); append(UInt16(16))
        wav.append(contentsOf: Data("data".utf8))
        append(UInt32(samples * 2))
        wav.append(Data(count: samples * 2))
        let (listener, base) = try await LocalHTTP.serve(["/sound.wav": ("Content-Type: audio/wav", wav)])
        defer { listener.cancel() }
        let browser = Browser()
        let tab = browser.newTab(url: base.appending(path: "sound.wav"))
        defer { browser.close(tab) }
        #expect(await waitUntil(30) { tab.webView.url != nil && !tab.webView.isLoading })
        try await Task.sleep(for: .seconds(1))
        #expect(tab.loadError == nil)
        #expect(tab.webView.title != "Can’t open this page")
        #expect(tab.url?.path() == "/sound.wav")
    }

    /// A ZIP of `files` at its root, like a store package.
    private static func archive(_ files: [String: String]) throws -> Data {
        let source = FileManager.default.temporaryDirectory.appending(path: "extension-\(UUID())")
        let zip = FileManager.default.temporaryDirectory.appending(path: "extension-\(UUID()).zip")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: zip)
        }
        for (name, text) in files { try Data(text.utf8).write(to: source.appending(path: name)) }
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", source.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        return try Data(contentsOf: zip)
    }

    private func waitUntil(_ seconds: Double, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }
}

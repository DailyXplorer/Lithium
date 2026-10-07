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

    /// The internal page's `call` reaches the app and gets its state back.
    private func bridgeAnswers(in tab: Lithium.Tab) async -> Bool {
        let answer = try? await tab.webView.callAsyncJavaScript("return typeof (await call('state'))", contentWorld: .page)
        return answer as? String == "object"
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

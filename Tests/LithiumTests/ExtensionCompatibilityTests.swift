import Foundation
import Testing
import WebKit
@testable import Lithium

/// A Chrome Web Store build's background uses Chrome APIs WebKit lacks as soon as it starts, as
/// 1Password's does. It runs a whole Browser, so only in a throwaway home folder (scripts/test).
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct ExtensionCompatibilityTests {
    private let id = "kkllmmnnooppaabbccddeeffgghhiijj"

    private static let files = [
        "manifest.json": #"""
            {"manifest_version": 3, "name": "Chrome build", "version": "1.0",
             "permissions": ["notifications", "storage", "webNavigation"], "host_permissions": ["<all_urls>"],
             "background": {"service_worker": "background/background.js", "type": "module"},
             "content_scripts": [{"matches": ["<all_urls>"], "run_at": "document_start", "js": ["content.js"]}]}
            """#,
        "background/background.js": """
            chrome.notifications.onClicked.addListener(() => {});
            // Busy enough for WebKit to collect the API objects nothing else holds.
            for (let i = 0; i < 40; i++) { const garbage = []; for (let j = 0; j < 200000; j++) garbage.push({ j }); }
            chrome.webNavigation.onCreatedNavigationTarget.addListener(() => {});
            browser.storage.managed.onChanged.addListener(() => {});
            const policy = chrome.storage.managed.get(null);
            chrome.runtime.onMessage.addListener((message, sender, respond) => { policy.then((managed) => respond(`pong ${JSON.stringify(managed)}`)); return true; });
            """,
        // Asked again until the background has started.
        "content.js": """
            const ask = () => chrome.runtime.sendMessage({ name: 'ping' }, {}, (reply) => {
                document.documentElement.setAttribute('data-reply', reply ?? chrome.runtime.lastError?.message ?? 'nothing');
                if (!reply) setTimeout(ask, 200);
            });
            ask();
            """,
    ]

    private func archive(_ files: [String: String] = Self.files) throws -> Data {
        let source = FileManager.default.temporaryDirectory.appending(path: "extension-\(UUID())")
        let zip = FileManager.default.temporaryDirectory.appending(path: "extension-\(UUID()).zip")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: zip)
        }
        for (path, text) in files {
            let file = source.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", source.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        return try Data(contentsOf: zip)
    }

    @Test func aChromeBuildsBackgroundStartsAndAnswersItsContentScripts() async throws {
        let browser = Browser()
        await browser.extensions.waitUntilLoaded()
        try await browser.extensions.install(archive: try archive(), id: id)
        defer { Task { await browser.extensions.remove(id: id) } }
        let tab = browser.newTab()
        tab.webView.loadHTMLString("<!doctype html><title>Page</title>", baseURL: URL(string: "https://example.com/")!)

        var reply: String?
        for _ in 0..<100 {
            reply = try? await tab.webView.callAsyncJavaScript("return document.documentElement.getAttribute('data-reply')", contentWorld: .page) as? String
            if reply?.hasPrefix("pong") == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(reply == "pong {}")
    }

    /// Its background opens its popup twice, as 1Password's does each time its Unlock button is
    /// clicked. WebKit refuses `action.openPopup()` while the popup it last asked Lithium to show
    /// is open; with no window to show it in, as here, Lithium closes that one.
    @Test func anExtensionCanOpenItsPopupAgainWhenItCouldNotBeShown() async throws {
        let id = "ppqqrrssttuuvvwwxxyyzzaabbccddee"
        let files = [
            "manifest.json": #"""
                {"manifest_version": 3, "name": "Popup", "version": "1.0", "host_permissions": ["<all_urls>"],
                 "action": {"default_popup": "popup.html"}, "background": {"service_worker": "background.js"},
                 "content_scripts": [{"matches": ["<all_urls>"], "run_at": "document_start", "js": ["content.js"]}]}
                """#,
            "popup.html": "<!doctype html><title>Popup</title>",
            "background.js": """
                const open = () => chrome.action.openPopup().then(() => 'opened', (error) => error.message);
                chrome.runtime.onMessage.addListener((message, sender, respond) => {
                    open().then(async (first) => { await new Promise((wait) => setTimeout(wait, 1000)); respond(`${first}, ${await open()}`); });
                    return true;
                });
                """,
            "content.js": """
                const ask = () => chrome.runtime.sendMessage({ name: 'open' }, {}, (reply) => {
                    document.documentElement.setAttribute('data-reply', reply ?? chrome.runtime.lastError?.message ?? 'nothing');
                    if (!reply) setTimeout(ask, 200);
                });
                ask();
                """,
        ]
        let browser = Browser()
        await browser.extensions.waitUntilLoaded()
        try await browser.extensions.install(archive: try archive(files), id: id)
        defer { Task { await browser.extensions.remove(id: id) } }
        let tab = browser.newTab()
        tab.webView.loadHTMLString("<!doctype html><title>Page</title>", baseURL: URL(string: "https://example.com/")!)

        var reply: String?
        for _ in 0..<100 {
            reply = try? await tab.webView.callAsyncJavaScript("return document.documentElement.getAttribute('data-reply')", contentWorld: .page) as? String
            if reply != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(reply == "opened, opened")
    }

    private static let pageFiles = [
        "manifest.json": #"{"manifest_version": 3, "name": "Pages", "version": "1.0"}"#,
        "page.html": "<!doctype html><title>Extension page</title>",
    ]

    private func waitForURL(_ url: URL, in tab: Tab) async throws -> URL? {
        for _ in 0..<50 where tab.webView.url != url {
            try await Task.sleep(for: .milliseconds(100))
        }
        return tab.webView.url
    }

    /// 1Password's setup page sends its own tab to its sign-in page on the web. WebKit loads
    /// nothing but the extension's pages in a web view made with its configuration.
    @Test func anExtensionPageCanSendItsTabToAWebsite() async throws {
        let id = "ffgghhiijjkkllmmnnooppaabbccddee"
        let browser = Browser()
        await browser.extensions.waitUntilLoaded()
        try await browser.extensions.install(archive: try archive(Self.pageFiles), id: id)
        defer { Task { await browser.extensions.remove(id: id) } }
        let page = URL(string: "webkit-extension://\(id)/page.html")!
        let tab = browser.newTab(url: page, configuration: browser.extensions.configuration(for: page))
        #expect(try await waitForURL(page, in: tab) == page)
        _ = try? await tab.webView.callAsyncJavaScript("await new Promise((loaded) => document.readyState === 'complete' ? loaded() : addEventListener('load', loaded))", contentWorld: .page)

        let site = URL(string: "https://example.com/")!
        _ = try? await tab.webView.callAsyncJavaScript("location.href = 'https://example.com/'", contentWorld: .page)
        #expect(try await waitForURL(site, in: tab) == site)
        #expect(tab.url == site)
    }

    @Test func aWebsiteCannotSendItsTabToAnExtensionsPage() async throws {
        let id = "hhiijjkkllmmnnooppaabbccddeeffgg"
        let browser = Browser()
        await browser.extensions.waitUntilLoaded()
        try await browser.extensions.install(archive: try archive(Self.pageFiles), id: id)
        defer { Task { await browser.extensions.remove(id: id) } }
        let tab = browser.newTab()
        let site = URL(string: "https://example.com/")!
        tab.webView.loadHTMLString("<!doctype html><title>Page</title>", baseURL: site)
        #expect(try await waitForURL(site, in: tab) == site)

        _ = try? await tab.webView.callAsyncJavaScript("location.href = 'webkit-extension://\(id)/page.html'", contentWorld: .page)
        try await Task.sleep(for: .seconds(2))
        let title = try? await tab.webView.callAsyncJavaScript("return document.title", contentWorld: .page) as? String
        // WebKit refuses it, and Lithium says so.
        #expect(title != nil && title != "Extension page")
    }

    /// And sends a tab on the web to one of its pages (`tabs.update`), as 1Password's does once
    /// its sign-in page is done.
    @Test func anExtensionCanSendAWebsitesTabToItsPage() async throws {
        let id = "gghhiijjkkllmmnnooppaabbccddeeff"
        let browser = Browser()
        await browser.extensions.waitUntilLoaded()
        try await browser.extensions.install(archive: try archive(Self.pageFiles), id: id)
        defer { Task { await browser.extensions.remove(id: id) } }
        let context = try #require(browser.extensions.contexts[id])
        let tab = browser.newTab()
        let site = URL(string: "https://example.com/")!
        tab.webView.loadHTMLString("<!doctype html><title>Page</title>", baseURL: site)
        #expect(try await waitForURL(site, in: tab) == site)

        let page = URL(string: "webkit-extension://\(id)/page.html")!
        try await tab.loadURL(page, for: context)
        #expect(try await waitForURL(page, in: tab) == page)
        var title: String?
        for _ in 0..<50 where title != "Extension page" {
            title = try? await tab.webView.callAsyncJavaScript("return document.title", contentWorld: .page) as? String
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(title == "Extension page")
    }
}

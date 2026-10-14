import AppKit
import Foundation
import Testing
import WebKit
@testable import Lithium

/// What a page may do on its own, without the user: open other apps, open tabs, hold up the app
/// with a dialog. Keeps its data in the home folder, like `BrowserTests`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct PageSecurityTests {
    /// Without it App Transport Security stops every `http://` page before it loads, even one whose
    /// server sends it on to https. The app's own connections (filter lists, updates) stay held to
    /// it. Read from the file `build-app.sh` copies: a test's `Bundle.main` is the test runner's.
    @Test func webContentMayLoadOverPlainHTTP() throws {
        let file = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Support/Info.plist").standardized
        let plist = try #require(NSDictionary(contentsOf: file) as? [String: Any])
        let ats = try #require(plist["NSAppTransportSecurity"] as? [String: Bool])
        #expect(ats == ["NSAllowsArbitraryLoadsInWebContent": true])
    }

    /// A script's `click()` on a `mailto:` link hands nothing to another app, and asks nothing.
    @Test func aScriptsClickOpensNoOtherApp() async throws {
        let (listener, base) = try await LocalHTTP.serve([
            "/": ("Content-Type: text/html", """
                <a id="mail" href="mailto:script-click@example.com">Write</a>
                <script>addEventListener('load', () => { document.getElementById('mail').click(); document.title = 'Clicked'; });</script>
                """),
        ])
        defer { listener.cancel() }
        let browser = Browser()
        let tab = browser.newTab(url: base)
        #expect(await waitUntil(30) { tab.webView.title == "Clicked" })
        try await Task.sleep(for: .seconds(1))
        #expect(!ExternalApps.recorded.contains(.open(URL(string: "mailto:script-click@example.com")!)))
    }

    /// A script's ⇧⌘-click (an untrusted `MouseEvent` with `metaKey`) opens no tab of Lithium's,
    /// which the popup blocker wouldn't see: the link is followed in place, as WebKit does.
    @Test func aScriptsCommandClickFollowsTheLinkInPlace() async throws {
        let (listener, base) = try await LocalHTTP.serve([
            "/": ("Content-Type: text/html", """
                <a id="next" href="/next">Next</a>
                <script>addEventListener('load', () => document.getElementById('next').dispatchEvent(
                  new MouseEvent('click', { bubbles: true, cancelable: true, metaKey: true, shiftKey: true })));</script>
                """),
            "/next": ("Content-Type: text/html", "<title>Next</title>"),
        ])
        defer { listener.cancel() }
        let browser = Browser()
        let tab = browser.newTab(url: base)
        let tabs = browser.tabs.count
        #expect(await waitUntil(30) { tab.webView.title == "Next" })
        #expect(browser.tabs.count == tabs)
        #expect(browser.commandWindow.selectedTabID == tab.id)
    }

    /// A tab out of sight never puts up an app-modal alert: its dialog waits for the tab to be
    /// shown, one more meanwhile gets the default answer, and closing the tab answers the waiting
    /// one with its default.
    @Test func aHiddenTabsDialogWaitsUntilTheTabIsShown() async throws {
        let browser = Browser()
        browser.newTab(url: URL(string: "data:text/html,<title>Front</title>")!)
        let tab = browser.newTab(url: URL(string: "data:text/html,<title>Back</title>")!, selecting: false)
        let webView = tab.webView
        #expect(await waitUntil(30) { webView.title == "Back" && !webView.isLoading })
        let ask = "setTimeout(() => { document.title = 'Answered ' + confirm('Sure?'); }); 0"
        _ = try await webView.evaluateJavaScript(ask)
        #expect(await waitUntil(10) { tab.hasHiddenDialog })
        #expect(webView.title == "Back")

        #expect(await tab.present(NSAlert()) == nil)
        #expect(tab.hasHiddenDialog)

        // Shown as `PageContainer` would, off screen: the waiting dialog comes up on its window.
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        #expect(await waitUntil(10) { window.attachedSheet != nil })
        #expect(!tab.hasHiddenDialog)
        let sheet = try #require(window.attachedSheet)
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        #expect(await waitUntil(10) { webView.title == "Answered true" })

        // Out of sight again, then closed.
        window.contentView = nil
        _ = try await webView.evaluateJavaScript(ask)
        #expect(await waitUntil(10) { tab.hasHiddenDialog })
        browser.close(tab)
        #expect(!tab.hasHiddenDialog)
        #expect(await waitUntil(10) { webView.title == "Answered false" })
    }

    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

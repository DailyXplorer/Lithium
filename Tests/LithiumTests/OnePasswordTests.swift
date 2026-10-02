import AppKit
import Foundation
import Testing
import WebKit
@testable import Lithium

/// 1Password, as installed from the Chrome Web Store, loaded the way Lithium loads it, on a
/// sign-in page. Its files are not Lithium's to ship: the test runs a copy of an installed one,
/// `LITHIUM_1PASSWORD_DIR="$HOME/Library/Application Support/Lithium/Extensions/<id>" scripts/test --filter OnePasswordTests`.
@MainActor
@Suite(.serialized, .enabled(
    if: ProcessInfo.processInfo.environment["LITHIUM_1PASSWORD_DIR"] != nil && ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil,
    "needs an installed 1Password in LITHIUM_1PASSWORD_DIR, and a throwaway home folder (scripts/test)"
))
struct OnePasswordTests {
    private static let login = """
        <!doctype html><html><head><title>Sign in</title></head><body>
        <form><input type=email autocomplete=username id=username><input type=password autocomplete=current-password id=password><button>Sign in</button></form>
        </body></html>
        """
    /// Added to the copy: asks the background what 1Password's content scripts ask first, and
    /// puts the answer in the page. Its inline menu waits for that answer; while the background
    /// isn't running it never comes. Asked again until it is ready.
    private static let probe = """
        const ask = () => chrome.runtime.sendMessage({ name: 'get-frame-manager-configuration' }, {}, (reply) => {
            document.documentElement.setAttribute('data-lithium-probe', JSON.stringify(reply ?? { error: chrome.runtime.lastError?.message ?? 'no reply' }));
            if (reply?.type !== 'Success') setTimeout(ask, 500);
        });
        ask();
        """

    /// Signed out, as the copy is, 1Password draws nothing in pages (`inlineDisabled`): its
    /// inline menu is checked only when the copy has an account.
    @Test func answersItsContentScriptsOnASignInPage() async throws {
        let source = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LITHIUM_1PASSWORD_DIR"]))
        let id = source.lastPathComponent
        let folder = URL.applicationSupportDirectory.appending(path: "Lithium/Extensions")
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appending(path: id)
        try FileManager.default.copyItem(at: source, to: copy)
        try addProbe(to: copy)
        try JSONEncoder().encode([InstalledExtension(id: id, name: "1Password", version: "", isEnabled: true)])
            .write(to: folder.appending(path: "installed.json"))

        let browser = Browser()
        await browser.extensions.waitUntilLoaded()
        #expect(browser.extensions.contexts[id] != nil)
        let tab = browser.newTab()
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.webView
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        tab.webView.loadHTMLString(Self.login, baseURL: URL(string: "https://login.example.com/")!)

        var state: [String: Any] = [:]
        var configuration: [String: Any] = [:]
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            _ = try? await tab.webView.callAsyncJavaScript("document.getElementById('username')?.focus()", contentWorld: .page)
            state = (try? await tab.webView.callAsyncJavaScript(Self.read, contentWorld: .page)) as? [String: Any] ?? [:]
            let reply = (state["probe"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            if reply?["type"] as? String == "Success" {
                configuration = reply?["data"] as? [String: Any] ?? [:]
                if configuration["inlineDisabled"] as? Bool == true || (state["inline"] as? [String])?.isEmpty == false { break }
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        #expect(state["mainWorld"] as? Bool == true, "1Password's MAIN world content script ran")
        #expect(configuration["tabId"] as? Int != nil, "1Password's background answered its content script: \(state["probe"] ?? "nothing")")
        #expect(configuration["locked"] as? Bool == true)
        if configuration["inlineDisabled"] as? Bool == false {
            #expect((state["inline"] as? [String])?.isEmpty == false, "1Password's inline menu is in the page")
        }
    }

    private static let read = """
        return {
            probe: document.documentElement.getAttribute('data-lithium-probe'),
            inline: [...document.querySelectorAll('*')].map((e) => e.localName).filter((name) => name.startsWith('com-1password')),
            mainWorld: !String(navigator.credentials?.get).includes('[native code]'),
        };
        """

    private func addProbe(to copy: URL) throws {
        try Data(Self.probe.utf8).write(to: copy.appending(path: "lithium-probe.js"))
        let file = copy.appending(path: "manifest.json")
        var manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file), options: .json5Allowed) as? [String: Any])
        let scripts = manifest["content_scripts"] as? [[String: Any]] ?? []
        manifest["content_scripts"] = scripts + [["matches": ["https://login.example.com/*"], "js": ["lithium-probe.js"], "run_at": "document_idle"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: file)
    }
}

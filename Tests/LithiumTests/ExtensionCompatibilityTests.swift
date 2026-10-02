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
        "content.js": """
            chrome.runtime.sendMessage('ping', {}, (reply) => document.documentElement.setAttribute('data-reply', reply ?? chrome.runtime.lastError?.message ?? 'nothing'));
            """,
    ]

    private func archive() throws -> Data {
        let source = FileManager.default.temporaryDirectory.appending(path: "extension-\(UUID())")
        let zip = FileManager.default.temporaryDirectory.appending(path: "extension-\(UUID()).zip")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: zip)
        }
        for (path, text) in Self.files {
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
            if reply != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(reply == "pong {}")
    }
}

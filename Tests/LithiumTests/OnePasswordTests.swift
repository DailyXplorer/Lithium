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
        let (browser, tab, window) = try await open1Password()
        defer { withExtendedLifetime(browser) { window.orderOut(nil) } }

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

    /// Added to the copy's background: keeps the popup 1Password sets when it has an account,
    /// which the copy lacks, and notes how each `action.openPopup()` ends.
    private static let backgroundProbe = """
        const opened = [];
        // WebKit makes a namespace's object again once nothing holds it, without what was added to it.
        globalThis.lithiumProbe = [...new Set([globalThis.browser.action, globalThis.chrome.action])];
        for (const action of globalThis.lithiumProbe) {
            const setPopup = action.setPopup.bind(action);
            const openPopup = action.openPopup.bind(action);
            action.setPopup = (details) => setPopup({ ...details, popup: '/popup/index.html' });
            action.openPopup = (...args) => {
                const result = openPopup(...args);
                result.then(() => 'opened', (error) => error.message).then((outcome) => chrome.storage.local.set({ lithiumOpened: [...opened, outcome] }, () => opened.push(outcome)));
                return result;
            };
        }
        """
    /// What 1Password's Unlock button sends, clicked twice.
    private static let unlockProbe = """
        const send = (message) => new Promise((resolve) => chrome.runtime.sendMessage(message, {}, resolve));
        const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
        (async () => {
            while ((await send({ name: 'get-frame-manager-configuration' }))?.type !== 'Success') await wait(500);
            const replies = [];
            for (let click = 0; click < 2; click++) {
                replies.push((await send({ name: 'request-managed-unlock' }))?.type ?? chrome.runtime.lastError?.message);
                await wait(1500);
            }
            const { lithiumOpened } = await chrome.storage.local.get('lithiumOpened');
            document.documentElement.setAttribute('data-lithium-unlock', JSON.stringify({ replies, opened: lithiumOpened ?? [] }));
        })();
        """

    /// Locked, its Unlock button asks the background to open its popup; WebKit refused every
    /// time after the first, which Lithium hadn't shown nor closed.
    @Test func itsUnlockButtonOpensThePopupEveryTime() async throws {
        let (browser, tab, window) = try await open1Password(probe: Self.unlockProbe, backgroundProbe: Self.backgroundProbe)
        defer { withExtendedLifetime(browser) { window.orderOut(nil) } }

        var result: [String: Any] = [:]
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, result.isEmpty {
            let text = try? await tab.webView.callAsyncJavaScript("return document.documentElement.getAttribute('data-lithium-unlock')", contentWorld: .page) as? String
            result = text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
            try await Task.sleep(for: .milliseconds(500))
        }
        #expect(result["replies"] as? [String] == ["Success", "Success"])
        // Once or twice a click, depending on what the copy ran before.
        let opened = result["opened"] as? [String] ?? []
        #expect(opened.count >= 2 && Set(opened) == ["opened"], "\(opened)")
    }

    /// Added to the copy's setup page, before 1Password's script: notes what goes wrong in it.
    private static let errorRecorder = """
        window.lithiumErrors = [];
        addEventListener('error', (event) => lithiumErrors.push(event.message));
        addEventListener('unhandledrejection', (event) => lithiumErrors.push(String(event.reason?.stack ?? event.reason)));
        const error = console.error.bind(console);
        console.error = (...args) => { lithiumErrors.push(args.join(' ')); error(...args); };
        """

    /// Signed out, 1Password opens its setup page in a tab. Its buttons send that tab to its pages
    /// on the web, which WebKit dropped: they did nothing. Both in one Browser: in a Browser of
    /// its own, after the Unlock test, the second one's page showed "Something went wrong".
    @Test func itsSetupPageButtonsOpenItsPagesOnTheWeb() async throws {
        var (browser, tab, window) = try await open1Password(onSetupPage: true)
        defer { withExtendedLifetime(browser) { window.orderOut(nil) } }

        // Its first screen's Continue, shown until it has been clicked once, leads to the Add account card.
        let click = """
            const find = (label) => [...document.querySelectorAll('button')].find((b) => b.innerText.trim() === label);
            const button = find(label);
            if (!button) { find('Continue')?.click(); return null; }
            const errors = [...window.lithiumErrors];
            button.click();
            return errors;
            """
        let setup = try #require(tab.url)
        for (button, address) in [("Sign in", "https://start.1password.com/signin/?auth-only=1"), ("Create your 1Password account", "https://1password.com/pricing")] {
            if tab.url != setup {
                tab = browser.newTab(url: setup, configuration: browser.extensions.configuration(for: setup))
                window.contentView = tab.webView
            }
            var errors: [String]?
            for _ in 0..<60 where errors == nil {
                errors = try? await tab.webView.callAsyncJavaScript(click, arguments: ["label": button], contentWorld: .page) as? [String]
                if errors == nil { try await Task.sleep(for: .milliseconds(500)) }
            }
            let shown = try? await tab.webView.callAsyncJavaScript("return `${location.href} ${document.body.innerText}`", contentWorld: .page) as? String
            #expect(errors == [], "\(button) is on the page, with nothing gone wrong: \(shown ?? "nil")")
            for _ in 0..<50 where tab.url?.absoluteString != address {
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(tab.url?.absoluteString == address)
            #expect(tab.webView.url?.absoluteString == address)
        }
    }

    private static let read = """
        return {
            probe: document.documentElement.getAttribute('data-lithium-probe'),
            inline: [...document.querySelectorAll('*')].map((e) => e.localName).filter((name) => name.startsWith('com-1password')),
            mainWorld: !String(navigator.credentials?.get).includes('[native code]'),
        };
        """

    /// Runs a copy of the installed 1Password, with the probes added, on the sign-in page or on
    /// the setup page it opens when signed out.
    private func open1Password(probe: String = Self.probe, backgroundProbe: String? = nil, onSetupPage: Bool = false) async throws -> (Browser, Tab, NSWindow) {
        let source = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LITHIUM_1PASSWORD_DIR"]))
        let id = source.lastPathComponent
        let folder = URL.applicationSupportDirectory.appending(path: "Lithium/Extensions")
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appending(path: id)
        try FileManager.default.copyItem(at: source, to: copy)
        try addProbes(probe, backgroundProbe, to: copy)
        let setupPage = copy.appending(path: "app/app.html")
        try Data(Self.errorRecorder.utf8).write(to: copy.appending(path: "lithium-errors.js"))
        try (try String(contentsOf: setupPage, encoding: .utf8)).replacingOccurrences(of: "<script defer", with: "<script src=\"/lithium-errors.js\"></script><script defer")
            .write(to: setupPage, atomically: true, encoding: .utf8)
        try JSONEncoder().encode([InstalledExtension(id: id, name: "1Password", version: "", isEnabled: true)])
            .write(to: folder.appending(path: "installed.json"))

        let browser = Browser()
        await browser.extensions.waitUntilLoaded()
        #expect(browser.extensions.contexts[id] != nil)
        // As 1Password's background opens it (`tabs.create`).
        let setup = URL(string: "\(Extensions.scheme)://\(id)/app/app.html#/page/welcome?language=en")!
        let tab = onSetupPage ? browser.newTab(url: setup, configuration: browser.extensions.configuration(for: setup)) : browser.newTab()
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.webView
        window.orderFrontRegardless()
        if !onSetupPage { tab.webView.loadHTMLString(Self.login, baseURL: URL(string: "https://login.example.com/")!) }
        return (browser, tab, window)
    }

    private func addProbes(_ probe: String, _ backgroundProbe: String?, to copy: URL) throws {
        try Data(probe.utf8).write(to: copy.appending(path: "lithium-probe.js"))
        try ExtensionCompatibility.apply(to: copy)
        let file = copy.appending(path: "manifest.json")
        var manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file), options: .json5Allowed) as? [String: Any])
        if let backgroundProbe {
            // Run after Lithium's compatibility script, before 1Password's background.
            let worker = copy.appending(path: try #require((manifest["background"] as? [String: Any])?["service_worker"] as? String))
            try Data(backgroundProbe.utf8).write(to: copy.appending(path: "lithium-background-probe.js"))
            let load = try String(contentsOf: worker, encoding: .utf8)
            try load.replacingOccurrences(of: "\";\n", with: "\";\nimport \"/lithium-background-probe.js\";\n", options: [], range: load.range(of: "\";\n"))
                .write(to: worker, atomically: true, encoding: .utf8)
        }
        let scripts = manifest["content_scripts"] as? [[String: Any]] ?? []
        manifest["content_scripts"] = scripts + [["matches": ["https://login.example.com/*"], "js": ["lithium-probe.js"], "run_at": "document_idle"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: file)
    }
}

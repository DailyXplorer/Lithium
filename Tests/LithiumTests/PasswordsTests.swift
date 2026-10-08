import AppKit
import Foundation
import Testing
import WebKit
@testable import Lithium

/// The hand-off to Apple's Passwords app: a field's menu, the store's iCloud Passwords and
/// Settings › Passwords. The app's place and its opening are the test's own; nothing opens.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PasswordsTests {
    private static let app = URL(filePath: "/System/Applications/Passwords.app")

    /// Runs `body` with a Passwords app at `app` (none when nil), noting what would open.
    private func withPasswords(at app: URL? = Self.app, _ body: @MainActor (Opened) async throws -> Void) async throws {
        let (appURL, openApp) = (Passwords.appURL, Passwords.openApp)
        let opened = Opened()
        Passwords.appURL = { app }
        Passwords.openApp = { opened.urls.append($0) }
        defer { (Passwords.appURL, Passwords.openApp) = (appURL, openApp) }
        try await body(opened)
    }

    private final class Opened {
        var urls: [URL] = []
    }

    /// WebKit's menu, which has Paste only in an editable field, as `willOpenMenu` gets it.
    private func menu(withPaste: Bool) throws -> NSMenu {
        let webView = PageWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let menu = NSMenu()
        for identifier in withPaste ? ["Cut", "Copy", "Paste"] : ["Copy"] {
            let item = NSMenuItem(title: identifier, action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifier" + identifier)
            menu.addItem(item)
        }
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: NSPoint(x: 20, y: 20), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        webView.willOpenMenu(menu, with: event)
        return menu
    }

    @Test func aFieldsMenuOpensPasswordsAfterForcePaste() async throws {
        try await withPasswords { opened in
            let plain = try menu(withPaste: false)
            #expect(plain.items.map(\.title) == ["Copy"])
            let editable = try menu(withPaste: true)
            #expect(editable.items.map(\.title) == ["Cut", "Copy", "Paste", PageOverrides.forcePasteTitle, Passwords.menuTitle])
            #expect(opened.urls.isEmpty, "nothing opens until the item is chosen")

            let item = try #require(editable.items.last)
            let action = try #require(item.action)
            #expect(NSApp.sendAction(action, to: item.target, from: item))
            #expect(opened.urls == [Self.app])
        }
    }

    @Test func noPasswordsAppNoMenuItem() async throws {
        try await withPasswords(at: nil) { opened in
            let titles = try menu(withPaste: true).items.map(\.title)
            #expect(titles == ["Cut", "Copy", "Paste", PageOverrides.forcePasteTitle])
            #expect(!Passwords.open())
            #expect(opened.urls.isEmpty)
        }
    }

    /// The store's Add to Chrome on iCloud Passwords adds nothing: Lithium says why, and offers
    /// the Passwords app, which opens only if chosen.
    @Test func iCloudPasswordsIsNotAddedAndOffersTheApp() async throws {
        try await withPasswords { opened in
            let extensions = Extensions(folder: .temporaryDirectory.appending(path: "extensions-\(UUID())"), configuration: .nonPersistent())
            let bridge = extensions.webstoreBridge
            let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            for (button, opens) in [(NSApplication.ModalResponse.alertSecondButtonReturn, false), (.alertFirstButtonReturn, true)] {
                let begin = Task {
                    await bridge.answer("webstorePrivate.beginInstallWithManifest3", arguments: [[
                        "id": Passwords.iCloudExtensionID, "manifest": #"{"name":"iCloud Passwords","manifest_version":3,"permissions":["nativeMessaging"]}"#,
                    ]], window: window).value as? String
                }
                let deadline = Date().addingTimeInterval(10)
                while window.attachedSheet == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
                let sheet = try #require(window.attachedSheet)
                let texts = sheet.contentView.map { Self.texts(in: $0) } ?? []
                #expect(texts.contains("iCloud Passwords can’t work in Lithium"), "\(texts)")
                window.endSheet(sheet, returnCode: button)
                #expect(await begin.value == "user_cancelled")
                #expect(opened.urls == (opens ? [Self.app] : []))
            }
            let complete = await bridge.answer("webstorePrivate.completeInstall", arguments: [Passwords.iCloudExtensionID], window: window)
            #expect(complete.error?.hasSuffix("does not match a previous call to beginInstallWithManifest3") == true)
            #expect(extensions.installed.isEmpty)
        }
    }

    /// Settings › Passwords' button. A whole Browser keeps its data in the home folder, so this
    /// one only runs in a throwaway one (`scripts/test`).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
    func settingsOpensPasswords() async throws {
        try await withPasswords { opened in
            let browser = Browser()
            let configuration = WKWebViewConfiguration()
            InternalSchemeHandler.shared.install(on: configuration)
            configuration.userContentController.addScriptMessageHandler(browser.internalBridge, contentWorld: .page, name: InternalBridge.name)
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 640), configuration: configuration)
            let navigation = PageLoad()
            webView.navigationDelegate = navigation
            webView.load(URLRequest(url: URL(string: "lithium://settings#passwords")!))
            try await navigation.wait()
            let shown = try await webView.evaluateJavaScript("""
                document.querySelector('#passwords').classList.contains('active') && document.querySelector('nav a.active')?.textContent
                """) as? String
            #expect(shown == "Passwords")
            #expect(opened.urls.isEmpty)
            _ = try await webView.evaluateJavaScript("document.querySelector('#open-passwords').click(); 0")
            let deadline = Date().addingTimeInterval(10)
            while opened.urls.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(opened.urls == [Self.app])
        }
    }

    private static func texts(in view: NSView) -> [String] {
        ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap { texts(in: $0) }
    }
}

import AppKit
import SwiftUI
import Testing
@testable import Lithium

/// Return and Escape in the browser window: what they may answer or close. Windows sit far off
/// screen. Runs a whole Browser, so only in a throwaway home folder (see `BrowserTests`).
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct WindowKeysTests {
    /// Return typed for the page or the address bar must never grant a permission (and remember
    /// it); Escape dismisses the prompt as a deny that isn't remembered.
    @Test func returnNeverAnswersAPermissionPromptAndEscapeDeniesItOnce() async throws {
        let browser = Browser()
        let tab = browser.newTab(url: URL(string: "data:text/html,page")!)
        defer { browser.close(tab) }
        // Asked once the page is in: its commit drops the prompts of the page before.
        #expect(await waitUntil(60) { !tab.webView.isLoading && tab.webView.url != nil })
        let host = "camera.example"
        defer { browser.permissions.set(nil, for: .camera, host: host) }
        let asked = Task { await browser.permissions.request([.camera], host: host, tabID: tab.id) }
        #expect(await waitUntil(10) { browser.permissions.pending.contains { $0.tabID == tab.id } })
        let request = try #require(browser.permissions.pending.first { $0.tabID == tab.id })

        let view = NSHostingView(rootView: PermissionPrompt(request: request).environment(browser))
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 46), styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.contentView = view
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(300))
        #expect(!press("\r", keyCode: 36, in: view, window))
        #expect(!press("\u{1b}", keyCode: 53, in: view, window))
        try await Task.sleep(for: .milliseconds(100))
        #expect(browser.permissions.pending.contains { $0.id == request.id }, "no key answers the prompt")

        let dismissed = browser.dismissOverlay()
        #expect(dismissed)
        // Not dismissed, the request is only answered when the tab closes.
        if dismissed { #expect(await asked.value == false) }
        #expect(browser.permissions.pending.isEmpty)
        #expect(browser.permissions.decisions[host] == nil, "nothing is remembered")
        #expect(!browser.dismissOverlay())
    }

    /// Lithium's Escape is for its own window only, with nothing over it, and not for a text
    /// field being edited (the address bar), except the find field and a tab's name.
    @Test func escapeIsLithiumsOnlyInItsWindowAndNotForAFieldBeingEdited() async throws {
        let browser = Browser()
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
        window.contentView?.addSubview(field)
        window.orderFrontRegardless()

        #expect(!browser.ownsEscape(in: window), "not the browser's window yet")
        browser.window = window
        #expect(browser.ownsEscape(in: window))
        #expect(!browser.ownsEscape(in: nil))

        #expect(window.makeFirstResponder(field))
        #expect((window.firstResponder as? NSTextView)?.isFieldEditor == true)
        #expect(!browser.ownsEscape(in: window), "the field ends its editing itself")
        browser.find.isFieldFocused = true
        #expect(browser.ownsEscape(in: window), "Escape in the find field closes the bar")
        browser.find.isFieldFocused = false
        window.makeFirstResponder(nil)

        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.beginSheet(sheet, completionHandler: nil)
        #expect(await waitUntil(5) { window.attachedSheet != nil })
        #expect(!browser.ownsEscape(in: window), "the sheet's Cancel gets it")
        window.endSheet(sheet)
        #expect(await waitUntil(5) { window.attachedSheet == nil })
        #expect(browser.ownsEscape(in: window))
    }

    /// The window can't be key off screen, so the key goes straight to the shortcuts.
    private func press(_ characters: String, keyCode: UInt16, in view: NSView, _ window: NSWindow) -> Bool {
        view.performKeyEquivalent(with: NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        )!)
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

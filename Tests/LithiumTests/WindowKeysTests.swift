import AppKit
import SwiftUI
import Testing
@testable import Lithium

/// Return, Escape and ⌘W in the browser window: what they may answer or close. Windows sit far off
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

        let view = NSHostingView(rootView: PermissionPrompt(request: request).environment(browser).environment(browser.windows[0]))
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

    /// In split view the other side's prompt shows too (nothing else would until it was clicked),
    /// after the focused side's, and Escape dismisses the one shown.
    @Test func theOtherSplitSidesPromptShows() async throws {
        let browser = Browser()
        let first = browser.newTab(url: URL(string: "data:text/html,first")!)
        defer { browser.tabs.forEach(browser.close) }
        let second = browser.newTab(url: URL(string: "data:text/html,second")!, selecting: false)
        browser.openInSplit(second)
        let focused = try #require(browser.commandWindow.selectedTab)
        let other = try #require(browser.commandWindow.shownPartner)
        #expect(Set([focused.id, other.id]) == Set([first.id, second.id]))
        // Asked once the pages are in: a commit drops the prompts of the page before.
        #expect(await waitUntil(60) { [first, second].allSatisfy { !$0.webView.isLoading && $0.webView.url != nil } })
        #expect(browser.commandWindow.shownPermissionRequest == nil)

        let host = "camera.example"
        let otherAsked = Task { await browser.permissions.request([.camera], host: host, tabID: other.id) }
        #expect(await waitUntil(10) { browser.commandWindow.shownPermissionRequest?.tabID == other.id })
        let focusedAsked = Task { await browser.permissions.request([.microphone], host: host, tabID: focused.id) }
        #expect(await waitUntil(10) { browser.commandWindow.shownPermissionRequest?.tabID == focused.id }, "the focused side's first")

        #expect(browser.dismissOverlay())
        #expect(await focusedAsked.value == false)
        #expect(browser.commandWindow.shownPermissionRequest?.tabID == other.id)
        #expect(browser.dismissOverlay())
        #expect(await otherAsked.value == false)
        #expect(browser.permissions.pending.isEmpty)
        #expect(browser.permissions.decisions[host] == nil, "nothing is remembered")
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
        // Ordered front, the window gives its only field the keyboard.
        window.makeFirstResponder(nil)

        #expect(!browser.ownsEscape(in: window), "not the browser's window yet")
        browser.windows[0].nsWindow = window
        #expect(browser.ownsEscape(in: window))
        #expect(!browser.ownsEscape(in: nil))

        #expect(window.makeFirstResponder(field))
        #expect((window.firstResponder as? NSTextView)?.isFieldEditor == true)
        #expect(!browser.ownsEscape(in: window), "the field ends its editing itself")
        browser.commandWindow.find.isFieldFocused = true
        #expect(browser.ownsEscape(in: window), "Escape in the find field closes the bar")
        browser.commandWindow.find.isFieldFocused = false
        window.makeFirstResponder(nil)

        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.beginSheet(sheet, completionHandler: nil)
        #expect(await waitUntil(5) { window.attachedSheet != nil })
        #expect(!browser.ownsEscape(in: window), "the sheet's Cancel gets it")
        window.endSheet(sheet)
        #expect(await waitUntil(5) { window.attachedSheet == nil })
        #expect(browser.ownsEscape(in: window))
    }

    /// ⌘W closes the selected tab only from the browser's window; another window in front (a
    /// detached Web Inspector) closes itself and leaves the tab alone. The windows are never shown.
    @Test func closeTabActsOnlyInTheBrowsersWindow() {
        let browser = Browser()
        let tab = browser.newTab(url: URL(string: "data:text/html,kept")!)
        defer { browser.close(tab) }
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        browser.windows[0].nsWindow = window
        let inspector = ClosingWindow(contentRect: NSRect(x: -30000, y: -30000, width: 400, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        inspector.isReleasedWhenClosed = false

        browser.closeTabOrWindow(keyWindow: inspector)
        #expect(inspector.didClose, "the window in front closes")
        #expect(browser.commandWindow.selectedTab === tab, "the tab stays")

        browser.closeTabOrWindow(keyWindow: nil)
        #expect(browser.commandWindow.selectedTab === tab, "no window in front, nothing closes")

        let other = browser.newTab(url: URL(string: "data:text/html,closed")!)
        browser.closeTabOrWindow(keyWindow: window)
        #expect(!browser.tabs.contains { $0 === other })

        // A video in full screen: WebKit's window in front holds the page, and ⌘W closes the tab.
        let video = browser.newTab(url: URL(string: "data:text/html,video")!)
        let fullScreen = ClosingWindow(contentRect: NSRect(x: -30000, y: -30000, width: 400, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        fullScreen.isReleasedWhenClosed = false
        fullScreen.contentView?.addSubview(video.webView)
        browser.closeTabOrWindow(keyWindow: fullScreen)
        #expect(!fullScreen.didClose)
        #expect(!browser.tabs.contains { $0 === video }, "the tab closes")
    }

    /// Closing the find bar with Escape, or ending a tab's rename with Return or Escape, gives the
    /// keyboard back to the page instead of leaving it on the window, where keys beep.
    @Test func closingTheFindBarOrARenameGivesThePageTheKeyboard() async throws {
        let (browser, tab, window) = try await shownBrowser()
        defer { window.orderOut(nil) }

        browser.commandWindow.find.show()
        #expect(await waitUntil(5) { browser.commandWindow.find.isFieldFocused })
        #expect(browser.dismissOverlay())
        #expect(window.firstResponder === tab.contentView, "\(String(describing: window.firstResponder))")
        // The bar clears its field's flag as it leaves, which its slide-out can delay under load;
        // until then an Escape in the name field reads as the find field's and keeps the keyboard.
        #expect(await waitUntil(5) { !browser.commandWindow.find.isFieldFocused })

        browser.commandWindow.renamingTabID = tab.id
        let editor = try #require(await nameEditor(in: window))
        editor.insertText("Notes", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        editor.insertNewline(nil)
        #expect(await waitUntil(5) { browser.commandWindow.renamingTabID == nil })
        #expect(tab.customTitle == "Notes")
        #expect(await waitUntil(5) { window.firstResponder === tab.contentView }, "\(String(describing: window.firstResponder))")

        browser.commandWindow.renamingTabID = tab.id
        _ = try #require(await nameEditor(in: window))
        #expect(browser.dismissOverlay())
        #expect(tab.customTitle == "Notes", "Escape keeps the old name")
        #expect(window.firstResponder === tab.contentView, "\(String(describing: window.firstResponder))")

        // Each field takes the keyboard again the next time, as the user starts it.
        try await Task.sleep(for: .milliseconds(200))
        browser.commandWindow.renamingTabID = tab.id
        #expect(await nameEditor(in: window) != nil)
        #expect(browser.dismissOverlay())
        browser.commandWindow.find.show()
        #expect(await waitUntil(5) { browser.commandWindow.find.isFieldFocused })
        #expect(browser.dismissOverlay())
    }

    /// With the find bar open but the page holding the keyboard, Escape is the page's (its menu,
    /// its dialog) and the bar stays; from the find field it closes the bar.
    @Test func escapeInThePageLeavesTheFindBarOpen() async throws {
        let (browser, tab, window) = try await shownBrowser()
        defer { window.orderOut(nil) }

        browser.commandWindow.find.show()
        #expect(await waitUntil(5) { browser.commandWindow.find.isFieldFocused })
        #expect(window.makeFirstResponder(tab.webView))
        #expect(!browser.dismissOverlay(), "the page gets the Escape")
        #expect(browser.commandWindow.find.isVisible)

        window.makeFirstResponder(nil)
        #expect(browser.dismissOverlay())
        #expect(!browser.commandWindow.find.isVisible)
    }

    /// Hiding the sidebar (⌘B) during a rename ends it with the name typed, so it doesn't go on
    /// holding Escape, the agent's input and the sidebar's peek.
    @Test func hidingTheSidebarEndsARename() async throws {
        let (browser, tab, window) = try await shownBrowser()
        defer { window.orderOut(nil) }
        browser.commandWindow.renamingTabID = tab.id
        let editor = try #require(await nameEditor(in: window))
        editor.insertText("Docs", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))

        browser.commandWindow.toggleSidebar()
        defer { browser.commandWindow.toggleSidebar() }
        #expect(await waitUntil(5) { browser.commandWindow.renamingTabID == nil })
        #expect(tab.customTitle == "Docs")
    }

    /// A name typed in the peeked sidebar is still there when ⌘B shows the sidebar, whose own
    /// field takes the rename over.
    @Test func showingTheSidebarKeepsANameTypedInThePeek() async throws {
        let (browser, tab, window) = try await shownBrowser()
        defer { window.orderOut(nil) }
        browser.commandWindow.toggleSidebar()
        defer { if !browser.commandWindow.isSidebarVisible { browser.commandWindow.toggleSidebar() } }
        try await Task.sleep(for: .milliseconds(300))
        browser.commandWindow.renamingTabID = tab.id
        let editor = try #require(await nameEditor(in: window))
        editor.insertText("Docs", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))

        browser.commandWindow.toggleSidebar()
        try await Task.sleep(for: .milliseconds(800))
        if browser.commandWindow.renamingTabID == tab.id {
            let field = try #require(await nameEditor(in: window))
            #expect(field.string == "Docs")
            browser.commandWindow.renamingTabID = nil
        } else {
            #expect(tab.customTitle == "Docs")
        }
    }

    /// A row being renamed that only scrolls out of the sidebar's lazy list keeps its rename.
    @Test func scrollingARenamedRowAwayKeepsTheRename() async throws {
        let (browser, _, window) = try await shownBrowser()
        defer { window.orderOut(nil) }
        let others = (1...50).map { browser.newTab(url: URL(string: "data:text/html,\($0)")!, selecting: false) }
        defer { others.forEach { browser.close($0) } }
        let first = try #require(browser.commandWindow.tabListEntries.first?.tab)
        browser.commandWindow.renamingTabID = first.id
        #expect(await nameEditor(in: window) != nil)

        // The tab list is the only scroll view taller than the window.
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        let content = try #require(window.contentView)
        let list = try #require(scrollViews(in: content).first {
            ($0.documentView?.frame.height ?? 0) > window.frame.height
        })
        let bottom = (list.documentView?.frame.height ?? 0) - list.contentView.bounds.height
        list.contentView.scroll(to: NSPoint(x: 0, y: list.documentView?.isFlipped == true ? bottom : 0))
        list.reflectScrolledClipView(list.contentView)
        try await Task.sleep(for: .milliseconds(500))

        #expect(browser.commandWindow.renamingTabID == first.id, "the rename goes on")
        #expect(first.customTitle == nil)
        browser.commandWindow.renamingTabID = nil
    }

    /// A tab picked with the keyboard while the address bar edits ends the edit: Return then
    /// can't send the text to the tab left and bring it back.
    @Test func pickingAnotherTabEndsAddressEditing() async throws {
        let (browser, first, window) = try await shownBrowser()
        defer { window.orderOut(nil) }
        let second = browser.newTab(url: URL(string: "data:text/html,second")!, selecting: false)
        defer { browser.close(second) }
        let page = first.url

        browser.commandWindow.requestAddressFocus()
        func editor() -> NSTextView? {
            (window.firstResponder as? NSTextView).flatMap { $0.delegate is URLTextField ? $0 : nil }
        }
        #expect(await waitUntil(5) { editor() != nil })
        editor()?.insertText("example.invalid", replacementRange: NSRange(location: NSNotFound, length: 0))

        browser.select(second)
        #expect(await waitUntil(5) { editor() == nil }, "the edit ends")
        #expect(await waitUntil(5) { window.firstResponder === second.contentView }, "\(String(describing: window.firstResponder))")
        #expect(browser.commandWindow.selectedTabID == second.id)
        #expect(first.url == page, "the tab left is untouched")
    }

    /// ⌘T and ⌘L from a link's window bring the main window forward, whose field gets the keys.
    /// The window is never shown.
    @Test func newTabAndOpenLocationBringTheMainWindowForward() {
        let browser = Browser()
        let tab = browser.newTab(url: URL(string: "data:text/html,page")!)
        defer { browser.close(tab) }
        let window = FrontingWindow(contentRect: NSRect(x: -30000, y: -30000, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
        browser.windows[0].nsWindow = window
        defer { browser.windows[0].nsWindow = nil }

        let token = browser.commandWindow.addressFocusToken
        browser.commandWindow.focusAddressFromMenu(newTab: false)
        #expect(window.frontings == 1)
        #expect(browser.commandWindow.addressFocusToken != token)
        #expect(browser.commandWindow.selectedTab === tab, "Open Location keeps the tab")

        browser.commandWindow.focusAddressFromMenu(newTab: true)
        #expect(window.frontings == 2)
        #expect(browser.commandWindow.selectedTabID == nil, "New Tab shows the start page")
    }

    /// ⌘= zooms in like Zoom In's ⌘+; the shifted key, which types "+", is left to the menu.
    @Test func commandEqualsZoomsIn() throws {
        func key(_ characters: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                          characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 24))
        }
        #expect(Browser.isZoomInWithoutShift(try key("=", .command)))
        #expect(!Browser.isZoomInWithoutShift(try key("+", [.command, .shift])))
        #expect(!Browser.isZoomInWithoutShift(try key("=", [])))
        #expect(!Browser.isZoomInWithoutShift(try key("=", [.command, .option])))

        let browser = Browser()
        let tab = browser.newTab(url: URL(string: "data:text/html,page")!)
        defer { browser.close(tab) }
        browser.zoomSelectedTab(by: PageZoom.step)
        #expect(tab.webView.pageZoom == 1.1)
    }

    /// The whole window, far off screen, showing one loaded tab, with the sidebar and no Zen mode:
    /// the session an earlier test's browser saves a moment after its last change may still be
    /// landing as this one reads it.
    private func shownBrowser() async throws -> (Browser, Lithium.Tab, NSWindow) {
        let browser = Browser()
        let first = browser.commandWindow
        if first.isZenMode { first.toggleZenMode() }
        if !first.isSidebarVisible { first.toggleSidebar() }
        let tab = browser.newTab(url: URL(string: "data:text/html,page")!)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1280, height: 820),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: BrowserView().environment(browser).environment(first))
        // What `BrowserNSWindow` tells the model as it opens.
        first.nsWindow = window
        window.orderFrontRegardless()
        #expect(await waitUntil(60) { !tab.webView.isLoading && tab.webView.url != nil && tab.webView.window === window })
        try await Task.sleep(for: .milliseconds(300))
        return (browser, tab, window)
    }

    /// The tab name field's editor, once it has the keyboard.
    private func nameEditor(in window: NSWindow) async -> NSTextView? {
        func editor() -> NSTextView? {
            (window.firstResponder as? NSTextView).flatMap { $0.isFieldEditor && !($0.delegate is URLTextField) ? $0 : nil }
        }
        _ = await waitUntil(5) { editor() != nil }
        return editor()
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

/// Tells whether it was closed, though never shown.
private final class ClosingWindow: NSWindow {
    private(set) var didClose = false

    override func close() {
        didClose = true
        super.close()
    }
}

/// Counts the requests to come forward and stays off screen.
private final class FrontingWindow: NSWindow {
    private(set) var frontings = 0

    override func makeKeyAndOrderFront(_ sender: Any?) {
        frontings += 1
    }
}

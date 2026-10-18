import SwiftUI
import WebKit

@main
struct LithiumApp: App {
    /// SwiftUI may build the App value more than once; the browser must exist exactly once.
    @MainActor static let sharedBrowser: Browser = {
        Theme.registerFonts()
        Keychain.atLaunch()
        return Browser()
    }()

    private let browser = LithiumApp.sharedBrowser
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// The browser windows are `BrowserNSWindow`s the browser opens itself (`Browser.openWindow`),
    /// so the one scene only carries the menu. A Settings scene opens no window at launch, leaves
    /// nothing for a saved window state to restore into, and keeps SwiftUI's standard menus; its
    /// own Settings item is the one `BrowserCommands` replaces.
    var body: some Scene {
        Settings { EmptyView() }
            .commands { BrowserCommands(browser: browser) }
    }
}

/// The windows at launch, the Dock menu and the links other apps send, which SwiftUI has no scene
/// for, a question before quitting stops downloads, and the session's last save as the app quits.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var quitReplied = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        LithiumApp.sharedBrowser.showRestoredWindows()
    }

    /// The Dock icon clicked: `Browser.reopenFromDock` decides, `hasVisibleWindows` aside.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        LithiumApp.sharedBrowser.reopenFromDock()
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(LithiumApp.sharedBrowser.openFromOtherApp)
    }

    /// The session cookies are read from WebKit's network process, asynchronously: the quit waits
    /// for them, but no more than two seconds, so a stuck process can't keep Lithium open.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reply = Downloads.shared.shouldTerminate()
        guard reply == .terminateNow else { return reply }
        quitReplied = false
        Task {
            // A Save or Import just before ⌘Q is still being written.
            await LithiumApp.sharedBrowser.passwords.finishSaving()
            await LithiumApp.sharedBrowser.saveSessionCookies()
            replyToQuit(sender)
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            if !quitReplied { LithiumApp.sharedBrowser.cookieSaveCutShort() }
            replyToQuit(sender)
        }
        return .terminateLater
    }

    private func replyToQuit(_ sender: NSApplication) {
        guard !quitReplied else { return }
        quitReplied = true
        sender.reply(toApplicationShouldTerminate: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        LithiumApp.sharedBrowser.saveNow()
        LithiumApp.sharedBrowser.history.close()
    }

    /// Built at each click on the Dock icon: Stop Agent shows only while an agent listens.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "New Window", action: #selector(newWindow), keyEquivalent: "").target = self
        if LithiumApp.sharedBrowser.agent?.state == .listening {
            menu.addItem(withTitle: "Stop Agent", action: #selector(stopAgent), keyEquivalent: "").target = self
        }
        return menu
    }

    /// A Dock menu item doesn't bring Lithium forward: chosen while another app is in front, the
    /// new window would open behind it.
    @objc private func newWindow() {
        NSApp.activate()
        LithiumApp.sharedBrowser.openWindow()
    }

    @objc private func stopAgent() {
        LithiumApp.sharedBrowser.agent?.stop()
    }
}

/// The menu reads `browser`: the page commands act on `commandTab`, the tab-list ones on
/// `commandWindow`, the browser window in front.
struct BrowserCommands: Commands {
    let browser: Browser

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { browser.inBrowserWindow { browser.openSettings(in: $0) } }
                .keyboardShortcut(",")
        }
        CommandGroup(after: .appSettings) {
            Button("Stop Agent") { browser.agent?.stop() }
                .keyboardShortcut(".", modifiers: [.control, .command])
                .disabled(browser.agent?.state != .listening)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Window") { browser.openWindow() }
                .keyboardShortcut("n")
            Button("New Tab") { browser.inBrowserWindow { $0.focusAddressFromMenu(newTab: true) } }
                .keyboardShortcut("t")
            Button("Open Location…") { browser.inBrowserWindow { $0.focusAddressFromMenu(newTab: false) } }
                .keyboardShortcut("l")
            Button("Move to Window") {
                if let tab = browser.quickLinks.keyTab { browser.quickLinks.moveToBrowserWindow(tab) }
            }
            .keyboardShortcut("o")
            .disabled(browser.quickLinks.keyTab == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") { browser.closeTabOrWindow() }
                .keyboardShortcut("w")
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            Button("Reopen Closed Tab") { browser.inBrowserWindow { browser.reopenClosedTab(into: $0) } }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(!browser.canReopenClosedTab)
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") { browser.commandTab?.print() }
                .keyboardShortcut("p")
                .disabled(browser.commandTab == nil)
        }
        CommandGroup(after: .pasteboard) {
            // No shortcut: ⌥⇧⌘V is Paste and Match Style, which editors handle as a paste.
            // Sent to the window in front, a link's too, so it follows `commandTab` like the other page commands.
            Button(PageOverrides.forcePasteTitle) { NSApp.sendAction(#selector(PageWebView.forcePaste(_:)), to: nil, from: nil) }
                .disabled(browser.commandTab == nil)
        }
        CommandGroup(after: .textEditing) {
            Divider()
            Button(browser.findBarIsInFront ? "Hide Find Bar" : "Find…") { browser.toggleFind() }
                .keyboardShortcut("f")
            Button("Find Next") { Task { await browser.findStep(forward: true) } }
                .keyboardShortcut("g")
                .disabled(browser.commandTab == nil)
            Button("Find Previous") { Task { await browser.findStep(forward: false) } }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(browser.commandTab == nil)
            Button("Use Selection for Find") { Task { await browser.useSelectionForFind() } }
            .keyboardShortcut("e")
            .disabled(browser.commandTab == nil)
        }
        CommandGroup(before: .sidebar) {
            Button(browser.commandWindow.showsSidebar ? "Hide Sidebar" : "Show Sidebar") {
                withAnimation(.snappy(duration: 0.2)) { browser.commandWindow.toggleSidebar() }
            }
            .keyboardShortcut("b")
            .disabled(!browser.canChangeTabs)
            Button(browser.commandWindow.isZenMode ? "Exit Zen Mode" : "Enter Zen Mode") {
                withAnimation(.snappy(duration: 0.2)) { browser.commandWindow.toggleZenMode() }
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(!browser.canChangeTabs)
            Button("Reload Page") { browser.navigate(browser.commandTab, .reload) }
                .keyboardShortcut("r")
                .disabled(browser.commandTab == nil)
            Button(browser.commandTab?.isReading == true ? "Hide Reader" : "Show Reader") { browser.toggleReader(browser.commandTab) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(browser.commandTab?.canRead != true)
            Button(browser.commandTab?.pageTranslation?.isActive == true ? "Show Original" : "Translate Page") { browser.toggleTranslation(browser.commandTab) }
                .disabled(browser.commandTab?.canTranslate != true)
            Divider()
            // The popover is a browser window's toolbar's: a link's window has none.
            Button(browser.commandWindow.isSummaryPresented ? "Hide Summary" : "Summarize Page") { browser.commandWindow.toggleSummary() }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(!browser.summaries.isEnabled || !browser.canChangeTabs || PageSummaries.page(of: browser.commandWindow.selectedTab?.url) == nil)
            Button(protectionsEnabled ? "Turn Off Protections for This Site" : "Turn On Protections for This Site") {
                browser.setProtections(!protectionsEnabled, for: browser.commandTab)
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(browser.commandTab?.url?.scheme?.hasPrefix("http") != true)
            Button(browser.commandWindow.videoPopout.tab == nil ? "Pop Out Video" : "Put Video Back") {
                let popout = browser.commandWindow.videoPopout
                if popout.tab == nil { popout.showSelected() } else { popout.returnToTab() }
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(browser.commandWindow.videoPopout.tab == nil && !browser.commandWindow.videoPopout.canShowSelected)
            Divider()
            // ⌘= zooms in too (`Browser.isZoomInWithoutShift`).
            Button("Zoom In") { browser.zoomSelectedTab(by: PageZoom.step) }
                .keyboardShortcut("+")
                .disabled(browser.commandTab == nil)
            Button("Zoom Out") { browser.zoomSelectedTab(by: -PageZoom.step) }
                .keyboardShortcut("-")
                .disabled(browser.commandTab == nil)
            Button("Actual Size") {
                guard let tab = browser.commandTab else { return }
                if let pdf = tab.pdf { pdf.setScale(1) } else { tab.webView.pageZoom = 1 }
            }
                .keyboardShortcut("0")
                .disabled(browser.commandTab == nil)
            Divider()
            Menu("Developer") {
                Button("Show Web Inspector") { showDeveloperTools(.inspector) }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Button("Show JavaScript Console") { showDeveloperTools(.console) }
                    .keyboardShortcut("c", modifiers: [.command, .option])
            }
            .disabled(!browser.canShowWebInspector)
            Divider()
        }
        CommandMenu("History") {
            Button("Show All History") { browser.inBrowserWindow { browser.openHistory(in: $0) } }
                .keyboardShortcut("y")
            Divider()
            Button("Back") { browser.navigate(browser.commandTab, .back) }
                .keyboardShortcut("[")
                .disabled(browser.commandTab?.canGoBack != true)
            Button("Forward") { browser.navigate(browser.commandTab, .forward) }
                .keyboardShortcut("]")
                .disabled(browser.commandTab?.canGoForward != true)
        }
        CommandMenu("Tabs") {
            // Not while a link's window is in front (`Browser.canChangeTabs`): its page gets the keys.
            let window = browser.commandWindow
            Button("Next Tab") { window.selectAdjacentTab(1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!browser.canChangeTabs)
            Button("Previous Tab") { window.selectAdjacentTab(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!browser.canChangeTabs)
            Button("Next Recent Tab") { window.cycleRecentTabs(backward: false) }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled(!browser.canChangeTabs)
            Button("Previous Recent Tab") { window.cycleRecentTabs(backward: true) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled(!browser.canChangeTabs)
            Divider()
            Button("Pin or Unpin Tab") { window.togglePinForSelectedTab() }
                .keyboardShortcut("d")
                .disabled(window.selectedTab?.url == nil || window.selectedTab?.isEphemeral == true || !browser.canChangeTabs)
            Button("Copy Link") { browser.copyLink(of: browser.commandTab) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(browser.commandTab?.url == nil)
            Button("Duplicate Tab") { if let tab = window.selectedTab { browser.duplicate(tab) } }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(window.selectedTab?.url == nil || !browser.canChangeTabs)
            if Tab.canMute {
                Button(browser.commandTab?.isMuted == true ? "Unmute Tab" : "Mute Tab") {
                    browser.commandTab?.isMuted.toggle()
                }
                .disabled(browser.commandTab == nil)
            }
            Divider()
            Button("New Folder") { withAnimation(.snappy(duration: 0.2)) { browser.newFolder(in: window) } }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(!browser.canChangeTabs)
            // A favorite's page stays in the grid: only the tab list has folders.
            if let tab = window.selectedTab, tab.pinID == nil, browser.canChangeTabs {
                MoveToFolderMenu(browser: browser, tab: tab, title: "Move Tab to Folder", showsShortcut: true)
            } else {
                Menu("Move Tab to Folder") {}
                    .disabled(true)
            }
            Divider()
            ForEach(1..<10) { number in
                Button("Go to Item \(number)") { window.selectItem(at: number - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")))
                    .disabled(!browser.canChangeTabs)
            }
            if browser.hasSpaces {
                Divider()
                // One digit each: `Character` traps on "10" (`restoreSpaces` keeps `Space.limit`).
                ForEach(Array(browser.spaces.prefix(Space.limit).enumerated()), id: \.element.id) { index, space in
                    Button("Go to \(space.name)") { withAnimation(.snappy(duration: 0.25)) { window.switchToSpace(at: index) } }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .control)
                        .disabled(!browser.canChangeTabs)
                }
            }
        }
    }

    private var protectionsEnabled: Bool {
        browser.privacy.isEnabled(for: browser.commandTab?.url, privateSession: browser.commandTab?.privateSession, space: browser.commandTab?.siteSpace)
    }

    private func showDeveloperTools(_ panel: DeveloperTools.Panel) {
        guard browser.canShowWebInspector, let tab = browser.commandTab else { return }
        DeveloperTools.show(panel, in: tab.webView)
    }

}

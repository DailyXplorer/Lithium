import SwiftUI
import WebKit

@main
struct LithiumApp: App {
    /// SwiftUI may build the App value more than once; the browser (and its background
    /// filter updates and tab sleeping) must exist exactly once.
    @MainActor static let sharedBrowser: Browser = {
        Theme.registerFonts()
        return Browser()
    }()

    private let browser = LithiumApp.sharedBrowser
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Lithium", id: "browser") {
            BrowserView()
                .environment(browser)
                .frame(minWidth: 760, minHeight: 480)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .commands { BrowserCommands(browser: browser) }

    }
}

/// The Dock menu, which SwiftUI has no scene API for: Stop Agent, reachable even when the
/// window is hidden behind other apps. And the session's last changes, written as the app quits.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        LithiumApp.sharedBrowser.saveNow()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard LithiumApp.sharedBrowser.agent?.state == .listening else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: "Stop Agent", action: #selector(stopAgent), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func stopAgent() {
        LithiumApp.sharedBrowser.agent?.stop()
    }
}

struct BrowserCommands: Commands {
    let browser: Browser
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { browser.openSettings() }
                .keyboardShortcut(",")
        }
        CommandGroup(after: .appSettings) {
            Button("Stop Agent") { browser.agent?.stop() }
                .keyboardShortcut(".", modifiers: [.control, .command])
                .disabled(browser.agent?.state != .listening)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { browser.newTabFocusingAddress() }
                .keyboardShortcut("t")
            Button("Open Location…") { browser.requestAddressFocus() }
                .keyboardShortcut("l")
            Button("Move to Main Window") {
                guard let tab = browser.quickLinks.keyTab else { return }
                browser.quickLinks.moveToMainWindow(tab)
                openWindow(id: "browser")
            }
            .keyboardShortcut("o")
            .disabled(browser.quickLinks.keyTab == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") { browser.closeTabOrWindow() }
                .keyboardShortcut("w")
            Button("Reopen Closed Tab") { browser.reopenClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(!browser.canReopenClosedTab)
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") { browser.commandTab?.print() }
                .keyboardShortcut("p")
                .disabled(browser.commandTab == nil)
        }
        CommandGroup(after: .pasteboard) {
            // The focused page's, through the responder chain: nothing happens in the address bar.
            // No shortcut: ⌥⇧⌘V is Paste and Match Style, which editors handle as a paste.
            Button(PageOverrides.forcePasteTitle) { NSApp.sendAction(#selector(PageWebView.forcePaste(_:)), to: nil, from: nil) }
                .disabled(browser.selectedTab == nil)
        }
        CommandGroup(after: .textEditing) {
            Divider()
            // ⌘F toggles the bar; closing it hands the keyboard back to the page.
            Button(browser.find.isVisible ? "Hide Find Bar" : "Find…") {
                if browser.find.isVisible {
                    browser.find.hide()
                    if let view = browser.selectedTab?.contentView { view.window?.makeFirstResponder(view) }
                } else if browser.selectedTab != nil {
                    browser.find.show()
                }
            }
            .keyboardShortcut("f")
            Button("Find Next") { findStep(forward: true) }
                .keyboardShortcut("g")
                .disabled(browser.selectedTab == nil)
            Button("Find Previous") { findStep(forward: false) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(browser.selectedTab == nil)
            Button("Use Selection for Find") {
                guard let tab = browser.selectedTab else { return }
                Task { await browser.find.useSelection(in: tab.findTarget) }
            }
            .keyboardShortcut("e")
            .disabled(browser.selectedTab == nil)
        }
        CommandGroup(before: .sidebar) {
            Button(browser.showsSidebar ? "Hide Sidebar" : "Show Sidebar") {
                withAnimation(.snappy(duration: 0.2)) { browser.toggleSidebar() }
            }
            .keyboardShortcut("b")
            Button(browser.isZenMode ? "Exit Zen Mode" : "Enter Zen Mode") {
                withAnimation(.snappy(duration: 0.2)) { browser.toggleZenMode() }
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Reload Page") { browser.navigate(browser.commandTab, .reload) }
                .keyboardShortcut("r")
                .disabled(browser.commandTab == nil)
            Divider()
            Button(browser.summaries.isPanelPresented ? "Hide Summary" : "Summarize Page") {
                if let tab = browser.selectedTab { browser.summaries.togglePanel(for: tab) }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(!browser.summaries.isEnabled || PageSummaries.page(of: browser.selectedTab?.url) == nil)
            Button(protectionsEnabled ? "Turn Off Protections for This Site" : "Turn On Protections for This Site") {
                browser.setProtections(!protectionsEnabled, for: browser.selectedTab)
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(browser.selectedTab?.url?.scheme?.hasPrefix("http") != true)
            Button(browser.videoPopout.tab == nil ? "Pop Out Video" : "Put Video Back") {
                if browser.videoPopout.tab == nil { browser.videoPopout.showSelected() } else { browser.videoPopout.returnToTab() }
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(browser.videoPopout.tab == nil && !browser.videoPopout.canShowSelected)
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
            Button("Show All History") { browser.openHistory() }
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
            Button("Next Tab") { browser.selectAdjacentTab(1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Previous Tab") { browser.selectAdjacentTab(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Next Recent Tab") { browser.cycleRecentTabs(backward: false) }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("Previous Recent Tab") { browser.cycleRecentTabs(backward: true) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            Divider()
            // As in the sidebar and the toolbar: a private tab is never pinned.
            Button("Pin or Unpin Tab") { browser.togglePinForSelectedTab() }
                .keyboardShortcut("d")
                .disabled(browser.selectedTab?.url == nil || browser.selectedTab?.isEphemeral == true)
            Button("Copy Link") { browser.copyLink(of: browser.commandTab) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(browser.commandTab?.url == nil)
            Button("Duplicate Tab") { if let tab = browser.selectedTab { browser.duplicate(tab) } }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(browser.selectedTab?.url == nil)
            if Tab.canMute {
                Button(browser.selectedTab?.isMuted == true ? "Unmute Tab" : "Mute Tab") {
                    browser.selectedTab?.isMuted.toggle()
                }
                .disabled(browser.selectedTab == nil)
            }
            Divider()
            ForEach(1..<10) { number in
                Button("Go to Item \(number)") { browser.selectItem(at: number - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")))
            }
        }
    }

    private var protectionsEnabled: Bool {
        browser.privacy.isEnabled(for: browser.selectedTab?.url, privateSession: browser.selectedTab?.privateSession)
    }

    private func findStep(forward: Bool) {
        guard let tab = browser.selectedTab else { return }
        browser.find.show(focusingField: false)
        Task { await browser.find.step(forward: forward, in: tab.findTarget) }
    }

    private func showDeveloperTools(_ panel: DeveloperTools.Panel) {
        guard browser.canShowWebInspector, let tab = browser.selectedTab else { return }
        DeveloperTools.show(panel, in: tab.webView)
    }

}

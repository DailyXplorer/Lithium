import SwiftUI
import WebKit

@main
struct LithiumApp: App {
    /// SwiftUI may build the App value more than once; the browser (and its background
    /// filter updates and tab sleeping) must exist exactly once.
    @MainActor private static let sharedBrowser: Browser = {
        Theme.registerFonts()
        return Browser()
    }()

    private let browser = LithiumApp.sharedBrowser

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

struct BrowserCommands: Commands {
    let browser: Browser

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { browser.openSettings() }
                .keyboardShortcut(",")
        }
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { browser.newTabFocusingAddress() }
                .keyboardShortcut("t")
            Button("Open Location…") { browser.requestAddressFocus() }
                .keyboardShortcut("l")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") { browser.closeSelectedTab() }
                .keyboardShortcut("w")
            Button("Reopen Closed Tab") { browser.reopenClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") { currentTab.print() }
                .keyboardShortcut("p")
        }
        CommandGroup(after: .textEditing) {
            Divider()
            // ⌘F toggles the bar; closing it hands the keyboard back to the page.
            Button(browser.find.isVisible ? "Hide Find Bar" : "Find…") {
                if browser.find.isVisible {
                    browser.find.hide()
                    let view = currentTab.contentView
                    view.window?.makeFirstResponder(view)
                } else {
                    browser.find.show()
                }
            }
            .keyboardShortcut("f")
            Button("Find Next") { findStep(forward: true) }
                .keyboardShortcut("g")
            Button("Find Previous") { findStep(forward: false) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button("Use Selection for Find") {
                let tab = currentTab
                Task { await browser.find.useSelection(in: tab) }
            }
            .keyboardShortcut("e")
        }
        CommandGroup(before: .sidebar) {
            Button(browser.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                withAnimation(.snappy(duration: 0.2)) { browser.isSidebarVisible.toggle() }
            }
            .keyboardShortcut("b")
            Button("Reload Page") { browser.selectedTab?.reload() }
                .keyboardShortcut("r")
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
            Divider()
            Button("Zoom In") { zoom(by: 0.1) }
                .keyboardShortcut("+")
            Button("Zoom Out") { zoom(by: -0.1) }
                .keyboardShortcut("-")
            Button("Actual Size") {
                if let pdf = currentTab.pdf { pdf.setScale(1) } else { currentWebView.pageZoom = 1 }
            }
                .keyboardShortcut("0")
            Divider()
        }
        CommandMenu("History") {
            Button("Show All History") { browser.openHistory() }
                .keyboardShortcut("y")
            Divider()
            Button("Back") { currentWebView.goBack() }
                .keyboardShortcut("[")
            Button("Forward") { currentWebView.goForward() }
                .keyboardShortcut("]")
        }
        CommandMenu("Tabs") {
            Button("Next Tab") { browser.selectAdjacentTab(1) }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("Previous Tab") { browser.selectAdjacentTab(-1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            Divider()
            Button("Pin or Unpin Tab") { browser.togglePinForSelectedTab() }
                .keyboardShortcut("d")
            Button("Copy Link") { copyLink() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Divider()
            ForEach(1..<10) { number in
                Button("Go to Item \(number)") { browser.selectItem(at: number - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")))
            }
        }
    }

    private var protectionsEnabled: Bool {
        browser.privacy.isEnabled(for: browser.selectedTab?.url)
    }

    private var currentTab: Tab {
        browser.selectedTab ?? browser.home
    }

    private var currentWebView: WKWebView {
        currentTab.webView
    }

    private func findStep(forward: Bool) {
        let tab = currentTab
        browser.find.show()
        Task { await browser.find.step(forward: forward, in: tab) }
    }

    private func zoom(by delta: Double) {
        if let pdf = currentTab.pdf {
            if delta > 0 { pdf.zoomIn() } else { pdf.zoomOut() }
            return
        }
        let webView = currentWebView
        webView.pageZoom = min(max(webView.pageZoom + delta, 0.5), 3)
    }

    private func copyLink() {
        guard let url = browser.selectedTab?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}

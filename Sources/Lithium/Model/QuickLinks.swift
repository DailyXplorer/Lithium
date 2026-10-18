import AppKit
import Observation
import WebKit

/// Links from other apps, each in a small window of its own, like Little Arc. The page is a `Tab`
/// kept out of `Browser.tabs`, so the tab list, session, sleeping and agents never see it.
@MainActor
@Observable
final class QuickLinks {
    var isEnabled = UserDefaults.standard.bool(forKey: Preference.quickLinks) {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Preference.quickLinks) }
    }
    private(set) var tabs: [Tab] = []
    /// The page whose window is in front: the menu's page commands act on it (`Browser.commandTab`).
    private(set) var keyTab: Tab?
    /// One find bar for the links' windows, over the link in front; each browser window has its own.
    let find = FindInPage()

    @ObservationIgnored weak var browser: Browser?
    /// Tests open no window.
    @ObservationIgnored var showWindow: @MainActor (Tab, Browser) -> NSWindow? = QuickLinkWindow.open
    @ObservationIgnored private var windows: [Tab.ID: NSWindow] = [:]

    /// Web addresses only: a file opened from the Finder is a document, for the main window.
    static func takes(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased())
    }

    /// Also where a link's page opens a page of its own (a popup, with WebKit's `configuration`):
    /// in the main window it would land behind this one, unseen.
    /// The page is the browser window in front's, in its space, which matters once it moves there.
    @discardableResult
    func open(_ url: URL? = nil, configuration: WKWebViewConfiguration? = nil, space: Space.ID? = nil) -> Tab? {
        guard let browser else { return nil }
        let window = browser.commandWindow
        let tab = Tab(browser: browser, configuration: configuration ?? browser.makeConfiguration(for: url), space: space ?? window.currentSpaceID, window: window.id)
        if let url { tab.load(url) }
        tabs.append(tab)
        windows[tab.id] = showWindow(tab, browser)
        return tab
    }

    func contains(_ tab: Tab) -> Bool {
        tabs.contains { $0 === tab }
    }

    /// Into the browser window in front, shown again if it was closed, with the same web view, so
    /// the page doesn't reload and keeps what was typed or played in it. Not while a sheet is up
    /// (a page's alert, a file picker): closing the window under it would leave the page waiting
    /// on an answer. False when it didn't move.
    @discardableResult
    func moveToBrowserWindow(_ tab: Tab) -> Bool {
        guard windows[tab.id]?.attachedSheet == nil, let browser, remove(tab) else { return false }
        browser.inBrowserWindow { window in
            browser.adopt(tab, into: window)
            window.nsWindow?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func showsFindBar(over tab: Tab) -> Bool {
        find.isVisible && find.linkTab === tab
    }

    var findBarIsInFront: Bool { keyTab.map(showsFindBar(over:)) ?? false }

    func toggleFind() {
        if findBarIsInFront {
            find.hide()
            browser?.returnKeyboardToPage(to: keyTab, fieldHadKeyboard: true)
        } else if let keyTab {
            find.show(inLink: keyTab)
        }
    }

    func findStep(forward: Bool) async {
        guard let keyTab else { return }
        find.show(focusingField: false, inLink: keyTab)
        await find.step(forward: forward, in: keyTab.findTarget)
    }

    func useSelectionForFind() async {
        guard let keyTab else { return }
        await find.useSelection(in: keyTab.findTarget, inLink: keyTab)
    }

    /// Escape in a link's window has only the find bar to close, and not while the page has the
    /// keyboard: the Escape is the page's, and the bar stays open.
    func closeFindBar() -> Bool {
        guard findBarIsInFront, !(keyTab?.contentView.window?.firstResponder is WKWebView) else { return false }
        let hadKeyboard = find.isFieldFocused
        find.hide()
        browser?.returnKeyboardToPage(to: keyTab, fieldHadKeyboard: hadKeyboard)
        return true
    }

    /// Not into Reopen Closed Tab: it never was a tab.
    func close(_ tab: Tab) {
        guard let browser, remove(tab) else { return }
        browser.permissions.cancel(tabID: tab.id)
        browser.appLinks.cancel(tabID: tab.id)
        browser.nowPlaying.discard(tab)
        tab.unpair()
        tab.tearDown()
    }

    func windowClosed(_ tab: Tab) {
        windows[tab.id] = nil
        close(tab)
    }

    var keyWindow: NSWindow? { keyTab.flatMap { windows[$0.id] } }

    /// A Dock click with one up only brings Lithium forward, as with a browser window on screen.
    var hasWindowOnScreen: Bool { windows.values.contains(where: \.isVisible) }

    func windowBecameKey(_ tab: Tab) {
        keyTab = tab
    }

    /// A sheet on the link's window (a page's alert, a file picker) takes the key from it, but the
    /// link stays in front: the menu's commands keep acting on it until another window becomes key.
    func windowResignedKey(_ tab: Tab, toSheet: Bool = false) {
        if keyTab === tab, !toSheet { keyTab = nil }
    }

    /// A browser window in front: no link's window is, even one that resigned to its sheet.
    func browserWindowBecameKey() {
        keyTab = nil
    }

    private func remove(_ tab: Tab) -> Bool {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return false }
        tabs.remove(at: index)
        if keyTab === tab { keyTab = nil }
        if find.linkTab === tab { find.hide() }
        windows.removeValue(forKey: tab.id)?.close()
        return true
    }
}

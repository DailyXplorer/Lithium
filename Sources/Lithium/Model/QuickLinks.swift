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
    @discardableResult
    func open(_ url: URL? = nil, configuration: WKWebViewConfiguration? = nil, space: Space.ID? = nil) -> Tab? {
        guard let browser else { return nil }
        let tab = Tab(browser: browser, configuration: configuration ?? browser.makeConfiguration(for: url), space: space ?? browser.currentSpaceID)
        if let url { tab.load(url) }
        tabs.append(tab)
        windows[tab.id] = showWindow(tab, browser)
        return tab
    }

    func contains(_ tab: Tab) -> Bool {
        tabs.contains { $0 === tab }
    }

    /// The same web view, so the page doesn't reload and keeps what was typed or played in it.
    func moveToMainWindow(_ tab: Tab) {
        guard let browser, remove(tab) else { return }
        browser.adopt(tab)
        browser.window?.makeKeyAndOrderFront(nil)
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

    func windowBecameKey(_ tab: Tab) {
        keyTab = tab
        tab.reloadIfStale()
    }

    func windowResignedKey(_ tab: Tab) {
        if keyTab === tab { keyTab = nil }
    }

    private func remove(_ tab: Tab) -> Bool {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return false }
        tabs.remove(at: index)
        if keyTab === tab { keyTab = nil }
        if browser?.find.linkTab === tab { browser?.find.hide() }
        windows.removeValue(forKey: tab.id)?.close()
        return true
    }
}

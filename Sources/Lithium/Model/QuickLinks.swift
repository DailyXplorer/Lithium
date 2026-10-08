import AppKit
import Observation
import WebKit

/// Links from other apps (Mail, Slack, Notes), each in a small window of its own instead of a new
/// tab, like Little Arc. The page is a `Tab` kept out of `Browser.tabs`, so the tab list, the
/// session, tab sleeping and agents never see it, until the user moves it into the main window,
/// web view and all. Off unless turned on; with no link open it holds nothing and runs nothing.
@MainActor
@Observable
final class QuickLinks {
    /// Settings › Advanced.
    var isEnabled = UserDefaults.standard.bool(forKey: Preference.quickLinks) {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Preference.quickLinks) }
    }
    /// One per open window, oldest first.
    private(set) var tabs: [Tab] = []
    /// The page whose window is in front: the menu's page commands act on it (`Browser.commandTab`).
    private(set) var keyTab: Tab?

    @ObservationIgnored weak var browser: Browser?
    /// Opens a page's window. Tests open none, so nothing shows on screen.
    @ObservationIgnored var showWindow: @MainActor (Tab, Browser) -> NSWindow? = QuickLinkWindow.open
    @ObservationIgnored private var windows: [Tab.ID: NSWindow] = [:]

    /// Web addresses only: a file opened from the Finder is a document, for the main window.
    static func takes(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased())
    }

    /// Also where a link's page opens a page of its own (a `target=_blank` link, a sign-in popup,
    /// with WebKit's `configuration`): in the main window it would land behind this one, unseen.
    /// In the space shown, as a link from another app opens, or in its opener's.
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

    /// A normal tab at the top of the list, selected. The same web view, so the page doesn't
    /// reload and keeps what was typed or played in it.
    func moveToMainWindow(_ tab: Tab) {
        guard let browser, remove(tab) else { return }
        browser.adopt(tab)
        browser.window?.makeKeyAndOrderFront(nil)
    }

    /// Gone like a closed tab, but not into Reopen Closed Tab: it never was one. Its visits stay
    /// in the history. Also where the page lands when it closes itself (`window.close()`, a link
    /// that turned out to be a download).
    func close(_ tab: Tab) {
        guard let browser, remove(tab) else { return }
        browser.permissions.cancel(tabID: tab.id)
        browser.appLinks.cancel(tabID: tab.id)
        browser.nowPlaying.discard(tab)
        tab.unpair()
        tab.tearDown()
    }

    /// The user closed the window (its Close, ⌘W).
    func windowClosed(_ tab: Tab) {
        windows[tab.id] = nil
        close(tab)
    }

    /// `keyTab`'s window.
    var keyWindow: NSWindow? { keyTab.flatMap { windows[$0.id] } }

    func windowBecameKey(_ tab: Tab) {
        keyTab = tab
    }

    func windowResignedKey(_ tab: Tab) {
        if keyTab === tab { keyTab = nil }
    }

    /// Forgets the page, and closes its window if it is still open.
    private func remove(_ tab: Tab) -> Bool {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return false }
        tabs.remove(at: index)
        if keyTab === tab { keyTab = nil }
        // Its find bar goes with it, rather than staying open for no window.
        if browser?.find.linkTab === tab { browser?.find.hide() }
        windows.removeValue(forKey: tab.id)?.close()
        return true
    }
}

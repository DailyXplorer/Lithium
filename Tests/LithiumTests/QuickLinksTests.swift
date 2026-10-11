import AppKit
import Network
import Testing
import WebKit
@testable import Lithium

/// Links from other apps in a small window of their own (Settings › Advanced). A whole Browser
/// keeps its data in the home folder, so this suite only runs in a throwaway one:
/// `scripts/test --filter QuickLinksTests`. The links' windows are recorded, never put on screen.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct QuickLinksTests {
    private static let page = (headers: "Content-Type: text/html", body: "<title>Quick</title><input id=q>")

    @Test func onlyWebAddressesGetAWindow() {
        #expect(QuickLinks.takes(URL(string: "https://example.com/")!))
        #expect(QuickLinks.takes(URL(string: "HTTP://example.com/")!))
        #expect(!QuickLinks.takes(URL(filePath: "/tmp/page.html")))
        #expect(!QuickLinks.takes(URL(string: "mailto:someone@example.com")!))
    }

    /// Off, as it is unless turned on, a link opens a selected tab, as before.
    @Test func whileOffALinkOpensATab() {
        UserDefaults.standard.removeObject(forKey: Preference.quickLinks)
        defer { UserDefaults.standard.removeObject(forKey: Preference.quickLinks) }
        let (browser, windows) = makeBrowser()
        #expect(!browser.quickLinks.isEnabled)
        let url = URL(string: "http://127.0.0.1:1/")!
        browser.openFromOtherApp(url)
        defer { browser.tabs.forEach(browser.close) }
        #expect(browser.selectedTab?.url == url)
        #expect(browser.quickLinks.tabs.isEmpty)
        #expect(windows.opened.isEmpty)

        browser.quickLinks.isEnabled = true
        #expect(QuickLinks().isEnabled, "the setting outlives the app")
    }

    /// The tab list, the selection and the saved session stay as they were, and the page never
    /// sleeps while its window is open.
    @Test func whileOnALinkOpensInItsOwnWindow() async throws {
        let (listener, base) = try await LocalHTTP.serve(["/": Self.page])
        defer { listener.cancel() }
        let (browser, windows) = makeBrowser(enabled: true)
        defer { UserDefaults.standard.removeObject(forKey: Preference.quickLinks) }
        let before = browser.tabs.map(\.id)
        let selected = browser.selectedTabID

        browser.openFromOtherApp(base)
        let tab = try #require(browser.quickLinks.tabs.first)
        defer { browser.quickLinks.close(tab) }
        #expect(windows.opened.map(\.tab) == [tab])
        #expect(browser.tabs.map(\.id) == before)
        #expect(browser.selectedTabID == selected)
        #expect(await waitUntil(15) { tab.title == "Quick" && !tab.isLoading })

        browser.saveNow()
        #expect(!SessionStore.load().tabs.contains { $0.url == base })
        browser.relieveMemoryPressure(critical: true)
        #expect(!tab.isAsleep)
    }

    /// A font setting changed in the main window reaches pages in links' windows at once, as it
    /// does the main window's tabs.
    @Test func fontSettingsReachLinksWindows() async throws {
        let (browser, _) = makeBrowser(enabled: true)
        defer { UserDefaults.standard.removeObject(forKey: Preference.quickLinks) }
        let previous = UserDefaults.standard.object(forKey: Preference.websiteFont)
        defer { UserDefaults.standard.set(previous, forKey: Preference.websiteFont) }
        PageStyle.usesFontEverywhere = true
        let tab = try #require(browser.quickLinks.open())
        defer { browser.quickLinks.close(tab) }
        tab.webView.loadHTMLString("<p>Text</p>", baseURL: URL(string: "https://example.com/")!)
        #expect(await waitUntil(15) { tab.url?.host() == "example.com" && !tab.isLoading })
        // Stands in for the font script, to tell whether it was stopped.
        _ = try await tab.webView.callAsyncJavaScript("window.__lithiumFont = { stop() { window.stopped = true; } };", contentWorld: .defaultClient)

        browser.changePageFont { PageStyle.usesFontEverywhere = false }
        var stopped = false
        for _ in 0..<100 where !stopped {
            stopped = try await tab.webView.callAsyncJavaScript("return window.stopped === true;", contentWorld: .defaultClient) as? Bool == true
            if !stopped { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(stopped)
    }

    /// ⌘= zooms the link's page while its window is in front, as Zoom Out and Actual Size do.
    @Test func commandEqualsZoomsALinksPage() throws {
        let (browser, windows) = makeBrowser(enabled: true)
        defer { UserDefaults.standard.removeObject(forKey: Preference.quickLinks) }
        let tab = try #require(browser.quickLinks.open(URL(string: "data:text/html,link")!))
        defer { browser.quickLinks.close(tab) }
        let window = try #require(windows.opened.first?.window)
        #expect(!browser.ownsZoomIn(in: window), "not in front")

        browser.quickLinks.windowBecameKey(tab)
        #expect(browser.ownsZoomIn(in: window))
        browser.zoomSelectedTab(by: PageZoom.step)
        #expect(tab.webView.pageZoom == 1.1)
        browser.quickLinks.windowResignedKey(tab)
        #expect(!browser.ownsZoomIn(in: window))
        #expect(!browser.ownsZoomIn(in: nil))
    }

    /// Moved in, it is a normal tab at the top of the list, selected, in the same web view: the
    /// page doesn't reload and keeps what was typed in it. The menu's page commands follow the
    /// window in front.
    @Test func movingThePageKeepsItsWebView() async throws {
        let (listener, base) = try await LocalHTTP.serve(["/": Self.page])
        defer { listener.cancel() }
        let (browser, windows) = makeBrowser(enabled: true)
        defer { UserDefaults.standard.removeObject(forKey: Preference.quickLinks) }
        let other = browser.newTab(url: URL(string: "data:text/html,other")!)
        defer { browser.tabs.forEach(browser.close) }

        let tab = try #require(browser.quickLinks.open(base))
        #expect(await waitUntil(15) { tab.title == "Quick" && !tab.isLoading })
        let webView = tab.webView
        _ = try await webView.evaluateJavaScript("document.querySelector('#q').value = 'typed'; 0")

        browser.quickLinks.windowBecameKey(tab)
        #expect(browser.commandTab === tab)
        browser.quickLinks.windowResignedKey(tab)
        #expect(browser.commandTab === other)
        browser.quickLinks.windowBecameKey(tab)

        browser.quickLinks.moveToMainWindow(tab)
        #expect(windows.opened.first?.window.closeCount == 1)
        #expect(browser.quickLinks.tabs.isEmpty)
        #expect(browser.quickLinks.keyTab == nil)
        #expect(browser.regularTabs.first === tab)
        #expect(browser.selectedTab === tab)
        #expect(browser.commandTab === tab)
        #expect(tab.webView === webView)
        #expect(!tab.isLoading)
        #expect(try await webView.evaluateJavaScript("document.querySelector('#q').value") as? String == "typed")
        browser.saveNow()
        #expect(SessionStore.load().tabs.contains { $0.url == base })
    }

    /// With a link's window in front, the menu's protections and inspector act on the link's page,
    /// not the main window's tab out of sight; popping out a video waits for the main window.
    @Test func pageCommandsFollowTheLinksWindow() async throws {
        let (listener, base) = try await LocalHTTP.serve(["/": Self.page])
        defer { listener.cancel() }
        let (browser, _) = makeBrowser(enabled: true)
        defer { UserDefaults.standard.removeObject(forKey: Preference.quickLinks) }
        let host = try #require(Privacy.siteHost(base))
        defer { browser.privacy.setEnabled(true, host: host) }
        browser.tabs.forEach(browser.close)

        let tab = try #require(browser.quickLinks.open(base))
        defer { browser.quickLinks.close(tab) }
        browser.quickLinks.windowBecameKey(tab)
        #expect(browser.selectedTab == nil)
        // The menu's page commands, Force Paste among them, stay enabled from this.
        #expect(browser.commandTab === tab)
        #expect(browser.canShowWebInspector)
        browser.setProtections(false, for: browser.commandTab)
        #expect(!browser.privacy.isEnabled(for: base))
        browser.setProtections(true, for: browser.commandTab)

        let main = browser.newTab(url: URL(string: "data:text/html,main")!)
        defer { browser.tabs.forEach(browser.close) }
        #expect(browser.selectedTab === main)
        #expect(browser.commandTab === tab)
        #expect(!browser.videoPopout.canShowSelected)
        browser.quickLinks.windowResignedKey(tab)
        #expect(browser.videoPopout.canShowSelected)
    }

    /// With a link's window in front, the guard of the Tabs menu's commands (Next Tab, ⌃⇥, ⌘1–9,
    /// ⌃1–9, New Folder, Pin…) is off: they would wake and switch the main window's tabs out of sight.
    /// The menu items themselves can't be read headless.
    @Test func tabCommandsWaitForTheMainWindow() throws {
        let (browser, _) = makeBrowser(enabled: true)
        defer { UserDefaults.standard.removeObject(forKey: Preference.quickLinks) }
        #expect(browser.canChangeTabs)

        let tab = try #require(browser.quickLinks.open())
        defer { browser.quickLinks.close(tab) }
        #expect(browser.canChangeTabs, "a link's window not in front yet")
        browser.quickLinks.windowBecameKey(tab)
        #expect(!browser.canChangeTabs)
        browser.quickLinks.windowResignedKey(tab)
        #expect(browser.canChangeTabs)

        browser.quickLinks.windowBecameKey(tab)
        browser.quickLinks.close(tab)
        #expect(browser.canChangeTabs, "a closed link's window gives them back")
    }

    /// `inMainWindow`, which Settings, History and Reopen Closed Tab run in: from a link's window it
    /// brings the main window forward, out of the Dock if minimized (even with no link in front),
    /// where they open or select their tab, and opens it again if closed; from the main window, it
    /// leaves it as it is. The menu items themselves can't be read headless.
    @Test func mainWindowCommandsBringItForward() throws {
        let (browser, _) = makeBrowser(enabled: true)
        defer { UserDefaults.standard.removeObject(forKey: Preference.quickLinks) }
        let main = RecordingWindow(contentRect: NSRect(x: -5000, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        main.isReleasedWhenClosed = false
        main.isShown = true
        browser.window = main
        var ran = 0, opened = 0
        browser.inMainWindow(open: { opened += 1 }) { ran += 1 }
        #expect(ran == 1)
        #expect(main.frontCount == 0)

        main.isInDock = true
        browser.inMainWindow(open: { opened += 1 }) { ran += 1 }
        #expect(ran == 2)
        #expect(main.deminiaturizeCount == 1, "minimized with no link in front")
        #expect(main.frontCount == 1)

        let tab = try #require(browser.quickLinks.open())
        defer { browser.quickLinks.close(tab) }
        browser.quickLinks.windowBecameKey(tab)
        browser.inMainWindow(open: { opened += 1 }) { ran += 1 }
        #expect(ran == 3)
        #expect(main.frontCount == 2)
        #expect(main.deminiaturizeCount == 1)

        main.isInDock = true
        browser.quickLinks.windowBecameKey(tab)
        browser.inMainWindow(open: { opened += 1 }) { ran += 1 }
        #expect(ran == 4)
        #expect(main.deminiaturizeCount == 2)
        #expect(main.frontCount == 3)
        #expect(opened == 0)

        main.isShown = false
        browser.inMainWindow(open: { opened += 1 }) { ran += 1 }
        #expect(opened == 1, "a closed main window opens again")
        #expect(main.frontCount == 3)
        browser.window = nil
        browser.inMainWindow(open: { opened += 1 }) { ran += 1 }
        #expect(opened == 2)
        #expect(ran == 6)
    }

    /// A page's alert or file picker on a link's window takes the key as a sheet: the link stays the
    /// window the menu acts on, until the main window becomes key. The window itself can't be made
    /// headless (it orders itself in), so the sheet check is passed in.
    @Test func linkWindowKeepsTheMenuWhileASheetIsUp() throws {
        let (browser, _) = makeBrowser(enabled: true)
        defer { UserDefaults.standard.removeObject(forKey: Preference.quickLinks) }
        let tab = try #require(browser.quickLinks.open())
        defer { browser.quickLinks.close(tab) }
        browser.quickLinks.windowBecameKey(tab)
        browser.quickLinks.windowResignedKey(tab, toSheet: true)
        #expect(!browser.canChangeTabs)
        #expect(browser.commandTab === tab)

        browser.windowDidBecomeKey()
        #expect(browser.canChangeTabs)
        #expect(browser.commandTab !== tab)
    }

    /// Move to Main Window (⌘O) stays enabled while a link's sheet is up, but moving would close the
    /// window under the page's alert or file picker: the page stays where its sheet is.
    @Test func linkWithASheetUpStaysInItsWindow() throws {
        let (browser, windows) = makeBrowser(enabled: true)
        defer { UserDefaults.standard.removeObject(forKey: Preference.quickLinks) }
        let tab = try #require(browser.quickLinks.open())
        defer { browser.quickLinks.close(tab) }
        let window = try #require(windows.opened.first?.window)
        browser.quickLinks.windowBecameKey(tab)
        browser.quickLinks.windowResignedKey(tab, toSheet: true)
        window.pageSheet = NSWindow()

        #expect(!browser.quickLinks.moveToMainWindow(tab))
        #expect(window.closeCount == 0)
        #expect(browser.quickLinks.contains(tab))
        #expect(browser.quickLinks.keyTab === tab)
        #expect(!browser.regularTabs.contains { $0 === tab })

        window.pageSheet = nil
        #expect(browser.quickLinks.moveToMainWindow(tab))
        #expect(window.closeCount == 1)
        #expect(browser.regularTabs.contains { $0 === tab })
    }

    /// Find follows the window in front: in a link's window, ⌘F shows the bar over its page, ⌘G
    /// steps through that page's matches, and Escape there closes the bar.
    @Test func findWorksInALinksWindow() async throws {
        let (listener, base) = try await LocalHTTP.serve(["/": ("Content-Type: text/html", "<title>Quick</title><p>needle</p><p>needle</p><p>needle</p>")])
        defer { listener.cancel() }
        let (browser, windows) = makeBrowser(enabled: true)
        defer { UserDefaults.standard.removeObject(forKey: Preference.quickLinks) }
        let other = browser.newTab(url: URL(string: "data:text/html,needle")!)
        defer { browser.tabs.forEach(browser.close) }
        let tab = try #require(browser.quickLinks.open(base))
        defer { browser.quickLinks.close(tab) }
        #expect(await waitUntil(15) { tab.title == "Quick" && !tab.isLoading })
        let window = try #require(windows.opened.first?.window)
        // The size its window gives it: unsized, the page lays nothing out and has no text to find.
        tab.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)

        browser.quickLinks.windowBecameKey(tab)
        browser.toggleFind()
        #expect(browser.showsFindBar(over: tab))
        #expect(!browser.showsFindBar(over: other))
        // What the bar does as the user types.
        await browser.find.update(query: "needle", in: tab.findTarget)
        #expect(browser.find.matchCount == 3)
        // The main window's page loading doesn't take the search over.
        other.load(URL(string: "data:text/html,needle again")!)
        #expect(await waitUntil(15) { other.url?.absoluteString.hasSuffix("again") == true && !other.isLoading })
        try await Task.sleep(for: .milliseconds(200))
        #expect(browser.find.matchCount == 3)
        await browser.findStep(forward: true)
        #expect(browser.find.currentMatch == 2)
        let marked = try await tab.webView.callAsyncJavaScript("return CSS.highlights.has('lithium-find');", contentWorld: .defaultClient) as? Bool
        #expect(marked == true, "the link's page shows the match")

        #expect(browser.ownsEscape(in: window))
        #expect(browser.dismissOverlay())
        #expect(!browser.find.isVisible)
        #expect(!browser.ownsEscape(in: window), "nothing left to close there")

        browser.quickLinks.windowResignedKey(tab)
        browser.toggleFind()
        #expect(browser.showsFindBar(over: other))
        #expect(!browser.showsFindBar(over: tab))
        browser.find.hide()
    }

    /// The bar stays in the window it was opened in: a link's window coming to the front and
    /// going again leaves the main window's search where it was, and never shows the bar there
    /// (which would search again and take the keyboard). ⌘F in the link's window moves it, and
    /// Escape there closes only it, not a tab's name being edited in the main window.
    @Test func findBarStaysInTheWindowItWasOpenedIn() async throws {
        let page = "<title>Find</title><p>needle</p><p>needle</p><p>needle</p>"
        let (listener, base) = try await LocalHTTP.serve(["/": ("Content-Type: text/html", page)])
        defer { listener.cancel() }
        let (browser, windows) = makeBrowser(enabled: true)
        defer { UserDefaults.standard.removeObject(forKey: Preference.quickLinks) }
        let main = browser.newTab(url: base)
        defer { browser.tabs.forEach(browser.close) }
        #expect(await waitUntil(15) { main.title == "Find" && !main.isLoading })
        main.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)

        browser.toggleFind()
        await browser.find.update(query: "needle", in: main.findTarget)
        await browser.findStep(forward: true)
        #expect(browser.find.currentMatch == 2 && browser.find.matchCount == 3)
        let focusToken = browser.find.focusToken

        let link = try #require(browser.quickLinks.open(base))
        defer { browser.quickLinks.close(link) }
        let window = try #require(windows.opened.first?.window)
        browser.quickLinks.windowBecameKey(link)
        #expect(browser.showsFindBar(over: main))
        #expect(!browser.showsFindBar(over: link))
        #expect(!browser.findBarIsInFront && !browser.ownsEscape(in: window))
        browser.quickLinks.windowResignedKey(link)
        #expect(browser.showsFindBar(over: main))
        #expect(browser.find.currentMatch == 2 && browser.find.matchCount == 3)
        #expect(browser.find.focusToken == focusToken, "the field didn't ask for the keyboard again")

        browser.quickLinks.windowBecameKey(link)
        browser.renamingTabID = main.id
        defer { browser.renamingTabID = nil }
        browser.toggleFind()
        #expect(browser.showsFindBar(over: link) && !browser.showsFindBar(over: main))
        #expect(browser.ownsEscape(in: window))
        #expect(browser.dismissOverlay())
        #expect(!browser.find.isVisible)
        #expect(browser.renamingTabID == main.id, "the tab's name is still being edited")

        // A link's window closing takes its bar with it.
        browser.toggleFind()
        #expect(browser.showsFindBar(over: link))
        browser.quickLinks.close(link)
        #expect(!browser.find.isVisible)
    }

    /// A page the link's page opens (a target=_blank link, a sign-in popup) gets a window of its
    /// own too, in front, its opener kept; the tab list and the selection stay as they were.
    @Test func pagesItOpensGetWindowsOfTheirOwn() async throws {
        let (listener, base) = try await LocalHTTP.serve([
            "/": ("Content-Type: text/html", #"""
                <title>Quick</title><a id="link" href="/next" target="_blank">Next</a>
                <button id="signin" onclick="window.open('/next', '', 'width=400,height=300')">Sign in</button>
                """#),
            "/next": ("Content-Type: text/html", "<title>Next</title>"),
        ])
        defer { listener.cancel() }
        let (browser, windows) = makeBrowser(enabled: true)
        defer { UserDefaults.standard.removeObject(forKey: Preference.quickLinks) }
        let before = browser.tabs.map(\.id)
        let selected = browser.selectedTabID

        let tab = try #require(browser.quickLinks.open(base))
        defer { browser.quickLinks.tabs.forEach(browser.quickLinks.close) }
        #expect(await waitUntil(15) { tab.title == "Quick" && !tab.isLoading })
        _ = try await tab.webView.evaluateJavaScript("document.getElementById('link').click(); 0")
        #expect(await waitUntil(15) { browser.quickLinks.tabs.count == 2 })
        _ = try await tab.webView.evaluateJavaScript("document.getElementById('signin').click(); 0")
        #expect(await waitUntil(15) { browser.quickLinks.tabs.count == 3 })

        let opened = browser.quickLinks.tabs.filter { $0 !== tab }
        #expect(windows.opened.map(\.tab) == browser.quickLinks.tabs)
        #expect(browser.tabs.map(\.id) == before)
        #expect(browser.selectedTabID == selected)
        #expect(await waitUntil(15) { opened.allSatisfy { $0.title == "Next" } })
        #expect(opened.allSatisfy { $0.scriptOpener === tab })
        #expect(opened.last?.opener === tab)
    }

    /// Closing the window discards the page, which leaves its visit in the history and nothing to
    /// reopen; so does a page closing itself, which closes its window.
    @Test func closingDiscardsThePage() async throws {
        let (listener, base) = try await LocalHTTP.serve(["/": Self.page])
        defer { listener.cancel() }
        let (browser, windows) = makeBrowser(enabled: true)
        defer { UserDefaults.standard.removeObject(forKey: Preference.quickLinks) }
        let tabs = browser.tabs.map(\.id)

        let tab = try #require(browser.quickLinks.open(base))
        #expect(await waitUntil(15) { tab.title == "Quick" && !tab.isLoading })
        browser.quickLinks.windowClosed(tab)
        #expect(browser.quickLinks.tabs.isEmpty)
        #expect(browser.tabs.map(\.id) == tabs)
        #expect(tab.loadedWebView?.navigationDelegate === PutAwayWebView.refusing)
        #expect(!browser.canReopenClosedTab)
        #expect(!browser.history.visits(matching: "127.0.0.1:\(base.port ?? 0)/").isEmpty)

        let closing = try #require(browser.quickLinks.open(base))
        browser.close(closing)
        #expect(windows.opened.last?.window.closeCount == 1)
        #expect(browser.quickLinks.tabs.isEmpty)
        #expect(browser.tabs.map(\.id) == tabs)
        #expect(!browser.canReopenClosedTab)
    }

    private func makeBrowser(enabled: Bool = false) -> (Browser, Windows) {
        let browser = Browser()
        browser.quickLinks.isEnabled = enabled
        let windows = Windows()
        browser.quickLinks.showWindow = { tab, _ in windows.open(tab) }
        return (browser, windows)
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

/// The windows the links would open, made but never ordered in.
@MainActor
private final class Windows {
    private(set) var opened: [(tab: Tab, window: RecordingWindow)] = []

    func open(_ tab: Tab) -> NSWindow {
        let window = RecordingWindow(contentRect: NSRect(x: -5000, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        opened.append((tab, window))
        return window
    }
}

private final class RecordingWindow: NSWindow {
    private(set) var closeCount = 0
    private(set) var frontCount = 0
    private(set) var deminiaturizeCount = 0
    var isInDock = false
    /// Set: taken as on screen (true) or closed (false), never ordered in.
    var isShown: Bool?
    /// Set: taken as the sheet attached to it, never shown.
    var pageSheet: NSWindow?

    override var isMiniaturized: Bool { isInDock }
    override var isVisible: Bool { isShown.map { $0 && !isInDock } ?? super.isVisible }
    override var attachedSheet: NSWindow? { pageSheet ?? super.attachedSheet }

    override func deminiaturize(_ sender: Any?) {
        deminiaturizeCount += 1
        isInDock = false
    }

    /// Recorded, never put on screen.
    override func makeKeyAndOrderFront(_ sender: Any?) {
        frontCount += 1
    }

    override func close() {
        closeCount += 1
        super.close()
    }
}

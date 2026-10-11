import Darwin
import Foundation
import Network
import os
import class SwiftUI.NSHostingView
import Testing
import WebKit
@testable import Lithium

/// A whole Browser: its tabs, their web processes and its background loops. It keeps its data
/// in the home folder, so this suite only runs in a throwaway one:
/// `CFFIXED_USER_HOME=$(mktemp -d) swift test --filter BrowserTests`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct BrowserTests {
    /// The tab restored at launch opens before the in-page engine is built (first launch, new lists,
    /// new uBO scriptlets); it must still get uBO's YouTube scriptlets, or its video plays an ad.
    @Test func restoredTabGetsTheAdScriptletsWhileTheEngineBuilds() async throws {
        try? FileManager.default.removeItem(at: URL.applicationSupportDirectory.appending(path: "Lithium/AdvancedEngine"))
        let url = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
        SessionStore.save(Session(tabs: [.init(url: url, title: "YouTube", customTitle: nil, pinID: nil)], selectedIndex: 0))
        let browser = Browser()
        let tab = try #require(browser.selectedTab)
        browser.windowDidAppear()
        let controller = tab.webView.configuration.userContentController
        #expect(await waitUntil(120) { !controller.userScripts.isEmpty })
        #expect(controller.userScripts.contains { $0.source.contains("function trustedJsonEditXhrRequest(") })
    }

    /// Launch leaves restored tabs asleep and bare: no web view configuration, no icon read, and
    /// the session file isn't written again. Each comes as the tab needs it.
    @Test func launchLeavesRestoredTabsBareUntilNeeded() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "favicons-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = URL(string: "http://127.0.0.1:1/first")!
        let second = URL(string: "http://127.0.0.1:1/second")!
        SessionStore.save(Session(tabs: [.init(url: first, title: "First", customTitle: nil, pinID: nil),
                                         .init(url: second, title: "Second", customTitle: nil, pinID: nil)], selectedIndex: 0))
        defer { SessionStore.save(Session()) }
        let writes = SessionStore.writes

        let browser = Browser(favicons: Favicons(folder: folder))
        defer { browser.tabs.forEach(browser.close) }
        #expect(SessionStore.writes == writes)
        let tab = try #require(browser.tabs.first { $0.url == second })
        #expect(tab.isAsleep && !tab.hasConfiguration && tab.loadedWebView == nil)

        // Cached after launch, the icon is still the one the tab shows: it is read when asked for.
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
                                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: folder.appending(path: "127.0.0.1.png"))
        #expect(tab.faviconData == png)
        #expect(tab.favicon != nil)

        browser.select(tab)
        #expect(!tab.isAsleep && tab.hasConfiguration && tab.loadedWebView != nil)
        #expect(tab.loadedWebView?.configuration.webExtensionController === browser.extensions.controller)
    }

    /// A web app showing another view (pushState) is searched again, so the find bar's count is the new view's.
    @Test func findSearchesAgainWhenAWebAppChangesView() async throws {
        let (listener, base) = try await LocalHTTP.serve(["/": ("Content-Type: text/html", "<title>App</title><p>needle</p><p>needle</p><p>needle</p>")])
        defer { listener.cancel() }
        let browser = Browser()
        let tab = browser.newTab(url: base)
        defer { browser.close(tab) }
        #expect(await waitUntil(30) { tab.title == "App" && !tab.isLoading })
        // The size a window gives it: unsized, the page lays nothing out and has no text to find.
        tab.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        browser.find.show(focusingField: false)
        defer { browser.find.hide() }
        await browser.find.update(query: "needle", in: tab.findTarget)
        #expect(browser.find.matchCount == 3)

        _ = try await tab.webView.callAsyncJavaScript("document.body.innerHTML = '<p>needle</p>'; history.pushState(null, '', '/next');", contentWorld: .page)
        #expect(await waitUntil(10) { browser.find.matchCount == 1 && browser.find.currentMatch == 1 })
    }

    /// Closing the tab the find bar is over closes the bar, as selecting another tab does: left
    /// open, it would search the tab shown next and scroll it to the first match.
    @Test func closingTheSelectedTabClosesTheFindBar() async throws {
        let browser = Browser()
        let kept = browser.newTab(url: URL(string: "about:blank")!)
        defer { browser.close(kept) }
        let other = browser.newTab(url: URL(string: "about:blank")!)
        defer { browser.close(other) }
        let closed = browser.newTab(url: URL(string: "about:blank")!)
        browser.find.show(focusingField: false)
        defer { browser.find.hide() }

        // A tab closing behind the selected one leaves the bar where it is.
        browser.close(other)
        #expect(browser.selectedTab === closed && browser.find.isVisible)
        browser.close(closed)
        #expect(browser.selectedTab != nil && browser.selectedTab !== closed)
        #expect(!browser.find.isVisible)
    }

    /// A bar over a link's window isn't the closing tab's: closing the selected tab leaves it open.
    @Test func closingTheSelectedTabKeepsALinksFindBar() async throws {
        let browser = Browser()
        // Stands in for the link's tab: the bar only checks that it's over one.
        let kept = browser.newTab(url: URL(string: "about:blank")!)
        defer { browser.close(kept) }
        let closed = browser.newTab(url: URL(string: "about:blank")!)
        browser.find.show(focusingField: false, inLink: kept)
        defer { browser.find.hide() }

        browser.close(closed)
        #expect(browser.find.isVisible && browser.find.linkTab === kept)
    }

    /// A wide page clips sideways overflow; a split pane's width or zooming in leaves it scrollable,
    /// so a fixed-width layout's right side can still be reached. So does a layout wider than the
    /// view: only overflow about a scrollbar wide is clipped.
    @Test func onlyWideViewsClipSidewaysOverflow() async throws {
        let (listener, base) = try await LocalHTTP.serve([
            "/": ("Content-Type: text/html", "<!doctype html><title>Wide</title><div style='width: calc(100vw + 15px)'>wide</div>"),
            "/layout": ("Content-Type: text/html", "<!doctype html><title>Layout</title><div style='width: 1500px'>layout</div>"),
        ])
        defer { listener.cancel() }
        let browser = Browser()
        let layout = browser.newTab(url: base.appending(path: "layout"))
        defer { browser.close(layout) }
        // Sized before it loads: the width is measured at load.
        layout.webView.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let tab = browser.newTab(url: base)
        defer { browser.close(tab) }
        tab.webView.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        #expect(await waitUntil(30) { tab.title == "Wide" && !tab.isLoading && layout.title == "Layout" && !layout.isLoading })
        let overflow = { (tab: Tab, expected: String) in
            await self.pollValue(10) {
                let value = try? await tab.webView.evaluateJavaScript("getComputedStyle(document.documentElement).overflowX") as? String
                return value == expected ? value : nil
            } != nil
        }
        #expect(await overflow(layout, "visible"))
        #expect(await overflow(tab, "clip"))
        tab.webView.pageZoom = 1.5
        #expect(await overflow(tab, "visible"))
        tab.webView.pageZoom = 1
        #expect(await overflow(tab, "clip"))
        tab.webView.frame = NSRect(x: 0, y: 0, width: 700, height: 800)
        #expect(await overflow(tab, "visible"))
    }

    /// The session is restored before NSApplication exists, so a settings tab can't ask NSApp for its icon.
    @Test func restoresAnInternalTabAtLaunch() throws {
        SessionStore.save(Session(tabs: [.init(url: Internal.settingsURL, title: "Settings", customTitle: nil, pinID: nil)], selectedIndex: 0))
        let browser = Browser()
        let tab = try #require(browser.selectedTab)
        #expect(tab.url == Internal.settingsURL)
        #expect(tab.favicon != nil)
    }

    /// Return in the address bar sends the text to the tab it was typed for, even once the
    /// selection moved on its own (a download-only tab closing, a popup closed by its page); to a
    /// new tab once that tab is gone, never to the one now shown.
    @Test func typedAddressGoesToTheTabBeingEdited() throws {
        let browser = Browser()
        let opener = browser.newTab(url: URL(string: "data:text/html,opener")!)
        let edited = browser.newTab(url: URL(string: "data:text/html,edited")!)
        defer { browser.tabs.forEach(browser.close) }
        let typed = URL(string: "data:text/html,typed")!

        browser.select(opener)
        browser.submitAddress(typed.absoluteString, editing: edited.id)
        #expect(edited.url == typed)
        #expect(opener.url == URL(string: "data:text/html,opener"))
        #expect(browser.selectedTab === edited)

        let gone = edited.id
        browser.close(edited)
        #expect(browser.selectedTab === opener)
        let count = browser.tabs.count
        browser.submitAddress(typed.absoluteString, editing: gone)
        #expect(browser.tabs.count == count + 1)
        #expect(opener.url == URL(string: "data:text/html,opener"))
        let opened = try #require(browser.selectedTab)
        #expect(opened !== opener)
        #expect(opened.url == typed)
    }

    /// A typed `mailto:` address goes to Mail (only recorded in tests); the tab stays on its page.
    @Test func typedMailtoGoesToMail() {
        let browser = Browser()
        let page = URL(string: "data:text/html,page")!
        let tab = browser.newTab(url: page)
        defer { browser.close(tab) }
        let mail = URL(string: "mailto:alice@example.com")!
        let (before, count) = (ExternalApps.recorded, browser.tabs.count)
        browser.submitAddress(mail.absoluteString)
        #expect(ExternalApps.recorded == before + [.open(mail)])
        #expect(tab.url == page)
        #expect(browser.tabs.count == count)
    }

    /// A tab out of sight waits to be selected; the visible one reloads once, then stops.
    @Test func crashedTabs() async throws {
        let browser = Browser()
        let visible = browser.newTab(url: URL(string: "data:text/html,<title>Visible</title>visible")!)
        let background = browser.newTab(url: URL(string: "data:text/html,<title>Background</title>background")!, selecting: false)
        #expect(await waitUntil(120) { loaded(visible) && loaded(background) })

        try crash(background)
        #expect(await waitUntil(5) { background.isAsleep })
        #expect(pid(background) == 0)

        var before = pid(visible)
        try crash(visible)
        #expect(await waitUntil(5) { pid(visible) != before && loaded(visible) })
        #expect(visible.webView.title == "Visible")

        before = pid(visible)
        try crash(visible)
        #expect(await waitUntil(5) { visible.webView.title == "Can’t open this page" })

        browser.select(background)
        #expect(await waitUntil(10) { loaded(background) })
        #expect(background.webView.title == "Background")
    }

    /// A tab whose first page never committed loads its address on Reload, and after its process
    /// ends, rather than staying blank.
    @Test func aTabThatNeverShowedItsPageLoadsItAgain() async {
        let browser = Browser()
        let first = browser.newTab(url: URL(string: "data:text/html,<title>First</title>first")!)
        defer { browser.close(first) }
        first.stopLoading()
        #expect(first.webView.backForwardList.currentItem == nil)
        first.reload()
        #expect(await waitUntil(120) { loaded(first) && first.webView.title == "First" })

        let second = browser.newTab(url: URL(string: "data:text/html,<title>Second</title>second")!)
        defer { browser.close(second) }
        second.stopLoading()
        #expect(second.webView.backForwardList.currentItem == nil)
        second.webViewWebContentProcessDidTerminate(second.webView)
        #expect(await waitUntil(120) { loaded(second) && second.webView.title == "Second" })
    }

    /// The sidebar opens as the user left it, and a screenshot's passing flip is not remembered.
    @Test func sidebarVisibilitySurvivesRelaunch() {
        UserDefaults.standard.removeObject(forKey: Preference.sidebarVisible)
        defer { UserDefaults.standard.removeObject(forKey: Preference.sidebarVisible) }
        let first = Browser()
        #expect(first.isSidebarVisible == true)

        first.toggleSidebar()
        #expect(Browser().isSidebarVisible == false)

        first.isSidebarVisible = true
        #expect(Browser().isSidebarVisible == false)
    }

    /// A background tab sleeps after 10 minutes, or 5 while the Mac saves energy, which a test can't control.
    @Test func backgroundTabsSleepAfterTenMinutes() {
        UserDefaults.standard.removeObject(forKey: "tabIdleSeconds")
        #expect(Browser.tabIdleInterval == 10 * 60 || Browser.tabIdleInterval == Browser.shortIdleInterval)
    }

    /// Switching tabs quickly while tabs fall asleep every few milliseconds never puts the selected one to sleep.
    @Test func selectedTabNeverFallsAsleep() async throws {
        UserDefaults.standard.set(0.002, forKey: "tabIdleSeconds")
        defer { UserDefaults.standard.removeObject(forKey: "tabIdleSeconds") }
        let browser = Browser()
        let first = browser.newTab(url: URL(string: "data:text/html,first")!)
        let second = browser.newTab(url: URL(string: "data:text/html,second")!)
        #expect(await waitUntil(120) { loaded(second) })
        for _ in 0..<200 {
            browser.select(second)
            // Not skipped: a selected tab that never loads is what this test is for.
            guard await waitUntil(5, { loaded(second) }) else { Issue.record("the selected tab didn't load"); break }
            browser.select(first)
            try await Task.sleep(for: .microseconds(Int.random(in: 1_500...3_500)))
            browser.select(second)
            try await Task.sleep(for: .milliseconds(5))
            #expect(!second.isAsleep, "the selected tab was put to sleep")
            if second.isAsleep { break }
        }
    }

    /// From the home page, the next tab is the first one and the previous tab the last one.
    @Test func adjacentTabFromHomeStartsAtTheEnds() {
        // Other tests may leave a session behind, so the order is read rather than assumed.
        let browser = Browser()
        browser.newTab(url: URL(string: "data:text/html,one")!)
        browser.newTab(url: URL(string: "data:text/html,two")!)
        browser.newTabFocusingAddress()
        browser.selectAdjacentTab(1)
        #expect(browser.selectedTabID == browser.navigationOrder.first?.id)
        browser.newTabFocusingAddress()
        browser.selectAdjacentTab(-1)
        #expect(browser.selectedTabID == browser.navigationOrder.last?.id)
    }

    /// Closing the last tab of the list shows the start page, not a favorite's live page.
    @Test func closingTheLastTabShowsHomeNotAFavorite() {
        let browser = Browser()
        browser.regularTabs.forEach(browser.close)
        let favorite = browser.newTab(url: URL(string: "data:text/html,favorite")!)
        browser.pin(favorite)
        defer { browser.pins.filter { $0.id == favorite.pinID }.forEach(browser.unpin) }
        let first = browser.newTab(url: URL(string: "data:text/html,first")!)
        let second = browser.newTab(url: URL(string: "data:text/html,second")!)

        browser.close(second)
        #expect(browser.selectedTabID == first.id)
        browser.close(first)
        #expect(browser.selectedTabID == nil)

        let third = browser.newTab(url: URL(string: "data:text/html,third")!)
        browser.select(favorite)
        browser.close(favorite)
        #expect(browser.selectedTabID == third.id)
    }

    /// A page downloads what it can't show; a frame inside it (an ad, or a site's Download button
    /// pointing a hidden frame at the file) asks first, as in Safari, once for all its frames.
    /// Served over HTTP: WebKit itself never downloads a data: frame.
    @Test func aFrameAsksBeforeDownloading() async throws {
        let (listener, base) = try await LocalHTTP.serve([
            "/": ("Content-Type: text/html", #"<iframe src="/file"></iframe><iframe src="/attachment"></iframe>"#),
            "/file": ("Content-Type: application/octet-stream", "Lithium"),
            "/attachment": ("Content-Type: text/plain\r\nContent-Disposition: attachment; filename=note.txt", "Lithium"),
        ])
        defer { listener.cancel() }
        let browser = Browser()
        let host = try #require(base.host())
        defer { browser.permissions.set(nil, for: .downloads, host: host) }
        let before = Downloads.shared.items.count
        let page = browser.newTab(url: base)
        #expect(await waitUntil(30) { browser.permissions.pending.contains { $0.tabID == page.id } })
        try await Task.sleep(for: .seconds(1))
        let asked = browser.permissions.pending.filter { $0.tabID == page.id }
        #expect(asked.count == 1)
        let request = try #require(asked.first)
        #expect(request.kinds == [.downloads] && request.host == host)
        #expect(Downloads.shared.items.count == before)

        browser.permissions.answer(request, allow: true)
        #expect(await waitUntil(30) { Downloads.shared.items.count == before + 2 })

        browser.newTab(url: base.appending(path: "file"))
        #expect(await waitUntil(30) { Downloads.shared.items.count == before + 3 })
        #expect(browser.permissions.pending.isEmpty, "the page itself downloads without asking")
    }

    /// A tab opened only to download a file closes itself, and Reopen Closed Tab skips it:
    /// reopened, it would only download the file again and hide the tabs closed before it.
    @Test func aTabClosedByItsDownloadIsntReopened() async throws {
        let (listener, base) = try await LocalHTTP.serve(["/file": ("Content-Type: application/octet-stream", "Lithium")])
        defer { listener.cancel() }
        let browser = Browser()
        let page = URL(string: "data:text/html,closed")!
        browser.close(browser.newTab(url: page))
        let before = Downloads.shared.items.count
        let downloading = browser.newTab(url: base.appending(path: "file"))
        #expect(await waitUntil(30) { Downloads.shared.items.count == before + 1 && !browser.tabs.contains { $0 === downloading } })
        let item = try #require(Downloads.shared.items.first)
        #expect(await waitUntil(30) { item.state != .downloading })
        if let file = item.destination { try? FileManager.default.removeItem(at: file) }

        browser.reopenClosedTab()
        #expect(browser.selectedTab?.url == page)
        if let reopened = browser.selectedTab { browser.close(reopened) }
    }

    /// A sign-in window that closes itself once done isn't a tab the user closed: Reopen Closed Tab
    /// skips it for the tab closed before it.
    @Test func aPopupThatClosesItselfIsntReopened() async throws {
        let (listener, base) = try await LocalHTTP.serve([
            "/": ("Content-Type: text/html", #"<title>Opener</title><button id="signin" onclick="window.open('/popup', '', 'width=400,height=300')">Sign in</button>"#),
            "/popup": ("Content-Type: text/html", "<title>Popup</title>"),
        ])
        defer { listener.cancel() }
        let browser = Browser()
        let page = URL(string: "data:text/html,closed")!
        browser.close(browser.newTab(url: page))
        let opener = browser.newTab(url: base)
        defer { browser.close(opener, remembering: false) }
        #expect(await waitUntil(30) { opener.title == "Opener" && !opener.isLoading })
        _ = try await opener.webView.evaluateJavaScript("document.getElementById('signin').click(); 0")
        #expect(await waitUntil(30) { browser.tabs.contains { $0.scriptOpener === opener && $0.title == "Popup" && !$0.isLoading } })
        let popup = try #require(browser.tabs.first { $0.scriptOpener === opener })
        _ = try await popup.webView.evaluateJavaScript("window.close(); 0")
        #expect(await waitUntil(30) { !browser.tabs.contains { $0 === popup } })

        browser.reopenClosedTab()
        #expect(browser.selectedTab?.url == page)
        if let reopened = browser.selectedTab { browser.close(reopened, remembering: false) }
    }

    /// A tab opened by no page (a typed address, a link from another app) that only fetched a file
    /// gives back what it was opened over, a tab or the start page, not the tab at the top of the list.
    @Test func aTabClosedByItsDownloadGoesBackToWhatWasShown() async throws {
        let (listener, base) = try await LocalHTTP.serve(["/file": ("Content-Type: application/octet-stream", "Lithium")])
        defer { listener.cancel() }
        let browser = Browser()
        let shown = browser.newTab(url: URL(string: "data:text/html,shown")!)
        let top = browser.newTab(url: URL(string: "data:text/html,top")!)
        defer { [shown, top].forEach(browser.close) }
        browser.select(shown)
        let before = Downloads.shared.items.count
        defer { Downloads.shared.items.prefix(Downloads.shared.items.count - before).compactMap(\.destination).forEach { try? FileManager.default.removeItem(at: $0) } }

        let first = browser.newTab(url: base.appending(path: "file"))
        #expect(await waitUntil(30) { !browser.tabs.contains { $0 === first } })
        #expect(browser.selectedTab === shown)

        browser.newTabFocusingAddress()
        let second = browser.newTab(url: base.appending(path: "file"))
        #expect(await waitUntil(30) { !browser.tabs.contains { $0 === second } })
        #expect(browser.selectedTabID == nil)
        #expect(await waitUntil(30) { Downloads.shared.items.prefix(2).allSatisfy { $0.state != .downloading } })
    }

    /// A tab from the last session wakes without its history: if its address now answers with a
    /// file, the file downloads and the tab stays, unlike one opened just to fetch it.
    @Test func aRestoredTabWhoseAddressNowDownloadsStays() async throws {
        let (listener, base) = try await LocalHTTP.serve([
            "/report": ("Content-Type: text/plain\r\nContent-Disposition: attachment; filename=note.txt", "Lithium"),
        ])
        defer { listener.cancel() }
        SessionStore.save(Session(tabs: [
            .init(url: URL(string: "data:text/html,first")!, title: "First"),
            .init(url: base.appending(path: "report"), title: "Report"),
        ], selectedIndex: 0))
        defer { SessionStore.save(Session()) }
        let browser = Browser()
        let restored = try #require(browser.tabs.last)
        #expect(restored.isAsleep)
        let before = Downloads.shared.items.count
        browser.select(restored)
        #expect(await waitUntil(30) { Downloads.shared.items.count == before + 1 })
        let item = try #require(Downloads.shared.items.first)
        #expect(await waitUntil(30) { item.state != .downloading })
        if let file = item.destination { try? FileManager.default.removeItem(at: file) }
        #expect(browser.tabs.contains { $0 === restored })
    }

    /// A frame's `<a download>` asks too, like its attachments: it isn't the page the user is on.
    @Test func aFramesDownloadLinkAsksFirst() async throws {
        let (listener, base) = try await LocalHTTP.serve([
            "/": ("Content-Type: text/html", #"<iframe src="/frame"></iframe>"#),
            "/frame": ("Content-Type: text/html", #"<a id="file" href="/note.txt" download>Note</a><script>document.getElementById('file').click()</script>"#),
            "/note.txt": ("Content-Type: text/plain", "Lithium"),
        ])
        defer { listener.cancel() }
        let browser = Browser()
        let host = try #require(base.host())
        let before = Downloads.shared.items.count
        let page = browser.newTab(url: base)
        defer { browser.close(page) }
        #expect(await waitUntil(30) { browser.permissions.pending.contains { $0.tabID == page.id } })
        let request = try #require(browser.permissions.pending.first { $0.tabID == page.id })
        #expect(request.kinds == [.downloads] && request.host == host)
        #expect(Downloads.shared.items.count == before)

        browser.permissions.dismiss(request)
        try await Task.sleep(for: .seconds(1))
        #expect(Downloads.shared.items.count == before)
    }

    /// A page sending itself to a file, or clicking its own `<a download>`, without a press asks
    /// first: otherwise any page could fill Downloads. (The address the user opens still
    /// downloads: see `aFrameAsksBeforeDownloading`.)
    @Test func aPageDownloadingWithoutAClickAsksFirst() async throws {
        let (listener, base) = try await LocalHTTP.serve([
            "/sends": ("Content-Type: text/html", "<script>location.href = '/file'</script>"),
            "/clicks": ("Content-Type: text/html", #"<a id="file" href="/note.txt" download>Note</a><script>document.getElementById('file').click()</script>"#),
            "/file": ("Content-Type: text/plain\r\nContent-Disposition: attachment; filename=note.txt", "Lithium"),
            "/note.txt": ("Content-Type: text/plain", "Lithium"),
        ])
        defer { listener.cancel() }
        let browser = Browser()
        let host = try #require(base.host())
        let before = Downloads.shared.items.count
        for path in ["sends", "clicks"] {
            let page = browser.newTab(url: base.appending(path: path))
            defer { browser.close(page) }
            #expect(await waitUntil(30) { browser.permissions.pending.contains { $0.tabID == page.id } }, "\(path)")
            let request = try #require(browser.permissions.pending.first { $0.tabID == page.id })
            #expect(request.kinds == [.downloads] && request.host == host)
            browser.permissions.dismiss(request)
        }
        try await Task.sleep(for: .seconds(1))
        #expect(Downloads.shared.items.count == before)
        #expect(browser.permissions.decisions[host]?[.downloads] == nil, "nothing is remembered")
    }

    /// A page reloading itself into a file (`history.go(0)` comes as a Reload, as the user's would)
    /// asks first, or it could download again and again; the user's own Reload doesn't ask.
    @Test func aPageReloadingItselfIntoADownloadAsksFirst() async throws {
        let (listener, base) = try await LocalHTTP.serve([
            "/reloads": ("Content-Type: text/html", "<script>history.replaceState(null, '', '/file'); history.go(0)</script>"),
            "/file": ("Content-Type: text/plain\r\nContent-Disposition: attachment; filename=note.txt", "Lithium"),
        ])
        defer { listener.cancel() }
        let browser = Browser()
        let host = try #require(base.host())
        let before = Downloads.shared.items.count
        let page = browser.newTab(url: base.appending(path: "reloads"))
        defer { browser.close(page) }
        #expect(await waitUntil(30) { browser.permissions.pending.contains { $0.tabID == page.id } })
        let request = try #require(browser.permissions.pending.first { $0.tabID == page.id })
        #expect(request.kinds == [.downloads] && request.host == host)
        browser.permissions.dismiss(request)
        try await Task.sleep(for: .seconds(1))
        #expect(Downloads.shared.items.count == before)

        browser.navigate(page, .reload)
        #expect(await waitUntil(30) { Downloads.shared.items.count == before + 1 })
        #expect(!browser.permissions.pending.contains { $0.tabID == page.id })
        let item = try #require(Downloads.shared.items.first)
        #expect(await waitUntil(30) { item.state != .downloading })
        if let file = item.destination { try? FileManager.default.removeItem(at: file) }
    }

    /// A private tab's answer holds for its private session only, in memory: nothing is saved,
    /// normal tabs still ask, and it goes when the session's last tab closes.
    @Test func privateTabPermissionsStayInTheirSession() async throws {
        let browser = Browser()
        let store = WKWebsiteDataStore.nonPersistent()
        let tab = browser.newTab(url: URL(string: "data:text/html,private")!, selecting: false, privateStore: store)
        let session = try #require(tab.privateSession)
        // Asked by the page shown: its commit would cancel a prompt asked before.
        #expect(await waitUntil(10) { tab.loadedWebView?.isLoading == false })
        let host = "private-\(UUID().uuidString.lowercased()).example"
        let permissions = browser.permissions
        func ask(_ privateSession: ObjectIdentifier?, tabID: Tab.ID) -> Task<Bool, Never> {
            Task { await permissions.request([.camera], host: host, tabID: tabID, privateSession: privateSession) }
        }
        func prompt(for tabID: Tab.ID) async -> PermissionRequest? {
            _ = await waitUntil(10) { permissions.pending.contains { $0.tabID == tabID } }
            return permissions.pending.first { $0.tabID == tabID }
        }

        let first = ask(session, tabID: tab.id)
        permissions.answer(try #require(await prompt(for: tab.id)), allow: true)
        #expect(await first.value)
        #expect(permissions.decisions[host] == nil)
        let saved = UserDefaults.standard.dictionary(forKey: "sitePermissions") ?? [:]
        #expect(saved[host] == nil, "nothing written to disk")
        #expect(await ask(session, tabID: tab.id).value, "remembered in the session")

        let normalTab = UUID()
        let normal = ask(nil, tabID: normalTab)
        permissions.dismiss(try #require(await prompt(for: normalTab)))
        #expect(await normal.value == false)

        browser.close(tab)
        let again = ask(session, tabID: tab.id)
        permissions.dismiss(try #require(await prompt(for: tab.id)))
        #expect(await again.value == false, "forgotten with its last tab")
    }

    /// Protections and the site's font changed in a private tab hold for its private session
    /// only, in memory; the lock panel shows that session's permission answers.
    @Test func privateTabSiteSettingsStayInTheirSession() async throws {
        let browser = Browser()
        let tab = browser.newTab(url: URL(string: "data:text/html,private")!, selecting: false, privateStore: .nonPersistent())
        let session = try #require(tab.privateSession)
        // Asked by the page shown: its commit would cancel a prompt asked before.
        #expect(await waitUntil(10) { tab.loadedWebView?.isLoading == false })
        let host = "private-\(UUID().uuidString.lowercased()).example"
        let url = try #require(URL(string: "https://\(host)/"))
        let privacy = browser.privacy

        privacy.setEnabled(false, for: url, privateSession: session)
        #expect(!privacy.isEnabled(for: url, privateSession: session))
        #expect(privacy.isEnabled(for: url), "normal tabs keep protections")
        #expect(!privacy.disabledHosts.contains(host))
        #expect(UserDefaults.standard.stringArray(forKey: "disabledProtectionHosts")?.contains(host) != true, "nothing written to disk")

        PageStyle.setKeepsSiteFont(true, for: host, privateSession: session)
        #expect(PageStyle.keepsSiteFont(host, privateSession: session))
        #expect(!PageStyle.keepsSiteFont(host))
        #expect(!PageStyle.siteFontDomains.contains(host), "nothing written to disk")

        let request = Task { await browser.permissions.request([.camera], host: host, tabID: tab.id, privateSession: session) }
        #expect(await waitUntil(10) { browser.permissions.pending.contains { $0.tabID == tab.id } })
        browser.permissions.answer(try #require(browser.permissions.pending.first { $0.tabID == tab.id }), allow: true)
        #expect(await request.value)
        #expect(browser.permissions.decisions(for: host, privateSession: session) == [.camera: .allow])
        #expect(browser.permissions.decisions(for: host, privateSession: nil).isEmpty)

        browser.close(tab)
        #expect(privacy.isEnabled(for: url, privateSession: session), "forgotten with its last tab")
        #expect(!PageStyle.keepsSiteFont(host, privateSession: session))
    }

    /// Settings' exceptions list turns protections back on by the host it shows, an IPv6 one too.
    @Test func protectionsComeBackOnForAnIPv6Host() throws {
        let privacy = Privacy()
        let url = try #require(URL(string: "http://[::1]:8080/page"))
        privacy.setEnabled(false, for: url)
        defer { privacy.setEnabled(true, for: url) }
        #expect(!privacy.isEnabled(for: url))
        let host = try #require(privacy.disabledHosts.first { $0.contains("::1") })

        privacy.setEnabled(true, host: host)
        #expect(privacy.isEnabled(for: url))
        #expect(!privacy.disabledHosts.contains(host))
        #expect(Privacy().isEnabled(for: url), "saved")
    }

    /// Lithium's error page names itself "Can’t open this page": that title stays on the tab, and
    /// never replaces the page's in the history or in the saved session.
    @Test func errorPageTitleStaysOutOfHistoryAndSession() async throws {
        let browser = Browser()
        let tab = browser.newTab(url: URL(string: "about:blank")!)
        defer { browser.close(tab) }
        #expect(await waitUntil(10) { tab.loadedWebView?.isLoading == false })
        let host = "error-\(UUID().uuidString.lowercased()).example"
        let url = try #require(URL(string: "https://\(host)/"))
        tab.webView.loadHTMLString("<title>Real</title>", baseURL: url)
        #expect(await waitUntil(10) { browser.history.visits(matching: host).first?.title == "Real" })

        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost, userInfo: [NSURLErrorFailingURLErrorKey: url])
        tab.webView(tab.webView, didFailProvisionalNavigation: nil, withError: error)
        #expect(await waitUntil(10) { tab.title == "Can’t open this page" })
        browser.saveNow()
        #expect(browser.history.visits(matching: host).map(\.title) == ["Real"])
        #expect(SessionStore.load().tabs.first { $0.url == url }?.title == "")

        // The next page's title is the page's again.
        tab.webView.loadHTMLString("<title>Fine</title>", baseURL: url)
        #expect(await waitUntil(10) { tab.title == "Fine" })
        browser.saveNow()
        #expect(browser.history.visits(matching: host).map(\.title) == ["Fine"])
        #expect(SessionStore.load().tabs.first { $0.url == url }?.title == "Fine")
    }

    /// Lithium's error page gets no history entry of its own (`loadHTMLString`): Back from the
    /// next page goes to the page before the error, and that page is the page, not the error.
    @Test func pageBeforeTheErrorIsNotTheErrorOnBack() async throws {
        let (listener, base) = try await LocalHTTP.serve([
            "/": ("Content-Type: text/html", "<title>Home</title>"),
            "/next": ("Content-Type: text/html", "<title>Next</title>"),
        ])
        defer { listener.cancel() }
        let browser = Browser()
        let tab = browser.newTab(url: base)
        defer { browser.close(tab) }
        #expect(await waitUntil(10) { tab.title == "Home" && tab.loadedWebView?.isLoading == false })
        tab.load(URL(string: "http://127.0.0.1:1/")!)
        #expect(await waitUntil(10) { tab.title == "Can’t open this page" && tab.loadedWebView?.isLoading == false })
        #expect(tab.isShowingError)

        tab.load(base.appending(path: "next"))
        #expect(await waitUntil(10) { tab.title == "Next" && tab.loadedWebView?.isLoading == false })
        tab.webView.goBack()
        #expect(await waitUntil(10) { tab.title == "Home" && tab.loadedWebView?.isLoading == false })
        #expect(tab.url == base)
        #expect(!tab.isShowingError)
        #expect(tab.loadError == nil)
    }

    /// Reload on the error page loads the address as a page of its own: that page, then left and
    /// come back to with Back, is the page, not the error.
    @Test func pageReloadedOverTheErrorPageIsNotTheErrorOnBack() async throws {
        let (listener, base) = try await LocalHTTP.serve([
            "/": ("Content-Type: text/html", "<title>Back up</title>"),
            "/next": ("Content-Type: text/html", "<title>Next</title>"),
        ])
        defer { listener.cancel() }
        let browser = Browser()
        let tab = browser.newTab(url: URL(string: "about:blank")!)
        defer { browser.close(tab) }
        #expect(await waitUntil(10) { tab.loadedWebView?.isLoading == false })

        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, userInfo: [NSURLErrorFailingURLErrorKey: base])
        tab.webView(tab.webView, didFailProvisionalNavigation: nil, withError: error)
        #expect(await waitUntil(10) { tab.title == "Can’t open this page" && tab.loadedWebView?.isLoading == false })
        tab.reload()
        #expect(await waitUntil(10) { tab.title == "Back up" && tab.loadedWebView?.isLoading == false })
        #expect(!tab.isShowingError)

        tab.load(base.appending(path: "next"))
        #expect(await waitUntil(10) { tab.title == "Next" && tab.loadedWebView?.isLoading == false })
        tab.webView.goBack()
        #expect(await waitUntil(10) { tab.url == base && tab.loadedWebView?.isLoading == false })
        #expect(!tab.isShowingError)
        #expect(tab.title == "Back up")
    }

    /// Private tabs (an agent's ephemeral tab, its popups and copies) are kept from extensions,
    /// as Chrome keeps incognito from extensions not allowed there: not in the tab list, never the
    /// active tab (the last normal tab stays it), and no extension running in their pages.
    @Test func privateTabsAreHiddenFromExtensions() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "extension-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"manifest_version": 3, "name": "Tiny", "version": "1.0"}"#.utf8).write(to: folder.appending(path: "manifest.json"))
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))

        let browser = Browser()
        let normal = browser.newTab(url: URL(string: "data:text/html,normal")!)
        let agentTab = browser.newAgentTab(session: "s1", privateStore: .nonPersistent())
        let popup = browser.newTab(url: URL(string: "data:text/html,popup")!, privateStore: agentTab.privateStore, openedFrom: agentTab)
        defer { [normal, agentTab, popup].forEach(browser.close) }
        let window = browser.extensions.window
        let listed = window.tabs(for: context).compactMap { $0 as? Lithium.Tab }

        #expect(listed.contains { $0 === normal })
        #expect(!listed.contains { $0 === agentTab || $0 === popup })
        #expect(popup.indexInWindow(for: context) == NSNotFound)
        #expect(browser.selectedTab === popup)
        #expect(window.activeTab(for: context) as? Lithium.Tab === normal, "a private tab shown is no extension's active tab")
        #expect(popup.webView.configuration.webExtensionController == nil)
        #expect(agentTab.webView.configuration.webExtensionController == nil)
        #expect(normal.webView.configuration.webExtensionController === browser.extensions.controller)

        browser.select(normal)
        #expect(window.activeTab(for: context) as? Lithium.Tab === normal)

        // An extension showing a tab isn't the user's pick: their address-bar typing goes on.
        let picks = browser.tabPickToken
        try await popup.activate(for: context)
        #expect(browser.selectedTab === popup)
        #expect(browser.tabPickToken == picks)
    }

    /// Double-clicking a tab and clicking away leaves it without a name of its own: its page's
    /// later titles still show.
    @Test func aRenameLeftAsShownKeepsThePageTitle() async throws {
        let browser = Browser()
        let tab = browser.newTab(url: URL(string: "data:text/html,<title>First</title>")!)
        defer { browser.close(tab) }
        #expect(await waitUntil(10) { tab.displayTitle == "First" })

        browser.renamingTabID = tab.id
        browser.rename(tab, to: "First", shown: tab.displayTitle)
        #expect(tab.customTitle == nil)
        #expect(browser.renamingTabID == nil)
        browser.rename(tab, to: " Mine ", shown: "First")
        #expect(tab.customTitle == "Mine")
        // A name of its own, left as shown, stays.
        browser.rename(tab, to: "Mine", shown: "Mine")
        #expect(tab.customTitle == "Mine")
        browser.rename(tab, to: "", shown: "Mine")
        #expect(tab.customTitle == nil)
    }

    /// A click on a suggestion goes to the tab being edited, as Return does: to a new tab once
    /// that one is gone, never to the one now shown.
    @Test func clickedSuggestionGoesToTheTabBeingEdited() throws {
        let browser = Browser()
        let opener = browser.newTab(url: URL(string: "data:text/html,opener")!)
        let edited = browser.newTab(url: URL(string: "data:text/html,edited")!)
        defer { browser.tabs.forEach(browser.close) }
        let typed = URL(string: "data:text/html,typed")!

        browser.suggestions.editedTabID = edited.id
        browser.close(edited)
        #expect(browser.selectedTab === opener)
        let count = browser.tabs.count
        browser.accept(.address(typed))
        #expect(browser.tabs.count == count + 1)
        #expect(opener.url == URL(string: "data:text/html,opener"))
        #expect(browser.selectedTab?.url == typed)
    }

    /// Settings' "Use … on websites" changes the font of open pages in place, both ways, without
    /// reloading them.
    @Test func websiteFontSettingAppliesToOpenPagesWithoutReload() async throws {
        let browser = Browser()
        let tab = browser.newTab(url: URL(string: "data:text/html,<p>page</p>")!)
        defer { browser.close(tab) }
        let original = PageStyle.usesFontEverywhere
        defer { PageStyle.usesFontEverywhere = original }
        #expect(await waitUntil(10) { tab.loadedWebView?.isLoading == false })
        _ = try await tab.webView.callAsyncJavaScript("window.marked = true", contentWorld: .page)
        let usesFont = { () async -> Bool? in
            (try? await tab.webView.callAsyncJavaScript(
                "return getComputedStyle(document.querySelector('p')).fontFamily.split(',')[0].replace(/\"/g, '').trim() === 'Lithium DM Sans'",
                contentWorld: .page)) as? Bool
        }
        try #require(PageStyle.websiteFamily == FontChoice.dmSans)
        #expect(await usesFont() == original)

        for on in [!original, original] {
            browser.changePageFont { PageStyle.usesFontEverywhere = on }
            var applied = false
            for _ in 0..<50 where !applied {
                try await Task.sleep(for: .milliseconds(100))
                applied = await usesFont() == on
            }
            #expect(applied, "font \(on ? "on" : "off")")
        }
        #expect(try await tab.webView.callAsyncJavaScript("return window.marked === true", contentWorld: .page) as? Bool == true)
    }

    /// A tab closed or pinned while its name was being edited ends the rename: its field went
    /// with its row, and the rename would otherwise hold Escape and the agent.
    @Test func closingOrPinningARenamedTabEndsTheRename() {
        let browser = Browser()
        let closed = browser.newTab(url: URL(string: "data:text/html,closed")!, selecting: false)
        browser.renamingTabID = closed.id
        browser.close(closed)
        #expect(browser.renamingTabID == nil)

        let pinned = browser.newTab(url: URL(string: "data:text/html,pinned")!, selecting: false)
        defer { browser.pins.filter { $0.id == pinned.pinID }.forEach(browser.unpin) }
        browser.renamingTabID = pinned.id
        browser.pin(pinned)
        #expect(pinned.pinID != nil)
        #expect(browser.renamingTabID == nil)

        // Another tab's rename goes on.
        let other = browser.newTab(url: URL(string: "data:text/html,other")!, selecting: false)
        let renamed = browser.newTab(url: URL(string: "data:text/html,renamed")!, selecting: false)
        browser.renamingTabID = renamed.id
        browser.close(other)
        #expect(browser.renamingTabID == renamed.id)
        browser.renamingTabID = nil
        browser.close(renamed)
    }

    /// A prompt left unanswered goes away with its page: answered over the next one, it would be
    /// taken for that page's.
    @Test func aDownloadPromptGoesAwayWithItsPage() async throws {
        let (listener, base) = try await LocalHTTP.serve([
            "/": ("Content-Type: text/html", #"<iframe src="/attachment"></iframe>"#),
            "/attachment": ("Content-Type: text/plain\r\nContent-Disposition: attachment; filename=note.txt", "Lithium"),
            "/next": ("Content-Type: text/html", "<p>Next</p>"),
        ])
        defer { listener.cancel() }
        let browser = Browser()
        let host = try #require(base.host())
        let before = Downloads.shared.items.count
        let page = browser.newTab(url: base)
        defer { browser.close(page) }
        #expect(await waitUntil(30) { browser.permissions.pending.contains { $0.tabID == page.id } })

        page.load(base.appending(path: "next"))
        #expect(await waitUntil(30) { loaded(page) && page.url?.path() == "/next" })
        #expect(!browser.permissions.pending.contains { $0.tabID == page.id })
        #expect(browser.permissions.decisions[host]?[.downloads] == nil, "nothing is remembered")
        try await Task.sleep(for: .seconds(1))
        #expect(Downloads.shared.items.count == before)
    }

    /// A tab that slept wakes on the page it showed, with its back history.
    @Test func sleepingTabKeepsItsHistory() async throws {
        let browser = Browser()
        let tab = browser.newTab(url: URL(string: "data:text/html,<title>First</title>first")!)
        #expect(await waitUntil(120) { loaded(tab) })
        tab.load(URL(string: "data:text/html,<title>Second</title>second")!)
        #expect(await waitUntil(10) { loaded(tab) && tab.webView.title == "Second" })

        browser.newTab(url: URL(string: "data:text/html,other")!)
        tab.sleep(configuration: browser.makeConfiguration(for: tab.url))
        #expect(tab.isAsleep)
        browser.select(tab)
        #expect(await waitUntil(10) { loaded(tab) && tab.webView.title == "Second" })
        #expect(await waitUntil(5) { tab.canGoBack })
        tab.webView.goBack()
        #expect(await waitUntil(10) { loaded(tab) && tab.webView.title == "First" })
    }

    /// A local file's read access comes from `load`, not history: a tab with one in its history
    /// wakes on its page afresh, without a Back that would fail.
    @Test func sleepingTabDropsAHistoryWithALocalFile() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "lithium-\(UUID().uuidString).html")
        try "<title>File</title>file".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let browser = Browser()
        let tab = browser.newTab(url: file)
        #expect(await waitUntil(120) { loaded(tab) && tab.webView.title == "File" })
        tab.load(URL(string: "data:text/html,<title>Web</title>web")!)
        #expect(await waitUntil(10) { loaded(tab) && tab.webView.title == "Web" && tab.canGoBack })

        browser.newTab(url: URL(string: "data:text/html,other")!)
        tab.sleep(configuration: browser.makeConfiguration(for: tab.url))
        browser.select(tab)
        #expect(await waitUntil(10) { loaded(tab) && tab.webView.title == "Web" })
        #expect(!tab.canGoBack)
    }

    /// A tab comes back after a relaunch with its back history, saved at quit, and keeps it while
    /// asleep. Saves before quitting leave a loaded tab's out: WebKit serializes it on the main thread.
    @Test func aRelaunchKeepsATabsHistory() async throws {
        let id = UUID().uuidString
        func isSecond(_ url: URL?) -> Bool { url?.absoluteString.contains("second-\(id)") == true }
        let browser = Browser()
        let tab = browser.newTab(url: URL(string: "data:text/html,<title>First</title>first-\(id)")!)
        // Written now, not a moment into the next test, which counts writes.
        defer { browser.close(tab); browser.saveNow() }
        #expect(await waitUntil(120) { loaded(tab) })
        tab.load(URL(string: "data:text/html,<title>Second</title>second-\(id)")!)
        #expect(await waitUntil(10) { loaded(tab) && tab.webView.title == "Second" })
        #expect(await waitUntil(10) { SessionStore.load().tabs.contains { isSecond($0.url) } })
        #expect(SessionStore.load().tabs.first { isSecond($0.url) }?.history == nil, "not at every save")
        browser.saveNow()
        #expect(SessionStore.load().tabs.first { isSecond($0.url) }?.history != nil)

        let relaunched = Browser()
        let restored = try #require(relaunched.tabs.first { isSecond($0.url) })
        #expect(restored.isAsleep)
        let otherTab = relaunched.newTab(url: URL(string: "data:text/html,other-\(id)")!, selecting: false)
        defer { relaunched.close(restored); relaunched.close(otherTab); relaunched.saveNow() }
        #expect(await waitUntil(10) { SessionStore.load().tabs.contains { $0.url.absoluteString.contains("other-\(id)") } })
        #expect(SessionStore.load().tabs.first { isSecond($0.url) }?.history != nil, "kept while asleep")

        relaunched.select(restored)
        #expect(await waitUntil(10) { loaded(restored) && restored.webView.title == "Second" })
        #expect(await waitUntil(5) { restored.canGoBack })
        restored.webView.goBack()
        #expect(await waitUntil(10) { loaded(restored) && restored.webView.title == "First" })
    }

    /// Low memory spares a tab used a moment ago; critical memory puts every background tab to sleep, never the selected one.
    @Test func memoryPressureSleepsBackgroundTabs() async throws {
        let browser = Browser()
        let background = browser.newTab(url: URL(string: "data:text/html,background")!, selecting: false)
        let visible = browser.newTab(url: URL(string: "data:text/html,visible")!)
        #expect(await waitUntil(120) { loaded(background) && loaded(visible) })

        browser.relieveMemoryPressure(critical: false)
        #expect(!background.isAsleep, "a tab used a moment ago stays awake while memory is only low")
        browser.relieveMemoryPressure(critical: true)
        #expect(background.isAsleep)
        #expect(!visible.isAsleep)
    }

    /// An open favorite stays awake through idle sleep, or its unread badge would stay as it was
    /// while the page can no longer change it; critical memory still puts it to sleep.
    @Test func idleSleepSparesAnOpenFavorite() async throws {
        let browser = Browser()
        let favorite = browser.newTab(url: URL(string: "data:text/html,favorite")!, selecting: false)
        let other = browser.newTab(url: URL(string: "data:text/html,other")!, selecting: false)
        let visible = browser.newTab(url: URL(string: "data:text/html,visible")!)
        defer { [favorite, other, visible].forEach(browser.close) }
        #expect(await waitUntil(120) { [favorite, other, visible].allSatisfy(loaded) })
        browser.pin(favorite)
        defer { browser.pins.filter { $0.id == favorite.pinID }.forEach(browser.unpin) }
        UserDefaults.standard.set(1, forKey: "tabIdleSeconds")
        defer { UserDefaults.standard.removeObject(forKey: "tabIdleSeconds") }

        try await Task.sleep(for: .seconds(1.2))
        browser.relieveMemoryPressure(critical: false)
        #expect(other.isAsleep)
        #expect(!favorite.isAsleep)
        browser.relieveMemoryPressure(critical: true)
        #expect(favorite.isAsleep)
        #expect(!visible.isAsleep)
    }

    /// Asleep, a favorite's tile drops the count its page can no longer change, keeps a dot not
    /// yet seen, and its page wakes once memory is back to normal.
    @Test func aFavoriteSleptByCriticalMemoryWakesWhenItEnds() async throws {
        let browser = Browser()
        browser.favoriteWakeDelay = .milliseconds(100)
        let favorite = browser.newTab(url: URL(string: "data:text/html,<title>(3) Chat</title>chat")!, selecting: false)
        let visible = browser.newTab(url: URL(string: "data:text/html,visible")!)
        defer { [favorite, visible].forEach(browser.close) }
        #expect(await waitUntil(120) { loaded(favorite) && loaded(visible) })
        browser.pin(favorite)
        defer { browser.pins.filter { $0.id == favorite.pinID }.forEach(browser.unpin) }
        #expect(favorite.unread.shown == .count(3))

        favorite.receive(.notification)
        browser.relieveMemoryPressure(critical: true)
        #expect(favorite.isAsleep)
        #expect(favorite.unread.shown == .dot)
        try await Task.sleep(for: .milliseconds(300))
        #expect(favorite.isAsleep, "nothing wakes it before macOS says memory is normal")

        browser.memoryLevelChanged(to: .normal)
        #expect(await waitUntil(10) { !favorite.isAsleep && loaded(favorite) && favorite.unread.shown == .count(3) })
        #expect(browser.selectedTab === visible)
    }

    /// A favorite's page that crashed out of sight wakes a moment later, once: crashing again
    /// right after, it stays asleep.
    @Test func aFavoriteThatCrashedOutOfSightWakesOnce() async throws {
        let browser = Browser()
        browser.favoriteWakeDelay = .milliseconds(100)
        let favorite = browser.newTab(url: URL(string: "data:text/html,<title>Chat</title>chat")!, selecting: false)
        let visible = browser.newTab(url: URL(string: "data:text/html,visible")!)
        defer { [favorite, visible].forEach(browser.close) }
        #expect(await waitUntil(120) { loaded(favorite) && loaded(visible) })
        browser.pin(favorite)
        defer { browser.pins.filter { $0.id == favorite.pinID }.forEach(browser.unpin) }

        favorite.webViewWebContentProcessDidTerminate(favorite.webView)
        #expect(favorite.isAsleep)
        #expect(await waitUntil(10) { !favorite.isAsleep && loaded(favorite) })

        favorite.webViewWebContentProcessDidTerminate(favorite.webView)
        #expect(favorite.isAsleep)
        try await Task.sleep(for: .milliseconds(500))
        #expect(favorite.isAsleep)
    }

    /// A notification that came while the window wasn't key leaves no dot on the favorite once
    /// the user is back on its page.
    @Test func aFavoritesDotGoesWhenItsWindowBecomesKey() async {
        let browser = Browser()
        let favorite = browser.newTab(url: URL(string: "data:text/html,chat")!)
        defer { browser.close(favorite) }
        #expect(await waitUntil(120) { loaded(favorite) })
        browser.pin(favorite)
        defer { browser.pins.filter { $0.id == favorite.pinID }.forEach(browser.unpin) }
        browser.select(favorite)

        favorite.receive(.notification)
        #expect(favorite.unread.shown == .dot, "no window is key in tests")
        browser.windowDidBecomeKey()
        #expect(favorite.unread.shown == nil)
    }

    /// A notification that came while the favorite's popup was in front leaves no dot once the
    /// popup closes and the favorite is shown again.
    @Test func aFavoritesDotGoesWhenItsPopupCloses() async {
        let browser = Browser()
        let favorite = browser.newTab(url: URL(string: "data:text/html,chat")!)
        defer { browser.close(favorite) }
        #expect(await waitUntil(120) { loaded(favorite) })
        browser.pin(favorite)
        defer { browser.pins.filter { $0.id == favorite.pinID }.forEach(browser.unpin) }
        browser.select(favorite)
        let popup = browser.newTab(url: URL(string: "data:text/html,popup")!, openedFrom: favorite)
        #expect(browser.selectedTab === popup)

        favorite.receive(.notification)
        #expect(favorite.unread.shown == .dot)
        browser.close(popup)
        #expect(browser.selectedTab === favorite)
        #expect(favorite.unread.shown == nil)
    }

    /// A popup that closes itself while the window isn't key leaves the favorite's dot: the user
    /// hasn't seen the page yet.
    @Test func aFavoritesDotStaysWhenItsPopupClosesInTheBackground() async {
        let browser = Browser()
        // Never shown, so never key.
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window
        let favorite = browser.newTab(url: URL(string: "data:text/html,chat")!)
        defer { browser.close(favorite) }
        #expect(await waitUntil(120) { loaded(favorite) })
        browser.pin(favorite)
        defer { browser.pins.filter { $0.id == favorite.pinID }.forEach(browser.unpin) }
        browser.select(favorite)
        let popup = browser.newTab(url: URL(string: "data:text/html,popup")!, openedFrom: favorite)
        #expect(browser.selectedTab === popup)

        favorite.receive(.notification)
        browser.close(popup)
        #expect(browser.selectedTab === favorite)
        #expect(favorite.unread.shown == .dot)
    }

    /// A tab zoomed in wakes from sleep at the same zoom.
    @Test func sleepingTabKeepsItsZoom() async throws {
        let browser = Browser()
        let tab = browser.newTab(url: URL(string: "data:text/html,<title>Zoomed</title>zoomed")!)
        defer { browser.close(tab) }
        #expect(await waitUntil(120) { loaded(tab) })
        tab.webView.pageZoom = 1.5
        #expect(await waitUntil(5) { tab.zoom == 1.5 })

        let other = browser.newTab(url: URL(string: "data:text/html,other")!)
        defer { browser.close(other) }
        tab.sleep(configuration: browser.makeConfiguration(for: tab.url))
        #expect(tab.isAsleep)
        #expect(tab.zoom == 1.5)
        browser.select(tab)
        #expect(await waitUntil(10) { loaded(tab) && tab.webView.title == "Zoomed" })
        #expect(tab.webView.pageZoom == 1.5)
        #expect(tab.zoom == 1.5)
    }

    /// Idle sleep passes by a page the user typed in, or pressed a key in while it has a
    /// `beforeunload` handler, for one more idle interval once left; a handler alone, with no
    /// interaction, keeps no tab awake. "Sleep Other Tabs" sleeps them anyway, and a page woken
    /// afresh holds nothing unsaved. Typed while shown, as a user does, then left.
    @Test func idleSleepSparesAPageWithUnsavedInput() async throws {
        let guarded = "<script>addEventListener('beforeunload', event => event.preventDefault())</script><title>Guarded</title><p>guarded"
        let (listener, base) = try await LocalHTTP.serve([
            "/form": ("Content-Type: text/html", "<title>Form</title><input id=field>"),
            "/guarded": ("Content-Type: text/html", guarded),
        ])
        defer { listener.cancel() }
        let browser = Browser()
        let typed = browser.newTab(url: base.appending(path: "form"), selecting: false)
        let pressed = browser.newTab(url: base.appending(path: "guarded"), selecting: false)
        let untouched = browser.newTab(url: base.appending(path: "guarded"), selecting: false)
        let visible = browser.newTab(url: URL(string: "data:text/html,visible")!)
        defer { [typed, pressed, untouched, visible].forEach(browser.close) }
        #expect(await waitUntil(120) { [typed, pressed, untouched, visible].allSatisfy(loaded) })
        UserDefaults.standard.set(3, forKey: "tabIdleSeconds")
        defer { UserDefaults.standard.removeObject(forKey: "tabIdleSeconds") }

        browser.select(typed)
        _ = try await typed.webView.callAsyncJavaScript("document.getElementById('field').focus()", contentWorld: .page)
        let client = try #require(typed.webView as NSView as? NSTextInputClient)
        client.insertText("draft", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(await waitUntil(10) { typed.unsavedInputAt != nil })

        // Off screen and never ordered in: the key goes to the page as a real one.
        browser.select(pressed)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil }
        window.contentView = pressed.webView
        window.makeFirstResponder(pressed.webView)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let key = try #require(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "j", charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38
            ))
            if type == .keyDown { pressed.webView.keyDown(with: key) } else { pressed.webView.keyUp(with: key) }
        }
        #expect(await waitUntil(10) { pressed.unsavedInputAt != nil })
        #expect(untouched.unsavedInputAt == nil)
        // Leaving them marks them active: idle from now, their input older than that.
        browser.select(visible)

        // Idle for longer than the interval: only input spares them.
        try await Task.sleep(for: .seconds(3.2))
        browser.relieveMemoryPressure(critical: false)
        #expect(untouched.isAsleep)
        #expect(!typed.isAsleep && !pressed.isAsleep)

        browser.sleepOtherTabs(than: pressed)
        #expect(typed.isAsleep)
        #expect(!pressed.isAsleep && !visible.isAsleep)

        // Left alone for a second idle interval, the input no longer counts.
        try await Task.sleep(for: .seconds(3))
        browser.relieveMemoryPressure(critical: false)
        #expect(pressed.isAsleep)
        #expect(!visible.isAsleep)
        browser.select(typed)
        #expect(await waitUntil(10) { loaded(typed) && typed.webView.title == "Form" })
        #expect(typed.unsavedInputAt == nil)
    }

    /// An `onbeforeunload` that throws when read is the page's own code at leaving: a key pressed
    /// there counts, as with a handler.
    @Test func aThrowingBeforeUnloadPropertyCountsAsAHandler() async throws {
        let page = "<script>Object.defineProperty(window, 'onbeforeunload', { configurable: true, get() { throw new Error('no') } })</script><title>Canvas</title><canvas></canvas>"
        let (listener, base) = try await LocalHTTP.serve(["/canvas": ("Content-Type: text/html", page)])
        defer { listener.cancel() }
        let browser = Browser()
        let tab = browser.newTab(url: base.appending(path: "canvas"), selecting: false)
        defer { browser.close(tab) }
        #expect(await waitUntil(120) { loaded(tab) })

        // Off screen and never ordered in: the key goes to the page as a real one.
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil }
        window.contentView = tab.webView
        window.makeFirstResponder(tab.webView)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let key = try #require(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "j", charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38
            ))
            if type == .keyDown { tab.webView.keyDown(with: key) } else { tab.webView.keyUp(with: key) }
        }
        #expect(await waitUntil(10) { tab.unsavedInputAt != nil })
    }

    /// A page guarding leaving, which the user pressed a key in, uploading files (by XHR or
    /// `fetch`) outlasts the idle interval: idle sleep spares it until the last upload ends.
    /// Text sent (analytics) is no upload.
    @Test func idleSleepSparesAPageWhileItUploadsFiles() async throws {
        let guarded = "<script>addEventListener('beforeunload', event => event.preventDefault())</script><title>Guarded</title><p>guarded"
        let (listener, base) = try await LocalHTTP.serve(["/guarded": ("Content-Type: text/html", guarded)])
        defer { listener.cancel() }
        // Answers long after the test: the uploads stay on their way until aborted.
        let (slow, slowBase) = try await LocalHTTP.serve([:], delay: 60)
        defer { slow.cancel() }
        let browser = Browser()
        let tab = browser.newTab(url: base.appending(path: "guarded"), selecting: false)
        let visible = browser.newTab(url: URL(string: "data:text/html,visible")!)
        defer { [tab, visible].forEach(browser.close) }
        #expect(await waitUntil(120) { [tab, visible].allSatisfy(loaded) })
        UserDefaults.standard.set(3, forKey: "tabIdleSeconds")
        defer { UserDefaults.standard.removeObject(forKey: "tabIdleSeconds") }

        // Off screen and never ordered in: the key goes to the page as a real one.
        browser.select(tab)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil }
        window.contentView = tab.webView
        window.makeFirstResponder(tab.webView)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let key = try #require(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "j", charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38
            ))
            if type == .keyDown { tab.webView.keyDown(with: key) } else { tab.webView.keyUp(with: key) }
        }
        #expect(await waitUntil(10) { tab.unsavedInputAt != nil })

        let target = ["url": slowBase.appending(path: "upload").absoluteString]
        _ = try await tab.webView.callAsyncJavaScript("fetch(url, { method: 'POST', body: 'event=view' }).catch(() => {})", arguments: target, contentWorld: .page)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!tab.isUploading)
        _ = try await tab.webView.callAsyncJavaScript("""
            window.xhr = new XMLHttpRequest();
            xhr.open('POST', url);
            xhr.send(new Blob(['file']));
            window.aborts = new AbortController();
            const form = new FormData();
            form.append('file', new Blob(['file']), 'file.txt');
            fetch(url, { method: 'POST', body: form, signal: aborts.signal }).catch(() => {});
            """, arguments: target, contentWorld: .page)
        #expect(await waitUntil(10) { tab.isUploading })
        browser.select(visible)

        // Idle for longer than twice the interval, its key press too old to count.
        try await Task.sleep(for: .seconds(6.5))
        browser.relieveMemoryPressure(critical: false)
        #expect(!tab.isAsleep)

        _ = try await tab.webView.callAsyncJavaScript("xhr.abort()", contentWorld: .page)
        try await Task.sleep(for: .milliseconds(300))
        #expect(tab.isUploading, "the fetch still runs")
        _ = try await tab.webView.callAsyncJavaScript("aborts.abort()", contentWorld: .page)
        #expect(await waitUntil(10) { !tab.isUploading })
        browser.relieveMemoryPressure(critical: false)
        #expect(tab.isAsleep)
    }

    /// A page that retitles itself again and again writes the session once, a moment later and
    /// off the main thread, not at every change; quitting writes what waits at once.
    @Test func titleChangesSaveTheSessionOnceAMomentLater() async throws {
        let browser = Browser()
        browser.titleSaveDelay = .zero
        let tab = browser.newTab(url: URL(string: "data:text/html,<title>Start</title>start")!)
        defer { browser.close(tab) }
        #expect(await waitUntil(120) { loaded(tab) && tab.title == "Start" })
        browser.saveNow()
        let before = SessionStore.writes
        let mainThreadBefore = SessionStore.mainThreadWrites

        // One at a time from here: the page's own timers are slowed while it isn't shown.
        for count in 1...20 {
            _ = try await tab.webView.evaluateJavaScript("document.title = 'Count \(count)'")
            #expect(await waitUntil(5) { tab.title == "Count \(count)" })
        }
        #expect(await waitUntil(10) { SessionStore.load().tabs.contains { $0.title == "Count 20" } })
        #expect(SessionStore.writes - before <= 2)
        #expect(SessionStore.mainThreadWrites == mainThreadBefore, "written off the main thread")

        _ = try await tab.webView.evaluateJavaScript("document.title = 'Final'")
        #expect(await waitUntil(10) { tab.title == "Final" })
        browser.saveNow()
        #expect(SessionStore.load().tabs.contains { $0.title == "Final" })
    }

    /// A background page ticking its title (a clock) doesn't rewrite the session every second; a
    /// change of tabs still goes out a moment later, the waiting title with it.
    @Test func aTickingTitleWaitsWhileOtherChangesDont() async throws {
        let browser = Browser()
        let tab = browser.newTab(url: URL(string: "data:text/html,<title>10:00:00</title>clock")!)
        defer { browser.close(tab) }
        #expect(await waitUntil(120) { loaded(tab) && tab.title == "10:00:00" })
        browser.saveNow()
        let before = SessionStore.writes

        for second in 1...3 {
            _ = try await tab.webView.evaluateJavaScript("document.title = '10:00:0\(second)'")
            #expect(await waitUntil(5) { tab.title == "10:00:0\(second)" })
        }
        try await Task.sleep(for: Browser.sessionSaveDelay + .milliseconds(500))
        #expect(SessionStore.writes == before)

        let url = try #require(URL(string: "data:text/html,other-\(UUID().uuidString)"))
        let other = browser.newTab(url: url, selecting: false)
        defer { browser.close(other) }
        #expect(await waitUntil(10) { SessionStore.load().tabs.contains { $0.url == url } })
        #expect(SessionStore.load().tabs.contains { $0.title == "10:00:03" })
    }

    /// A title that changes and changes back while the changed one is still being written ends
    /// with the file holding the page's title, not the one in between.
    @Test func aChangeBackWhileAWriteIsInFlightIsWritten() async throws {
        let browser = Browser()
        browser.titleSaveDelay = .zero
        let tab = browser.newTab(url: URL(string: "data:text/html,<title>Steady</title>steady")!)
        defer { browser.close(tab) }
        #expect(await waitUntil(120) { loaded(tab) && tab.title == "Steady" })
        browser.saveNow()

        // Holds the write of the title in between until the title is back.
        let held = DispatchSemaphore(value: 0)
        let reached = OSAllocatedUnfairLock(initialState: false)
        SessionStore.beforeWrite = { session in
            guard session.tabs.contains(where: { $0.title == "Between" }) else { return }
            reached.withLock { $0 = true }
            held.wait()
        }
        defer { SessionStore.beforeWrite = nil }
        _ = try await tab.webView.evaluateJavaScript("document.title = 'Between'")
        #expect(await waitUntil(10) { reached.withLock { $0 } })
        _ = try await tab.webView.evaluateJavaScript("document.title = 'Steady'")
        #expect(await waitUntil(5) { tab.title == "Steady" })
        let before = SessionStore.writes
        // The change back's save, a moment later, while the write is still held.
        try await Task.sleep(for: Browser.sessionSaveDelay + .milliseconds(500))
        held.signal()

        #expect(await waitUntil(10) { SessionStore.writes >= before + 2 })
        #expect(SessionStore.load().tabs.contains { $0.title == "Steady" })
    }

    /// Clearing the history leaves no closed tab for ⇧⌘T to bring back with its pages.
    @Test func clearingTheHistoryForgetsClosedTabs() async {
        let browser = Browser()
        let tab = browser.newTab(url: URL(string: "data:text/html,<title>Closed</title>")!)
        browser.close(tab)
        #expect(browser.canReopenClosedTab)
        await browser.clearHistory()
        #expect(!browser.canReopenClosedTab)
    }

    /// A session write that failed is tried again at the next save, though nothing changed since.
    @Test func aFailedSessionWriteIsTriedAgain() throws {
        let browser = Browser()
        browser.saveNow()
        // A folder where the file goes: the write fails.
        try FileManager.default.removeItem(at: SessionStore.fileURL)
        try FileManager.default.createDirectory(at: SessionStore.fileURL, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: SessionStore.fileURL) }
        let url = URL(string: "data:text/html,<title>\(UUID().uuidString)</title>")!
        let tab = browser.newTab(url: url)
        defer { browser.close(tab) }
        browser.saveNow()

        try FileManager.default.removeItem(at: SessionStore.fileURL)
        browser.saveNow()
        #expect(SessionStore.load().tabs.contains { $0.url == url })
    }

    /// The real Chrome Web Store, YouTube and SponsorBlock:
    /// `LITHIUM_LIVE_TESTS=1 CFFIXED_USER_HOME=$(mktemp -d) swift test --filter BrowserTests/addsAnExtension`.
    /// Adds SponsorBlock with the store's own button and Lithium's confirmation, then watches it skip a sponsor.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHIUM_LIVE_TESTS"] == "1"))
    func addsAnExtensionFromTheChromeWebStoreAndRunsIt() async throws {
        let id = "mnjggcdmjocbbbhaepdhchncahnbgone"
        let (video, sponsor) = try await videoWithASponsor()
        let browser = Browser()
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1280, height: 860), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        func show(_ tab: Tab) {
            // A test runner's window never counts as visible to WebKit, so pages would stay hidden.
            let occlusion = Selector(("_setWindowOcclusionDetectionEnabled:"))
            if tab.webView.responds(to: occlusion) {
                typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
                unsafeBitCast(tab.webView.method(for: occlusion), to: Setter.self)(tab.webView, occlusion, false)
            }
            window.contentView = tab.webView
            window.orderFrontRegardless()
        }
        let pastConsent = """
            const reject = [...document.querySelectorAll('button, input[type=submit]')].find((b) => /^(Reject all|Tout refuser)$/.test((b.innerText || b.value || '').trim()));
            if (reject) reject.click();
            const button = (label) => [...document.querySelectorAll('button')].find((b) => b.innerText.trim() === label);
            """

        let store = browser.newTab(url: URL(string: "https://\(ChromeWebStore.host)/detail/\(id)")!)
        show(store)
        #expect(await poll(90) { await self.run(store, pastConsent + "const add = button('Add to Chrome'); return !!add && !add.disabled;") as? Bool == true })
        await run(store, pastConsent + "button('Add to Chrome').click();")
        let sheet = try #require(await pollValue(30) { window.attachedSheet })
        let add = try #require(buttons(in: sheet.contentView).first { $0.title == "Add Extension" })
        add.performClick(nil)
        #expect(await poll(60) { browser.extensions.contexts[id] != nil })
        #expect(browser.extensions.installed.map(\.id) == [id])
        #expect(await poll(30) { await self.run(store, pastConsent + "return !!button('Remove from Chrome');") as? Bool == true })

        // Once added, SponsorBlock opens its welcome page in a tab of its own, as it does in Chrome.
        let welcome = try #require(await pollValue(30) { browser.tabs.first { $0.url?.scheme == Extensions.scheme } })
        #expect(welcome.url?.host() == id)
        #expect(await poll(30) { !welcome.title.isEmpty })
        browser.close(welcome)

        let youtube = browser.newTab(url: URL(string: "https://www.youtube.com/watch?v=\(video)")!)
        show(youtube)
        #expect(await poll(90) {
            await self.run(youtube, pastConsent + """
                return !!document.querySelector('#sponsorblock-document-script') && document.querySelectorAll('#previewbar li').length > 0;
                """) as? Bool == true
        }, "SponsorBlock drew its segments on the seek bar")
        // Muted through YouTube's own player: WebKit lets a page start playback by itself only without sound.
        // YouTube's cookie dialog can come up late and pause the video, so each check dismisses it first.
        await run(youtube, "const player = document.querySelector('#movie_player'); player.mute(); player.seekTo(\(sponsor.start - 3), true);")
        #expect(await poll(30) {
            let time = await self.run(youtube, pastConsent + """
                const player = document.querySelector('#movie_player');
                if (player.getPlayerState() !== 1) player.playVideo();
                return player.getCurrentTime();
                """) as? Double ?? 0
            return time > sponsor.end - 1
        }, "SponsorBlock skipped the sponsor at \(sponsor.start)–\(sponsor.end)")

        await browser.extensions.remove(id: id)
        #expect(browser.extensions.installed.isEmpty)
        #expect(browser.extensions.contexts.isEmpty)
    }

    /// A video whose sponsor SponsorBlock's server knows, far enough in to seek before it.
    private func videoWithASponsor() async throws -> (id: String, segment: (start: Double, end: Double)) {
        let url = URL(string: #"https://sponsor.ajay.app/api/skipSegments/5f6b?categories=["sponsor"]"#.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)!
        let (data, _) = try await URLSession.shared.data(from: url)
        let entries = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        for entry in entries {
            for segment in entry["segments"] as? [[String: Any]] ?? [] {
                guard let times = segment["segment"] as? [Double], times.count == 2, let id = entry["videoID"] as? String,
                      times[0] > 10, times[1] - times[0] > 8, (segment["videoDuration"] as? Double ?? 0) > 60 else { continue }
                return (id, (times[0], times[1]))
            }
        }
        throw CancellationError()
    }

    /// Leaving a tab whose video plays with sound pops it out into the mini player, where it goes
    /// on playing; coming back puts it back in the page. A muted one stays, and closing the tab
    /// closes the player.
    @Test func leavingAPlayingVideoPopsItOut() async throws {
        let video = try #require(Bundle.module.url(forResource: "Fixtures/red", withExtension: "mp4"))
        let folder = FileManager.default.temporaryDirectory.appending(path: "popout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.copyItem(at: video, to: folder.appending(path: "red.mp4"))
        let page = folder.appending(path: "video.html")
        try #"<video src="red.mp4" loop style="width: 640px; height: 360px"></video>"#.write(to: page, atomically: true, encoding: .utf8)

        let browser = Browser()
        let other = browser.newTab(url: URL(string: "data:text/html,other")!)
        let tab = browser.newTab(url: page)
        // Drawn in a window far off screen: WebKit plays video only in a window it takes for visible.
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1280, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: BrowserView().environment(browser))
        [tab, other].forEach { disableOcclusionDetection($0.webView) }
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        #expect(await waitUntil(120) { loaded(tab) && loaded(other) })
        let started = await run(tab, """
            const v = document.querySelector('video');
            await Promise.race([v.play(), new Promise((r) => setTimeout(r, 5000))]);
            for (let i = 0; i < 100 && v.currentTime === 0; i++) await new Promise((r) => setTimeout(r, 50));
            return v.currentTime > 0;
            """)
        try #require(started as? Bool == true, "the video plays")

        browser.select(other)
        #expect(await waitUntil(5) { browser.videoPopout.tab === tab && browser.videoPopout.playback?.aspectRatio == 16 / 9 })
        // In the player, in the page's bottom right corner, at its default size.
        #expect(await waitUntil(5) { tab.webView.window === window && tab.webView.bounds.size == CGSize(width: 400, height: 225) })
        let corner = CGPoint(x: 1280 - Layout.margin - PopoutLayout.inset, y: Layout.margin + PopoutLayout.inset)
        #expect(await waitUntil(2) {
            let frame = tab.webView.convert(tab.webView.bounds, to: nil)
            return abs(frame.maxX - corner.x) < 0.5 && abs(frame.minY - corner.y) < 0.5
        }, "\(tab.webView.convert(tab.webView.bounds, to: nil))")
        #expect(other.webView.window === window)
        // A shadow on a layer holding a web view makes its playing video flash black.
        var layer = tab.webView.layer
        while let current = layer {
            #expect(current.shadowOpacity == 0, "\(String(describing: current.delegate.map { type(of: $0) })) casts a shadow over the player")
            layer = current.superlayer
        }
        let time = browser.videoPopout.playback?.time ?? 0
        #expect(await waitUntil(5) { (browser.videoPopout.playback?.time ?? 0) > time + 0.5 }, "the video goes on playing")

        browser.select(tab)
        #expect(browser.videoPopout.tab == nil)
        #expect(await poll(5) { await run(tab, "return document.querySelector('video').matches(':popover-open')") as? Bool == false })
        #expect(await run(tab, "return document.querySelector('video').paused") as? Bool == false)

        // Popped out, then left and back before the page answers: the video stays in the page.
        browser.videoPopout.showSelected()
        browser.select(other)
        browser.select(tab)
        try await Task.sleep(for: .seconds(1))
        #expect(browser.videoPopout.tab == nil)
        #expect(await run(tab, "return document.querySelector('video').matches(':popover-open')") as? Bool == false, "a late answer leaves only the video in the page")

        await run(tab, "document.querySelector('video').muted = true")
        browser.select(other)
        try await Task.sleep(for: .seconds(1))
        #expect(browser.videoPopout.tab == nil, "a muted video stays with its tab")

        browser.select(tab)
        await run(tab, "document.querySelector('video').muted = false")
        browser.select(other)
        #expect(await waitUntil(5) { browser.videoPopout.tab === tab })
        browser.close(tab)
        #expect(browser.videoPopout.tab == nil)
    }

    @discardableResult
    private func run(_ tab: Tab, _ body: String) async -> Any? {
        try? await tab.webView.callAsyncJavaScript(body, contentWorld: .page)
    }

    private func poll(_ seconds: Double, _ condition: () async -> Bool) async -> Bool {
        await pollValue(seconds) { await condition() ? true : nil } ?? false
    }

    private func pollValue<Value>(_ seconds: Double, _ value: () async -> Value?) async -> Value? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let value = await value() { return value }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return await value()
    }

    private func buttons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        return ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(buttons(in:))
    }

    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// Off screen, WebKit takes the window for hidden and pauses its media.
    private func disableOcclusionDetection(_ webView: WKWebView) {
        let selector = Selector(("_setWindowOcclusionDetectionEnabled:"))
        guard webView.responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(webView.method(for: selector), to: Setter.self)(webView, selector, false)
    }

    private func pid(_ tab: Tab) -> pid_t {
        (tab.webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value ?? 0
    }

    private func loaded(_ tab: Tab) -> Bool {
        !tab.isAsleep && !tab.webView.isLoading && tab.webView.url != nil && pid(tab) > 0
    }

    /// Kills the tab's own web process, the way a crash would.
    private func crash(_ tab: Tab) throws {
        let target = pid(tab)
        var name = [UInt8](repeating: 0, count: 256)
        proc_name(target, &name, 256)
        try #require(target > 0 && String(decoding: name.prefix { $0 != 0 }, as: UTF8.self) == "com.apple.WebKit.WebContent")
        kill(target, SIGKILL)
    }
}

/// A tiny HTTP server on 127.0.0.1: each path answers with its headers and body, then closes.
/// Headers that begin with a status line (`HTTP/1.1 302 Found`) replace `200 OK`.
/// Outside the main actor: Network calls its handlers on a queue of its own.
enum LocalHTTP {
    /// `delay` holds every answer back, for a page still on its way.
    static func serve(_ routes: [String: (headers: String, body: String)], delay: TimeInterval = 0) async throws -> (NWListener, URL) {
        try await serve(routes.mapValues { ($0.headers, Data($0.body.utf8)) }, delay: delay)
    }

    /// `requested` hears the path of every request, for a test counting fetches. `answer`, asked
    /// first, answers a path differently each time (a 503, then 200).
    static func serve(
        _ routes: [String: (headers: String, body: Data)], delay: TimeInterval = 0, requested: (@Sendable (String) -> Void)? = nil,
        answer: (@Sendable (String) -> (headers: String, body: Data)?)? = nil
    ) async throws -> (NWListener, URL) {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                requested?(path)
                let (headers, body) = answer?(path) ?? routes[path] ?? ("Content-Type: text/plain", Data())
                let status = headers.hasPrefix("HTTP/") ? "" : "HTTP/1.1 200 OK\r\n"
                let response = Data("\(status)\(headers)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
        listener.start(queue: .global())
        for _ in 0..<500 {
            if let port = listener.port, listener.state == .ready {
                return (listener, URL(string: "http://127.0.0.1:\(port.rawValue)/")!)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        listener.cancel()
        throw URLError(.cannotConnectToHost)
    }
}

import Darwin
import Foundation
import Network
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

    /// The session is restored before NSApplication exists, so a settings tab can't ask NSApp for its icon.
    @Test func restoresAnInternalTabAtLaunch() throws {
        SessionStore.save(Session(tabs: [.init(url: Internal.settingsURL, title: "Settings", customTitle: nil, pinID: nil)], selectedIndex: 0))
        let browser = Browser()
        let tab = try #require(browser.selectedTab)
        #expect(tab.url == Internal.settingsURL)
        #expect(tab.favicon != nil)
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
            guard await waitUntil(5, { loaded(second) }) else { continue }
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
            await v.play();
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
/// Outside the main actor: Network calls its handlers on a queue of its own.
enum LocalHTTP {
    static func serve(_ routes: [String: (headers: String, body: String)]) async throws -> (NWListener, URL) {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let (headers, body) = routes[path] ?? ("Content-Type: text/plain", "")
                let response = "HTTP/1.1 200 OK\r\n\(headers)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
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

import AppKit
import Foundation
import Testing
import WebKit
@testable import Lithium

struct NowPlayingTests {
    @Test func formatsTimes() {
        #expect(PlaybackTime.format(0) == "0:00")
        #expect(PlaybackTime.format(75.9) == "1:15")
        #expect(PlaybackTime.format(3725) == "1:02:05")
        #expect(PlaybackTime.format(-3) == "0:00")
        #expect(PlaybackTime.format(.nan) == "0:00")
    }

    @Test func readsThePageMessage() throws {
        let date = Date(timeIntervalSinceReferenceDate: 0)
        let media = try #require(NowPlaying.Media(message: [
            "title": "Song", "artist": "", "artwork": "https://i.example/a.jpg",
            "paused": false, "time": 12, "duration": 200.5, "rate": 1.5, "previous": false, "next": true,
        ] as [String: Any], at: date))
        #expect(media.title == "Song")
        #expect(media.artist == nil)
        #expect(media.artwork == URL(string: "https://i.example/a.jpg"))
        #expect(!media.isPaused)
        #expect(media.time == 12)
        #expect(media.duration == 200.5)
        #expect(media.rate == 1.5)
        #expect(!media.hasPrevious && media.hasNext)

        let live = try #require(NowPlaying.Media(message: ["artwork": "javascript:alert(1)", "duration": NSNull()], at: date))
        #expect(live.artwork == nil)
        #expect(live.duration == nil)
        #expect(live.isPaused)
        #expect(live.rate == 1)
        #expect(NowPlaying.Media(message: NSNull(), at: date) == nil)
    }

    @Test func countsOnFromTheLastReport() throws {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var media = try #require(NowPlaying.Media(message: ["paused": false, "time": 10, "duration": 30, "rate": 2], at: start))
        #expect(media.elapsed(at: start.addingTimeInterval(5)) == 20)
        #expect(media.elapsed(at: start.addingTimeInterval(60)) == 30)
        media.isPaused = true
        #expect(media.elapsed(at: start.addingTimeInterval(5)) == 10)
    }
}

/// A whole Browser, which keeps its data in the home folder, so this suite only runs in a
/// throwaway one: `CFFIXED_USER_HOME=$(mktemp -d) swift test --filter NowPlaying`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct NowPlayingBrowserTests {
    @Test func followsTheLastTabThatPlayed() {
        let browser = Browser()
        let (first, second) = (browser.newTab(), browser.newTab())
        let player = browser.nowPlaying
        let playing = NowPlaying.Media(message: ["paused": false], at: Date())
        let paused = NowPlaying.Media(message: ["paused": true], at: Date())

        player.receive(playing, from: first)
        #expect(player.tab === first)
        player.receive(paused, from: second)
        #expect(player.tab === first, "a paused page doesn't take the player")
        player.receive(playing, from: second)
        #expect(player.tab === second)
        player.receive(paused, from: second)
        #expect(player.tab === second && player.media?.isPaused == true, "paused, it stays")
        player.receive(nil, from: first)
        #expect(player.tab === second)
        player.receive(nil, from: second)
        #expect(player.tab == nil && player.media == nil)

        player.receive(playing, from: first)
        browser.close(first)
        #expect(player.tab == nil)
    }
}

/// `now-playing.js` in a real page playing `red.mp4` (a red video with a silent sound track),
/// its messages caught as `NowPlaying` would get them. Nothing is shown.
@MainActor
@Suite(.serialized)
struct NowPlayingPageTests {
    @Test func reportsAndControlsAPage() async throws {
        let page = try await PlayingPage("""
            <video src="red.mp4" loop playsinline></video>
            <script>
              navigator.mediaSession.metadata = new MediaMetadata({ title: 'Song', artist: 'Band', artwork: [
                { src: 'https://i.example/64.jpg', sizes: '64x64' },
                { src: 'https://i.example/128.jpg', sizes: '128x128' },
                { src: 'https://i.example/512.jpg', sizes: '512x512' },
              ] });
              window.nexts = 0;
              navigator.mediaSession.setActionHandler('nexttrack', () => window.nexts++);
            </script>
            """)
        defer { page.close() }
        try await page.play("document.querySelector('video')")

        #expect(await waitUntil { page.last?.isPaused == false })
        let media = try #require(page.last)
        #expect(media.title == "Song" && media.artist == "Band")
        #expect(media.artwork == URL(string: "https://i.example/128.jpg"))
        #expect(media.hasNext && !media.hasPrevious)
        #expect(media.duration ?? 0 > 0)

        await NowPlaying.run("next", in: page.webView)
        #expect(await waitUntil { try await page.run("return window.nexts") as? Int == 1 })
        await NowPlaying.run("toggle", in: page.webView)
        #expect(await waitUntil { page.last?.isPaused == true }, "paused, the page still reports its media")
        #expect(try await page.run("return document.querySelector('video').paused") as? Bool == true)

        let count = page.messages.count
        page.webView.load(URLRequest(url: URL(string: "about:blank")!))
        #expect(await waitUntil { page.messages.count > count && page.messages.last! == nil }, "leaving the page clears it")
    }

    /// Spotify plays a sound it never puts in the document; muted media isn't heard.
    @Test func hearsDetachedAudioOnly() async throws {
        let page = try await PlayingPage("<title>Detached</title>")
        defer { page.close() }
        try await page.play("Object.assign(new Audio('red.mp4'), { muted: true })")
        try await Task.sleep(for: .milliseconds(400))
        #expect(page.messages.isEmpty, "a muted sound is no music")

        try await page.play("window.sound = new Audio('red.mp4')")
        #expect(await waitUntil { page.last?.isPaused == false })
        #expect(page.last?.title == nil && page.last?.hasNext == false)
        await NowPlaying.run("toggle", in: page.webView)
        #expect(await waitUntil { try await page.run("return window.sound.paused") as? Bool == true })
    }

    private func waitUntil(_ seconds: Double = 5, _ condition: () async throws -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if (try? await condition()) == true { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
}

@MainActor
private final class PlayingPage: NSObject, WKScriptMessageHandler {
    let webView: WKWebView
    /// Every message, nil for "nothing plays".
    private(set) var messages: [NowPlaying.Media?] = []
    private let folder: URL
    private let window: NSWindow

    var last: NowPlaying.Media? { messages.last ?? nil }

    init(_ html: String) async throws {
        let video = try #require(Bundle.module.url(forResource: "Fixtures/red", withExtension: "mp4"))
        folder = FileManager.default.temporaryDirectory.appending(path: "now-playing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: video, to: folder.appending(path: "red.mp4"))
        let file = folder.appending(path: "page.html")
        try html.write(to: file, atomically: true, encoding: .utf8)

        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.addUserScript(NowPlaying.script)
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        // Media plays only in a page in a window: one far off screen, which WebKit mustn't take for hidden.
        window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        super.init()
        let selector = Selector(("_setWindowOcclusionDetectionEnabled:"))
        if webView.responds(to: selector) {
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(webView.method(for: selector), to: Setter.self)(webView, selector, false)
        }
        window.orderFrontRegardless()
        configuration.userContentController.add(self, contentWorld: .page, name: NowPlaying.name)

        webView.loadFileURL(file, allowingReadAccessTo: folder)
        for _ in 0..<200 where webView.isLoading || webView.url != file {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        messages.append(NowPlaying.Media(message: message.body, at: Date()))
    }

    @discardableResult
    func run(_ script: String) async throws -> Any? {
        try await webView.callAsyncJavaScript(script, contentWorld: .page)
    }

    /// Starts the media the expression makes or finds, giving up after a few seconds.
    func play(_ media: String) async throws {
        let started = try await run("""
            const media = \(media);
            return await Promise.race([media.play().then(() => true), new Promise((resolve) => setTimeout(() => resolve(false), 5000))]);
            """) as? Bool
        #expect(started == true, "\(media) didn't play")
    }

    func close() {
        window.orderOut(nil)
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        try? FileManager.default.removeItem(at: folder)
    }
}

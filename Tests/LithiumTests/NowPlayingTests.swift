import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
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
            "title": "Song", "artist": "", "artwork": try picture(.png, label: "png"),
            "paused": false, "time": 12, "duration": 200.5, "rate": 1.5, "previous": false, "next": true,
        ] as [String: Any], at: date))
        #expect(media.title == "Song")
        #expect(media.artist == nil)
        #expect(media.artwork?.width == 4 && media.artwork?.height == 4)
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

        for url in ["https://i.example/a.jpg", "data:image/svg+xml;base64,PHN2Zy8+", "data:image/png;base64," + String(repeating: "A", count: 70_000)] {
            #expect(NowPlaying.Media(message: ["artwork": url], at: date)?.artwork == nil, "the app loads no picture itself")
        }
        #expect(NowPlaying.Media(message: ["time": 250, "duration": 200], at: date)?.time == 200)
    }

    /// The app decodes the page's picture outside WebContent's sandbox: nothing but what it says it is.
    @Test func takesOnlyAJPEGOrAPNG() throws {
        let date = Date(timeIntervalSinceReferenceDate: 0)
        let artwork = { (url: String) in NowPlaying.Media(message: ["artwork": url], at: date)?.artwork }
        #expect(artwork(try picture(.png, label: "png"))?.width == 4)
        #expect(artwork(try picture(.jpeg, label: "jpeg"))?.width == 4)
        #expect(artwork(try picture(.tiff, label: "png")) == nil, "a TIFF said to be a PNG")
        #expect(artwork(try picture(.gif, label: "jpeg")) == nil, "a GIF said to be a JPEG")
        #expect(artwork(try picture(.jpeg, label: "png")) == nil, "a JPEG said to be a PNG")
        #expect(artwork(try picture(.png, label: "jpeg")) == nil, "a PNG said to be a JPEG")
        let truncated = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).base64EncodedString()
        #expect(artwork("data:image/png;base64," + truncated) == nil, "a PNG's signature alone")
        #expect(artwork(try picture(.png, label: "png", side: 600)) == nil, "too large to be drawn by the script")
    }

    /// A data URL of a blue square, encoded as `type` and labelled `image/<label>`.
    private func picture(_ type: UTType, label: String, side: Int = 4) throws -> String {
        let context = try #require(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return "data:image/\(label);base64," + (data as Data).base64EncodedString()
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

    /// A video muted while it plays still reports, but the tab heard keeps the player.
    @Test func takesThePlayerOnlyWhenHeard() {
        let browser = Browser()
        let (first, second) = (browser.newTab(), browser.newTab())
        let player = browser.nowPlaying
        let playing = NowPlaying.Media(message: ["paused": false, "audible": true], at: Date())
        let muted = NowPlaying.Media(message: ["paused": false, "audible": false], at: Date())

        player.receive(playing, from: first)
        player.receive(muted, from: second)
        #expect(player.tab === first, "a muted video doesn't take the player")
        player.receive(muted, from: first)
        #expect(player.tab === first && player.media?.isPaused == false && player.media?.isAudible == false, "muted, it keeps its own")
        player.receive(playing, from: second)
        #expect(player.tab === second)
    }

    @Test func letsGoWhenThePageCrashes() {
        let browser = Browser()
        let tab = browser.newTab()
        let player = browser.nowPlaying
        player.receive(NowPlaying.Media(message: ["paused": false], at: Date()), from: tab)
        #expect(browser.selectedTab === tab && player.tab === tab)

        tab.webViewWebContentProcessDidTerminate(tab.webView)
        #expect(player.tab == nil && player.media == nil, "the selected tab reloads, but its media are gone now")
    }

    @Test func followsTheLastFrameThatPlayed() {
        let browser = Browser()
        let tab = browser.newTab()
        let player = browser.nowPlaying
        let playing = NowPlaying.Media(message: ["paused": false], at: Date())
        let paused = NowPlaying.Media(message: ["paused": true], at: Date())
        let (page, embed) = (NowPlaying.Frame(id: "page"), NowPlaying.Frame(id: "embed"))

        player.receive(playing, from: tab, frame: page)
        player.receive(playing, from: tab, frame: embed)
        player.receive(paused, from: tab, frame: page)
        #expect(player.media?.isPaused == false, "the page's other media don't speak for the embed")
        player.receive(nil, from: tab, frame: page)
        #expect(player.tab === tab)
        player.receive(nil, from: tab, frame: embed)
        #expect(player.tab == nil && player.media == nil)
    }

    /// Back from the back-forward cache, a page's media are paused, and the tab lost the player
    /// when it left.
    @Test func takesARestoredPageBackWhenFree() {
        let browser = Browser()
        let (first, second) = (browser.newTab(), browser.newTab())
        let player = browser.nowPlaying
        let playing = NowPlaying.Media(message: ["paused": false], at: Date())
        let restored = NowPlaying.Media(message: ["paused": true, "restored": true], at: Date())

        player.receive(restored, from: first)
        #expect(player.tab === first && player.media?.isPaused == true)
        player.receive(playing, from: second)
        player.receive(restored, from: first)
        #expect(player.tab === second, "it doesn't take the player from another tab")
    }

    @Test func holdsAToggleUntilThePageFollows() async throws {
        let browser = Browser()
        let tab = browser.newTab()
        let player = browser.nowPlaying
        let playing = { (date: Date) in NowPlaying.Media(message: ["paused": false], at: date) }

        player.receive(playing(Date()), from: tab)
        player.togglePlay()
        #expect(player.media?.isPaused == true)
        player.receive(playing(Date()), from: tab)
        #expect(player.media?.isPaused == true, "a page that pauses later still says it plays for a moment")
        player.receive(NowPlaying.Media(message: ["paused": true], at: Date()), from: tab)
        #expect(player.media?.isPaused == true)
        player.receive(playing(Date()), from: tab)
        #expect(player.media?.isPaused == false, "once it followed, the page has the last word")

        player.togglePlay()
        player.receive(playing(Date().addingTimeInterval(NowPlaying.settle + 1)), from: tab)
        #expect(player.media?.isPaused == false, "after a while too")

        player.togglePlay()
        #expect(player.media?.isPaused == true)
        try await Task.sleep(for: .seconds(NowPlaying.settle + 0.3))
        #expect(player.media?.isPaused == false, "a page that didn't follow shows what it plays again")

        player.togglePlay()
        player.togglePlay()
        #expect(player.media?.isPaused == false)
        player.receive(NowPlaying.Media(message: ["paused": true], at: Date()), from: tab)
        #expect(player.media?.isPaused == false, "the first click's pause comes before the second's play")
    }

    @Test func hidesWhileItsVideoIsPoppedOut() {
        let browser = Browser()
        let (first, second) = (browser.newTab(), browser.newTab())
        let player = browser.nowPlaying
        #expect(player.shownTab(besides: nil) == nil)

        player.receive(NowPlaying.Media(message: ["paused": false], at: Date()), from: first)
        #expect(player.shownTab(besides: nil) === first)
        #expect(player.shownTab(besides: first) == nil, "the floating player already shows it")
        #expect(player.tab === first, "it keeps the player for when the video goes back")
        #expect(player.shownTab(besides: second) === first, "another tab's video is other media")
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
        #expect(media.artwork == nil, "a picture the page may not read leaves the tab's icon")
        #expect(media.hasNext && !media.hasPrevious)
        #expect(media.duration ?? 0 > 0)

        await NowPlaying.run("next", in: page.webView)
        #expect(await waitUntil { try await page.run("return window.nexts") as? Int == 1 })
        await NowPlaying.run("pause", in: page.webView)
        #expect(await waitUntil { page.last?.isPaused == true }, "paused, the page still reports its media")
        #expect(try await page.run("return document.querySelector('video').paused") as? Bool == true)
        #expect(page.last?.isRestored == false)

        try await page.run("dispatchEvent(new PageTransitionEvent('pageshow', { persisted: true }))")
        #expect(await waitUntil { page.last?.isRestored == true }, "back from the back-forward cache, it asks for the player again")
        #expect(page.last?.isPaused == true)

        let count = page.messages.count
        page.webView.load(URLRequest(url: URL(string: "about:blank")!))
        #expect(await waitUntil { page.messages.count > count && page.messages.last! == nil }, "leaving the page clears it")
    }

    /// The page loads and draws the picture; the app gets a small one.
    @Test func drawsTheArtworkInThePage() async throws {
        let page = try await PlayingPage("""
            <video src="red.mp4" loop playsinline></video>
            <script>
              const canvas = Object.assign(document.createElement('canvas'), { width: 300, height: 200 });
              const context = canvas.getContext('2d');
              context.fillStyle = 'blue';
              context.fillRect(0, 0, 300, 200);
              navigator.mediaSession.metadata = new MediaMetadata({ title: 'Song', artwork: [{ src: canvas.toDataURL(), sizes: '300x200' }] });
            </script>
            """)
        defer { page.close() }
        try await page.play("document.querySelector('video')")

        #expect(await waitUntil { page.last?.artwork != nil })
        let picture = try #require(page.last?.artwork.map(NSBitmapImageRep.init(cgImage:)))
        #expect(picture.pixelsWide == 96 && picture.pixelsHigh == 96)
        let color = try #require(picture.colorAt(x: 48, y: 48))
        #expect(color.blueComponent > 0.9 && color.redComponent < 0.1)
    }

    /// Spotify pauses a moment after its handler is called: the page mustn't say it still plays.
    @Test func reportsAToggleOnceThePageFollows() async throws {
        let page = try await PlayingPage("""
            <video src="red.mp4" loop playsinline></video>
            <script>
              navigator.mediaSession.setActionHandler('pause', () => setTimeout(() => document.querySelector('video').pause(), 500));
            </script>
            """)
        defer { page.close() }
        try await page.play("document.querySelector('video')")
        #expect(await waitUntil { page.last?.isPaused == false })
        try await Task.sleep(for: .milliseconds(400))

        let count = page.messages.count
        await NowPlaying.run("pause", in: page.webView)
        #expect(await waitUntil { page.last?.isPaused == true })
        #expect(page.messages[count...].allSatisfy { $0?.isPaused == true }, "no report in between says it plays")
    }

    /// Clicked twice before Spotify paused, the player asks for a pause then a play, not two pauses.
    @Test func endsInTheLastStateAskedFor() async throws {
        let page = try await PlayingPage("""
            <video src="red.mp4" loop playsinline></video>
            <script>
              const video = document.querySelector('video');
              window.pauses = 0;
              video.addEventListener('pause', () => window.pauses++);
              navigator.mediaSession.setActionHandler('pause', () => setTimeout(() => video.pause(), 300));
              navigator.mediaSession.setActionHandler('play', () => setTimeout(() => video.play(), 300));
            </script>
            """)
        defer { page.close() }
        try await page.play("document.querySelector('video')")
        #expect(await waitUntil { page.last?.isPaused == false })

        await NowPlaying.run("pause", in: page.webView)
        await NowPlaying.run("play", in: page.webView)
        #expect(await waitUntil { try await page.run("return window.pauses") as? Int == 1 }, "the first click's pause comes")
        try await Task.sleep(for: .milliseconds(500))
        #expect(try await page.run("return document.querySelector('video').paused") as? Bool == false, "then the second click's play")
        #expect(page.last?.isPaused == false)
    }

    /// The page's position is its active media's; WebKit's refusals don't count.
    @Test func keepsThePositionStateOfItsMedia() async throws {
        let page = try await PlayingPage("""
            <video id="first" src="red.mp4" loop playsinline></video>
            <video id="second" src="red.mp4" loop playsinline></video>
            """)
        defer { page.close() }
        try await page.play("document.querySelector('#first')")
        try await page.run("navigator.mediaSession.setPositionState({ duration: 1000, position: 500 })")
        #expect(await waitUntil { page.last?.duration == 1000 && page.last?.isPaused == false })

        let refused = try await page.run("""
            try { navigator.mediaSession.setPositionState({ duration: 10, position: 50 }); return false; } catch { return true; }
            """) as? Bool
        #expect(refused == true)
        try await page.run("navigator.mediaSession.metadata = new MediaMetadata({ title: 'After' })")
        #expect(await waitUntil { page.last?.title == "After" })
        #expect(page.last?.duration == 1000)

        try await page.run("document.querySelector('#first').pause()")
        try await page.play("document.querySelector('#second')")
        let duration = try #require(try await page.run("return document.querySelector('#second').duration") as? Double)
        #expect(duration < 1000)
        #expect(await waitUntil { page.last?.duration == duration && page.last?.isPaused == false }, "the other media has its own time")
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
        await NowPlaying.run("pause", in: page.webView)
        #expect(await waitUntil { try await page.run("return window.sound.paused") as? Bool == true })
        try await Task.sleep(for: .milliseconds(300))
        #expect(page.last?.isPaused == true, "paused, a sound never in the document stays in the player")
    }

    /// Muted after it started, the media playing says it isn't heard, and is again once unmuted.
    @Test func reportsWhetherItIsHeard() async throws {
        let page = try await PlayingPage("<video src=\"red.mp4\" loop playsinline></video>")
        defer { page.close() }
        try await page.play("document.querySelector('video')")
        #expect(await waitUntil { page.last?.isPaused == false && page.last?.isAudible == true })

        try await page.run("document.querySelector('video').muted = true")
        #expect(await waitUntil { page.last?.isAudible == false })
        #expect(page.last?.isPaused == false)
        try await page.run("document.querySelector('video').muted = false")
        #expect(await waitUntil { page.last?.isAudible == true })
    }

    /// X takes a video out of the page when its view closes: WebKit pauses it, but it stays loaded.
    @Test func dropsMediaTakenOutOfThePage() async throws {
        let page = try await PlayingPage("""
            <video id="first" src="red.mp4" loop playsinline></video>
            <video id="second" src="red.mp4" loop playsinline></video>
            """)
        defer { page.close() }
        let cleared = { page.messages.last.map { $0 == nil } ?? false }
        try await page.play("document.querySelector('#first')")
        #expect(await waitUntil { page.last?.isPaused == false })
        try await page.run("document.querySelector('#first').remove()")
        #expect(await waitUntil { cleared() }, "removed while playing")

        try await page.play("document.querySelector('#second')")
        #expect(await waitUntil { page.last?.isPaused == false })
        try await page.run("document.querySelector('#second').pause()")
        #expect(await waitUntil { page.last?.isPaused == true })
        try await page.run("document.body.replaceChildren()")
        #expect(await waitUntil { cleared() }, "removed paused, with no media event")
    }

    /// Reddit's player keeps its video in a shadow root, whose play event never reaches the window.
    @Test func hearsMediaInAShadowRoot() async throws {
        let page = try await PlayingPage("""
            <script>
            customElements.define('shadow-player', class extends HTMLElement {
                constructor() {
                    super();
                    window.shadow = this.attachShadow({ mode: 'closed' });
                    window.shadow.innerHTML = '<video src="red.mp4" autoplay loop playsinline></video>';
                }
            });
            </script>
            <shadow-player></shadow-player>
            """)
        defer { page.close() }
        #expect(await waitUntil { page.last?.isPaused == false && page.last?.isAudible == true }, "started by autoplay")

        await NowPlaying.run("pause", in: page.webView)
        #expect(await waitUntil { page.last?.isPaused == true })
        try await page.run("window.shadow.replaceChildren()")
        #expect(await waitUntil { page.messages.last.map { $0 == nil } ?? false }, "removed paused from its shadow root")
    }

    /// A video embedded in an article plays in its own frame, which answers the buttons.
    @Test func hearsAnIframe() async throws {
        let page = try await PlayingPage("""
            <title>Article</title>
            <iframe srcdoc="<video src='red.mp4' loop playsinline></video>"></iframe>
            """)
        defer { page.close() }
        let video = "document.querySelector('iframe').contentDocument.querySelector('video')"
        #expect(await waitUntil { try await page.run("return !!\(video)") as? Bool == true })
        try await page.play(video)

        #expect(await waitUntil { page.last?.isPaused == false })
        let frame = try #require(page.lastFrame)
        #expect(!frame.isMainFrame)
        #expect(page.last?.title == nil)

        await NowPlaying.run("pause", in: page.webView)
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await page.run("return \(video).paused") as? Bool == false, "the page itself plays nothing")
        await NowPlaying.run("pause", in: page.webView, frame: frame)
        #expect(await waitUntil { try await page.run("return \(video).paused") as? Bool == true })
        #expect(await waitUntil { page.last?.isPaused == true })
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
    private(set) var lastFrame: WKFrameInfo?
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
        lastFrame = message.frameInfo
        messages.append(NowPlaying.Media(message: (message.body as? [String: Any])?["media"] ?? NSNull(), at: Date()))
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

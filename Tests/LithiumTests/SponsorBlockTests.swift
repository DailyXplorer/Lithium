import Foundation
import Testing
import WebKit
@testable import Lithium

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SponsorBlockTests {
    @Test func asksByHashPrefixOnly() throws {
        #expect(SponsorBlock.hashPrefix("dQw4w9WgXcQ") == "5f6b")
        let url = SponsorBlock.request(for: "dQw4w9WgXcQ", categories: [.sponsor, .musicOfftopic])
        #expect(url.path() == "/api/skipSegments/5f6b")
        #expect(!url.absoluteString.contains("dQw4w9WgXcQ"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "categories" }?.value == #"["sponsor","music_offtopic"]"#)
        #expect(items.first { $0.name == "actionTypes" }?.value == #"["skip"]"#)
    }

    @Test func keepsOnlyThisVideosSkips() {
        let data = Data("""
            [
              {"videoID": "other_video", "segments": [{"category": "sponsor", "actionType": "skip", "segment": [1, 2], "UUID": "x"}]},
              {"videoID": "dQw4w9WgXcQ", "segments": [
                {"category": "selfpromo", "actionType": "skip", "segment": [40, 50.5], "UUID": "b", "videoDuration": 212},
                {"category": "sponsor", "actionType": "skip", "segment": [10, 20], "UUID": "a", "videoDuration": 212},
                {"category": "sponsor", "actionType": "mute", "segment": [60, 70], "UUID": "c"},
                {"category": "poi_highlight", "actionType": "skip", "segment": [80, 90], "UUID": "d"},
                {"category": "intro", "actionType": "skip", "segment": [30, 30], "UUID": "e"}
              ]}
            ]
            """.utf8)
        #expect(SponsorBlock.segments(in: data, for: "dQw4w9WgXcQ") == [
            Segment(id: "a", start: 10, end: 20, category: .sponsor, videoDuration: 212),
            Segment(id: "b", start: 40, end: 50.5, category: .selfpromo, videoDuration: 212),
        ])
        #expect(SponsorBlock.segments(in: Data("Not Found".utf8), for: "dQw4w9WgXcQ").isEmpty)
    }

    @Test func runsOnYouTubeOnly() {
        #expect(SponsorBlock.handles(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")))
        #expect(SponsorBlock.handles(URL(string: "https://youtube.com/")))
        #expect(!SponsorBlock.handles(URL(string: "https://notyoutube.com/watch?v=dQw4w9WgXcQ")))
        #expect(!SponsorBlock.handles(URL(string: "https://youtube.com.example.net/")))
        #expect(!SponsorBlock.handles(URL(string: "http://www.youtube.com/")))
    }

    /// A 20-second video in a YouTube-shaped player: a sponsor at 3–6 s, self-promotion at 10–12 s.
    /// The next video, reached without a new page as on YouTube, has a sponsor at 1–4 s.
    @Test func skipsSponsorsAndOffersTheRest() async throws {
        let sponsorBlock = SponsorBlock { url in
            let body = #"[{"videoID": "dQw4w9WgXcQ", "segments": ["#
                + #"{"category": "sponsor", "actionType": "skip", "segment": [3, 6], "UUID": "s", "videoDuration": 20},"#
                + #"{"category": "selfpromo", "actionType": "skip", "segment": [10, 12], "UUID": "p", "videoDuration": 20}]},"#
                + #"{"videoID": "9bZkp7q19f0", "segments": [{"category": "sponsor", "actionType": "skip", "segment": [1, 4], "UUID": "n", "videoDuration": 20}]}]"#
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let (webView, window) = try await Self.player(sponsorBlock)
        defer { window.close() }

        let skipped = try await Self.run(webView, "video.currentTime = 2.6; await video.play(); await sleep(1200); return video.currentTime;") as? Double
        #expect(try #require(skipped) >= 6)

        let offered = try await Self.run(webView, "video.currentTime = 10.2; await sleep(700); return video.currentTime;") as? Double
        #expect(try #require(offered) < 12, "self-promotion waits for a click")

        let marks = try await Self.run(webView, """
            return [...document.querySelectorAll('.ytp-progress-bar > div > div')].map((mark) => mark.style.left + ' ' + mark.style.width).join(', ');
            """) as? String
        #expect(marks == "15% 15%, 50% 10%")

        let pageSeesBridge = try await Self.run(webView, "return String(!!window.webkit?.messageHandlers?.sponsorBlock);") as? String
        #expect(pageSeesBridge == "false", "YouTube's own scripts cannot reach the app")

        let next = try await Self.run(webView, """
            video.pause();
            history.pushState({}, '', '/watch?v=9bZkp7q19f0');
            window.dispatchEvent(new CustomEvent('yt-navigate-finish'));
            await sleep(300);
            video.currentTime = 0.6;
            await video.play();
            await sleep(1000);
            return video.currentTime;
            """) as? Double
        #expect(try #require(next) >= 4, "the next video's own sponsor, not the last one's")
    }

    /// Real YouTube and SponsorBlock, over the network: `LITHIUM_LIVE_TESTS=1 swift test --filter SponsorBlockTests`.
    /// Plays up to a sponsor that SponsorBlock's server knows about and checks it gets skipped.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHIUM_LIVE_TESTS"] == "1"))
    func skipsARealSponsorOnYouTube() async throws {
        let (data, _) = try await SponsorBlock.download(SponsorBlock.request(for: "dQw4w9WgXcQ", categories: [.sponsor]))
        let entries = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let candidates = entries.compactMap { entry -> (id: String, segment: Segment)? in
            guard let id = entry["videoID"] as? String else { return nil }
            let data = (try? JSONSerialization.data(withJSONObject: [entry])) ?? Data()
            let segment = SponsorBlock.segments(in: data, for: id).first { $0.videoDuration > 60 && $0.start > 10 && $0.end - $0.start > 8 }
            return segment.map { (id, $0) }
        }

        let folder = try #require(Resources.bundle.url(forResource: "Filters", withExtension: nil))
        let blocking = AdvancedBlocking(container: FileManager.default.temporaryDirectory.appending(path: "live-\(UUID())"))
        await blocking.load(folder: folder, stamp: UUID().uuidString)

        for (id, segment) in candidates.prefix(4) {
            let url = URL(string: "https://www.youtube.com/watch?v=\(id)")!
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
            configuration.mediaTypesRequiringUserActionForPlayback = []
            let sponsorBlock = SponsorBlock()
            sponsorBlock.install(on: configuration)
            configuration.userContentController.addUserScript(SponsorBlock.script)
            if let script = blocking.script(for: url) {
                configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
            }
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
            let window = Self.window(for: webView)
            defer { window.close() }
            let loaded = Loaded()
            webView.navigationDelegate = loaded
            webView.load(URLRequest(url: url))
            await loaded.wait()

            let duration = try await Self.run(webView, """
                for (let i = 0; i < 60; i++) {
                  const video = document.querySelector('#movie_player video');
                  if (video && Number.isFinite(video.duration) && !document.querySelector('#movie_player.ad-showing')) return video.duration;
                  await sleep(500);
                }
                return 0;
                """, limit: 40) as? Double ?? 0
            guard abs(duration - segment.videoDuration) < 3 else { continue }

            let time = try await Self.run(webView, """
                const video = document.querySelector('#movie_player video');
                video.muted = true;
                video.currentTime = \(segment.start - 2);
                await video.play();
                // Seeking far ahead buffers first; wait until playback reaches the segment.
                while (video.currentTime < \(segment.start)) await sleep(100);
                await sleep(600);
                return video.currentTime;
                """, limit: 30) as? Double
            #expect(try #require(time) >= segment.end - 1, "\(id): \(segment.start)–\(segment.end) s")

            let marks = try await Self.run(webView, "return document.querySelectorAll('#movie_player .ytp-progress-bar > div > div').length;") as? Int
            #expect(marks ?? 0 >= 1, "the sponsor is marked on the seek bar")

            if let directory = ProcessInfo.processInfo.environment["LITHIUM_SNAPSHOT_DIR"],
               let image = try? await webView.takeSnapshot(configuration: nil),
               let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: directory).appending(path: "sponsorblock-\(id).png"))
            }
            return
        }
        Issue.record("No playable video among \(candidates.prefix(4).map(\.id))")
    }

    private static func player(_ sponsorBlock: SponsorBlock) async throws -> (WKWebView, NSWindow) {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        sponsorBlock.install(on: configuration)
        configuration.userContentController.addUserScript(SponsorBlock.script)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 450), configuration: configuration)
        let window = Self.window(for: webView)
        let loaded = Loaded()
        webView.navigationDelegate = loaded
        webView.loadHTMLString("""
            <div id="movie_player" style="position: relative; width: 640px; height: 360px">
              <video muted playsinline></video>
              <div class="ytp-progress-bar" style="position: absolute; left: 0; right: 0; bottom: 40px; height: 4px"></div>
            </div>
            """, baseURL: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!)
        await loaded.wait()
        // Twenty seconds of silence as a WAV file.
        _ = try await run(webView, """
            const rate = 8000, seconds = 20, samples = rate * seconds;
            const bytes = new Uint8Array(44 + samples);
            const view = new DataView(bytes.buffer);
            const text = (offset, string) => [...string].forEach((c, i) => view.setUint8(offset + i, c.charCodeAt(0)));
            text(0, 'RIFF'); view.setUint32(4, 36 + samples, true); text(8, 'WAVEfmt ');
            view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true);
            view.setUint32(24, rate, true); view.setUint32(28, rate, true); view.setUint16(32, 1, true); view.setUint16(34, 8, true);
            text(36, 'data'); view.setUint32(40, samples, true); bytes.fill(128, 44);
            video.src = URL.createObjectURL(new Blob([bytes], { type: 'audio/wav' }));
            await new Promise((resolve) => video.addEventListener('loadedmetadata', resolve, { once: true }));
            await sleep(300);
            """)
        return (webView, window)
    }

    /// WebKit loads no media for a view outside a window.
    private static func window(for webView: WKWebView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: webView.frame.width, height: webView.frame.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.orderFrontRegardless()
        return window
    }

    @discardableResult
    private static func run(_ webView: WKWebView, _ body: String, limit seconds: Int = 8) async throws -> Any? {
        try await webView.callAsyncJavaScript("""
            const video = document.querySelector('video');
            const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
            const timeout = sleep(\(seconds * 1000)).then(() => { throw new Error(`timed out: readyState ${video.readyState}, error ${video.error?.code}, paused ${video.paused}`); });
            return await Promise.race([(async () => { \(body) })(), timeout]);
            """, contentWorld: .page)
    }
}

@MainActor
private final class Loaded: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var done = false
    func wait() async { if !done { await withCheckedContinuation { continuation = $0 } } }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true; continuation?.resume() }
}

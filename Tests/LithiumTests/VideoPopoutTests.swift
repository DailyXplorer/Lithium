import AppKit
import Testing
import WebKit
@testable import Lithium

/// `video-popout.js` on a real video (red, with a silent sound track) in a page that does its
/// best to get in the way: the player is small, scaled down, clipped and under other content.
/// The page is drawn in a window far off screen, so nothing shows and focus stays where it is.
@MainActor
@Suite(.serialized)
struct VideoPopoutTests {
    private static let page = """
        <body style="margin: 0; background: rgb(0, 0, 255)">
          <div style="transform: scale(0.5); transform-origin: 0 0; overflow: hidden; width: 640px; height: 360px; contain: paint">
            <video src="red.mp4" loop playsinline style="width: 640px; height: 360px"></video>
          </div>
          <div style="position: fixed; inset: 0; z-index: 9999; background: rgba(0, 255, 0, 0.5)"></div>
        </body>
        """

    @Test func videoFillsThePlayerAndKeepsPlaying() async throws {
        let (webView, window) = try await playingPage()
        defer { window.orderOut(nil) }

        webView.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
        try await Task.sleep(for: .milliseconds(300))
        let inPage = try #require(await snapshot(of: webView))
        #expect(!isRed(inPage.colorAt(x: 160, y: 90)), "in the page, the overlay covers the video")

        #expect(try await VideoPopout.run("playing", in: webView) as? Bool == true)
        let shown = try #require(try await VideoPopout.run("show", in: webView) as? [String: Any])
        #expect(shown["width"] as? Int == 160 && shown["height"] as? Int == 90)

        try await Task.sleep(for: .milliseconds(300))
        let snapshot = try #require(await snapshot(of: webView))
        for point in [(160, 90), (6, 6), (314, 6), (6, 174), (314, 174)] {
            #expect(isRed(snapshot.colorAt(x: point.0, y: point.1)), "not the video at \(point)")
        }

        let before = try #require(try await state(of: webView)["time"] as? Double)
        try await Task.sleep(for: .seconds(1))
        let after = try await state(of: webView)
        #expect(after["paused"] as? Bool == false)
        #expect(try #require(after["time"] as? Double) > before + 0.5, "the video stopped when it popped out")

        let sought = try #require(try await VideoPopout.run("seek", in: webView, value: 5.0) as? [String: Any])
        #expect(abs((sought["time"] as? Double ?? 0) - 5) < 0.2)
        #expect(try await VideoPopout.run("pause", in: webView).flatMap { $0 as? [String: Any] }?["paused"] as? Bool == true)
        #expect(try await VideoPopout.run("mute", in: webView, value: true).flatMap { $0 as? [String: Any] }?["muted"] as? Bool == true)

        _ = try await VideoPopout.run("hide", in: webView)
        #expect(try await VideoPopout.run("state", in: webView) as? [String: Any] == nil)
        let leftovers = try await webView.callAsyncJavaScript(
            "return [...document.querySelector('video').attributes].map((a) => a.name).join(' ') + ' ' + document.querySelectorAll('style').length",
            contentWorld: .page
        ) as? String
        #expect(leftovers == "src loop playsinline style 0", "the page is left as it was")
    }

    /// YouTube moves its player elsewhere in the page when its window narrows, which takes the
    /// video out of the top layer; the whole page then showed, shrunk, instead of the video.
    @Test func videoStaysUpWhenThePageMovesIt() async throws {
        let (webView, window) = try await playingPage()
        defer { window.orderOut(nil) }
        _ = try await VideoPopout.run("show", in: webView)
        _ = try await webView.callAsyncJavaScript(
            "const box = document.createElement('div'); box.style.transform = 'scale(0.5)'; document.body.prepend(box); box.append(document.querySelector('video'));",
            contentWorld: .page
        )
        try await Task.sleep(for: .milliseconds(200))
        let open = try await webView.callAsyncJavaScript("return document.querySelector('video').matches(':popover-open')", contentWorld: .page)
        #expect(open as? Bool == true)
        let snapshot = try #require(await snapshot(of: webView))
        #expect(isRed(snapshot.colorAt(x: 400, y: 300)), "the video fills the view again")
    }

    /// A page redrawing its player may drop the popover attribute. Showing the video again then
    /// threw, and the failed state check closed the mini player.
    @Test func videoStaysUpWhenThePageDropsItsPopover() async throws {
        let (webView, window) = try await playingPage()
        defer { window.orderOut(nil) }
        _ = try await VideoPopout.run("show", in: webView)
        _ = try await webView.callAsyncJavaScript(
            "const video = document.querySelector('video'); video.hidePopover(); video.removeAttribute('popover');",
            contentWorld: .page
        )
        #expect(try await state(of: webView)["paused"] as? Bool == false, "the state check still answers")
        try await Task.sleep(for: .milliseconds(200))
        let open = try await webView.callAsyncJavaScript("return document.querySelector('video').matches(':popover-open')", contentWorld: .page)
        #expect(open as? Bool == true)
        _ = try await VideoPopout.run("hide", in: webView)
        let popover = try await webView.callAsyncJavaScript("return document.querySelector('video').hasAttribute('popover')", contentWorld: .page)
        #expect(popover as? Bool == false, "the page is left as it was")
    }

    /// Paused, the video isn't raised every frame, and the state check waits in the page for it to
    /// change instead of answering twice a second; playing again brings both back at once.
    @Test func aPausedVideoCostsNothingUntilItPlays() async throws {
        let (webView, window) = try await playingPage()
        defer { window.orderOut(nil) }
        _ = try await VideoPopout.run("show", in: webView)
        let looping = { try await webView.callAsyncJavaScript("return globalThis.lithiumVideoPopout.frame !== 0", contentWorld: .defaultClient) as? Bool }
        #expect(try await looping() == true)

        _ = try await VideoPopout.run("pause", in: webView)
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await looping() == false, "no frame loop while paused")

        let start = Date()
        let waiting = Task {
            (try await VideoPopout.run("state", in: webView, value: VideoPopout.pausedWait) as? [String: Any])?["paused"] as? Bool
        }
        try await Task.sleep(for: .milliseconds(500))
        _ = try await webView.callAsyncJavaScript("document.querySelector('video').play()", contentWorld: .page)
        let paused = try await waiting.value
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed >= 0.4 && elapsed < 3, "answered when it played, not before")
        #expect(paused == false)
        #expect(try await looping() == true)
        _ = try await VideoPopout.run("hide", in: webView)
    }

    /// A paused video the page removes ends the state check's wait at once: the player closes
    /// as soon as before, not seconds later.
    @Test func aPausedVideoRemovedEndsTheWait() async throws {
        let (webView, window) = try await playingPage()
        defer { window.orderOut(nil) }
        _ = try await VideoPopout.run("show", in: webView)
        _ = try await VideoPopout.run("pause", in: webView)

        let start = Date()
        let waiting = Task { try await VideoPopout.run("state", in: webView, value: VideoPopout.pausedWait) as? [String: Any] == nil }
        try await Task.sleep(for: .milliseconds(500))
        _ = try await webView.callAsyncJavaScript("document.querySelector('video').parentElement.remove()", contentWorld: .page)
        let gone = try await waiting.value
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed >= 0.4 && elapsed < 3, "answered when it went, not after the wait")
        #expect(gone, "the player closes")
    }

    /// The player stays where it is dropped, and keeps its distance from the nearest corner when
    /// the page changes size. Dropped past an edge, it stays whole in the page.
    @Test func playerStaysWhereItIsDropped() {
        let size = CGSize(width: 400, height: 225)
        let page = PopoutLayout(container: CGSize(width: 1000, height: 700), aspectRatio: 16 / 9)
        let dropped = CGPoint(x: 90, y: 400)
        let placement = page.placement(of: dropped, size: size)
        #expect(placement.corner == .bottomLeading)
        #expect(page.origin(of: size, in: placement.corner, inset: placement.inset) == dropped)

        let wider = PopoutLayout(container: CGSize(width: 1400, height: 900), aspectRatio: 16 / 9)
        #expect(wider.origin(of: size, in: placement.corner, inset: placement.inset) == CGPoint(x: 90, y: 600))
        #expect(page.clamped(CGPoint(x: 900, y: -50), size: size) == CGPoint(x: 600, y: 0))
    }

    /// A tall video in a short page (a split, a small window) fits the page's height, narrower
    /// than usual; a page claiming an extreme shape gets 4:1 at most.
    @Test func aTallVideoFitsThePage() throws {
        let short = PopoutLayout(container: CGSize(width: 500, height: 300), aspectRatio: 9 / 16)
        let size = short.size(width: PopoutLayout.defaultWidth)
        #expect(size.height <= 300 * 0.75 + 0.001)
        #expect(abs(size.width / size.height - 9 / 16) < 0.001)
        #expect(short.origin(of: size, in: .bottomTrailing, inset: CGSize(width: 12, height: 12)).y >= 0)

        let tall = try #require(VideoPopout.playback(from: ["width": 1.0, "height": 4000.0]))
        #expect(tall.aspectRatio == 0.25)
        let wide = try #require(VideoPopout.playback(from: ["width": 4000.0, "height": 1.0]))
        #expect(wide.aspectRatio == 4)
        #expect(VideoPopout.playback(from: ["width": 1280.0, "height": 720.0])?.aspectRatio == 1280.0 / 720.0)
    }

    /// A muted video, or none playing, stays with its tab.
    @Test func onlyAVideoPlayingWithSoundPopsOut() async throws {
        let (webView, window) = try await playingPage()
        defer { window.orderOut(nil) }
        _ = try await webView.callAsyncJavaScript("document.querySelector('video').muted = true", contentWorld: .page)
        #expect(try await VideoPopout.run("playing", in: webView) as? Bool == false)
        _ = try await webView.callAsyncJavaScript("const v = document.querySelector('video'); v.muted = false; v.pause()", contentWorld: .page)
        #expect(try await VideoPopout.run("playing", in: webView) as? Bool == false)
    }

    private func playingPage() async throws -> (WKWebView, NSWindow) {
        let video = try #require(Bundle.module.url(forResource: "Fixtures/red", withExtension: "mp4"))
        let folder = FileManager.default.temporaryDirectory.appending(path: "popout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: video, to: folder.appending(path: "red.mp4"))
        let file = folder.appending(path: "page.html")
        try Self.page.write(to: file, atomically: true, encoding: .utf8)

        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        window.contentView = NSView(frame: webView.frame)
        window.contentView?.addSubview(webView)
        disableOcclusionDetection(webView)
        window.orderFrontRegardless()

        webView.loadFileURL(file, allowingReadAccessTo: folder)
        for _ in 0..<200 where webView.isLoading || webView.url != file {
            try await Task.sleep(for: .milliseconds(50))
        }
        let started = try await webView.callAsyncJavaScript("""
            const video = await new Promise((resolve) => {
              const find = () => document.querySelector('video') ? resolve(document.querySelector('video')) : setTimeout(find, 50);
              find();
            });
            await Promise.race([video.play(), new Promise((r) => setTimeout(r, 5000))]);
            for (let i = 0; i < 200 && (video.readyState < 3 || video.currentTime === 0); i++) await new Promise((r) => setTimeout(r, 50));
            return video.readyState >= 3 && video.currentTime > 0;
            """, contentWorld: .page) as? Bool
        #expect(started == true)
        return (webView, window)
    }

    private func state(of webView: WKWebView) async throws -> [String: Any] {
        try #require(try await VideoPopout.run("state", in: webView) as? [String: Any])
    }

    /// Off screen, WebKit takes the window for hidden and stops drawing the page.
    private func disableOcclusionDetection(_ webView: WKWebView) {
        let selector = Selector(("_setWindowOcclusionDetectionEnabled:"))
        guard webView.responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(webView.method(for: selector), to: Setter.self)(webView, selector, false)
    }

    private func snapshot(of webView: WKWebView) async -> NSBitmapImageRep? {
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = NSNumber(value: Double(webView.bounds.width))
        guard let image = try? await webView.takeSnapshot(configuration: configuration),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage)
    }

    private func isRed(_ color: NSColor?) -> Bool {
        guard let color = color?.usingColorSpace(.sRGB) else { return false }
        return color.redComponent > 0.7 && color.greenComponent < 0.3 && color.blueComponent < 0.3
    }
}

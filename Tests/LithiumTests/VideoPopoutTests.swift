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
            await video.play();
            while (video.readyState < 3 || video.currentTime === 0) await new Promise((r) => setTimeout(r, 50));
            return true;
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

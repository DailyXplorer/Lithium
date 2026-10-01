import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers
import WebKit

/// What the last tab heard plays, for the mini player at the bottom of the sidebar. Pages tell
/// it themselves through `now-playing.js` when their media changes: a tab takes the player when
/// one of its frames starts playing sound, keeps it while paused, and gives it up when that
/// frame's page goes away.
@MainActor
@Observable
final class NowPlaying: NSObject, WKScriptMessageHandler {
    struct Media: Equatable {
        /// From the page's Media Session; the player falls back on the tab's title and icon.
        var title: String?
        var artist: String?
        /// A small JPEG or PNG the page drew itself: the app never loads what a page names.
        var artwork: CGImage?
        var isPaused: Bool
        /// Not muted nor at volume 0: only media heard take the player from another tab.
        var isAudible: Bool
        /// Where the media was when the page reported it, at `reportedAt`.
        var time: Double
        /// Nil for a live stream.
        var duration: Double?
        var rate: Double
        var hasPrevious: Bool
        var hasNext: Bool
        /// Its page just came back from the back-forward cache, its media paused by WebKit.
        var isRestored: Bool
        var reportedAt: Date

        /// Where the media is now, counted on from the last report rather than asked again.
        func elapsed(at date: Date) -> Double {
            guard !isPaused else { return time }
            let elapsed = time + max(0, date.timeIntervalSince(reportedAt)) * rate
            return duration.map { min(elapsed, $0) } ?? elapsed
        }

        /// A message from the page; nil when it has nothing playing.
        init?(message body: Any, at date: Date) {
            guard let body = body as? [String: Any] else { return nil }
            let text = { (key: String) in (body[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
            let number = { (key: String) in (body[key] as? NSNumber)?.doubleValue.nonNegative }
            title = text("title")
            artist = text("artist")
            artwork = text("artwork").flatMap(Self.picture)
            isPaused = body["paused"] as? Bool ?? true
            isAudible = body["audible"] as? Bool ?? true
            duration = number("duration").flatMap { $0 > 0 ? $0 : nil }
            time = min(number("time") ?? 0, duration ?? .infinity)
            rate = number("rate").flatMap { $0 > 0 ? $0 : nil } ?? 1
            hasPrevious = body["previous"] as? Bool ?? false
            hasNext = body["next"] as? Bool ?? false
            isRestored = body["restored"] as? Bool ?? false
            reportedAt = date
        }

        /// A data URL as the script makes it, at most 64 KB and 512 pixels a side. Any script of
        /// the page can post one, and ImageIO decodes it here, outside WebContent's sandbox:
        /// only a JPEG or a PNG gets that far, whatever the bytes say they are.
        private static func picture(_ url: String) -> CGImage? {
            let formats: [String: (type: UTType, magic: [UInt8])] = [
                "data:image/jpeg;base64": (.jpeg, [0xFF, 0xD8, 0xFF]),
                "data:image/png;base64": (.png, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
            ]
            guard url.utf8.count <= 64 * 1024, let comma = url.firstIndex(of: ","),
                  let format = formats[String(url[..<comma])],
                  let data = Data(base64Encoded: String(url[url.index(after: comma)...])), data.starts(with: format.magic),
                  let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceTypeIdentifierHint: format.type.identifier] as CFDictionary),
                  CGImageSourceGetType(source) as String? == format.type.identifier,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  1...512 ~= width, 1...512 ~= height else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
    }

    /// The frame of the tab that reports, the page or one of its iframes, each with its own script.
    struct Frame {
        /// Made up by the frame's script.
        var id: String
        /// Where the player's buttons go; nil for the page itself.
        var info: WKFrameInfo? = nil
        /// An iframe, perhaps an ad's: its word alone takes no player.
        var isSubframe = false
    }

    static let name = "lithiumNowPlaying"

    /// Whether the sidebar shows the player, on by default. Pages get the script and its channel
    /// either way, which any script of the page could see to tell Lithium from Safari: a tab
    /// that starts playing sound pauses the one heard before, player shown or not.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Preference.miniPlayer) as? Bool ?? true
    }

    /// In the page's world, where its Media Session and its media elements are.
    static let script = WKUserScript(
        source: Resources.bundle.url(forResource: "now-playing", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "",
        injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page
    )

    private(set) var tab: Tab?
    private(set) var media: Media?
    @ObservationIgnored private var frame: Frame?
    /// The page's own last word, which `media` may contradict while a toggle settles.
    @ObservationIgnored private var reported: Media?
    /// What the last toggle shows, until the page agrees or `settle` seconds pass.
    @ObservationIgnored private var expected: (isPaused: Bool, until: Date)?
    /// Ends the last toggle's wait; awaited in tests, where the main actor may run it late.
    @ObservationIgnored private(set) var settling: Task<Void, Never>?
    /// The tab heard before the one holding the player, paused once WebKit hears the new one too:
    /// a page's word alone silences no other tab. WebKit may hear it only a report later, once
    /// the media loaded (the script reports at `play`, then at `playing`).
    @ObservationIgnored private weak var unpaused: Tab?

    static let settle: TimeInterval = 1.5

    @ObservationIgnored weak var browser: Browser?
    /// Whether WebKit hears the tab, nil when it can't tell; replaced in tests.
    @ObservationIgnored var isHeard: (Tab) -> Bool? = { $0.isPlayingAudio }
    /// Whether the tab is in a call, which no other sound pauses; replaced in tests.
    @ObservationIgnored var isInCall: (Tab) -> Bool = { $0.isInCall }
    /// Pauses every media of the tab, in all its frames and in the floating player; replaced in tests.
    @ObservationIgnored var pause: (Tab) -> Void = { tab in
        guard !tab.isAsleep, let webView = tab.loadedWebView else { return }
        Task { await webView.pauseAllMediaPlayback() }
    }
    /// The content controllers that have the channel.
    @ObservationIgnored private let channels = NSHashTable<WKUserContentController>.weakObjects()

    /// The tab the sidebar's player shows: none while its video is in the floating player, which
    /// already shows it. The tab keeps the player meanwhile, and shows again when the video goes back.
    func shownTab(besides popout: Tab?) -> Tab? {
        tab === popout ? nil : tab
    }

    /// Gives the controller the script, when a configuration is made and before each page, and
    /// the channel once.
    func install(on controller: WKUserContentController) {
        if !channels.contains(controller) {
            controller.add(self, contentWorld: .page, name: Self.name)
            channels.add(controller)
        }
        controller.addUserScript(Self.script)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let id = body["frame"] as? String,
              let tab = (message.webView as? PageWebView)?.tab,
              browser?.tabs.contains(tab) == true, !tab.isAsleep else { return }
        let isMain = message.frameInfo.isMainFrame
        let frame = Frame(id: id, info: isMain ? nil : message.frameInfo, isSubframe: !isMain)
        receive(Media(message: body["media"] ?? NSNull(), at: Date()), from: tab, frame: frame)
    }

    /// A frame playing sound takes the player, as does a page back from the back-forward cache when
    /// the player is free; the frame in it updates it, muted too, or leaves it with nothing to play.
    /// An iframe takes it only if WebKit hears the tab too: any page, or an ad in it, may say it
    /// plays. The page itself is taken at its word; it is the site the user went to. A muted tab
    /// is not heard, so it never takes the player, even back from the back-forward cache.
    /// One sound at a time: a tab taking the player from another that was heard pauses it once
    /// WebKit hears it as well, unless that one is in a call, whose participants it would silence,
    /// or muted, which makes no sound to stop.
    func receive(_ media: Media?, from tab: Tab, frame: Frame = Frame(id: "")) {
        let holds = tab === self.tab && frame.id == self.frame?.id
        let claims = { (media: Media) in
            !media.isPaused && media.isAudible && !tab.isMuted && (!frame.isSubframe || self.isHeard(tab) != false)
        }
        if let media, holds || claims(media) || media.isRestored && self.tab == nil && !tab.isMuted {
            if !holds {
                expected = nil
                unpaused = nil
                if let previous = self.tab, previous !== tab, !previous.isMuted,
                   let heard = self.media, !heard.isPaused, heard.isAudible {
                    unpaused = previous
                }
            }
            if let previous = unpaused, !media.isPaused, media.isAudible {
                if isHeard(tab) != false {
                    unpaused = nil
                    if !isInCall(previous), !previous.isMuted { pause(previous) }
                }
            } else {
                unpaused = nil
            }
            self.tab = tab
            self.frame = frame
            reported = media
            self.media = settled(media)
        } else if holds {
            discard(tab)
        }
    }

    /// The tab closed, fell asleep, went to another page, or was muted.
    func discard(_ tab: Tab) {
        if tab === unpaused { unpaused = nil }
        guard tab === self.tab else { return }
        self.tab = nil
        unpaused = nil
        frame = nil
        media = nil
        reported = nil
        expected = nil
    }

    /// The page's report, unless it contradicts a toggle still settling: a page that pauses
    /// later (Spotify) reports playing for a moment, which would flicker the button.
    private func settled(_ media: Media) -> Media {
        guard let expected else { return media }
        guard media.isPaused != expected.isPaused, media.reportedAt < expected.until else {
            self.expected = nil
            return media
        }
        var media = media
        media.isPaused = expected.isPaused
        return media
    }

    /// Shows the change at once, until the page's media follow, or shows them again if they don't.
    /// The page is told what the button showed, not to toggle: a page still pausing from the
    /// last click (Spotify) would take a second one for another pause.
    func togglePlay() {
        guard var media else { return }
        let now = Date()
        media.time = media.elapsed(at: now)
        media.reportedAt = now
        media.isPaused.toggle()
        self.media = media
        let until = now.addingTimeInterval(Self.settle)
        expected = (media.isPaused, until)
        send(media.isPaused ? "pause" : "play")
        settling = Task {
            try? await Task.sleep(for: .seconds(Self.settle))
            guard expected?.until == until else { return }
            expected = nil
            self.media = reported
        }
    }

    func previous() { send("previous") }
    func next() { send("next") }

    func showTab() {
        if let tab { browser?.select(tab) }
    }

    private func send(_ command: String) {
        guard let tab, !tab.isAsleep else { return }
        let webView = tab.webView
        let frame = frame?.info
        Task { await Self.run(command, in: webView, frame: frame) }
    }

    /// "play", "pause", "previous" or "next", answered by the script of the frame that plays.
    static func run(_ command: String, in webView: WKWebView, frame: WKFrameInfo? = nil) async {
        _ = try? await webView.callAsyncJavaScript(
            "globalThis[Symbol.for('lithium.nowPlaying')]?.(command)",
            arguments: ["command": command], in: frame, contentWorld: .page
        )
    }
}

private extension Double {
    var nonNegative: Double? { isFinite && self >= 0 ? self : nil }
}

import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers
import WebKit

/// What the last tab heard plays, for the sidebar's mini player, as `now-playing.js` reports it.
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
        var time: Double
        /// Nil for a live stream.
        var duration: Double?
        /// A stream with no end, as its media element says: Web Audio and media still loading have no
        /// duration either.
        var isLive: Bool
        /// Which of the frame's sounds this is (a media element, or Web Audio since WebKit last heard the
        /// page): a second ping is another sound, its position or volume changing the same one.
        var source: Int?
        var rate: Double
        var hasPrevious: Bool
        var hasNext: Bool
        /// Its page just came back from the back-forward cache, its media paused by WebKit.
        var isRestored: Bool
        var reportedAt: Date

        /// The player's time moves only while media of known length plays: a stream shows a fixed
        /// "Live", so a clock for it would wake the main thread for nothing.
        var showsMovingTime: Bool { !isPaused && duration != nil }

        func elapsed(at date: Date) -> Double {
            guard !isPaused else { return time }
            let elapsed = time + max(0, date.timeIntervalSince(reportedAt)) * rate
            return duration.map { min(elapsed, $0) } ?? elapsed
        }

        init?(message body: Any, at date: Date) {
            guard let body = body as? [String: Any] else { return nil }
            let text = { (key: String) in (body[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
            let number = { (key: String) in (body[key] as? NSNumber)?.doubleValue.nonNegative }
            title = text("title")
            artist = text("artist")
            artwork = text("artwork").flatMap(Self.picture)
            isPaused = body["paused"] as? Bool ?? true
            isAudible = body["audible"] as? Bool ?? true
            // A page may claim any length: past `PlaybackTime.longest` it is none, like a stream's.
            duration = number("duration").flatMap { 0 < $0 && $0 <= PlaybackTime.longest ? $0 : nil }
            time = min(number("time") ?? 0, duration ?? PlaybackTime.longest)
            isLive = body["live"] as? Bool ?? false
            source = (body["source"] as? NSNumber)?.intValue
            rate = number("rate").flatMap { $0 > 0 ? $0 : nil } ?? 1
            hasPrevious = body["previous"] as? Bool ?? false
            hasNext = body["next"] as? Bool ?? false
            isRestored = body["restored"] as? Bool ?? false
            reportedAt = date
        }

        /// Any page script can post one, and ImageIO decodes it outside WebContent's sandbox: only a
        /// JPEG or PNG of at most 64 KB and 512 pixels a side gets that far.
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

    struct Frame {
        var id: String
        /// Where the player's buttons go; nil for the page itself.
        var info: WKFrameInfo? = nil
        /// An iframe, perhaps an ad's: its word alone takes no player.
        var isSubframe = false
    }

    static let name = "lithiumNowPlaying"

    /// Pages get the script and its channel either way, which a page could see to tell Lithium
    /// from Safari: a tab that starts playing sound pauses the one heard before, player shown or not.
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
    /// The tab heard before, paused once WebKit hears the new one too: a page's word alone silences
    /// no other tab. WebKit may hear it only a report later, or after the last (`hearingChanged`).
    @ObservationIgnored private weak var unpaused: Tab?
    /// The frame that played in `unpaused`, whose Web Audio the main frame's script can't hold.
    @ObservationIgnored private var unpausedFrame: Frame?
    /// Each tab's iframes that made Web Audio: they never report it (WebKit tells only the page what
    /// it hears), yet another tab's sound must hold it too.
    @ObservationIgnored private var audioFrames: [ObjectIdentifier: [String: WKFrameInfo]] = [:]
    /// The iframes each tab was held with (`hush`), freed with it by a click in any of its frames.
    @ObservationIgnored private var hushed: [ObjectIdentifier: [WKFrameInfo]] = [:]
    /// An iframe's last word from before WebKit heard its tab, one per tab: WebKit often hears a
    /// sound only after the first report, which would otherwise be lost.
    @ObservationIgnored private var unheard: [ObjectIdentifier: (media: Media, frame: Frame)] = [:]
    /// Each tab's frames another of its frames took the player from while they played on, until they
    /// say otherwise: one takes it back once the frame shown stops, as a page's script follows its media.
    @ObservationIgnored private var behind: [ObjectIdentifier: [String: (media: Media, frame: Frame)]] = [:]
    /// A sound not known to last, one per frame of each tab, with when it was first reported playing: a
    /// ping or music, told apart by whether WebKit still hears it `sustain` seconds later.
    @ObservationIgnored private var unproven: [ObjectIdentifier: [String: (media: Media, frame: Frame, since: Date)]] = [:]
    /// The last wait for such a sound; awaited in tests.
    @ObservationIgnored private(set) var proving: Task<Void, Never>?

    static let settle: TimeInterval = 1.5
    /// A sound this long or shorter may be an effect (a chat's ping), not something to listen to.
    static let brief: TimeInterval = 5
    /// A sound still heard this long after it started is no ping: WhatsApp's lasts 2.3 s.
    static let sustain: TimeInterval = 3

    @ObservationIgnored weak var browser: Browser?
    /// Whether WebKit hears the tab, nil when it can't tell; replaced in tests.
    @ObservationIgnored var isHeard: (Tab) -> Bool? = { $0.isPlayingAudio }
    /// Whether the tab is in a call, which no other sound pauses; replaced in tests.
    @ObservationIgnored var isInCall: (Tab) -> Bool = { $0.isInCall }
    /// Pauses all the tab's media, the floating player's too; replaced in tests.
    @ObservationIgnored var pause: (Tab) -> Void = { tab in
        guard !tab.isAsleep, let webView = tab.loadedWebView else { return }
        Task { await webView.pauseAllMediaPlayback() }
    }
    /// Silences the tab heard before another (`hush(_:frames:)`); replaced in tests.
    @ObservationIgnored var hush: (Tab, [WKFrameInfo]) -> Void = { tab, frames in
        guard !tab.isAsleep, let webView = tab.loadedWebView else { return }
        Task { await NowPlaying.hush(webView, frames: frames) }
    }
    /// Replaced in tests.
    @ObservationIgnored var tell: (Tab, String, WKFrameInfo?) -> Void = { tab, command, frame in
        guard !tab.isAsleep, let webView = tab.loadedWebView else { return }
        Task { await NowPlaying.run(command, in: webView, frame: frame) }
    }
    @ObservationIgnored private let channels = NSHashTable<WKUserContentController>.weakObjects()

    /// None while the tab's video is in the floating player, which already shows it.
    func shownTab(besides popout: Tab?) -> Tab? {
        tab === popout ? nil : tab
    }

    /// The script each time (a configuration is made, and before each page); the channel once.
    func install(on controller: WKUserContentController) {
        if !channels.contains(controller) {
            controller.add(self, contentWorld: .page, name: Self.name)
            channels.add(controller)
        }
        controller.addUserScript(Self.script)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let tab = (message.webView as? PageWebView)?.tab else { return }
        receive(message.body, from: tab, frameInfo: message.frameInfo)
    }

    /// A frame's word: what it plays, or that it made Web Audio. The page itself is reached without
    /// its `WKFrameInfo`.
    func receive(_ body: Any, from tab: Tab, frameInfo: WKFrameInfo) {
        guard let body = body as? [String: Any], let id = body["frame"] as? String,
              browser?.tabs.contains(tab) == true, !tab.isAsleep else { return }
        let isMain = frameInfo.isMainFrame
        let frame = Frame(id: id, info: isMain ? nil : frameInfo, isSubframe: !isMain)
        if body["audio"] != nil { return receiveAudio(from: tab, frame: frame) }
        if body["released"] != nil { return free(tab) }
        receive(Media(message: body["media"] ?? NSNull(), at: Date()), from: tab, frame: frame)
    }

    /// A frame playing sound takes the player, as does a page back from the back-forward cache when
    /// the player is free. An iframe takes it only if WebKit hears the tab too: any ad may say it
    /// plays; the page itself is taken at its word. One sound at a time: the tab heard before is
    /// paused once WebKit hears the new one, unless it is in a call or muted. Only a sound that lasts
    /// claims: one longer than `brief` or a live stream at once, any other (a chat's ping, Web Audio,
    /// media still loading) once it has `lasted`, still heard `sustain` seconds after its frame first
    /// reported it.
    func receive(_ media: Media?, from tab: Tab, frame: Frame = Frame(id: ""), lasted: Bool = false) {
        let holds = tab === self.tab && frame.id == self.frame?.id
        let key = ObjectIdentifier(tab)
        if unheard[key]?.frame.id == frame.id { unheard[key] = nil }
        // Kept only for the same sound: another one (a second ping) may still be heard at the old check.
        let waited = unproven[key]?.removeValue(forKey: frame.id)
        let next = holds && media?.isPaused != false ? behind[key]?.values.max { $0.media.reportedAt < $1.media.reportedAt } : nil
        if behind[key]?[frame.id] != nil {
            behind[key]?[frame.id] = media.flatMap { !$0.isPaused && $0.isAudible ? (media: $0, frame: frame) : nil }
        }
        // An iframe's word needs WebKit's ear, back from the back-forward cache too.
        let isTrusted = !frame.isSubframe || isHeard(tab) != false
        let lasts = { (media: Media) in lasted || media.isLive || media.duration.map { $0 > Self.brief } == true }
        let claims = { (media: Media) in
            !media.isPaused && media.isAudible && !tab.isMuted && isTrusted && lasts(media)
        }
        if let media, holds || claims(media) || media.isRestored && self.tab == nil && !tab.isMuted && isTrusted {
            if !holds {
                expected = nil
                // Another sound took the player: none still waiting takes it back.
                if !media.isPaused { unproven.removeAll() }
                // A third tab's word leaves the claim on the tab heard before.
                if unpaused === tab { unpaused = nil }
                if unpaused == nil, let previous = self.tab, previous !== tab, !previous.isMuted,
                   let heard = self.media, !heard.isPaused, heard.isAudible {
                    unpaused = previous
                    unpausedFrame = self.frame
                }
                if self.tab === tab, let shown = self.frame, let reported, !reported.isPaused, reported.isAudible {
                    behind[key, default: [:]][shown.id] = (reported, shown)
                }
                behind[key]?[frame.id] = nil
            }
            if let previous = unpaused, !media.isPaused, media.isAudible {
                if isHeard(tab) != false {
                    unpaused = nil
                    if !isInCall(previous), !previous.isMuted {
                        let frames = subframes(of: previous)
                        hushed[ObjectIdentifier(previous)] = frames
                        hush(previous, frames)
                    }
                }
            } else if isHeard(tab) != false {
                // A pause before WebKit hears the tab (a source swapped, an ad) keeps the claim.
                unpaused = nil
            }
            self.tab = tab
            self.frame = frame
            reported = media
            self.media = settled(media)
        } else if holds {
            // The other frames' sounds still wait.
            let waiting = unproven[key]
            discard(tab, pageGone: false)
            unproven[key] = waiting
        } else if let media, !media.isPaused, media.isAudible, !tab.isMuted, !lasts(media) {
            if let waited, waited.media.source == media.source {
                // The same sound again (its position, metadata or volume): its check stays.
                unproven[key, default: [:]][frame.id] = (media, frame, waited.since)
            } else {
                prove(media, from: tab, frame: frame)
            }
        } else if let media, frame.isSubframe, !media.isPaused, media.isAudible {
            // Turned down only for want of WebKit's ear, which hears no muted tab.
            unheard[key] = (media, frame)
        }
        // The frame shown stopped: another of the tab's, playing on, shows instead.
        if let next {
            behind[key]?[next.frame.id] = nil
            receive(next.media, from: tab, frame: next.frame)
        }
    }

    /// One check, `sustain` seconds after the frame first reported the sound playing: it claims if WebKit
    /// still hears its tab and the frame has reported no other sound nor a pause since. Web Audio that
    /// plays on sends no other report.
    private func prove(_ media: Media, from tab: Tab, frame: Frame) {
        let key = ObjectIdentifier(tab), since = Date()
        unproven[key, default: [:]][frame.id] = (media, frame, since)
        proving = Task { [weak tab] in
            try? await Task.sleep(for: .seconds(Self.sustain))
            guard let tab, unproven[key]?[frame.id]?.since == since,
                  let waiting = unproven[key]?.removeValue(forKey: frame.id),
                  isHeard(tab) == true, browser?.tabs.contains(tab) == true, !tab.isAsleep else { return }
            receive(waiting.media, from: tab, frame: waiting.frame, lasted: true)
        }
    }

    /// WebKit started or stopped hearing the tab (Safari's speaker icon). The page is asked what it
    /// plays either way: its sound may come from no media element (Web Audio).
    func hearingChanged(_ tab: Tab) {
        guard browser?.tabs.contains(tab) == true, !tab.isAsleep else { return }
        guard isHeard(tab) == true else {
            // Over before its check: none of the tab's sounds may claim for one heard later.
            unproven[ObjectIdentifier(tab)] = nil
            if tab === self.tab, frame?.isSubframe == false { tell(tab, "silent", nil) }
            return
        }
        if let waiting = unheard.removeValue(forKey: ObjectIdentifier(tab)) {
            receive(waiting.media, from: tab, frame: waiting.frame)
        } else if tab === self.tab, let reported, let frame {
            // A paused last word would drop a claim made before WebKit heard the tab: the page says again.
            if !reported.isPaused { receive(reported, from: tab, frame: frame) }
            // A sound shown paused when it went silent plays again (Web Audio resumed).
            if !frame.isSubframe { tell(tab, "heard", nil) }
        } else {
            tell(tab, "heard", nil)
        }
    }

    /// An iframe of the tab made Web Audio.
    private func receiveAudio(from tab: Tab, frame: Frame) {
        if let info = frame.info { audioFrames[ObjectIdentifier(tab), default: [:]][frame.id] = info }
    }

    /// A click in one of the held tab's frames: the page and the iframes held with it may play again.
    private func free(_ tab: Tab) {
        guard let frames = hushed.removeValue(forKey: ObjectIdentifier(tab)) else { return }
        tell(tab, "free", nil)
        for info in frames { tell(tab, "free", info) }
    }

    /// The iframes to hold besides the page: the one that played and those with Web Audio.
    private func subframes(of tab: Tab) -> [WKFrameInfo] {
        var frames = audioFrames[ObjectIdentifier(tab)] ?? [:]
        if let unpausedFrame, let info = unpausedFrame.info { frames[unpausedFrame.id] = info }
        return Array(frames.values)
    }

    /// Muted, the tab lets go of the player. An iframe playing on keeps its word for when WebKit hears
    /// the tab again, which asks only the page what it plays (`hearingChanged`). The page playing on
    /// stays behind: an iframe that takes the player back on unmute shows it again once it stops.
    func mute(_ tab: Tab) {
        let shown = tab === self.tab ? frame.flatMap { frame in reported.map { (media: $0, frame: frame) } } : nil
        discard(tab, pageGone: false)
        guard let shown, !shown.media.isPaused else { return }
        let key = ObjectIdentifier(tab)
        if shown.frame.isSubframe {
            unheard[key] = shown
        } else if shown.media.isAudible {
            behind[key, default: [:]][shown.frame.id] = shown
        }
    }

    /// The tab closed, fell asleep, went to another page, or was muted. Its iframes' Web Audio is kept
    /// while its page stays (`pageGone` false): each says so only once.
    func discard(_ tab: Tab, pageGone: Bool = true) {
        if tab === unpaused { unpaused = nil }
        unheard[ObjectIdentifier(tab)] = nil
        unproven[ObjectIdentifier(tab)] = nil
        if pageGone {
            behind[ObjectIdentifier(tab)] = nil
            audioFrames[ObjectIdentifier(tab)] = nil
            hushed[ObjectIdentifier(tab)] = nil
        }
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
        guard let tab else { return }
        tell(tab, command, frame?.info)
        // Played again, the iframes held with it (`hush`) may resume their Web Audio too.
        if command == "play" {
            // Played in an iframe, the page held with it resumes too.
            if frame?.isSubframe == true { tell(tab, "release", nil) }
            for info in (audioFrames[ObjectIdentifier(tab)] ?? [:]).values { tell(tab, "release", info) }
        }
    }

    /// The page pauses with its own pause key first, then WebKit pauses all its media and suspends its
    /// Web Audio: a page paused behind its back may start its sound again, unaware why it stopped.
    /// The page, and the iframes given, keep their Web Audio suspended until played again.
    static func hush(_ webView: WKWebView, frames: [WKFrameInfo] = []) async {
        await run("hush", in: webView)
        for frame in frames { await run("hush", in: webView, frame: frame) }
        await webView.pauseAllMediaPlayback()
    }

    /// "play", "pause", "hush", "release", "free", "previous" or "next", answered by the script of the frame that plays;
    /// "heard" or "silent", what WebKit hears of the page.
    static func run(_ command: String, in webView: WKWebView, frame: WKFrameInfo? = nil) async {
        _ = try? await webView.callAsyncJavaScript(
            "globalThis[Symbol.for('lithium.nowPlaying')]?.(command)",
            arguments: ["command": command], in: frame, contentWorld: .page
        )
    }
}

/// Calls back when WebKit starts or stops hearing a web view: private `_isPlayingAudio`, which
/// WebKit announces to key-value observers. Nothing runs while the page's sound doesn't change.
final class Hearing: NSObject {
    private static let key = "_isPlayingAudio"
    private let webView: NSObject
    private let changed: @MainActor @Sendable () -> Void

    /// Nil from a WebKit without the property.
    init?(_ webView: WKWebView, changed: @escaping @MainActor @Sendable () -> Void) {
        guard webView.responds(to: Selector((Self.key))) else { return nil }
        self.webView = webView
        self.changed = changed
        super.init()
        webView.addObserver(self, forKeyPath: Self.key, options: [], context: nil)
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        let changed = changed
        MainActor.assumeIsolated { changed() }
    }

    deinit {
        webView.removeObserver(self, forKeyPath: Self.key)
    }
}

private extension Double {
    var nonNegative: Double? { isFinite && self >= 0 ? self : nil }
}

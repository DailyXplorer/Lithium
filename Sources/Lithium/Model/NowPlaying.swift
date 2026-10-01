import Foundation
import Observation
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
        var artwork: URL?
        var isPaused: Bool
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
            artwork = text("artwork").flatMap(URL.init(string:)).flatMap { ["http", "https"].contains($0.scheme) ? $0 : nil }
            isPaused = body["paused"] as? Bool ?? true
            time = number("time") ?? 0
            duration = number("duration").flatMap { $0 > 0 ? $0 : nil }
            rate = number("rate").flatMap { $0 > 0 ? $0 : nil } ?? 1
            hasPrevious = body["previous"] as? Bool ?? false
            hasNext = body["next"] as? Bool ?? false
            isRestored = body["restored"] as? Bool ?? false
            reportedAt = date
        }
    }

    /// The frame of the tab that reports, the page or one of its iframes, each with its own script.
    struct Frame {
        /// Made up by the frame's script.
        var id: String
        /// Where the player's buttons go; nil for the page itself.
        var info: WKFrameInfo? = nil
    }

    static let name = "lithiumNowPlaying"

    /// On by default. Pages loaded while it is off don't get the script.
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

    @ObservationIgnored weak var browser: Browser?

    /// The tab the sidebar's player shows: none while its video is in the floating player, which
    /// already shows it. The tab keeps the player meanwhile, and shows again when the video goes back.
    func shownTab(besides popout: Tab?) -> Tab? {
        tab === popout ? nil : tab
    }

    func install(on configuration: WKWebViewConfiguration) {
        configuration.userContentController.add(self, contentWorld: .page, name: Self.name)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let id = body["frame"] as? String,
              let tab = (message.webView as? PageWebView)?.tab,
              browser?.tabs.contains(tab) == true, !tab.isAsleep else { return }
        let frame = Frame(id: id, info: message.frameInfo.isMainFrame ? nil : message.frameInfo)
        receive(Media(message: body["media"] ?? NSNull(), at: Date()), from: tab, frame: frame)
    }

    /// A frame playing takes the player, as does a page back from the back-forward cache when the
    /// player is free; the frame in it updates it, or leaves it with nothing to play.
    func receive(_ media: Media?, from tab: Tab, frame: Frame = Frame(id: "")) {
        let holds = tab === self.tab && frame.id == self.frame?.id
        if let media, !media.isPaused || holds || media.isRestored && self.tab == nil {
            self.tab = tab
            self.frame = frame
            self.media = media
        } else if holds {
            discard(tab)
        }
    }

    /// The tab closed, fell asleep, or went to another page.
    func discard(_ tab: Tab) {
        guard tab === self.tab else { return }
        self.tab = nil
        frame = nil
        media = nil
    }

    /// Shows the change at once; the page's next report confirms it.
    func togglePlay() {
        guard var media else { return }
        let now = Date()
        media.time = media.elapsed(at: now)
        media.reportedAt = now
        media.isPaused.toggle()
        self.media = media
        send("toggle")
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

    /// "toggle", "previous" or "next", answered by the script of the frame that plays.
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

import AppKit
import Observation
import WebKit

/// A tab's video, kept playing in a small player over its window: the tab's own web view moves
/// into the player, and `video-popout.js` makes its video fill it. One player per window.
@MainActor
@Observable
final class VideoPopout {
    struct Playback: Equatable {
        var isPaused: Bool
        var time: Double
        /// Nil for a live stream.
        var duration: Double?
        var isMuted: Bool
        var aspectRatio: Double
    }

    private(set) var tab: Tab?
    private(set) var playback: Playback?

    @ObservationIgnored weak var window: BrowserWindow?
    private var browser: Browser? { window?.browser }
    /// Only the newest request shows the player: the user may have switched tabs while the page answered.
    @ObservationIgnored private var request = 0
    /// The page acts on a request even when its answer comes too late, so a late answer puts the video back.
    @ObservationIgnored private var pending: (tab: Tab, request: Int)?
    @ObservationIgnored private var polling: Task<Void, Never>?

    private static let script = Resources.bundle.url(forResource: "video-popout", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    private static let pollInterval: Duration = .milliseconds(500)
    /// How long the page holds the state check of a paused video that doesn't change (in ms).
    static let pausedWait = 5000

    /// The tab left behind pops its playing video out; the one shown takes its video back.
    func selectionChanged(from previous: Tab?, to selected: Tab?) {
        if let selected, selected === tab {
            hide()
        } else if let selected, selected === pending?.tab {
            request += 1
            pending = nil
        }
        guard let previous, previous !== tab, !previous.isAsleep, previous.pdf == nil else { return }
        // A request only once the page plays: leaving a tab that plays nothing leaves another
        // tab's video on its way to the player alone.
        let current = request
        Task {
            let playing = try? await Self.run("playing", in: previous.webView)
            guard playing as? Bool == true, current == request, isOutOfSight(previous) else { return }
            request += 1
            await show(previous, request: request)
        }
    }

    func showSelected() {
        guard browser?.quickLinks.keyTab == nil, let tab = window?.selectedTab, !tab.isAsleep, tab.pdf == nil else { return }
        request += 1
        let current = request
        // Known from now, not from when the task starts: the tab can be left and shown again
        // before it does, and the answer must then put the video back.
        pending = (tab, current)
        Task {
            await show(tab, request: current)
            // Still the newest request, yet no player: the page has no video the script reaches
            // (one in an iframe, such as an embed, or a shadow root). Like Reader, say so.
            if current == request, self.tab !== tab { beep() }
        }
    }

    /// Replaced in tests.
    @ObservationIgnored var beep: () -> Void = { NSSound.beep() }

    /// Not while a link's window is in front: the menu would pop out a browser window's video,
    /// and the player takes only `Browser.tabs`, which a link's page isn't in.
    var canShowSelected: Bool {
        guard browser?.quickLinks.keyTab == nil, let tab = window?.selectedTab else { return false }
        return tab !== self.tab && !tab.isAsleep && tab.pdf == nil && tab.url != nil
    }

    func hide() {
        guard let webView = detach() else { return }
        Task { await Self.putBack(webView, pausing: false) }
    }

    func close() {
        guard let webView = detach() else { return }
        Task { await Self.putBack(webView, pausing: true) }
    }

    /// For tests: the player takes `tab`, as if its video had popped out.
    func adopt(_ tab: Tab, playback: Playback? = nil) {
        self.tab = tab
        self.playback = playback
    }

    func discard(_ tab: Tab) {
        if tab === self.tab { hide() }
    }

    func togglePlay() {
        guard let playback else { return }
        // The player plays from its own world, which the page's hold (another tab's sound) doesn't see.
        if playback.isPaused, let tab { browser?.nowPlaying.release(tab) }
        send(playback.isPaused ? "play" : "pause")
    }

    func seek(to time: Double) {
        playback?.time = time
        send("seek", value: time)
    }

    func skip(by seconds: Double) {
        guard let playback else { return }
        seek(to: max(0, min(playback.time + seconds, playback.duration ?? .infinity)))
    }

    func toggleMute() {
        guard let playback else { return }
        send("mute", value: !playback.isMuted)
    }

    func returnToTab() {
        guard let tab else { return }
        if window?.selectedTab === tab { hide() } else { window?.select(tab) }
    }

    private func isOutOfSight(_ tab: Tab) -> Bool {
        guard let browser else { return false }
        return browser.tabs.contains(tab) && !browser.isOnScreen(tab) && !tab.isAsleep
    }

    private func show(_ tab: Tab, request current: Int) async {
        pending = (tab, current)
        let webView = tab.webView
        let state = try? await Self.run("show", in: webView)
        let newer = pending.map { $0.tab === tab && $0.request != current } ?? false
        if pending?.request == current { pending = nil }
        let isLive = browser?.tabs.contains(tab) == true && !tab.isAsleep
        guard current == request, isLive else {
            // Unless the player has this video or a newer request shows it, the page would be
            // left showing only its video.
            if self.tab !== tab, !newer { await Self.putBack(webView, pausing: false) }
            return
        }
        guard let playback = Self.playback(from: state) else { return }
        if let previous = self.tab, previous !== tab {
            let webView = previous.webView
            Task { await Self.putBack(webView, pausing: true) }
        }
        self.tab = tab
        self.playback = playback
        poll(tab)
    }

    /// Also closes the player when the video is gone (the page went elsewhere, or its process died).
    /// A paused video's check waits in the page until it changes, so an idle player asks every few seconds.
    private func poll(_ tab: Tab) {
        polling?.cancel()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self, !Task.isCancelled, self.tab === tab else { return }
                self.update(try? await Self.run("state", in: tab.webView, value: Self.pausedWait), from: tab)
            }
        }
    }

    private func send(_ command: String, value: Any = 0) {
        guard let tab else { return }
        Task { update(try? await Self.run(command, in: tab.webView, value: value), from: tab) }
    }

    private func update(_ state: Any?, from tab: Tab) {
        guard self.tab === tab else { return }
        guard let playback = Self.playback(from: state) else {
            hide()
            return
        }
        if playback != self.playback { self.playback = playback }
    }

    private func detach() -> WKWebView? {
        request += 1
        polling?.cancel()
        polling = nil
        guard let tab else { return nil }
        self.tab = nil
        playback = nil
        return tab.isAsleep ? nil : tab.webView
    }

    private static func putBack(_ webView: WKWebView, pausing: Bool) async {
        if pausing { _ = try? await run("pause", in: webView) }
        _ = try? await run("hide", in: webView)
    }

    static func run(_ command: String, in webView: WKWebView, value: Any = 0) async throws -> Any? {
        try await webView.callAsyncJavaScript(script, arguments: ["command": command, "value": value], contentWorld: .defaultClient)
    }

    /// Past 4:1 either way, the player keeps 4:1.
    static func playback(from state: Any?) -> Playback? {
        guard let state = state as? [String: Any],
              let width = state["width"] as? Double, let height = state["height"] as? Double,
              width > 0, height > 0 else { return nil }
        return Playback(
            isPaused: state["paused"] as? Bool ?? true,
            time: state["time"] as? Double ?? 0,
            duration: state["duration"] as? Double,
            isMuted: state["muted"] as? Bool ?? false,
            aspectRatio: min(max(width / height, 0.25), 4)
        )
    }
}

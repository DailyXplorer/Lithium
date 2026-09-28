import Foundation
import Observation
import WebKit

/// A tab's video, kept playing in a small player over the window while other tabs show: the
/// tab's own web view moves into the player, and `video-popout.js` makes its video fill it.
/// Leaving a tab whose video plays with sound pops it out; coming back to the tab puts it back.
@MainActor
@Observable
final class VideoPopout {
    struct Playback: Equatable {
        var isPaused: Bool
        var time: Double
        /// Nil for a live stream.
        var duration: Double?
        var isMuted: Bool
        /// Width over height.
        var aspectRatio: Double
    }

    /// The tab whose video shows in the player, and what it plays; nil while hidden.
    private(set) var tab: Tab?
    private(set) var playback: Playback?

    @ObservationIgnored weak var browser: Browser?
    /// Only the newest request shows the player: the page answers asynchronously, and the user
    /// may have switched tabs again, or come back, in between.
    @ObservationIgnored private var request = 0
    /// The page last asked to show its video, until its answer comes. The page acts on the
    /// request even when the answer comes too late, so a late answer puts the video back.
    @ObservationIgnored private var pending: (tab: Tab, request: Int)?
    @ObservationIgnored private var polling: Task<Void, Never>?

    private static let script = Resources.bundle.url(forResource: "video-popout", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    private static let pollInterval: Duration = .milliseconds(500)

    /// The selected tab changed: the one left behind pops its video out if it plays one with
    /// sound, and the one shown takes its video back.
    func selectionChanged(from previous: Tab?, to selected: Tab?) {
        if let selected, selected === tab {
            hide()
        } else if let selected, selected === pending?.tab {
            request += 1
            pending = nil
        }
        guard let previous, previous !== tab, !previous.isAsleep, !previous.isHome, previous.pdf == nil else { return }
        request += 1
        let current = request
        Task {
            let playing = try? await Self.run("playing", in: previous.webView)
            guard playing as? Bool == true, current == request, isOutOfSight(previous) else { return }
            await show(previous, request: current)
        }
    }

    /// Pops out the selected tab's video from the menu or ⌥⌘P; the page shows where it went.
    func showSelected() {
        guard let tab = browser?.selectedTab, !tab.isAsleep, tab.pdf == nil else { return }
        request += 1
        let current = request
        Task { await show(tab, request: current) }
    }

    var canShowSelected: Bool {
        guard let tab = browser?.selectedTab else { return false }
        return tab !== self.tab && !tab.isAsleep && tab.pdf == nil && tab.url != nil
    }

    /// Back to the page, where the video goes on playing.
    func hide() {
        guard let webView = detach() else { return }
        Task { await Self.putBack(webView, pausing: false) }
    }

    /// The close button: the video stops with the player.
    func close() {
        guard let webView = detach() else { return }
        Task { await Self.putBack(webView, pausing: true) }
    }

    /// The tab went away or fell asleep.
    func discard(_ tab: Tab) {
        if tab === self.tab { hide() }
    }

    func togglePlay() {
        guard let playback else { return }
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

    /// Selecting the tab takes the video back; a popped out selected tab just takes it back.
    func returnToTab() {
        guard let tab else { return }
        if browser?.selectedTab === tab { hide() } else { browser?.select(tab) }
    }

    private func isOutOfSight(_ tab: Tab) -> Bool {
        guard let browser else { return false }
        return browser.tabs.contains(tab) && browser.selectedTab !== tab && !tab.isAsleep
    }

    private func show(_ tab: Tab, request current: Int) async {
        pending = (tab, current)
        let webView = tab.webView
        let state = try? await Self.run("show", in: webView)
        let newer = pending.map { $0.tab === tab && $0.request != current } ?? false
        if pending?.request == current { pending = nil }
        guard current == request else {
            // Unless the player has this video or a newer request shows it, the page would be
            // left showing only its video.
            if self.tab !== tab, !newer { await Self.putBack(webView, pausing: false) }
            return
        }
        guard let playback = Self.playback(from: state) else { return }
        // A newer video takes the player; the one it replaces stops and goes back to its page.
        if let previous = self.tab, previous !== tab {
            let webView = previous.webView
            Task { await Self.putBack(webView, pausing: true) }
        }
        self.tab = tab
        self.playback = playback
        poll(tab)
    }

    /// Keeps the controls in step with the page, and closes the player when the video is gone
    /// (the page went elsewhere, or its process died).
    private func poll(_ tab: Tab) {
        polling?.cancel()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self, !Task.isCancelled, self.tab === tab else { return }
                self.update(try? await Self.run("state", in: tab.webView), from: tab)
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

    /// Stops polling and forgets the tab; its web view is what goes back to the page.
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

    private static func playback(from state: Any?) -> Playback? {
        guard let state = state as? [String: Any],
              let width = state["width"] as? Double, let height = state["height"] as? Double,
              width > 0, height > 0 else { return nil }
        return Playback(
            isPaused: state["paused"] as? Bool ?? true,
            time: state["time"] as? Double ?? 0,
            duration: state["duration"] as? Double,
            isMuted: state["muted"] as? Bool ?? false,
            aspectRatio: width / height
        )
    }
}

import AppKit
import WebKit

/// The window background tabs act in (design section 2.6). Off every screen, never key or
/// main, out of the Windows menu and window cycling, and blind to the mouse: it can't take
/// the user's focus or show anything, and it only exists so a page out of sight is laid out,
/// rendered and given events as if it were shown.
final class AgentStageWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

extension NSView {
    /// The window the user can see this view in: nil when it has none or sits in the stage.
    var userWindow: NSWindow? {
        window is AgentStageWindow ? nil : window
    }
}

/// Hosts background tabs' web views while an agent acts in them. A web view already in a
/// window (the selected tab, the video pop-out) stays where it is. One that isn't joins the
/// stage, with window occlusion detection off so its page counts as visible and unthrottled,
/// and leaves it 30 seconds after the agent's last action, or as soon as the user selects its
/// tab (`PageContainer` takes it, and `didLeave` restores occlusion detection).
@MainActor
final class AgentStage {
    static let origin = CGPoint(x: -30_000, y: -30_000)
    var releaseDelay: Duration = .seconds(30)

    private(set) var window: AgentStageWindow?
    private struct Entry {
        weak var webView: WKWebView?
        var lastUse: ContinuousClock.Instant
        /// Actions running in its tab: none is ever swept away mid-way.
        var holds = 0
    }
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var sweep: Task<Void, Never>?

    /// The web views staged now.
    var staged: [WKWebView] { entries.values.compactMap(\.webView) }

    /// Puts `webView` in a window, at `size`, unless it already is in one; either way it stays
    /// staged until `releaseDelay` after this call.
    func host(_ webView: WKWebView, size: CGSize) {
        if let entry = entries[ObjectIdentifier(webView)], entry.webView?.window === window, window != nil {
            entries[ObjectIdentifier(webView)]?.lastUse = .now
            scheduleSweep()
            return
        }
        guard webView.window == nil else { return }
        let window = stageWindow(size: size)
        Self.setOcclusionDetection(false, on: webView)
        webView.frame = CGRect(origin: .zero, size: size)
        webView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(webView)
        entries[ObjectIdentifier(webView)] = Entry(webView: webView, lastUse: .now)
        placeForFallback(window)
        scheduleSweep()
    }

    /// An action running in `webView`'s tab keeps it staged, however long it waits, until `letGo`.
    func hold(_ webView: WKWebView) {
        entries[ObjectIdentifier(webView)]?.holds += 1
    }

    /// The action ended: the web view stays staged until `releaseDelay` from now.
    func letGo(_ webView: WKWebView) {
        guard let entry = entries[ObjectIdentifier(webView)] else { return }
        entries[ObjectIdentifier(webView)] = Entry(webView: entry.webView, lastUse: .now, holds: max(0, entry.holds - 1))
        scheduleSweep()
    }

    /// Hooked from `PageWebView.viewDidMoveToWindow`: the user selected its tab, or it slept.
    func didLeave(_ webView: WKWebView) {
        guard !(webView.window is AgentStageWindow), entries.removeValue(forKey: ObjectIdentifier(webView)) != nil else { return }
        Self.setOcclusionDetection(true, on: webView)
        if entries.isEmpty { window?.orderOut(nil) }
    }

    func releaseAll() {
        sweep?.cancel()
        sweep = nil
        for webView in staged where webView.window === window { release(webView) }
        entries = [:]
        window?.orderOut(nil)
        window = nil
    }

    private func release(_ webView: WKWebView) {
        entries[ObjectIdentifier(webView)] = nil
        webView.removeFromSuperview()
        Self.setOcclusionDetection(true, on: webView)
    }

    private func scheduleSweep() {
        sweep?.cancel()
        guard let next = entries.values.filter({ $0.holds == 0 }).map(\.lastUse).min() else { return }
        let delay = releaseDelay
        sweep = Task { [weak self] in
            try? await Task.sleep(until: next + delay)
            guard !Task.isCancelled, let self else { return }
            let now = ContinuousClock.now
            for (key, entry) in self.entries where entry.holds == 0 && entry.lastUse + delay <= now {
                if let webView = entry.webView, webView.window === self.window { self.release(webView) } else { self.entries[key] = nil }
            }
            self.sweep = nil
            if self.entries.isEmpty { self.window?.orderOut(nil) }
            self.scheduleSweep()
        }
    }

    private func stageWindow(size: CGSize) -> AgentStageWindow {
        if let window {
            if window.frame.size != size { window.setContentSize(size) }
            if !window.isVisible { show(window) }
            return window
        }
        let window = AgentStageWindow(contentRect: CGRect(origin: Self.origin, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // An ordered-in window can be moved back onto a screen by macOS (one was seen under the
        // menu bar, a white rectangle behind Lithium's window): transparent, it shows nothing
        // wherever it ends up.
        window.alphaValue = 0
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.ignoresCycle, .transient, .canJoinAllSpaces]
        window.hasShadow = false
        window.animationBehavior = .none
        // Keys a page doesn't handle travel up the responder chain; here they would beep.
        window.contentView = WebContainerView(frame: CGRect(origin: .zero, size: size))
        show(window)
        self.window = window
        return window
    }

    /// Behind every window, off every screen: ordered in so WebKit counts it as shown, never
    /// in front of anything, never key. Ordered out again once nothing is staged.
    private func show(_ window: AgentStageWindow) {
        window.setFrameOrigin(Self.origin)
        window.orderBack(nil)
    }

    // MARK: Occlusion

    private static let occlusionSelector = Selector(("_setWindowOcclusionDetectionEnabled:"))

    /// Whether this WebKit has the private call; without it the stage moves to the fallback placement.
    static func hasOcclusionControl(_ webView: WKWebView) -> Bool {
        webView.responds(to: occlusionSelector)
    }

    private static func setOcclusionDetection(_ enabled: Bool, on webView: WKWebView) {
        guard hasOcclusionControl(webView) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(webView.method(for: occlusionSelector), to: Setter.self)(webView, occlusionSelector, enabled)
    }

    /// Without the private call, a window off every screen counts as occluded and its pages as
    /// hidden: the stage sits under Lithium's window instead, at its frame, where it can't be
    /// seen (design section 3, item 17: unverified). With no window of Lithium's shown, it stays off screen.
    private func placeForFallback(_ window: AgentStageWindow) {
        guard let webView = staged.first, !Self.hasOcclusionControl(webView) else { return }
        guard let main = NSApp?.windows.first(where: { $0.isVisible && $0.canBecomeMain && !($0 is AgentStageWindow) }) else { return }
        window.setFrame(main.frame, display: false)
        window.order(.below, relativeTo: main.windowNumber)
    }
}

import AppKit
import Observation

/// The order tabs were last shown in, for Control-Tab, and the tab a tab was opened from, for
/// closing it. A switch stamps the tab shown and nothing more: the order is only worked out when
/// Control-Tab is pressed, and nothing watches the keyboard until then.
@MainActor
@Observable
final class RecentTabs {
    /// While Control is held after Control-Tab: the tabs, the one shown first and then the most
    /// recently shown. Empty otherwise.
    private(set) var cycle: [Tab] = []
    /// The tab in `cycle` that letting go of Control goes to.
    private(set) var cycleIndex = 0
    var target: Tab? { cycle.indices.contains(cycleIndex) ? cycle[cycleIndex] : nil }

    @ObservationIgnored private var shown: [Tab.ID: Int] = [:]
    @ObservationIgnored private var clock = 0
    @ObservationIgnored private var openings: [Tab.ID: Opening] = [:]
    /// The tab the user went to straight from the one that opened it, with no other switch in
    /// between, and that opener: closing the first goes back to the second.
    @ObservationIgnored private weak var opened: Tab?
    @ObservationIgnored private weak var opener: Tab?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var focusObservers: [any NSObjectProtocol] = []

    private struct Opening {
        weak var opener: Tab?
        /// `clock` when it was opened: the opener was still the tab shown if its stamp is this one.
        let at: Int
    }

    func didOpen(_ tab: Tab, from opener: Tab) {
        openings[tab.id] = Opening(opener: opener, at: clock)
    }

    func didShow(_ tab: Tab, after previous: Tab?) {
        if let previous, let opening = openings[tab.id], opening.opener === previous, shown[previous.id] ?? 0 == opening.at {
            opened = tab
            opener = previous
        } else {
            opened = nil
            opener = nil
        }
        clock += 1
        shown[tab.id] = clock
    }

    /// The tab to show once `tab`, the one shown, closes, if it should be its opener.
    func opener(returningFrom tab: Tab) -> Tab? {
        opened === tab ? opener : nil
    }

    func didClose(_ tab: Tab) {
        shown[tab.id] = nil
        openings[tab.id] = nil
    }

    /// The first press starts from `current`: forward goes to the tab shown before it, back to the
    /// one shown longest ago. From the start page forward goes to the last tab shown. Tabs never
    /// shown keep their order at the end.
    func step(backward: Bool, among tabs: [Tab], current: Tab?) {
        if cycle.isEmpty {
            var order = tabs.filter { $0 !== current }.enumerated()
                .sorted { (shown[$0.element.id] ?? 0, -$0.offset) > (shown[$1.element.id] ?? 0, -$1.offset) }
                .map(\.element)
            if let current { order.insert(current, at: 0) }
            guard order.count > (current == nil ? 0 : 1) else { return }
            cycle = order
            cycleIndex = current == nil && !backward ? order.count - 1 : 0
        }
        cycleIndex = (cycleIndex + (backward ? -1 : 1) + cycle.count) % cycle.count
    }

    /// Only while a cycle is open. Letting go of Control ends it on the highlighted tab, as does a
    /// key pressed without Control (it was let go outside the window); a click ends it where it was,
    /// and so does the window losing the keyboard, since Control may then be let go where Lithium
    /// never hears it.
    func watchControl(_ end: @escaping @MainActor (_ commit: Bool) -> Void) {
        guard monitor == nil, !cycle.isEmpty else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]) { event in
            MainActor.assumeIsolated {
                switch event.type {
                case .flagsChanged, .keyDown: if !event.modifierFlags.contains(.control) { end(true) }
                default: end(false)
                }
            }
            return event
        }
        focusObservers = [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification].map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { end(false) }
            }
        }
    }

    /// The tab the cycle was on, and the keyboard is left alone again.
    func endCycle() -> Tab? {
        let tab = target
        cycle = []
        cycleIndex = 0
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        focusObservers.forEach { NotificationCenter.default.removeObserver($0) }
        focusObservers = []
        return tab
    }
}

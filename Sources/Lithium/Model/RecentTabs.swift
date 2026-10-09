import AppKit
import Observation

/// The order tabs were last shown in, for Control-Tab, and each tab's opener, for closing it.
/// A switch only stamps the tab: the order is worked out, and the keyboard watched, on Control-Tab.
@MainActor
@Observable
final class RecentTabs {
    /// While Control is held after Control-Tab: the tabs, most recently shown first. Empty otherwise.
    private(set) var cycle: [Tab] = []
    /// The tab in `cycle` that letting go of Control goes to.
    private(set) var cycleIndex = 0
    var target: Tab? { cycle.indices.contains(cycleIndex) ? cycle[cycleIndex] : nil }

    @ObservationIgnored private var shown: [Tab.ID: Int] = [:]
    @ObservationIgnored private var clock = 0
    @ObservationIgnored private var openings: [Tab.ID: Opening] = [:]
    /// A tab opened by no page (an address typed, a link from another app), with the tab shown
    /// before it: nil for the start page.
    @ObservationIgnored private var replacements: [Tab.ID: Tab.ID?] = [:]
    /// A tab gone to straight from its opener: closing it goes back to the opener.
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

    func didOpen(_ tab: Tab, replacing shown: Tab?) {
        replacements[tab.id] = .some(shown?.id)
    }

    /// What `tab` was opened over, if no page opened it: `.some(nil)` is the start page.
    func shownBefore(_ tab: Tab) -> Tab.ID?? {
        replacements[tab.id]
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
        replacements[tab.id] = nil
    }

    /// Forward goes to the tab shown before `current`, back to the one shown longest ago; tabs
    /// never shown keep their order at the end.
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

    /// A key pressed without Control means it was let go outside the window. Losing the keyboard
    /// ends the cycle too, since Control may then be let go where Lithium never hears it.
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

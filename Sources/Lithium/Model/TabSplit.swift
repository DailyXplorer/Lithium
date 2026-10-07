import AppKit
import Observation

/// Two tabs of the tab list shown together, Arc-like: side by side, or one above the other.
/// The selected tab is the focused side, so the address bar, the toolbar and the menus act on
/// it as they would on a lone tab. Selecting another tab shows that tab alone; selecting either
/// side of the pair shows both again.
struct TabSplit: Equatable {
    enum Side { case first, second }

    /// Left, or top when stacked.
    var first: Tab.ID
    /// Right, or bottom when stacked.
    var second: Tab.ID
    var isStacked = false
    /// The first side's share of the page area.
    var fraction = 0.5

    static let fractions = 0.25...0.75

    func contains(_ id: Tab.ID) -> Bool { first == id || second == id }

    func partner(of id: Tab.ID) -> Tab.ID? {
        id == first ? second : id == second ? first : nil
    }

    func side(of id: Tab.ID) -> Side? {
        id == first ? .first : id == second ? .second : nil
    }
}

/// The window's splits, and the tab being dragged from the sidebar, which brings the page's
/// drop zones in until the next click.
@MainActor
@Observable
final class TabSplits {
    fileprivate(set) var pairs: [TabSplit] = []
    fileprivate(set) var draggedTabID: Tab.ID?
}

extension Session {
    /// A split by the places of its tabs in `Session.tabs`.
    struct Split: Codable, Equatable {
        var first: Int
        var second: Int
        var isStacked: Bool
        var fraction: Double
    }
}

/// One row of the tab list: a tab alone, or the pair it leads. `index` is the tab's place in
/// `regularTabs`, which drops are measured against.
struct TabListEntry: Identifiable {
    let index: Int
    let tab: Tab
    let split: TabSplit?
    var id: Tab.ID { tab.id }
}

extension Browser {
    /// Only tabs of the tab list pair up: a favorite's page and an agent's tab live elsewhere.
    func split(of tab: Tab) -> TabSplit? {
        guard !splits.pairs.isEmpty, tab.isInTabList else { return nil }
        return splits.pairs.first { $0.contains(tab.id) }
    }

    /// The other side of the selected tab's split, which is on screen too.
    var shownPartner: Tab? {
        guard let selected = selectedTab, let id = split(of: selected)?.partner(of: selected.id) else { return nil }
        return tabs.first { $0.id == id }
    }

    /// The selected tab, and its partner in split view.
    func isOnScreen(_ tab: Tab) -> Bool {
        tab.id == selectedTabID || shownPartner === tab
    }

    /// The pair shows once, where its first tab in the list is.
    var tabListEntries: [TabListEntry] {
        let list = regularTabs
        guard !splits.pairs.isEmpty else { return list.enumerated().map { TabListEntry(index: $0, tab: $1, split: nil) } }
        var seen: Set<Tab.ID> = []
        return list.enumerated().compactMap { index, tab in
            let split = split(of: tab)
            if let split, seen.contains(split.first) || seen.contains(split.second) { return nil }
            seen.insert(tab.id)
            return TabListEntry(index: index, tab: tab, split: split)
        }
    }

    /// Who a tab opened in split view goes beside: the selected tab, else its neighbour in the list.
    func splitPartner(for tab: Tab) -> Tab? {
        guard tab.isInTabList else { return nil }
        if let selected = selectedTab, selected !== tab, selected.isInTabList { return selected }
        let list = regularTabs
        guard let index = list.firstIndex(where: { $0 === tab }) else { return nil }
        return index + 1 < list.count ? list[index + 1] : index > 0 ? list[index - 1] : nil
    }

    /// The tab list's "Open in Split View": beside the selected tab, on the side its partner
    /// leaves free, and focused.
    func openInSplit(_ tab: Tab) {
        guard let partner = splitPartner(for: tab) else { return }
        let side: TabSplit.Side = split(of: partner)?.side(of: partner.id) == .second ? .first : .second
        pair(tab, with: partner, on: side)
    }

    /// A tab dragged onto the left or right of the page goes there, beside the selected one.
    func dropForSplit(_ item: String, on side: TabSplit.Side) -> Bool {
        defer { splits.draggedTabID = nil }
        guard let tab = tabs.first(where: { $0.id.uuidString == item }), let selected = selectedTab,
              selected !== tab, tab.isInTabList, selected.isInTabList else { return false }
        pair(tab, with: selected, on: side)
        return true
    }

    /// Takes `tab` out of any split, and `partner` out of its own; the split `partner` leaves
    /// lends the new one its orientation and divider.
    private func pair(_ tab: Tab, with partner: Tab, on side: TabSplit.Side) {
        var split = split(of: partner) ?? TabSplit(first: partner.id, second: tab.id)
        splits.pairs.removeAll { $0.contains(tab.id) || $0.contains(partner.id) }
        (split.first, split.second) = side == .first ? (tab.id, partner.id) : (partner.id, tab.id)
        splits.pairs.append(split)
        select(tab)
    }

    func exitSplit(of tab: Tab) {
        splits.pairs.removeAll { $0.contains(tab.id) }
    }

    func swapSides(of tab: Tab) {
        update(tab) { swap(&$0.first, &$0.second) }
    }

    func toggleStacked(of tab: Tab) {
        update(tab) { $0.isStacked.toggle() }
    }

    func resizeSplit(of tab: Tab, to fraction: Double) {
        update(tab) { $0.fraction = min(max(fraction, TabSplit.fractions.lowerBound), TabSplit.fractions.upperBound) }
    }

    private func update(_ tab: Tab, _ change: (inout TabSplit) -> Void) {
        guard let index = splits.pairs.firstIndex(where: { $0.contains(tab.id) }) else { return }
        change(&splits.pairs[index])
    }

    /// Called as a tab closes or leaves the tab list: its split ends, and the partner is returned
    /// so it can fill the window.
    @discardableResult
    func leaveSplit(_ tab: Tab) -> Tab? {
        guard let index = splits.pairs.firstIndex(where: { $0.contains(tab.id) }) else { return nil }
        let partner = splits.pairs.remove(at: index).partner(of: tab.id)
        return tabs.first { $0.id == partner }
    }

    /// The tab list's drag source: the page's drop zones show while it is on its way.
    func startDragging(_ tab: Tab) -> String {
        splits.draggedTabID = tab.id
        return tab.id.uuidString
    }

    /// From the window's click monitor, before the click goes on. A click in the other side of
    /// the split focuses it, as Arc does; any click ends a tab drag that was dropped elsewhere.
    func noteClick(_ event: NSEvent) {
        if splits.draggedTabID != nil { splits.draggedTabID = nil }
        guard let partner = shownPartner, !NativeInput.isAgents(event),
              let view = partner.loadedWebView, view.window === event.window else { return }
        if view.bounds.contains(view.convert(event.locationInWindow, from: nil)) { select(partner) }
    }

    func savedSplits(at places: [Tab.ID: Int]) -> [Session.Split]? {
        let saved = splits.pairs.compactMap { split -> Session.Split? in
            guard let first = places[split.first], let second = places[split.second] else { return nil }
            return Session.Split(first: first, second: second, isStacked: split.isStacked, fraction: split.fraction)
        }
        return saved.isEmpty ? nil : saved
    }

    func restoreSplits(_ saved: [Session.Split]?, tabs restored: [Int: Tab]) {
        for split in saved ?? [] {
            guard let first = restored[split.first], let second = restored[split.second], first !== second,
                  first.isInTabList, second.isInTabList,
                  !splits.pairs.contains(where: { $0.contains(first.id) || $0.contains(second.id) }) else { continue }
            let fraction = min(max(split.fraction, TabSplit.fractions.lowerBound), TabSplit.fractions.upperBound)
            splits.pairs.append(TabSplit(first: first.id, second: second.id, isStacked: split.isStacked, fraction: fraction))
        }
    }
}

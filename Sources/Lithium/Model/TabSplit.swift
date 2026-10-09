import AppKit
import Observation

/// Two tabs of the tab list shown together. The selected tab is the focused side, so the address
/// bar, the toolbar and the menus act on it as they would on a lone tab.
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

/// The window's splits, and the tab dragged from the sidebar, which shows the page's drop zones.
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

/// `index` is the tab's place in its folder (or among tabs outside folders), for measuring drops.
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

    var shownPartner: Tab? {
        guard let selected = selectedTab, let id = split(of: selected)?.partner(of: selected.id) else { return nil }
        return tabs.first { $0.id == id }
    }

    /// A link in its own window counts too.
    func isOnScreen(_ tab: Tab) -> Bool {
        tab.id == selectedTabID || shownPartner === tab || quickLinks.contains(tab)
    }

    /// The prompt over the page: the focused tab's, else the other side's in split view, whose page
    /// would otherwise wait unseen until clicked.
    var shownPermissionRequest: PermissionRequest? {
        shown(permissions.pending, tabID: \.tabID)
    }

    var shownAppLinkRequest: AppLinkRequest? {
        shown(appLinks.pending, tabID: \.tabID)
    }

    private func shown<Request>(_ pending: [Request], tabID: KeyPath<Request, Tab.ID>) -> Request? {
        guard !pending.isEmpty else { return nil }
        return pending.first { $0[keyPath: tabID] == selectedTabID }
            ?? shownPartner.flatMap { partner in pending.first { $0[keyPath: tabID] == partner.id } }
    }

    /// The pair shows once, where its first tab in the list is.
    var tabListEntries: [TabListEntry] {
        let list = regularTabs
        guard !splits.pairs.isEmpty || !folders.all.isEmpty else { return list.enumerated().map { TabListEntry(index: $0, tab: $1, split: nil) } }
        var seen: Set<Tab.ID> = []
        // Where the tab's folder (or the tabs outside folders) starts: the list keeps each together.
        var start = 0
        return list.enumerated().compactMap { offset, tab in
            if offset > 0, tab.folderID != list[offset - 1].folderID { start = offset }
            let split = split(of: tab)
            if let split, seen.contains(split.first) || seen.contains(split.second) { return nil }
            seen.insert(tab.id)
            return TabListEntry(index: offset - start, tab: tab, split: split)
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

    /// Opens on the side the partner leaves free.
    func openInSplit(_ tab: Tab) {
        guard let partner = splitPartner(for: tab) else { return }
        let side: TabSplit.Side = split(of: partner)?.side(of: partner.id) == .second ? .first : .second
        pair(tab, with: partner, on: side)
    }

    func dropForSplit(_ item: String, on side: TabSplit.Side) -> Bool {
        defer { splits.draggedTabID = nil }
        guard let tab = tabs.first(where: { $0.id.uuidString == item }), let selected = selectedTab,
              selected !== tab, tab.isInTabList, selected.isInTabList else { return false }
        pair(tab, with: selected, on: side)
        return true
    }

    /// The split `partner` leaves lends the new one its orientation and divider.
    private func pair(_ tab: Tab, with partner: Tab, on side: TabSplit.Side) {
        shownPartner?.markActive()
        var split = split(of: partner) ?? TabSplit(first: partner.id, second: tab.id)
        splits.pairs.removeAll { $0.contains(tab.id) || $0.contains(partner.id) }
        (split.first, split.second) = side == .first ? (tab.id, partner.id) : (partner.id, tab.id)
        // A pair is one row, so in one place: the partner's folder, or outside folders with it.
        if tab.folderID != partner.folderID { tab.folderID = partner.folderID }
        splits.pairs.append(split)
        select(tab)
    }

    /// The side shown until now counts as used as it leaves the screen, like in `select`.
    func exitSplit(of tab: Tab) {
        shownPartner?.markActive()
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

    /// Returns the partner, so it can fill the window.
    @discardableResult
    func leaveSplit(_ tab: Tab) -> Tab? {
        guard let index = splits.pairs.firstIndex(where: { $0.contains(tab.id) }) else { return nil }
        let partner = splits.pairs.remove(at: index).partner(of: tab.id)
        return tabs.first { $0.id == partner }
    }

    func startDragging(_ tab: Tab) -> String {
        splits.draggedTabID = tab.id
        return tab.id.uuidString
    }

    func endTabDrag() {
        if splits.draggedTabID != nil { splits.draggedTabID = nil }
    }

    /// Any other drag (a link or text from another app) means the tab's drag ended without a
    /// click to say so: the drop zone stands down, and the page gets the drop.
    func carriesDraggedTab(_ item: String?) -> Bool {
        guard let dragged = splits.draggedTabID, item == dragged.uuidString else {
            endTabDrag()
            return false
        }
        return true
    }

    /// From the window's click monitor: a click in the other side focuses it. Only a click the page
    /// or its PDF viewer gets counts, not one on a view over it (selecting the partner there slid the
    /// peeked sidebar away under a right-click's menu). A popped-out video's web view is the player's.
    func noteClick(_ event: NSEvent) {
        endTabDrag()
        guard let partner = shownPartner, partner !== videoPopout.tab, !NativeInput.isAgents(event),
              let view = partner.loadedWebView, view.window === event.window,
              let content = view.window?.contentView,
              let hit = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow) else { return }
        let inPDF = sequence(first: hit, next: \.superview).contains { ($0 as? SplitPDFReader.Host)?.tabID == partner.id }
        if hit.isDescendant(of: view) || inPDF { select(partner) }
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

import AppKit
import Observation

enum Suggestion: Hashable, Identifiable {
    case search(String)
    case address(URL)
    case openTab(Tab.ID, title: String, url: URL)
    case pin(Pin.ID, title: String, url: URL)
    case history(title: String, url: URL)
    case action(BarAction)

    var id: String {
        switch self {
        case .search(let query): "search:\(query)"
        case .address(let url): "address:\(url.absoluteString)"
        case .openTab(let id, _, _): "tab:\(id)"
        case .pin(let id, _, _): "pin:\(id)"
        case .history(_, let url): "history:\(url.absoluteString)"
        case .action(let action): "action:\(action)"
        }
    }

    var url: URL? {
        switch self {
        case .search, .action: nil
        case .address(let url), .openTab(_, _, let url), .pin(_, _, let url), .history(_, let url): url
        }
    }
}

/// What the address bar proposes while typing. The first row is always what Return does with the raw text.
@MainActor
@Observable
final class AddressSuggestions {
    private(set) var items: [Suggestion] = []
    private(set) var selectedIndex = 0
    /// The tab shown when the address bar's editing began: Return or a click on a row goes there.
    @ObservationIgnored var editedTabID: Tab.ID?
    @ObservationIgnored private(set) var historyQuery: Task<Void, Never>?
    /// A row that comes up under a resting pointer counts as hovered, but only a pointer moved
    /// since picks what Return opens.
    @ObservationIgnored private var pointerAtChange: CGPoint?
    /// Tests replace it, so the real pointer is never read.
    @ObservationIgnored var pointerLocation: @MainActor () -> CGPoint = { NSEvent.mouseLocation }

    private static let perSource = 3
    private static let limit = 8

    var selected: Suggestion? { items.indices.contains(selectedIndex) ? items[selectedIndex] : nil }

    /// Typed words that name an action whole, without a typo ("copy link"), have Return run it.
    func update(query rawQuery: String, tabs: [Tab], pins: [Pin], history: HistoryStore, actions: [BarAction] = []) {
        let query = rawQuery.trimmingCharacters(in: .whitespaces)
        let first: Suggestion
        var named: [(action: BarAction, match: BarAction.Match)] = []
        switch AddressInput.target(for: query) {
        case .address(let url): first = .address(url)
        case .search:
            first = .search(query)
            named = BarAction.matches(query, among: actions)
        case nil:
            clear()
            return
        }

        var seen: Set<String> = [first.url?.absoluteString ?? ""]
        func fresh(_ url: URL) -> Bool { seen.insert(url.absoluteString).inserted }
        func matches(_ title: String, _ url: URL) -> Bool {
            title.localizedCaseInsensitiveContains(query) || url.absoluteString.localizedCaseInsensitiveContains(query)
        }

        let openTabs = tabs.compactMap { tab -> Suggestion? in
            guard let url = tab.url, matches(tab.displayTitle, url), fresh(url) else { return nil }
            return .openTab(tab.id, title: tab.displayTitle, url: url)
        }.prefix(Self.perSource)
        let pinned = pins.compactMap { pin -> Suggestion? in
            guard matches(pin.title, pin.url), fresh(pin.url) else { return nil }
            return .pin(pin.id, title: pin.title, url: pin.url)
        }.prefix(Self.perSource)

        let commands = named.map { Suggestion.action($0.action) }
        items = Array(([first] + commands + openTabs + pinned).prefix(Self.limit))
        selectedIndex = named.first.map { $0.match.isWhole && !$0.match.hasTypo } == true ? 1 : 0
        pointerAtChange = pointerLocation()
        historyQuery?.cancel()
        historyQuery = Task { [weak self] in
            guard let sites = await history.topSitesInBackground(matching: query, limit: Self.limit),
                  !Task.isCancelled, let self else { return }
            let visited = sites.filter { seen.insert($0.url.absoluteString).inserted }.map { Suggestion.history(title: $0.title, url: $0.url) }
            items = Array((items + visited).prefix(Self.limit))
            pointerAtChange = pointerLocation()
        }
    }

    func move(by offset: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + offset + items.count) % items.count
    }

    func select(_ suggestion: Suggestion) {
        selectedIndex = items.firstIndex(of: suggestion) ?? 0
    }

    func hover(_ suggestion: Suggestion) {
        if let resting = pointerAtChange {
            guard pointerLocation() != resting else { return }
            pointerAtChange = nil
        }
        guard items.firstIndex(of: suggestion) != selectedIndex else { return }
        select(suggestion)
    }

    func clear() {
        historyQuery?.cancel()
        items = []
        selectedIndex = 0
    }
}

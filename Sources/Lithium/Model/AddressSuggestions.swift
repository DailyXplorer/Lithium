import Foundation
import Observation

enum Suggestion: Hashable, Identifiable {
    case search(String)
    case address(URL)
    case openTab(Tab.ID, title: String, url: URL)
    case pin(Pin.ID, title: String, url: URL)
    case history(title: String, url: URL)

    var id: String {
        switch self {
        case .search(let query): "search:\(query)"
        case .address(let url): "address:\(url.absoluteString)"
        case .openTab(let id, _, _): "tab:\(id)"
        case .pin(let id, _, _): "pin:\(id)"
        case .history(_, let url): "history:\(url.absoluteString)"
        }
    }

    var url: URL? {
        switch self {
        case .search: nil
        case .address(let url), .openTab(_, _, let url), .pin(_, _, let url), .history(_, let url): url
        }
    }
}

/// What the address bar proposes while typing. The first row is always what Return does
/// with the raw text (search or go to the address); the rest come from open tabs, pins and history.
@MainActor
@Observable
final class AddressSuggestions {
    private(set) var items: [Suggestion] = []
    private(set) var selectedIndex = 0

    private static let perSource = 3
    private static let limit = 8

    var selected: Suggestion? { items.indices.contains(selectedIndex) ? items[selectedIndex] : nil }

    func update(query rawQuery: String, tabs: [Tab], pins: [Pin], history: HistoryStore) {
        let query = rawQuery.trimmingCharacters(in: .whitespaces)
        let first: Suggestion
        switch AddressInput.target(for: query) {
        case .address(let url): first = .address(url)
        case .search: first = .search(query)
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
        let visited = history.topSites(matching: query, limit: Self.limit).compactMap { site -> Suggestion? in
            guard fresh(site.url) else { return nil }
            return .history(title: site.title, url: site.url)
        }

        items = Array(([first] + openTabs + pinned + visited).prefix(Self.limit))
        selectedIndex = 0
    }

    func move(by offset: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + offset + items.count) % items.count
    }

    func select(_ suggestion: Suggestion) {
        selectedIndex = items.firstIndex(of: suggestion) ?? 0
    }

    func clear() {
        items = []
        selectedIndex = 0
    }
}

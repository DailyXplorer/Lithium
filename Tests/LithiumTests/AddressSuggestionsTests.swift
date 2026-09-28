import Foundation
import Testing
@testable import Lithium

@MainActor
struct AddressSuggestionsTests {
    private func history(_ visits: [(String, String, Int)]) -> HistoryStore {
        let store = HistoryStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "history-\(UUID()).sqlite"))
        for (url, title, count) in visits {
            for _ in 0..<count {
                store.record(URL(string: url)!, title: title)
                store.record(URL(string: "https://separator.example/")!, title: "")
            }
        }
        return store
    }

    @Test func typedTextFirstThenHistoryRankedByPrefixAndFrequency() async {
        let store = history([
            ("https://www.github.com/", "GitHub", 1),
            ("https://news.ycombinator.com/item?id=1", "Show HN: git tools", 5),
            ("https://github.com/apple/swift", "apple/swift", 3),
        ])
        let suggestions = AddressSuggestions()
        suggestions.update(query: "git", tabs: [], pins: [], history: store)
        #expect(suggestions.items.map(\.id) == ["search:git"])
        await suggestions.historyQuery?.value

        #expect(suggestions.items.map(\.id) == [
            "search:git",
            "history:https://github.com/apple/swift",
            "history:https://www.github.com/",
            "history:https://news.ycombinator.com/item?id=1",
        ])
    }

    /// Typing faster than the history answers only ever shows the pages for the latest text.
    @Test func historyForReplacedTextNeverShows() async {
        let store = history([("https://swift.org/", "Swift", 1), ("https://github.com/", "GitHub", 1)])
        let suggestions = AddressSuggestions()
        suggestions.update(query: "swift", tabs: [], pins: [], history: store)
        suggestions.update(query: "git", tabs: [], pins: [], history: store)
        await suggestions.historyQuery?.value
        try? await Task.sleep(for: .milliseconds(100))
        #expect(suggestions.items.map(\.id) == ["search:git", "history:https://github.com/"])
    }

    @Test func domainsBecomeAnAddressAndArrowsWrap() {
        let suggestions = AddressSuggestions()
        suggestions.update(query: "swift.org", tabs: [], pins: [], history: history([]))
        #expect(suggestions.items.map(\.id) == ["address:https://swift.org"])

        suggestions.move(by: -1)
        #expect(suggestions.selectedIndex == 0)
        suggestions.update(query: "  ", tabs: [], pins: [], history: history([]))
        #expect(suggestions.items.isEmpty)
    }
}

import AppKit
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

    /// Rows that come up under a resting pointer (history arriving late) don't change what Return
    /// opens; once the pointer moves, the row under it does.
    @Test func hoverPicksARowOnlyOnceThePointerMoves() async throws {
        let store = history([("https://swift.org/", "Swift", 1)])
        let suggestions = AddressSuggestions()
        var pointer = CGPoint(x: 100, y: 100)
        suggestions.pointerLocation = { pointer }
        suggestions.update(query: "swift", tabs: [], pins: [], history: store)
        await suggestions.historyQuery?.value
        let row = try #require(suggestions.items.last)
        #expect(row.id == "history:https://swift.org/")

        suggestions.hover(row)
        #expect(suggestions.selectedIndex == 0)
        pointer.y += 3
        suggestions.hover(row)
        #expect(suggestions.selected == row)

        // Typing again brings new rows under the pointer, which hasn't moved since.
        suggestions.update(query: "swift.org", tabs: [], pins: [], history: store)
        await suggestions.historyQuery?.value
        let again = try #require(suggestions.items.last)
        suggestions.hover(again)
        #expect(suggestions.selectedIndex == 0)
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

    /// Favorites past the first three that match aren't looked at: their pages may still come
    /// from history, as they aren't listed anywhere else.
    @Test func onlyTheFirstThreeMatchingFavoritesAreRead() async {
        let pins = (1...5).map { Pin(id: UUID(), url: URL(string: "https://docs\($0).example/")!, title: "Docs \($0)") }
        let store = history([("https://docs5.example/", "Docs 5", 1)])
        let suggestions = AddressSuggestions()
        suggestions.update(query: "docs", tabs: [], pins: pins, history: store)
        #expect(suggestions.items.map(\.id) == ["search:docs"] + pins.prefix(3).map { "pin:\($0.id)" })
        await suggestions.historyQuery?.value
        #expect(suggestions.items.last?.id == "history:https://docs5.example/")
    }

    /// A click on a row that ended the edit keeps the list for as long as it is held, and the list
    /// goes only after its mouse-up is handled; back in the field by then, the list stays.
    @Test func aHeldClickKeepsTheListUntilItsMouseUp() async throws {
        let suggestions = AddressSuggestions()
        let mainQueueTurn = { await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } } }
        suggestions.update(query: "swift", tabs: [], pins: [], history: history([]))
        suggestions.historyQuery?.cancel()

        suggestions.clearAfterMouseUp()
        try await Task.sleep(for: .milliseconds(800))
        #expect(suggestions.items.map(\.id) == ["search:swift"], "a long press keeps the row")
        suggestions.mouseWentUp()
        #expect(!suggestions.items.isEmpty, "the row is still there while the mouse-up is handled")
        await mainQueueTurn()
        #expect(suggestions.items.isEmpty)

        suggestions.update(query: "swift", tabs: [], pins: [], history: history([]))
        suggestions.historyQuery?.cancel()
        suggestions.clearAfterMouseUp()
        suggestions.editingBegan()
        suggestions.mouseWentUp()
        await mainQueueTurn()
        #expect(suggestions.items.map(\.id) == ["search:swift"], "a new edit keeps its list")
    }
}

/// The address bar's rows ask for their icons at every keystroke.
@MainActor
struct SuggestionIconTests {
    @Test func iconsAreDecodedOnceAndAMissingFileIsReadOnce() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "suggestion-icons-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let png = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]))
        try png.write(to: folder.appending(path: "shown.example.png"))
        let favicons = Favicons(folder: folder)

        let first = try #require(favicons.cached(host: "shown.example"))
        #expect(favicons.cached(host: "shown.example") === first, "decoded once")

        #expect(favicons.cached(host: "none.example") == nil)
        try png.write(to: folder.appending(path: "none.example.png"))
        #expect(favicons.cached(host: "none.example") == nil, "the disk isn't read again for it")
    }
}

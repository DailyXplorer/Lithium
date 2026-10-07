import Foundation
import Testing
@testable import Lithium

@MainActor
struct HistoryStoreTests {
    private func makeStore() -> HistoryStore {
        HistoryStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "history-\(UUID()).sqlite"))
    }

    @Test func recordsSearchesAndDeletes() {
        let store = makeStore()
        store.record(URL(string: "https://swift.org/")!, title: "Swift")
        store.record(URL(string: "https://webkit.org/")!, title: "WebKit")
        store.record(URL(string: "about:blank")!, title: "ignored")

        #expect(store.visits(matching: "").map(\.title) == ["WebKit", "Swift"])
        #expect(store.visits(matching: "swift").map(\.url.absoluteString) == ["https://swift.org/"])

        store.delete(store.visits(matching: "webkit")[0])
        #expect(store.visits(matching: "").map(\.title) == ["Swift"])
    }

    @Test func collapsesImmediateRevisitsAndUpdatesTitles() {
        let store = makeStore()
        let url = URL(string: "https://example.com/")!
        store.record(url, title: "")
        store.record(url, title: "")
        store.updateTitle("Example Domain", for: url)
        #expect(store.visits(matching: "").map(\.title) == ["Example Domain"])

        store.clear()
        #expect(store.visits(matching: "").isEmpty)
    }

    /// A page retitling itself (an unread count) costs one write a moment later, not one per
    /// change; the store's own reads see the latest title at once.
    @Test func writesTitlesAMomentLater() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "history-\(UUID()).sqlite")
        let store = HistoryStore(fileURL: file)
        // Another connection, which sees only what was written.
        let reader = HistoryStore(fileURL: file)
        let url = URL(string: "https://mail.example.com/")!
        store.record(url, title: "Inbox")
        for count in 1...20 { store.updateTitle("(\(count)) Inbox", for: url) }
        #expect(reader.visits(matching: "").map(\.title) == ["Inbox"])

        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, reader.visits(matching: "").map(\.title) != ["(20) Inbox"] {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(reader.visits(matching: "").map(\.title) == ["(20) Inbox"])

        store.updateTitle("(21) Inbox", for: url)
        #expect(store.visits(matching: "").map(\.title) == ["(21) Inbox"])
    }
}

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
}

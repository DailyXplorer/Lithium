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

    @Test func collapsesImmediateRevisitsAndUpdatesTitles() async {
        let store = makeStore()
        let url = URL(string: "https://example.com/")!
        store.record(url, title: "")
        store.record(url, title: "")
        store.updateTitle("Example Domain", for: url)
        #expect(store.visits(matching: "").map(\.title) == ["Example Domain"])

        await store.clear()
        #expect(store.visits(matching: "").isEmpty)
    }

    /// Clearing a long history deletes and rewrites the whole file: on a connection of its own,
    /// off the main thread. Both of the store's connections see it done, and visits recorded
    /// afterwards are kept.
    @Test func clearsALongHistoryOffTheMainThread() async {
        let store = makeStore()
        for index in 0..<2_000 { store.record(URL(string: "https://example.com/page/\(index)")!, title: "Page \(index)") }
        #expect(store.visits(matching: "", limit: 5_000).count == 2_000)

        await store.clear()
        #expect(store.visits(matching: "").isEmpty)
        #expect(await store.visitsInBackground(matching: "")?.isEmpty == true)
        store.record(URL(string: "https://swift.org/")!, title: "Swift")
        #expect(store.visits(matching: "").map(\.title) == ["Swift"])
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

    /// The History page's search reads on the background connection, titles still waiting
    /// included, and never cancels the address bar's (nor the other way round).
    @Test func historyPageSearchesInTheBackground() async {
        let store = makeStore()
        let swift = URL(string: "https://swift.org/")!
        store.record(swift, title: "Swift")
        store.record(URL(string: "https://webkit.org/")!, title: "WebKit")
        store.updateTitle("Swift.org", for: swift)

        #expect(await store.visitsInBackground(matching: "swift")?.map(\.title) == ["Swift.org"])
        #expect(await store.visitsInBackground(matching: "")?.map(\.title) == ["WebKit", "Swift.org"])
        #expect(await store.visitsInBackground(matching: "nothing") == [])

        async let page = store.visitsInBackground(matching: "webkit")
        async let addressBar = store.topSitesInBackground(matching: "swift", limit: 5)
        #expect(await page?.map(\.url.absoluteString) == ["https://webkit.org/"])
        #expect(await addressBar?.map(\.url.absoluteString) == ["https://swift.org/"])
    }
}

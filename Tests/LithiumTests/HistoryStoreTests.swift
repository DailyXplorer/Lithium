import Foundation
import SQLite3
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

    /// Visits commit on the main thread: they don't wait for the disk on each one.
    @Test func visitsDontSyncTheDiskOnEachCommit() {
        let store = makeStore()
        #expect(store.synchronousSetting == 1)
        store.record(URL(string: "https://swift.org/")!, title: "Swift")
        #expect(store.visits(matching: "").map(\.title) == ["Swift"])
    }

    /// Closed at quit, with a search's connection open too, the log is folded into the file, so
    /// the next launch has nothing to replay. A title still waiting is kept; nothing is written after.
    @Test func closingFoldsTheLogIntoTheFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "history-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "history.sqlite")
        let store = HistoryStore(fileURL: file)
        let url = URL(string: "https://example.com/")!
        store.record(url, title: "")
        #expect(await store.visitsInBackground(matching: "example")?.count == 1)
        store.updateTitle("Example Domain", for: url)

        store.close()
        store.record(URL(string: "https://example.org/")!, title: "After")
        // The file alone, without the log beside it, holds every visit.
        let copy = folder.appending(path: "copy.sqlite")
        try FileManager.default.copyItem(at: file, to: copy)
        #expect(HistoryStore(fileURL: copy).visits(matching: "").map(\.title) == ["Example Domain"])
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

    /// The History page shows a page of visits at a time: the next one starts after the last shown,
    /// for a search too, and none is left out or repeated.
    @Test func pagesGoOnFromTheLastVisitShown() async throws {
        let store = makeStore()
        for index in 0..<5 { store.record(URL(string: "https://example.com/\(index)")!, title: "Page \(index)") }
        store.record(URL(string: "https://swift.org/")!, title: "Swift")
        let first = store.visits(matching: "", limit: 2)
        #expect(first.map(\.title) == ["Swift", "Page 4"])
        let last = try #require(first.last)
        #expect(store.visits(matching: "", before: last.id, limit: 2).map(\.title) == ["Page 3", "Page 2"])
        #expect(await store.visitsInBackground(matching: "example", before: last.id, limit: 10)?.map(\.title) == ["Page 3", "Page 2", "Page 1", "Page 0"])
        #expect(store.visits(matching: "swift", before: last.id).isEmpty)
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

    /// While a clear holds the file, the main connection's writes would fail at once
    /// (`SQLITE_BUSY`): visits and titles written meanwhile are kept, and written once it is done.
    @Test func visitsDuringAClearAreKept() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "history-\(UUID()).sqlite")
        let store = HistoryStore(fileURL: file)
        store.record(URL(string: "https://old.example/")!, title: "Old")
        // Another connection holds the write lock, so the clear can't finish before the visit.
        var blocker: OpaquePointer?
        try #require(sqlite3_open(file.path, &blocker) == SQLITE_OK)
        defer { sqlite3_close(blocker) }
        try #require(sqlite3_exec(blocker, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)

        let clearing = Task { await store.clear() }
        while !store.isClearing { await Task.yield() }
        let url = URL(string: "https://new.example/")!
        store.record(url, title: "")
        store.updateTitle("New", for: url)
        store.writeTitles()
        sqlite3_exec(blocker, "COMMIT", nil, nil, nil)
        await clearing.value

        #expect(store.visits(matching: "").map(\.title) == ["New"])
    }

    /// A page retitling itself (an unread count) costs one write a moment later, not one per
    /// change; the store's own reads see the latest title at once.
    @Test func writesTitlesAMomentLater() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "history-\(UUID()).sqlite")
        let store = HistoryStore(fileURL: file)
        store.titleDelay = .milliseconds(500)
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

    /// A background page ticking its title (a clock) doesn't write its history row every second:
    /// the title waits, and the store's own reads still see it at once.
    @Test func aTickingTitleIsNotWrittenEverySecond() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "history-\(UUID()).sqlite")
        let store = HistoryStore(fileURL: file)
        let reader = HistoryStore(fileURL: file)
        let url = URL(string: "https://clock.example.com/")!
        store.record(url, title: "Clock")
        for second in 1...3 {
            store.updateTitle("10:00:0\(second)", for: url)
            try await Task.sleep(for: .milliseconds(600))
        }
        #expect(reader.visits(matching: "").map(\.title) == ["Clock"])
        #expect(store.visits(matching: "").map(\.title) == ["10:00:03"])
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

    /// `%`, `_` and `\` are searched for as typed, not as LIKE wildcards, in the History page and
    /// the address bar alike.
    @Test func searchesWildcardCharactersLiterally() async {
        let store = makeStore()
        store.record(URL(string: "https://files.example/my_file")!, title: "My file")
        store.record(URL(string: "https://files.example/myXfile")!, title: "50% off")
        store.record(URL(string: "https://files.example/back")!, title: #"C:\Temp"#)

        #expect(store.visits(matching: "my_file").map(\.title) == ["My file"])
        #expect(store.visits(matching: "_").map(\.title) == ["My file"])
        #expect(store.visits(matching: "50%").map(\.title) == ["50% off"])
        #expect(store.visits(matching: #"C:\"#).map(\.title) == [#"C:\Temp"#])
        #expect(await store.visitsInBackground(matching: "%")?.map(\.title) == ["50% off"])
        #expect(await store.topSitesInBackground(matching: "my_", limit: 5)?.map(\.url.absoluteString) == ["https://files.example/my_file"])
        #expect(store.topSites(matching: "files.example/my_", limit: 5).map(\.url.absoluteString) == ["https://files.example/my_file"])
    }

    /// Case is folded beyond ASCII, as the open tabs' suggestions do: "éclair" finds "Éclair".
    @Test func foldsTheCaseOfAccentedLetters() async {
        let store = makeStore()
        store.record(URL(string: "https://bakery.example/")!, title: "Éclair au café")
        store.record(URL(string: "https://news.example/")!, title: "ΑΘΗΝΑ")

        #expect(store.visits(matching: "éclair").map(\.title) == ["Éclair au café"])
        #expect(store.visits(matching: "CAFÉ").map(\.title) == ["Éclair au café"])
        #expect(await store.visitsInBackground(matching: "αθηνα")?.map(\.title) == ["ΑΘΗΝΑ"])
        #expect(await store.topSitesInBackground(matching: "éclair", limit: 5)?.map(\.url.absoluteString) == ["https://bakery.example/"])
        #expect(store.visits(matching: "eclair").isEmpty, "accents still count, as in the open tabs' search")
    }
}

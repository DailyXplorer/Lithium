import Foundation
import SQLite3

struct Visit: Identifiable, Hashable {
    let id: Int64
    let url: URL
    let title: String
    let date: Date
}

/// Browsing history in a local SQLite file. Nothing leaves the machine.
@MainActor
final class HistoryStore {
    private var db: OpaquePointer?
    private var lastRecorded: (url: URL, date: Date)?
    /// Titles waiting to be written, by address: a page that retitles itself (an unread count,
    /// a clock) costs one write a second at most, not one per change.
    private var pendingTitles: [URL: String] = [:]
    private var titleWrite: Task<Void, Never>?
    static let titleDelay = Duration.seconds(1)
    /// The address bar's query reads every visit (70 ms at 200,000): its own connection, off the main thread.
    private let search: HistorySearch
    private let fileURL: URL
    /// Writes made while `clear()` holds the file, run once it is done: the main connection
    /// would get `SQLITE_BUSY` meanwhile, and waiting for the lock would freeze the window.
    private var heldWrites: [(sql: String, values: [Any])]?
    private var runningClears = 0
    var isClearing: Bool { runningClears > 0 }

    nonisolated(unsafe) private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(fileURL: URL = URL.applicationSupportDirectory.appending(path: "Lithium/history.sqlite")) {
        self.fileURL = fileURL
        search = HistorySearch(fileURL: fileURL)
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(fileURL.path, &db) == SQLITE_OK else {
            NSLog("Lithium: cannot open history database")
            return
        }
        Self.addUnicodeLower(to: db)
        execute("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS visits (
                id INTEGER PRIMARY KEY,
                url TEXT NOT NULL,
                title TEXT NOT NULL DEFAULT '',
                visited_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS visits_by_date ON visits (visited_at DESC);
            CREATE INDEX IF NOT EXISTS visits_by_url ON visits (url, visited_at);
            """)
    }

    func record(_ url: URL, title: String) {
        guard ["http", "https"].contains(url.scheme) else { return }
        // A title still waiting belongs to the visit before this one.
        writeTitles()
        let now = Date()
        // Reloads and redirect bounces land on the same URL within seconds; keep one row.
        if let last = lastRecorded, last.url == url, now.timeIntervalSince(last.date) < 60 { return }
        lastRecorded = (url, now)
        run("INSERT INTO visits (url, title, visited_at) VALUES (?, ?, ?)", url.absoluteString, title, now.timeIntervalSince1970)
    }

    /// Written a moment later, or as soon as anything reads or adds visits.
    func updateTitle(_ title: String, for url: URL) {
        guard !title.isEmpty else { return }
        pendingTitles[url] = title
        guard titleWrite == nil else { return }
        titleWrite = Task { [weak self] in
            try? await Task.sleep(for: Self.titleDelay)
            guard !Task.isCancelled else { return }
            self?.writeTitles()
        }
    }

    func writeTitles() {
        titleWrite?.cancel()
        titleWrite = nil
        guard !pendingTitles.isEmpty else { return }
        let titles = pendingTitles
        pendingTitles = [:]
        for (url, title) in titles {
            run(
                "UPDATE visits SET title = ? WHERE id = (SELECT id FROM visits WHERE url = ? ORDER BY visited_at DESC LIMIT 1)",
                title, url.absoluteString
            )
        }
    }

    func visits(matching query: String, limit: Int = 500) -> [Visit] {
        writeTitles()
        return Self.visits(in: db, matching: query, limit: limit)
    }

    /// Off the main thread (a query few visits match reads them all); nil when a newer query replaced this one.
    func visitsInBackground(matching query: String, limit: Int = 500) async -> [Visit]? {
        writeTitles()
        return await search.visits(matching: query, limit: limit)
    }

    /// Escapes LIKE wildcards. SQLite folds the case of ASCII letters only, so a query with other
    /// letters compares through `unicode_lower`; ASCII queries keep SQLite's own folding and its speed.
    nonisolated private static func searchTerms(_ text: String) -> (text: String, column: (String) -> String) {
        let escaped = text.replacing("\\", with: "\\\\").replacing("%", with: "\\%").replacing("_", with: "\\_")
        guard !text.allSatisfy(\.isASCII) else { return (escaped, { $0 }) }
        return (escaped.lowercased(), { "unicode_lower(\($0))" })
    }

    nonisolated fileprivate static func addUnicodeLower(to db: OpaquePointer?) {
        sqlite3_create_function_v2(db, "unicode_lower", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, { context, _, values in
            guard let text = sqlite3_value_text(values?[0]) else { return sqlite3_result_null(context) }
            sqlite3_result_text(context, String(cString: text).lowercased(), -1, HistoryStore.transient)
        }, nil, nil, nil)
    }

    nonisolated fileprivate static func visits(in db: OpaquePointer?, matching query: String, limit: Int) -> [Visit] {
        let (text, column) = searchTerms(query.trimmingCharacters(in: .whitespaces))
        let pattern = "%\(text)%"
        var statement: OpaquePointer?
        let sql = """
            SELECT id, url, title, visited_at FROM visits WHERE \(column("url")) LIKE ?1 ESCAPE '\\' OR \(column("title")) LIKE ?1 ESCAPE '\\'
            ORDER BY visited_at DESC LIMIT ?2
            """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, pattern, -1, Self.transient)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var visits: [Visit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let url = URL(string: String(cString: sqlite3_column_text(statement, 1))) else { continue }
            visits.append(Visit(
                id: sqlite3_column_int64(statement, 0),
                url: url,
                title: String(cString: sqlite3_column_text(statement, 2)),
                date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            ))
        }
        return visits
    }

    /// Distinct pages matching `query`, best first: addresses that start with it, then the most visited.
    func topSites(matching query: String, limit: Int) -> [(url: URL, title: String)] {
        writeTitles()
        return Self.topSites(in: db, matching: query, limit: limit)
    }

    /// `topSites` off the main thread; nil when a newer query replaced this one before it ran.
    func topSitesInBackground(matching query: String, limit: Int) async -> [(url: URL, title: String)]? {
        writeTitles()
        return await search.topSites(matching: query, limit: limit)
    }

    nonisolated fileprivate static func topSites(in db: OpaquePointer?, matching query: String, limit: Int) -> [(url: URL, title: String)] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let (text, column) = searchTerms(trimmed)
        var statement: OpaquePointer?
        // NOT INDEXED: walking visits_by_url for GROUP BY reads the table in random order, 3 to 4
        // times slower than a plain scan (measured on 50,000 visits).
        let sql = """
            SELECT url, (SELECT title FROM visits v2 WHERE v2.url = v.url AND title != '' ORDER BY visited_at DESC LIMIT 1),
                   (\(column("url")) LIKE 'http%://' || ?2 || '%' ESCAPE '\\' OR \(column("url")) LIKE 'http%://www.' || ?2 || '%' ESCAPE '\\') AS prefix,
                   COUNT(*) AS visits, MAX(visited_at) AS latest
            FROM visits v NOT INDEXED WHERE \(column("url")) LIKE ?1 ESCAPE '\\' OR \(column("title")) LIKE ?1 ESCAPE '\\'
            GROUP BY url ORDER BY prefix DESC, visits DESC, latest DESC LIMIT ?3
            """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, "%\(text)%", -1, Self.transient)
        sqlite3_bind_text(statement, 2, text, -1, Self.transient)
        sqlite3_bind_int(statement, 3, Int32(limit))

        var sites: [(URL, String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let url = URL(string: String(cString: sqlite3_column_text(statement, 0))) else { continue }
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            sites.append((url, title))
        }
        return sites
    }

    func delete(_ visit: Visit) {
        delete(id: visit.id)
    }

    func delete(id: Int64) {
        writeTitles()
        run("DELETE FROM visits WHERE id = ?", id)
    }

    /// Deleting every visit and rewriting the file takes seconds on a long history: it runs on a
    /// connection of its own, off the main thread, which waits for the main one's short writes.
    func clear() async {
        titleWrite?.cancel()
        titleWrite = nil
        pendingTitles = [:]
        lastRecorded = nil
        guard db != nil else { return }
        runningClears += 1
        if heldWrites == nil { heldWrites = [] }
        let fileURL = fileURL
        await Task.detached(priority: .userInitiated) {
            var db: OpaquePointer?
            defer { sqlite3_close(db) }
            guard sqlite3_open(fileURL.path, &db) == SQLITE_OK else { return }
            sqlite3_busy_timeout(db, 5_000)
            if sqlite3_exec(db, "DELETE FROM visits; VACUUM;", nil, nil, nil) != SQLITE_OK {
                NSLog("Lithium: couldn’t clear history: %@", String(cString: sqlite3_errmsg(db)))
            }
        }.value
        runningClears -= 1
        guard runningClears == 0 else { return }
        let held = heldWrites ?? []
        heldWrites = nil
        for write in held { run(write.sql, values: write.values) }
    }

    private func execute(_ sql: String) {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            NSLog("Lithium: history database error: %@", String(cString: sqlite3_errmsg(db)))
        }
    }

    private func run(_ sql: String, _ values: Any...) {
        run(sql, values: values)
    }

    private func run(_ sql: String, values: [Any]) {
        if heldWrites != nil {
            heldWrites?.append((sql, values))
            return
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            NSLog("Lithium: couldn’t write history: %@", String(cString: sqlite3_errmsg(db)))
            return
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case let text as String: sqlite3_bind_text(statement, position, text, -1, Self.transient)
            case let number as Double: sqlite3_bind_double(statement, position, number)
            case let number as Int64: sqlite3_bind_int64(statement, position, number)
            default: sqlite3_bind_null(statement, position)
            }
        }
        if sqlite3_step(statement) != SQLITE_DONE {
            NSLog("Lithium: couldn’t write history: %@", String(cString: sqlite3_errmsg(db)))
        }
    }
}

/// A read-only connection on a queue of its own. Only the newest query of each kind runs: those
/// typing made obsolete while it was busy are skipped.
private final class HistorySearch: @unchecked Sendable {
    private enum Kind { case topSites, visits }

    private let fileURL: URL
    private let queue = DispatchQueue(label: "app.lithium.history-search", qos: .userInitiated)
    private let lock = NSLock()
    private var newest: [Kind: Int] = [:]
    private var db: OpaquePointer?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func topSites(matching query: String, limit: Int) async -> [(url: URL, title: String)]? {
        await run(.topSites) { HistoryStore.topSites(in: $0, matching: query, limit: limit) }
    }

    func visits(matching query: String, limit: Int) async -> [Visit]? {
        await run(.visits) { HistoryStore.visits(in: $0, matching: query, limit: limit) }
    }

    private func run<Result: Sendable>(_ kind: Kind, _ read: @escaping @Sendable (OpaquePointer?) -> Result) async -> Result? {
        let ticket = lock.withLock { newest[kind, default: 0] += 1; return newest[kind, default: 0] }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard lock.withLock({ ticket == newest[kind] }) else { return continuation.resume(returning: nil) }
                if db == nil {
                    if sqlite3_open_v2(fileURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
                        HistoryStore.addUnicodeLower(to: db)
                    } else {
                        sqlite3_close(db)
                        db = nil
                    }
                }
                continuation.resume(returning: read(db))
            }
        }
    }
}

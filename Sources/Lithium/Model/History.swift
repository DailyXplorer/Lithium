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
    /// The address bar's query reads every visit (70 ms at 200,000), so it runs on a connection
    /// of its own, off the main thread.
    private let search: HistorySearch

    nonisolated(unsafe) private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(fileURL: URL = URL.applicationSupportDirectory.appending(path: "Lithium/history.sqlite")) {
        search = HistorySearch(fileURL: fileURL)
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(fileURL.path, &db) == SQLITE_OK else {
            NSLog("Lithium: cannot open history database")
            return
        }
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
        let now = Date()
        // Reloads and redirect bounces land on the same URL within seconds; keep one row.
        if let last = lastRecorded, last.url == url, now.timeIntervalSince(last.date) < 60 { return }
        lastRecorded = (url, now)
        run("INSERT INTO visits (url, title, visited_at) VALUES (?, ?, ?)", url.absoluteString, title, now.timeIntervalSince1970)
    }

    func updateTitle(_ title: String, for url: URL) {
        guard !title.isEmpty else { return }
        run(
            "UPDATE visits SET title = ? WHERE id = (SELECT id FROM visits WHERE url = ? ORDER BY visited_at DESC LIMIT 1)",
            title, url.absoluteString
        )
    }

    func visits(matching query: String, limit: Int = 500) -> [Visit] {
        let pattern = "%\(query.trimmingCharacters(in: .whitespaces))%"
        var statement: OpaquePointer?
        let sql = "SELECT id, url, title, visited_at FROM visits WHERE url LIKE ?1 OR title LIKE ?1 ORDER BY visited_at DESC LIMIT ?2"
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
        Self.topSites(in: db, matching: query, limit: limit)
    }

    /// `topSites` off the main thread; nil when a newer query replaced this one before it ran.
    func topSitesInBackground(matching query: String, limit: Int) async -> [(url: URL, title: String)]? {
        await search.topSites(matching: query, limit: limit)
    }

    nonisolated fileprivate static func topSites(in db: OpaquePointer?, matching query: String, limit: Int) -> [(url: URL, title: String)] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return [] }
        var statement: OpaquePointer?
        // The title lookup uses visits_by_url. The outer scan must not: walking that index for
        // GROUP BY reads the table in random order, 3 to 4 times slower than a plain scan
        // (measured on 50,000 visits).
        let sql = """
            SELECT url, (SELECT title FROM visits v2 WHERE v2.url = v.url AND title != '' ORDER BY visited_at DESC LIMIT 1),
                   (url LIKE 'http%://' || ?2 || '%' OR url LIKE 'http%://www.' || ?2 || '%') AS prefix,
                   COUNT(*) AS visits, MAX(visited_at) AS latest
            FROM visits v NOT INDEXED WHERE url LIKE ?1 OR title LIKE ?1
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
        run("DELETE FROM visits WHERE id = ?", id)
    }

    func clear() {
        execute("DELETE FROM visits; VACUUM;")
        lastRecorded = nil
    }

    private func execute(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func run(_ sql: String, _ values: Any...) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
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
        sqlite3_step(statement)
    }
}

/// A read-only connection to the history file, used on a queue of its own. Only the newest
/// query runs: the ones typing made obsolete while it was busy are skipped.
private final class HistorySearch: @unchecked Sendable {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "app.lithium.history-search", qos: .userInitiated)
    private let lock = NSLock()
    private var newest = 0
    private var db: OpaquePointer?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func topSites(matching query: String, limit: Int) async -> [(url: URL, title: String)]? {
        let ticket = lock.withLock { newest += 1; return newest }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard lock.withLock({ ticket == newest }) else { return continuation.resume(returning: nil) }
                if db == nil, sqlite3_open_v2(fileURL.path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
                    sqlite3_close(db)
                    db = nil
                }
                continuation.resume(returning: HistoryStore.topSites(in: db, matching: query, limit: limit))
            }
        }
    }
}

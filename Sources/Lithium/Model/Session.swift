import Foundation

/// The open tabs, in sidebar order, so they come back after a relaunch.
struct Session: Codable, Equatable {
    struct Tab: Codable, Equatable {
        var url: URL
        var title: String
        var customTitle: String?
        var pinID: Pin.ID?
    }

    var tabs: [Tab] = []
    var selectedIndex: Int?
    var splits: [Split]?
}

enum SessionStore {
    /// For tests.
    nonisolated(unsafe) private(set) static var writes = 0

    static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "Lithium/session.json")
    }

    /// Read whole: tabs and splits refer to each other by index. A file that can't be read is
    /// kept aside before launch writes the new session over it (`StoredFile`).
    static func load(from url: URL = fileURL) -> Session {
        StoredFile.read(Session.self, at: url) ?? Session()
    }

    static func save(_ session: Session) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(session).write(to: fileURL, options: .atomic)
            writes += 1
        } catch {
            NSLog("Lithium: failed to save the session: %@", error.localizedDescription)
        }
    }
}

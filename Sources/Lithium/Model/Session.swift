import Foundation

/// The open tabs, in sidebar order, so they come back after a relaunch.
struct Session: Codable, Equatable {
    struct Tab: Codable, Equatable {
        var url: URL
        var title: String
        var customTitle: String?
        var pinID: Pin.ID?
        /// Nil for the main space (`Space.saved`).
        var spaceID: Space.ID? = nil
        /// The tab last shown in its space, another than the one shown at quit: switching back
        /// brings it back.
        var lastShown: Bool? = nil
        /// The sidebar folder it is in (`TabFolder`); nil outside folders.
        var folderID: TabFolder.ID? = nil
    }

    var tabs: [Tab] = []
    var selectedIndex: Int?
    var splits: [Split]?
    /// Nil until the user makes a second space, then the main one first.
    var spaces: [Space]? = nil
    /// The space shown at quit; nil for the main one.
    var spaceID: Space.ID? = nil
    /// Nil until the user makes a folder, so files written without folders stay as they were.
    var folders: [TabFolder]? = nil
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

    /// Whether the session was written: one that wasn't is tried again at the next save.
    @discardableResult
    static func save(_ session: Session) -> Bool {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(session).write(to: fileURL, options: .atomic)
            writes += 1
            return true
        } catch {
            NSLog("Lithium: failed to save the session: %@", error.localizedDescription)
            return false
        }
    }
}

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
        /// The tab last shown in a space other than the one shown at quit.
        var lastShown: Bool? = nil
        var folderID: TabFolder.ID? = nil
        /// Its back and forward pages (`WKWebView.interactionState`), only at quit: WebKit serializes
        /// a loaded tab's on the main thread, and every save would rewrite a sleeping tab's.
        var history: Data? = nil
        /// Nil for the first window, as `spaceID` is nil for the main space.
        var windowID: UUID? = nil
    }

    /// One browser window: an older build reads the tabs and ignores it.
    struct Window: Codable, Equatable {
        var id: UUID
        /// `NSWindow.frameDescriptor`; nil for a window never shown.
        var frame: String? = nil
        var selectedIndex: Int? = nil
        var spaceID: Space.ID? = nil
        var isSidebarVisible: Bool? = nil
        var isZenMode: Bool? = nil
    }

    var tabs: [Tab] = []
    /// The first window's, as `spaceID` is, so an older build still reads the file.
    var selectedIndex: Int?
    var splits: [Split]?
    /// Nil until the user makes a second space, then the main one first.
    var spaces: [Space]? = nil
    var spaceID: Space.ID? = nil
    /// Nil until the user makes a folder, so files written without folders stay as they were.
    var folders: [TabFolder]? = nil
    /// Every window, the first one first; nil in files written before windows were saved.
    var windows: [Window]? = nil

    /// As saved before quitting.
    var withoutHistory: Session {
        var session = self
        for index in session.tabs.indices { session.tabs[index].history = nil }
        return session
    }

    /// Same tabs, places and spaces, page titles aside: such a change can wait to be written.
    func differsOnlyInTitles(from other: Session) -> Bool {
        guard tabs.count == other.tabs.count else { return false }
        var untitled = self
        untitled.tabs = zip(tabs, other.tabs).map { tab, saved in
            var tab = tab
            tab.title = saved.title
            return tab
        }
        return untitled == other
    }
}

enum SessionStore {
    /// For tests.
    nonisolated(unsafe) private(set) static var writes = 0
    /// For tests: the writes the main thread waited for.
    nonisolated(unsafe) private(set) static var mainThreadWrites = 0
    /// For tests: runs on the save queue before each write, so one can be held in flight.
    nonisolated(unsafe) static var beforeWrite: (@Sendable (Session) -> Void)?

    static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "Lithium/session.json")
    }

    /// Read whole, not per entry: tabs and splits refer to each other by index.
    static func load(from url: URL = fileURL) -> Session {
        StoredFile.read(Session.self, at: url) ?? Session()
    }

    /// Encoding and writing take the main thread a few milliseconds a save: saves in use go
    /// through here, one at a time and in order.
    private static let queue = DispatchQueue(label: "Lithium.session", qos: .utility)

    /// Whether the session was written: one that wasn't is tried again at the next save. Waits
    /// for the saves before it (quitting).
    @discardableResult
    static func save(_ session: Session) -> Bool {
        if Thread.isMainThread { mainThreadWrites += 1 }
        return queue.sync { write(session) }
    }

    /// `done` gets on the main actor whether it was written.
    static func saveInBackground(_ session: Session, done: @escaping @MainActor @Sendable (Bool) -> Void) {
        queue.async {
            let written = write(session)
            Task { @MainActor in done(written) }
        }
    }

    private static func write(_ session: Session) -> Bool {
        beforeWrite?(session)
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

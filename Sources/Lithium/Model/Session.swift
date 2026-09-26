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
}

enum SessionStore {
    private static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "Lithium/session.json")
    }

    static func load() -> Session {
        guard let data = try? Data(contentsOf: fileURL) else { return Session() }
        return (try? JSONDecoder().decode(Session.self, from: data)) ?? Session()
    }

    static func save(_ session: Session) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(session).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Lithium: failed to save the session: %@", error.localizedDescription)
        }
    }
}

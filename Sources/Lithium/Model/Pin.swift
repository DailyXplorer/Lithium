import Foundation

struct Pin: Codable, Identifiable, Equatable {
    let id: UUID
    var url: URL
    var title: String
    var favicon: Data?
    /// The icon the page last declared, fetched again each day while the tab sleeps (a calendar's shows the date).
    var iconURL: URL? = nil
    /// The space whose grid shows it; nil for the main space (`Space.saved`).
    var spaceID: Space.ID? = nil

    var space: Space.ID { spaceID ?? Space.mainID }
}

enum PinStore {
    static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "Lithium/pins.json")
    }

    static func load(from url: URL = fileURL) -> [Pin] {
        StoredFile.readList(Pin.self, at: url)
    }

    static func save(_ pins: [Pin]) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(pins).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Lithium: failed to save pins: %@", error.localizedDescription)
        }
    }
}

import Foundation

struct Pin: Codable, Identifiable, Equatable {
    let id: UUID
    var url: URL
    var title: String
    var favicon: Data?
    /// The icon the page last declared, fetched again each day while the tab sleeps (a
    /// calendar's icon shows the date). Missing from favorites saved before it existed.
    var iconURL: URL? = nil
    /// The space whose grid shows it; nil for the main space (`Space.saved`).
    var spaceID: Space.ID? = nil

    var space: Space.ID { spaceID ?? Space.mainID }
}

enum PinStore {
    static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "Lithium/pins.json")
    }

    /// A favorite that can't be read doesn't take the others with it, and the file is kept aside
    /// before the next change writes over it (`StoredFile`).
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

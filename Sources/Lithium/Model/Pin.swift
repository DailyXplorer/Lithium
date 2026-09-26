import Foundation

struct Pin: Codable, Identifiable, Equatable {
    let id: UUID
    var url: URL
    var title: String
    var favicon: Data?
}

enum PinStore {
    private static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "Lithium/pins.json")
    }

    static func load() -> [Pin] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Pin].self, from: data)) ?? []
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

import Foundation

/// Reading the JSON files Lithium keeps its state in (the session, favorites, extensions). A file
/// this build can't read (cut short by a crash, or written by a newer build) is never overwritten
/// by an empty default: it is moved aside first, as `<name>.unreadable-<date>`, so nothing in it
/// is lost for good.
enum StoredFile {
    /// The decoded file; nil when there is none, or none that can be read, which is then moved aside.
    static func read<Value: Decodable>(_ type: Value.Type, at url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else {
            // One there that can't be opened (its permissions) is kept aside too: the next save replaces it.
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue { moveAside(url) }
            return nil
        }
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            NSLog("Lithium: couldn’t read %@: %@", url.lastPathComponent, String(describing: error))
            moveAside(url)
            return nil
        }
    }

    /// A list read one entry at a time: an entry this build can't read doesn't take the others
    /// with it. The whole file is moved aside then, and what could be read written in its place.
    static func readList<Element: Codable>(_ type: Element.Type, at url: URL) -> [Element] {
        guard let entries = read([Lossy<Element>].self, at: url) else { return [] }
        let readable = entries.compactMap(\.value)
        if readable.count < entries.count {
            NSLog("Lithium: couldn’t read %d entries of %@", entries.count - readable.count, url.lastPathComponent)
            if moveAside(url) { try? JSONEncoder().encode(readable).write(to: url, options: .atomic) }
        }
        return readable
    }

    @discardableResult
    static func moveAside(_ url: URL) -> Bool {
        let date = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
        var destination = url.deletingLastPathComponent().appending(path: "\(url.lastPathComponent).unreadable-\(date)")
        if FileManager.default.fileExists(atPath: destination.path) {
            destination = url.deletingLastPathComponent().appending(path: "\(destination.lastPathComponent)-\(UUID().uuidString.prefix(8))")
        }
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            return true
        } catch {
            NSLog("Lithium: couldn’t keep %@ aside: %@", url.lastPathComponent, error.localizedDescription)
            return false
        }
    }

    private struct Lossy<Wrapped: Decodable>: Decodable {
        let value: Wrapped?

        init(from decoder: Decoder) throws {
            value = try? Wrapped(from: decoder)
        }
    }
}

import Foundation

/// Reads Lithium's JSON state files. One this build can't read (cut short by a crash, or from a
/// newer build) is moved aside as `<name>.unreadable-<date>` rather than overwritten by a default.
enum StoredFile {
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

    /// Read one entry at a time, so a bad entry doesn't take the others with it.
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

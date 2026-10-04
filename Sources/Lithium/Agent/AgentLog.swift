import Foundation

/// Every agent tool call, one JSON object per line in `log/YYYY-MM-DD.jsonl` under the agent
/// folder, readable by the user alone and kept 30 days. Written off the main thread.
actor AgentLog {
    static let retentionDays = 30

    let folder: URL
    /// Orders the entries of one app run; `ts` orders runs.
    private var seq = 0

    init(folder: URL) {
        self.folder = folder
    }

    /// `entry` is the line without `ts` and `seq`, which the log adds.
    func append(_ entry: [String: JSONValue], at date: Date = Date()) {
        seq += 1
        var line = entry
        line["ts"] = .string(Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date))
        line["seq"] = .int(seq)
        let file = folder.appending(path: Self.fileName(for: date))
        do {
            try AgentFiles.prepare(folder)
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: JSONValue.object(line).encoded() + Data("\n".utf8))
        } catch {
            NSLog("Lithium: agent log write failed: \(error.localizedDescription)")
        }
    }

    /// Deletes day files older than the retention period.
    func prune(now: Date = Date()) {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -Self.retentionDays, to: now) else { return }
        let oldest = Self.fileName(for: cutoff)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in files where name.hasSuffix(".jsonl") && name < oldest {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
    }

    /// The local calendar day, so a day's file holds what the user did that day.
    static func fileName(for date: Date) -> String {
        let day = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d.jsonl", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }
}

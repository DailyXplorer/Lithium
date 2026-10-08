import Foundation

/// Every agent tool call and session eviction, one JSON object per line in `log/YYYY-MM-DD.jsonl` under the agent
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

    /// The newest `limit` entries, newest first, for `lithium://agents`.
    func entries(limit: Int) -> [JSONValue] {
        var entries: [JSONValue] = []
        for name in dayFiles().reversed() {
            let text = (try? String(contentsOf: folder.appending(path: name), encoding: .utf8)) ?? ""
            for line in text.split(separator: "\n").reversed() {
                guard let entry = try? JSONValue.decode(Data(line.utf8)) else { continue }
                entries.append(entry)
                if entries.count == limit { return entries }
            }
        }
        return entries
    }

    /// Every day file, oldest first, as one JSON Lines document.
    func export() -> Data {
        dayFiles().reduce(into: Data()) { data, name in
            data += (try? Data(contentsOf: folder.appending(path: name))) ?? Data()
        }
    }

    func clear() {
        for name in dayFiles() { try? FileManager.default.removeItem(at: folder.appending(path: name)) }
    }

    /// Names sort by date.
    private func dayFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".jsonl") }.sorted()
    }

    /// Deletes day files older than the retention period, and those named after tomorrow: files
    /// an earlier version named in a Buddhist year (2569) would otherwise sort as the newest and
    /// never go.
    func prune(now: Date = Date()) {
        guard let cutoff = Self.dayCalendar.date(byAdding: .day, value: -Self.retentionDays, to: now),
              let tomorrow = Self.dayCalendar.date(byAdding: .day, value: 1, to: now) else { return }
        let oldest = Self.fileName(for: cutoff)
        let newest = Self.fileName(for: tomorrow)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in files where name.hasSuffix(".jsonl") && (name < oldest || name > newest) {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
    }

    /// The local day, so a day's file holds what the user did that day, as a Gregorian date
    /// whatever the user's calendar: names are sorted and compared as text, which a Buddhist
    /// year (2569) or a Japanese era's (0008) would put out of order.
    static func fileName(for date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = dayCalendar
        calendar.timeZone = timeZone
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d.jsonl", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }

    /// Gregorian, in the user's time zone.
    static var dayCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = .current
        return calendar
    }

    /// Where the log lives, also while access is off: the page still shows and clears it.
    static let folder = AgentFiles.folder.appending(path: "log")
}

/// A call as the toolbar panel lists it.
struct AgentLogLine: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let session: String
    let tool: String
    let tab: String?
    let host: String?
    /// The error code; nil when the call succeeded.
    let error: String?
}

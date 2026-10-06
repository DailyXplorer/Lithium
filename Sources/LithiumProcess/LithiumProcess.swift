import Darwin

/// Tells the Lithium that wrote the endpoint file from whatever runs under its pid now: the file
/// outlives a quit or a restart, and its pid may since belong to any process, but no other
/// process has both Lithium's executable and its start time.
public enum LithiumProcess {
    /// When `pid` started, in microseconds since 1970; nil when nothing runs under it.
    public static func started(_ pid: Int32) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    /// The path of the executable `pid` runs; nil when nothing runs under it.
    public static func executable(_ pid: Int32) -> String? {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return String(cString: path)
    }

    /// Whether `pid` is the Lithium that started at `started`. Its executable must be `expected`,
    /// else any app's `Contents/MacOS/Lithium`, so a Lithium launched from another copy of the app
    /// still counts. No `started` (a file from before it was written) never counts.
    public static func isLithium(_ pid: Int32, started: UInt64?, executable expected: String? = nil) -> Bool {
        guard let started, self.started(pid) == started, let path = executable(pid) else { return false }
        guard let expected else { return path.hasSuffix(".app/Contents/MacOS/Lithium") }
        return path == expected
    }
}

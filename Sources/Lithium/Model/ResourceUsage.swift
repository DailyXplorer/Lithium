import Darwin
import Foundation

/// What the tab hover card says about the page's process.
enum TabUsage: Equatable {
    /// No web view, so no process: nothing to measure, and nothing used.
    case asleep
    /// `cpu` is nil until a second sample gives it a span to be measured over. `sharedWith`
    /// counts the other tabs in the same process, whose numbers these are too.
    case live(footprint: UInt64, cpu: Double?, sharedWith: Int)
}

/// Reads a process's memory and CPU the way Activity Monitor does. CPU is a rate, so each
/// sample is measured against the previous one of the same process; a sampler lives only as
/// long as the card that shows it, which keeps those to the processes on screen.
struct ResourceSampler {
    struct Reading: Equatable {
        /// Nanoseconds of user and system time the process has used since it started.
        let cpuTime: UInt64
        /// Nanoseconds on a monotonic clock, when `cpuTime` was read.
        let wallTime: UInt64
    }

    private var previous: [pid_t: Reading] = [:]

    /// The process's "Memory" in Activity Monitor, and its CPU since the last sample; nil when
    /// the process is gone or not ours to read.
    mutating func sample(_ pid: pid_t) -> (footprint: UInt64, cpu: Double?)? {
        // pid 0 is the kernel, which would answer.
        guard pid > 0 else { return nil }
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard status == 0 else {
            previous[pid] = nil
            return nil
        }
        let reading = Reading(
            cpuTime: Self.nanoseconds(fromMachTicks: info.ri_user_time + info.ri_system_time),
            wallTime: DispatchTime.now().uptimeNanoseconds
        )
        let cpu = previous[pid].flatMap { Self.cpuPercent(from: $0, to: reading) }
        previous[pid] = reading
        return (info.ri_phys_footprint, cpu)
    }

    /// Percent of one core, so a page busy on two shows 200 %, as in Activity Monitor.
    static func cpuPercent(from old: Reading, to new: Reading) -> Double? {
        guard new.wallTime > old.wallTime, new.cpuTime >= old.cpuTime else { return nil }
        return Double(new.cpuTime - old.cpuTime) / Double(new.wallTime - old.wallTime) * 100
    }

    /// rusage times count Mach ticks, which are nanoseconds on Intel but not on Apple silicon.
    private static func nanoseconds(fromMachTicks ticks: UInt64) -> UInt64 {
        ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()
}

enum UsageFormat {
    /// Like Chrome's hover card: whole megabytes, gigabytes to one decimal. Always English, as
    /// the rest of the interface is.
    static func memory(_ bytes: UInt64) -> String {
        let megabytes = Double(bytes) / 1_048_576
        if megabytes.rounded() < 1024 { return "\(max(Int(megabytes.rounded()), 1)) MB" }
        return String(format: "%.1f GB", megabytes / 1024)
    }

    static func cpu(_ percent: Double) -> String {
        percent < 1 ? "< 1 %" : "\(Int(percent.rounded())) %"
    }

    static func shared(with others: Int) -> String {
        "Shared with \(others) other \(others == 1 ? "tab" : "tabs")"
    }
}

extension TabUsage {
    /// How many of `others`, the processes of every other awake tab, are `pid`.
    static func sharing(_ pid: pid_t, among others: [pid_t?]) -> Int {
        others.count { $0 == pid }
    }
}

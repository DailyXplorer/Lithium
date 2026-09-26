// Sums memory (phys_footprint, what Activity Monitor shows), CPU time and energy over every
// process macOS holds a browser responsible for: its own processes plus its WebKit or Chromium helpers.
// Usage: probe <browser pid>   Prints one JSON line.
import Darwin
import Foundation

typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
let handle = dlopen(nil, RTLD_NOW)
guard let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { fatalError("missing responsibility API") }
let responsible = unsafeBitCast(symbol, to: ResponsibleFn.self)

guard CommandLine.arguments.count == 2, let target = pid_t(CommandLine.arguments[1]) else {
    fputs("usage: probe <pid>\n", stderr); exit(2)
}

var pids = [pid_t](repeating: 0, count: 8192)
let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))

var footprint: UInt64 = 0, cpuNanos: UInt64 = 0, energy: UInt64 = 0, processes = 0
var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)

for pid in pids.prefix(count) where pid > 0 {
    guard pid == target || responsible(pid) == target else { continue }
    var info = rusage_info_v6()
    let ok = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
    }
    guard ok == 0 else { continue }
    processes += 1
    footprint += info.ri_phys_footprint
    cpuNanos += (info.ri_user_time + info.ri_system_time) * UInt64(timebase.numer) / UInt64(timebase.denom)
    energy += info.ri_energy_nj
}

print(String(format: "{\"processes\":%d,\"memoryMB\":%.1f,\"cpuSeconds\":%.3f,\"energyJ\":%.3f}",
             processes, Double(footprint) / 1_048_576, Double(cpuNanos) / 1e9, Double(energy) / 1e9))

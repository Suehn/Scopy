import Darwin
import Foundation

// Kernel process counters only. No address, file-path, or memory-content inspection.
// Convert kernel CPU absolute-time counters to nanoseconds; footprint and disk IO are bytes.
guard [2, 4].contains(CommandLine.arguments.count), let pid = Int32(CommandLine.arguments[1]) else {
    fputs("usage: procstats <pid> [intervalMs stopFile]\n", stderr)
    exit(64)
}
var timebase = mach_timebase_info_data_t()
guard mach_timebase_info(&timebase) == KERN_SUCCESS else { exit(2) }
func nanoseconds(_ absoluteTime: UInt64) -> Double {
    Double(absoluteTime) * Double(timebase.numer) / Double(timebase.denom)
}
func observe() -> [String: Any]? {
    var usage = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &usage) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { buffer in
            proc_pid_rusage(pid, RUSAGE_INFO_V4, buffer)
        }
    }
    guard result == 0 else { return nil }
    return [
        "observed_ns": DispatchTime.now().uptimeNanoseconds,
        "user_cpu_ns": nanoseconds(usage.ri_user_time),
        "system_cpu_ns": nanoseconds(usage.ri_system_time),
        "resident_bytes": usage.ri_resident_size,
        "physical_footprint_bytes": usage.ri_phys_footprint,
        "lifetime_peak_physical_footprint_bytes": usage.ri_lifetime_max_phys_footprint,
        "disk_read_bytes": usage.ri_diskio_bytesread,
        "disk_write_bytes": usage.ri_diskio_byteswritten,
        "logical_write_counter": usage.ri_logical_writes,
        "pageins": usage.ri_pageins,
        "instructions": usage.ri_instructions,
        "cycles": usage.ri_cycles
    ]
}
let interval = CommandLine.arguments.count == 4 ? Double(CommandLine.arguments[2]) ?? 0 : 0
let stopFile = CommandLine.arguments.count == 4 ? CommandLine.arguments[3] : nil
guard stopFile == nil || (interval >= 10 && interval <= 1000) else { exit(64) }
let started = DispatchTime.now().uptimeNanoseconds
repeat {
    guard let payload = observe() else {
        fputs("proc_pid_rusage failed\n", stderr)
        exit(2)
    }
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
    guard let stopFile else { break }
    if FileManager.default.fileExists(atPath: stopFile) { break }
    usleep(UInt32(interval * 1000))
} while Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9 < 180

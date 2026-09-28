import Darwin
import Foundation

/// Samples every process on the system via libproc.
///
/// Holds per-pid delta state (CPU ticks, disk bytes) between calls; not thread-safe.
public final class ProcessSampler {
    private struct Entry {
        var startSec: UInt64
        var startUsec: UInt64
        var name: String
        var path: String?
        var cpuTicks: UInt64
        var diskRead: UInt64
        var diskWrite: UInt64
        var startDate: Date?
        var restricted: Bool
        var responsiblePID: Int32?
    }

    private var entries: [Int32: Entry] = [:]
    private var pids: [pid_t] = []
    /// PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN), a macro Swift cannot import.
    private var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    private var previousSample: Date?
    private let ticksToNanos: Double
    /// `responsibility_get_pid_responsible_for_pid`, private libsystem API; resolved at runtime so its absence only disables the feature.
    private let responsibilityLookup: (@convention(c) (pid_t) -> pid_t)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    public init() {
        var timebase = mach_timebase_info_data_t()
        if mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom != 0 {
            ticksToNanos = Double(timebase.numer) / Double(timebase.denom)
        } else {
            ticksToNanos = 1
        }
    }

    /// Per-second rate of a monotonically increasing counter; resets and wraparound clamp to 0.
    public static func rate(previous: UInt64, current: UInt64, elapsed: TimeInterval) -> Double {
        guard elapsed > 0, current >= previous else { return 0 }
        return Double(current - previous) / elapsed
    }

    /// CPU share of one core from a CPU-time delta in Mach ticks.
    public static func cpuShare(previousTicks: UInt64, currentTicks: UInt64, ticksToNanos: Double, elapsed: TimeInterval) -> Double {
        rate(previous: previousTicks, current: currentTicks, elapsed: elapsed) * ticksToNanos / 1_000_000_000
    }

    public func sample(now: Date = .now) -> [ProcessStats] {
        let elapsed = previousSample.map { now.timeIntervalSince($0) } ?? 0
        previousSample = now
        let count = listPids()
        var result: [ProcessStats] = []
        result.reserveCapacity(count)
        var seen = Set<Int32>(minimumCapacity: count)

        for index in 0..<count {
            let pid = pids[index]
            if let stats = sampleProcess(pid, elapsed: elapsed) {
                result.append(stats)
                seen.insert(pid)
            }
        }
        if entries.count != seen.count {
            entries = entries.filter { seen.contains($0.key) }
        }
        return result
    }

    private func listPids() -> Int {
        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else { return 0 }
        let capacity = Int(needed) + 64
        if pids.count < capacity {
            pids = [pid_t](repeating: 0, count: capacity * 2)
        }
        let got = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        return max(0, min(Int(got), pids.count))
    }

    private func sampleProcess(_ pid: Int32, elapsed: TimeInterval) -> ProcessStats? {
        var info = proc_taskallinfo()
        let size = Int32(MemoryLayout<proc_taskallinfo>.size)
        errno = 0
        if proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, size) == size {
            return sampleFull(pid, info: info, elapsed: elapsed)
        }
        guard errno != ESRCH else {
            entries[pid] = nil
            return nil
        }
        return sampleRestricted(pid)
    }

    private func sampleFull(_ pid: Int32, info: proc_taskallinfo, elapsed: TimeInterval) -> ProcessStats {
        let bsd = info.pbsd
        let task = info.ptinfo
        let cpuTicks = task.pti_total_user &+ task.pti_total_system

        var usage = rusage_info_v4()
        let hasUsage = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        } == 0

        var entry: Entry
        var isNew = false
        if let existing = entries[pid], !existing.restricted,
           existing.startSec == bsd.pbi_start_tvsec, existing.startUsec == bsd.pbi_start_tvusec {
            entry = existing
        } else {
            let path = executablePath(pid)
            let fallback = Self.string(fromTuple: bsd.pbi_name).nonEmpty ?? Self.string(fromTuple: bsd.pbi_comm)
            let start = Date(timeIntervalSince1970: Double(bsd.pbi_start_tvsec) + Double(bsd.pbi_start_tvusec) / 1_000_000)
            entry = Entry(
                startSec: bsd.pbi_start_tvsec, startUsec: bsd.pbi_start_tvusec,
                name: Self.displayName(path: path, fallback: fallback), path: path,
                cpuTicks: cpuTicks, diskRead: 0, diskWrite: 0,
                startDate: bsd.pbi_start_tvsec > 0 ? start : nil, restricted: false,
                responsiblePID: responsiblePID(of: pid)
            )
            isNew = true
        }

        let cpu = isNew ? 0 : Self.cpuShare(previousTicks: entry.cpuTicks, currentTicks: cpuTicks, ticksToNanos: ticksToNanos, elapsed: elapsed)
        var readRate = 0.0
        var writeRate = 0.0
        if hasUsage {
            if !isNew {
                readRate = Self.rate(previous: entry.diskRead, current: usage.ri_diskio_bytesread, elapsed: elapsed)
                writeRate = Self.rate(previous: entry.diskWrite, current: usage.ri_diskio_byteswritten, elapsed: elapsed)
            }
            entry.diskRead = usage.ri_diskio_bytesread
            entry.diskWrite = usage.ri_diskio_byteswritten
        }
        entry.cpuTicks = cpuTicks
        entries[pid] = entry

        return ProcessStats(
            pid: pid, ppid: Int32(bitPattern: bsd.pbi_ppid), name: entry.name, executablePath: entry.path,
            cpu: cpu, memory: hasUsage ? usage.ri_phys_footprint : 0, threads: Int(task.pti_threadnum),
            uid: bsd.pbi_uid, startDate: entry.startDate,
            diskReadBytesPerSecond: readRate, diskWriteBytesPerSecond: writeRate, isRestricted: false,
            responsiblePID: entry.responsiblePID
        )
    }

    private func sampleRestricted(_ pid: Int32) -> ProcessStats? {
        var short = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &short, size) == size else {
            entries[pid] = nil
            return nil
        }
        let comm = Self.string(fromTuple: short.pbsi_comm)
        let entry: Entry
        if let existing = entries[pid], existing.restricted, existing.startSec == UInt64(short.pbsi_uid),
           existing.startUsec == UInt64(short.pbsi_ppid) {
            entry = existing
        } else {
            let path = executablePath(pid)
            // Restricted entries reuse the start fields as an identity key (uid, ppid) to detect pid reuse.
            entry = Entry(
                startSec: UInt64(short.pbsi_uid), startUsec: UInt64(short.pbsi_ppid),
                name: pid == 0 ? "kernel_task" : Self.displayName(path: path, fallback: comm), path: path,
                cpuTicks: 0, diskRead: 0, diskWrite: 0, startDate: Self.startDate(pid), restricted: true,
                responsiblePID: responsiblePID(of: pid)
            )
            entries[pid] = entry
        }
        return ProcessStats(
            pid: pid, ppid: Int32(bitPattern: short.pbsi_ppid), name: entry.name, executablePath: entry.path,
            cpu: 0, memory: 0, threads: 0, uid: short.pbsi_uid, startDate: entry.startDate,
            diskReadBytesPerSecond: 0, diskWriteBytesPerSecond: 0, isRestricted: true,
            responsiblePID: entry.responsiblePID
        )
    }

    /// The responsible process per the libsystem SPI, or nil when it is the process itself, launchd, or unknown.
    private func responsiblePID(of pid: Int32) -> Int32? {
        guard pid > 1, let lookup = responsibilityLookup else { return nil }
        let responsible = lookup(pid)
        return responsible > 1 && responsible != pid ? responsible : nil
    }

    private func executablePath(_ pid: Int32) -> String? {
        let length = pathBuffer.withUnsafeMutableBytes { buffer in
            proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count))
        }
        guard length > 0 else { return nil }
        return pathBuffer.withUnsafeBufferPointer { buffer in
            String(decoding: UnsafeRawBufferPointer(start: buffer.baseAddress, count: Int(length)), as: UTF8.self)
        }
    }

    /// Start time via sysctl, which works for processes whose task info is restricted.
    private static func startDate(_ pid: Int32) -> Date? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size == MemoryLayout<kinfo_proc>.size else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        guard start.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }

    /// The untruncated executable file name beats the kernel's 32-char process name.
    static func displayName(path: String?, fallback: String) -> String {
        if let path, let slash = path.lastIndex(of: "/") {
            let base = path[path.index(after: slash)...]
            if !base.isEmpty { return String(base) }
        }
        return fallback
    }

    static func string<T>(fromTuple tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let end = bytes.firstIndex(of: 0) ?? bytes.count
            return String(decoding: UnsafeBufferPointer(rebasing: bytes[..<end]), as: UTF8.self)
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

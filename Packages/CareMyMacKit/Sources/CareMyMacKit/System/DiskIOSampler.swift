import Foundation
import IOKit

/// Sums IOBlockStorageDriver statistics across all block devices.
public final class DiskIOSampler {
    struct Counters: Equatable {
        var bytesRead: UInt64 = 0
        var bytesWritten: UInt64 = 0
        var readOps: UInt64 = 0
        var writeOps: UInt64 = 0
    }

    private var previous: (counters: Counters, date: Date)?

    public init() {}

    public func sample(now: Date = .now) -> DiskIOStats {
        let current = Self.readCounters()
        defer { previous = (current, now) }
        return Self.stats(previous: previous, current: current, now: now)
    }

    static func stats(previous: (counters: Counters, date: Date)?, current: Counters, now: Date) -> DiskIOStats {
        guard let previous else {
            return DiskIOStats(readBytesPerSecond: 0, writeBytesPerSecond: 0, readOpsPerSecond: 0, writeOpsPerSecond: 0, totalRead: current.bytesRead, totalWritten: current.bytesWritten)
        }
        let elapsed = now.timeIntervalSince(previous.date)
        let old = previous.counters
        return DiskIOStats(
            readBytesPerSecond: SystemProbe.rate(from: old.bytesRead, to: current.bytesRead, elapsed: elapsed),
            writeBytesPerSecond: SystemProbe.rate(from: old.bytesWritten, to: current.bytesWritten, elapsed: elapsed),
            readOpsPerSecond: SystemProbe.rate(from: old.readOps, to: current.readOps, elapsed: elapsed),
            writeOpsPerSecond: SystemProbe.rate(from: old.writeOps, to: current.writeOps, elapsed: elapsed),
            totalRead: current.bytesRead,
            totalWritten: current.bytesWritten
        )
    }

    private static func readCounters() -> Counters {
        var counters = Counters()
        SystemProbe.forEachService(matching: "IOBlockStorageDriver") { driver in
            guard let statistics = SystemProbe.property(driver, "Statistics") as? [String: Any] else { return true }
            counters.bytesRead &+= SystemProbe.uint64(from: statistics["Bytes (Read)"]) ?? 0
            counters.bytesWritten &+= SystemProbe.uint64(from: statistics["Bytes (Write)"]) ?? 0
            counters.readOps &+= SystemProbe.uint64(from: statistics["Operations (Read)"]) ?? 0
            counters.writeOps &+= SystemProbe.uint64(from: statistics["Operations (Write)"]) ?? 0
            return true
        }
        return counters
    }
}

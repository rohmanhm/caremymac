import Foundation

/// Folds per-second snapshots into one `HistoryRecord` per calendar minute.
///
/// A record is emitted only for minutes that received samples: after a sleep gap the pending
/// minute is returned when the next sample arrives, and the skipped minutes produce nothing.
public struct MinuteAggregator: Sendable {
    /// How many apps each ranking contributes to `HistoryRecord.topApps`.
    public static let topCPUAppCount = 5
    public static let topMemoryAppCount = 5

    private var bucket: Bucket?

    public init() {}

    /// Adds one tick. Returns the previous minute's record when `snapshot.date` falls in a different minute.
    public mutating func add(_ snapshot: SystemSnapshot, apps: [AppActivity]) -> HistoryRecord? {
        let minute = Self.minute(of: snapshot.date)
        var finished: HistoryRecord?
        var current: Bucket
        if let existing = bucket, existing.minute == minute {
            current = existing
        } else {
            finished = bucket?.record()
            current = Bucket(minute: minute)
        }
        // Release the stored copy so `current` mutates its dictionary in place.
        bucket = nil
        current.add(snapshot, apps: apps)
        bucket = current
        return finished
    }

    /// Returns the in-progress minute (if any) and clears it.
    public mutating func flush() -> HistoryRecord? {
        defer { bucket = nil }
        return bucket?.record()
    }

    /// Seconds-since-1970 of the minute containing `date`, divided by 60.
    static func minute(of date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 / 60).rounded(.down))
    }

    private struct AppAccumulator: Sendable {
        var name: String
        var bundleIdentifier: String?
        var cpuSum: Double = 0
        var memorySum: Double = 0
        var presentSamples = 0
        var processCount = 0
    }

    private struct Bucket: Sendable {
        let minute: Int64
        var count = 0
        var cpuSum = 0.0
        var cpuPeak = 0.0
        var userSum = 0.0
        var systemSum = 0.0
        var memoryUsedSum = 0.0
        var memoryPhysical: UInt64 = 0
        var pressure = MemoryPressure.normal
        var swapSum = 0.0
        var diskReadSum = 0.0
        var diskWriteSum = 0.0
        var netInSum = 0.0
        var netOutSum = 0.0
        var gpuSum = 0.0
        var gpuCount = 0
        var batteryLevel: Double?
        var batteryPluggedIn: Bool?
        var apps: [String: AppAccumulator] = [:]

        init(minute: Int64) {
            self.minute = minute
        }

        mutating func add(_ snapshot: SystemSnapshot, apps activities: [AppActivity]) {
            count += 1
            let cpu = snapshot.cpu.total
            cpuSum += cpu
            cpuPeak = max(cpuPeak, cpu)
            userSum += snapshot.cpu.user
            systemSum += snapshot.cpu.system
            memoryUsedSum += Double(snapshot.memory.used)
            memoryPhysical = snapshot.memory.physical
            if snapshot.memory.pressure.ordinal > pressure.ordinal {
                pressure = snapshot.memory.pressure
            }
            swapSum += Double(snapshot.memory.swapUsed)
            diskReadSum += snapshot.disk.readBytesPerSecond
            diskWriteSum += snapshot.disk.writeBytesPerSecond
            netInSum += snapshot.network.receivedBytesPerSecond
            netOutSum += snapshot.network.sentBytesPerSecond
            if let utilization = snapshot.gpu?.utilization {
                gpuSum += utilization
                gpuCount += 1
            }
            if let battery = snapshot.battery {
                batteryLevel = battery.level
                batteryPluggedIn = battery.isPluggedIn
            }
            for app in activities {
                var accumulator = apps.removeValue(forKey: app.id) ?? AppAccumulator(name: app.name, bundleIdentifier: app.bundleIdentifier)
                accumulator.name = app.name
                accumulator.bundleIdentifier = app.bundleIdentifier
                accumulator.cpuSum += app.cpu
                accumulator.memorySum += Double(app.memory)
                accumulator.presentSamples += 1
                accumulator.processCount = max(accumulator.processCount, app.processes.count)
                apps[app.id] = accumulator
            }
        }

        func record() -> HistoryRecord {
            let samples = Double(count)
            return HistoryRecord(
                date: Date(timeIntervalSince1970: Double(minute * 60)),
                cpuAverage: cpuSum / samples,
                cpuPeak: cpuPeak,
                cpuUser: userSum / samples,
                cpuSystem: systemSum / samples,
                memoryUsed: UInt64((memoryUsedSum / samples).rounded()),
                memoryPhysical: memoryPhysical,
                memoryPressure: pressure,
                swapUsed: UInt64((swapSum / samples).rounded()),
                diskReadBytesPerSecond: diskReadSum / samples,
                diskWriteBytesPerSecond: diskWriteSum / samples,
                networkInBytesPerSecond: netInSum / samples,
                networkOutBytesPerSecond: netOutSum / samples,
                gpuUtilization: gpuCount > 0 ? gpuSum / Double(gpuCount) : nil,
                batteryLevel: batteryLevel,
                batteryPluggedIn: batteryPluggedIn,
                topApps: topApps(samples: samples),
                sampleCount: count
            )
        }

        private func topApps(samples: Double) -> [AppSummary] {
            let summaries = apps.map { id, accumulator in
                AppSummary(
                    id: id,
                    name: accumulator.name,
                    bundleIdentifier: accumulator.bundleIdentifier,
                    cpu: accumulator.cpuSum / samples,
                    memory: UInt64((accumulator.memorySum / Double(accumulator.presentSamples)).rounded()),
                    processCount: accumulator.processCount
                )
            }
            let byCPU = summaries.sorted { $0.cpu != $1.cpu ? $0.cpu > $1.cpu : $0.id < $1.id }
            let byMemory = summaries.sorted { $0.memory != $1.memory ? $0.memory > $1.memory : $0.id < $1.id }
            var selected = Array(byCPU.prefix(MinuteAggregator.topCPUAppCount))
            var ids = Set(selected.map(\.id))
            for app in byMemory.prefix(MinuteAggregator.topMemoryAppCount) where ids.insert(app.id).inserted {
                selected.append(app)
            }
            return selected.sorted { $0.cpu != $1.cpu ? $0.cpu > $1.cpu : $0.id < $1.id }
        }
    }
}

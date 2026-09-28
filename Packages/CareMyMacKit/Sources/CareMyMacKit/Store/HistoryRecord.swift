import Foundation

/// Compact, persistable view of one app's resource use.
public struct AppSummary: Codable, Sendable, Hashable, Identifiable {
    /// Same identity as `AppActivity.id`.
    public var id: String
    public var name: String
    public var bundleIdentifier: String?
    /// Share of ONE core (1.0 = 100%).
    public var cpu: Double
    /// Physical footprint in bytes.
    public var memory: UInt64
    public var processCount: Int

    public init(id: String, name: String, bundleIdentifier: String?, cpu: Double, memory: UInt64, processCount: Int) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.cpu = cpu
        self.memory = memory
        self.processCount = processCount
    }

    public init(_ app: AppActivity) {
        self.init(
            id: app.id,
            name: app.name,
            bundleIdentifier: app.bundleIdentifier,
            cpu: app.cpu,
            memory: app.memory,
            processCount: app.processes.count
        )
    }
}

/// Aggregated measurements for one calendar minute.
public struct HistoryRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: Date { date }

    /// Start of the minute (whole seconds since 1970, divisible by 60).
    public var date: Date
    /// Mean of `CPUStats.total` over the minute's samples.
    public var cpuAverage: Double
    public var cpuPeak: Double
    public var cpuUser: Double
    public var cpuSystem: Double
    /// Mean of `MemoryStats.used`.
    public var memoryUsed: UInt64
    public var memoryPhysical: UInt64
    /// Worst pressure seen during the minute.
    public var memoryPressure: MemoryPressure
    /// Mean swap in use.
    public var swapUsed: UInt64
    public var diskReadBytesPerSecond: Double
    public var diskWriteBytesPerSecond: Double
    public var networkInBytesPerSecond: Double
    public var networkOutBytesPerSecond: Double
    /// Mean over samples that reported utilization; nil when none did.
    public var gpuUtilization: Double?
    /// Last reported level in the minute.
    public var batteryLevel: Double?
    public var batteryPluggedIn: Bool?
    /// Union of the top CPU and top memory apps, sorted by CPU (descending).
    /// `cpu` is averaged over every sample in the minute; `memory` over the samples the app was running.
    public var topApps: [AppSummary]
    public var sampleCount: Int

    public init(date: Date, cpuAverage: Double, cpuPeak: Double, cpuUser: Double, cpuSystem: Double, memoryUsed: UInt64, memoryPhysical: UInt64, memoryPressure: MemoryPressure, swapUsed: UInt64, diskReadBytesPerSecond: Double, diskWriteBytesPerSecond: Double, networkInBytesPerSecond: Double, networkOutBytesPerSecond: Double, gpuUtilization: Double?, batteryLevel: Double?, batteryPluggedIn: Bool?, topApps: [AppSummary], sampleCount: Int) {
        self.date = date
        self.cpuAverage = cpuAverage
        self.cpuPeak = cpuPeak
        self.cpuUser = cpuUser
        self.cpuSystem = cpuSystem
        self.memoryUsed = memoryUsed
        self.memoryPhysical = memoryPhysical
        self.memoryPressure = memoryPressure
        self.swapUsed = swapUsed
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
        self.networkInBytesPerSecond = networkInBytesPerSecond
        self.networkOutBytesPerSecond = networkOutBytesPerSecond
        self.gpuUtilization = gpuUtilization
        self.batteryLevel = batteryLevel
        self.batteryPluggedIn = batteryPluggedIn
        self.topApps = topApps
        self.sampleCount = sampleCount
    }
}

extension MemoryPressure {
    /// Severity ordinal: normal 0, warning 1, critical 2.
    var ordinal: Int {
        switch self {
        case .normal: 0
        case .warning: 1
        case .critical: 2
        }
    }
}

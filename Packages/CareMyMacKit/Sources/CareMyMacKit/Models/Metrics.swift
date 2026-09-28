import Foundation

// All fractions are 0...1 unless stated otherwise. Rates are per second.
// `nil` means the measurement is unavailable on this Mac (shown as a dash).

public struct CPUStats: Sendable, Hashable, Codable {
    public struct Core: Sendable, Hashable, Codable {
        public var user: Double
        public var system: Double
        public var total: Double { user + system }
        public init(user: Double, system: Double) {
            self.user = user
            self.system = system
        }
    }

    /// Share of total machine capacity spent in user space.
    public var user: Double
    /// Share of total machine capacity spent in the kernel.
    public var system: Double
    public var cores: [Core]
    public var performanceCoreCount: Int?
    public var efficiencyCoreCount: Int?
    /// 1, 5 and 15 minute load averages.
    public var loadAverage: [Double]

    public var total: Double { user + system }
    public var idle: Double { max(0, 1 - total) }

    public init(user: Double, system: Double, cores: [Core], performanceCoreCount: Int?, efficiencyCoreCount: Int?, loadAverage: [Double]) {
        self.user = user
        self.system = system
        self.cores = cores
        self.performanceCoreCount = performanceCoreCount
        self.efficiencyCoreCount = efficiencyCoreCount
        self.loadAverage = loadAverage
    }

    public static let zero = CPUStats(user: 0, system: 0, cores: [], performanceCoreCount: nil, efficiencyCoreCount: nil, loadAverage: [])
}

public enum MemoryPressure: String, Sendable, Hashable, Codable, CaseIterable {
    case normal, warning, critical
}

public struct MemoryStats: Sendable, Hashable, Codable {
    /// Installed RAM (hw.memsize).
    public var physical: UInt64
    /// Activity Monitor "Memory Used": app + wired + compressed.
    public var used: UInt64 { app + wired + compressed }
    /// Anonymous memory owned by apps (internal - purgeable).
    public var app: UInt64
    public var active: UInt64
    public var inactive: UInt64
    public var wired: UInt64
    /// Bytes occupied by the compressor.
    public var compressed: UInt64
    /// File-backed and purgeable memory the system can reclaim.
    public var cachedFiles: UInt64
    public var free: UInt64
    public var swapUsed: UInt64
    public var swapTotal: UInt64
    public var pressure: MemoryPressure

    public init(physical: UInt64, app: UInt64, active: UInt64, inactive: UInt64, wired: UInt64, compressed: UInt64, cachedFiles: UInt64, free: UInt64, swapUsed: UInt64, swapTotal: UInt64, pressure: MemoryPressure) {
        self.physical = physical
        self.app = app
        self.active = active
        self.inactive = inactive
        self.wired = wired
        self.compressed = compressed
        self.cachedFiles = cachedFiles
        self.free = free
        self.swapUsed = swapUsed
        self.swapTotal = swapTotal
        self.pressure = pressure
    }

    public static let zero = MemoryStats(physical: 0, app: 0, active: 0, inactive: 0, wired: 0, compressed: 0, cachedFiles: 0, free: 0, swapUsed: 0, swapTotal: 0, pressure: .normal)
}

public struct DiskIOStats: Sendable, Hashable, Codable {
    public var readBytesPerSecond: Double
    public var writeBytesPerSecond: Double
    public var readOpsPerSecond: Double
    public var writeOpsPerSecond: Double
    /// Cumulative since boot.
    public var totalRead: UInt64
    public var totalWritten: UInt64

    public init(readBytesPerSecond: Double, writeBytesPerSecond: Double, readOpsPerSecond: Double, writeOpsPerSecond: Double, totalRead: UInt64, totalWritten: UInt64) {
        self.readBytesPerSecond = readBytesPerSecond
        self.writeBytesPerSecond = writeBytesPerSecond
        self.readOpsPerSecond = readOpsPerSecond
        self.writeOpsPerSecond = writeOpsPerSecond
        self.totalRead = totalRead
        self.totalWritten = totalWritten
    }

    public static let zero = DiskIOStats(readBytesPerSecond: 0, writeBytesPerSecond: 0, readOpsPerSecond: 0, writeOpsPerSecond: 0, totalRead: 0, totalWritten: 0)
}

public enum NetworkInterfaceKind: String, Sendable, Hashable, Codable {
    case wifi, ethernet, cellular, vpn, bridge, loopback, other
}

public struct NetworkInterfaceStats: Sendable, Hashable, Codable, Identifiable {
    /// BSD name, e.g. "en0".
    public var id: String
    /// Human name, e.g. "Wi-Fi"; falls back to the BSD name.
    public var displayName: String
    public var kind: NetworkInterfaceKind
    public var isUp: Bool
    public var receivedBytesPerSecond: Double
    public var sentBytesPerSecond: Double
    public var totalReceived: UInt64
    public var totalSent: UInt64
    public var addresses: [String]

    public init(id: String, displayName: String, kind: NetworkInterfaceKind, isUp: Bool, receivedBytesPerSecond: Double, sentBytesPerSecond: Double, totalReceived: UInt64, totalSent: UInt64, addresses: [String]) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.isUp = isUp
        self.receivedBytesPerSecond = receivedBytesPerSecond
        self.sentBytesPerSecond = sentBytesPerSecond
        self.totalReceived = totalReceived
        self.totalSent = totalSent
        self.addresses = addresses
    }
}

public struct NetworkStats: Sendable, Hashable, Codable {
    /// Sum over non-loopback interfaces.
    public var receivedBytesPerSecond: Double
    public var sentBytesPerSecond: Double
    public var interfaces: [NetworkInterfaceStats]

    public init(receivedBytesPerSecond: Double, sentBytesPerSecond: Double, interfaces: [NetworkInterfaceStats]) {
        self.receivedBytesPerSecond = receivedBytesPerSecond
        self.sentBytesPerSecond = sentBytesPerSecond
        self.interfaces = interfaces
    }

    public static let zero = NetworkStats(receivedBytesPerSecond: 0, sentBytesPerSecond: 0, interfaces: [])
}

public struct GPUStats: Sendable, Hashable, Codable {
    /// e.g. "Apple M4".
    public var name: String
    public var coreCount: Int?
    /// Device utilization; nil when the counter isn't exposed.
    public var utilization: Double?
    public var rendererUtilization: Double?
    public var tilerUtilization: Double?
    public var memoryInUse: UInt64?

    public init(name: String, coreCount: Int?, utilization: Double?, rendererUtilization: Double?, tilerUtilization: Double?, memoryInUse: UInt64?) {
        self.name = name
        self.coreCount = coreCount
        self.utilization = utilization
        self.rendererUtilization = rendererUtilization
        self.tilerUtilization = tilerUtilization
        self.memoryInUse = memoryInUse
    }
}

public enum BatteryState: String, Sendable, Hashable, Codable {
    case charging, discharging, charged, notCharging
}

public struct BatteryStats: Sendable, Hashable, Codable {
    public var level: Double
    public var state: BatteryState
    public var isPluggedIn: Bool
    /// Seconds to empty (discharging) or full (charging); nil while macOS is estimating.
    public var timeRemaining: TimeInterval?
    public var cycleCount: Int?
    /// Maximum capacity as a share of design capacity (battery health).
    public var health: Double?
    public var designCapacity: Int?
    public var maxCapacity: Int?
    public var temperatureCelsius: Double?
    /// System power draw in watts (positive while discharging).
    public var powerWatts: Double?
    public var adapterWatts: Int?
    public var condition: String?

    public init(level: Double, state: BatteryState, isPluggedIn: Bool, timeRemaining: TimeInterval?, cycleCount: Int?, health: Double?, designCapacity: Int?, maxCapacity: Int?, temperatureCelsius: Double?, powerWatts: Double?, adapterWatts: Int?, condition: String?) {
        self.level = level
        self.state = state
        self.isPluggedIn = isPluggedIn
        self.timeRemaining = timeRemaining
        self.cycleCount = cycleCount
        self.health = health
        self.designCapacity = designCapacity
        self.maxCapacity = maxCapacity
        self.temperatureCelsius = temperatureCelsius
        self.powerWatts = powerWatts
        self.adapterWatts = adapterWatts
        self.condition = condition
    }
}

public struct VolumeStats: Sendable, Hashable, Codable, Identifiable {
    /// Mount path.
    public var id: String
    public var name: String
    public var totalBytes: UInt64
    public var availableBytes: UInt64
    /// Includes purgeable space macOS can free on demand.
    public var availableForImportantUsage: UInt64
    public var isInternal: Bool
    public var isRemovable: Bool
    public var isRoot: Bool
    public var format: String?

    public var usedBytes: UInt64 { totalBytes > availableForImportantUsage ? totalBytes - availableForImportantUsage : 0 }

    public init(id: String, name: String, totalBytes: UInt64, availableBytes: UInt64, availableForImportantUsage: UInt64, isInternal: Bool, isRemovable: Bool, isRoot: Bool, format: String?) {
        self.id = id
        self.name = name
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.availableForImportantUsage = availableForImportantUsage
        self.isInternal = isInternal
        self.isRemovable = isRemovable
        self.isRoot = isRoot
        self.format = format
    }
}

/// System-wide measurements for one tick.
public struct SystemSnapshot: Sendable, Hashable, Codable {
    public var date: Date
    public var cpu: CPUStats
    public var memory: MemoryStats
    public var disk: DiskIOStats
    public var network: NetworkStats
    public var gpu: GPUStats?
    public var battery: BatteryStats?

    public init(date: Date, cpu: CPUStats, memory: MemoryStats, disk: DiskIOStats, network: NetworkStats, gpu: GPUStats?, battery: BatteryStats?) {
        self.date = date
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
        self.network = network
        self.gpu = gpu
        self.battery = battery
    }
}

/// Static facts about this Mac.
public struct MachineInfo: Sendable, Hashable, Codable {
    /// e.g. "MacBook Pro".
    public var modelName: String
    /// e.g. "Apple M4".
    public var chipName: String
    public var coreCount: Int
    public var physicalMemory: UInt64
    public var osVersion: String
    public var hostName: String

    public init(modelName: String, chipName: String, coreCount: Int, physicalMemory: UInt64, osVersion: String, hostName: String) {
        self.modelName = modelName
        self.chipName = chipName
        self.coreCount = coreCount
        self.physicalMemory = physicalMemory
        self.osVersion = osVersion
        self.hostName = hostName
    }
}

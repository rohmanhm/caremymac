import Foundation

/// How an `AlertMetric` value (and a rule threshold) is scaled.
public enum AlertUnit: String, Codable, Sendable, Hashable {
    /// 0...1, shown as a percentage.
    case fraction
    /// Share of one core (1.0 = 100%), shown as a percentage that can exceed 100%.
    case coreShare
    case bytes
    case bytesPerSecond
    /// Memory pressure ordinal: normal 0, warning 1, critical 2.
    case pressureLevel
}

public enum AlertMetric: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case cpu
    case memoryPressure
    case memoryUsedFraction
    case swapUsed
    case gpu
    case batteryLevel
    case diskWrite
    case networkIn
    case appCPU
    case appMemory
    /// Growth of one app's memory within `AlertRule.window`; threshold in bytes.
    case appMemoryGrowth

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .cpu: "CPU"
        case .memoryPressure: "Memory pressure"
        case .memoryUsedFraction: "Memory used"
        case .swapUsed: "Swap used"
        case .gpu: "GPU"
        case .batteryLevel: "Battery"
        case .diskWrite: "Disk write"
        case .networkIn: "Network in"
        case .appCPU: "App CPU"
        case .appMemory: "App memory"
        case .appMemoryGrowth: "App memory growth"
        }
    }

    /// Evaluated per app; streaks and cooldowns are tracked per app id.
    public var isAppMetric: Bool {
        switch self {
        case .appCPU, .appMemory, .appMemoryGrowth: true
        default: false
        }
    }

    public var unit: AlertUnit {
        switch self {
        case .cpu, .memoryUsedFraction, .gpu, .batteryLevel: .fraction
        case .appCPU: .coreShare
        case .memoryPressure: .pressureLevel
        case .swapUsed, .appMemory, .appMemoryGrowth: .bytes
        case .diskWrite, .networkIn: .bytesPerSecond
        }
    }

    /// Human-readable value in this metric's unit, e.g. "90%", "12.7 GB", "3 MB/s", "Critical".
    public func format(_ value: Double) -> String {
        switch unit {
        case .fraction, .coreShare:
            return value.formatted(.percent.precision(.fractionLength(0)))
        case .bytes:
            return ByteCountFormatter.string(fromByteCount: clampedInt64(value), countStyle: .memory)
        case .bytesPerSecond:
            return ByteCountFormatter.string(fromByteCount: clampedInt64(value), countStyle: .file) + "/s"
        case .pressureLevel:
            switch value.rounded() {
            case ..<1: return "Normal"
            case ..<2: return "Warning"
            default: return "Critical"
            }
        }
    }

    /// System-wide measurement; nil for app metrics or when unavailable.
    func value(in snapshot: SystemSnapshot) -> Double? {
        switch self {
        case .cpu: snapshot.cpu.total
        case .memoryPressure: Double(snapshot.memory.pressure.ordinal)
        case .memoryUsedFraction:
            snapshot.memory.physical > 0 ? Double(snapshot.memory.used) / Double(snapshot.memory.physical) : nil
        case .swapUsed: Double(snapshot.memory.swapUsed)
        case .gpu: snapshot.gpu?.utilization
        case .batteryLevel: snapshot.battery?.level
        case .diskWrite: snapshot.disk.writeBytesPerSecond
        case .networkIn: snapshot.network.receivedBytesPerSecond
        case .appCPU, .appMemory, .appMemoryGrowth: nil
        }
    }
}

public enum AlertComparison: String, Codable, Sendable, Hashable, CaseIterable {
    case above
    case below

    public var displayName: String { rawValue }

    /// Inclusive: "above 90%" holds at exactly 90%.
    public func matches(_ value: Double, threshold: Double) -> Bool {
        switch self {
        case .above: value >= threshold
        case .below: value <= threshold
        }
    }
}

public struct AlertRule: Codable, Sendable, Hashable, Identifiable {
    public static let defaultSystemCooldown: TimeInterval = 15 * 60
    /// "Alerts for the same app and condition are limited to one every 10 minutes."
    public static let defaultAppCooldown: TimeInterval = 10 * 60
    public static let defaultGrowthWindow: TimeInterval = 60 * 60

    public var id: UUID
    public var metric: AlertMetric
    public var comparison: AlertComparison
    /// In `metric.unit` (fractions 0...1, core share, bytes, bytes/s, pressure ordinal).
    public var threshold: Double
    /// How long the condition must hold continuously before firing; 0 fires on the first matching sample.
    public var duration: TimeInterval
    /// Minimum time between two events of this rule (per app for app metrics).
    public var cooldown: TimeInterval
    public var isEnabled: Bool
    /// Bundle identifier (or `AppActivity.id`) for app metrics; nil matches every app.
    public var appFilter: String?
    /// Rolling window for `appMemoryGrowth`; nil means `defaultGrowthWindow`. Ignored by other metrics.
    public var window: TimeInterval?

    public init(id: UUID = UUID(), metric: AlertMetric, comparison: AlertComparison = .above, threshold: Double, duration: TimeInterval = 0, cooldown: TimeInterval? = nil, isEnabled: Bool = true, appFilter: String? = nil, window: TimeInterval? = nil) {
        self.id = id
        self.metric = metric
        self.comparison = comparison
        self.threshold = threshold
        self.duration = duration
        self.cooldown = cooldown ?? (metric.isAppMetric ? Self.defaultAppCooldown : Self.defaultSystemCooldown)
        self.isEnabled = isEnabled
        self.appFilter = appFilter
        self.window = window
    }

    public var effectiveWindow: TimeInterval { window ?? Self.defaultGrowthWindow }

    /// One-line description, e.g. "CPU above 90% for 2 min".
    public var summary: String {
        if metric == .appMemoryGrowth {
            return "App memory grows by \(metric.format(threshold)) within \(formatDuration(effectiveWindow))"
        }
        let relation = metric == .memoryPressure ? (comparison == .above ? "at or above" : "at or below") : comparison.displayName
        let base = "\(metric.displayName) \(relation) \(metric.format(threshold))"
        return duration > 0 ? "\(base) for \(formatDuration(duration))" : base
    }

    /// Starter rules seeded into a new store.
    public static var defaults: [AlertRule] {
        [
            AlertRule(metric: .appCPU, threshold: 0.8, duration: 120),
            AlertRule(metric: .appMemoryGrowth, threshold: 1_073_741_824, window: defaultGrowthWindow),
            AlertRule(metric: .cpu, threshold: 0.9, duration: 120, isEnabled: false),
            AlertRule(metric: .memoryPressure, threshold: Double(MemoryPressure.critical.ordinal), duration: 60),
            AlertRule(metric: .batteryLevel, comparison: .below, threshold: 0.15, isEnabled: false),
        ]
    }
}

public struct AlertEvent: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var ruleID: UUID
    public var date: Date
    public var metric: AlertMetric
    /// Measured value in `metric.unit`; for `appMemoryGrowth` the growth in bytes.
    public var value: Double
    /// Headline, e.g. "Google Chrome is using sustained CPU".
    public var title: String
    /// Explanation, e.g. "Above 80% of one core for at least 2 min."
    public var detail: String
    public var appName: String?
    public var isRead: Bool

    public init(id: UUID = UUID(), ruleID: UUID, date: Date, metric: AlertMetric, value: Double, title: String, detail: String, appName: String? = nil, isRead: Bool = false) {
        self.id = id
        self.ruleID = ruleID
        self.date = date
        self.metric = metric
        self.value = value
        self.title = title
        self.detail = detail
        self.appName = appName
        self.isRead = isRead
    }
}

func formatDuration(_ interval: TimeInterval) -> String {
    Duration.seconds(interval.rounded()).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
}

private func clampedInt64(_ value: Double) -> Int64 {
    guard value.isFinite else { return 0 }
    if value >= 9.2e18 { return .max }
    if value <= -9.2e18 { return .min }
    return Int64(value)
}

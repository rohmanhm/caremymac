import Foundation

/// Pure alert evaluator fed one snapshot per tick.
///
/// - A rule fires once its condition has held continuously for `duration` (measured from the
///   first matching sample), then stays silent until the condition clears (re-arm).
/// - A breach that becomes due inside `cooldown` of the previous event fires once the cooldown
///   ends, if the condition still holds.
/// - Missing readings (nil GPU/battery, app not running) never fire and reset the streak.
/// - App metrics track streaks and cooldowns per app id.
/// - A gap between ticks longer than `maxSampleGap` (sleep) resets every streak.
public struct AlertEngine: Sendable {
    public var maxSampleGap: TimeInterval

    private var streaks: [Key: Streak] = [:]
    private var lastFired: [Key: Date] = [:]
    private var memoryHistory: [String: MemoryHistory] = [:]
    private var lastEvaluation: Date?

    public init(maxSampleGap: TimeInterval = 30) {
        self.maxSampleGap = maxSampleGap
    }

    public mutating func evaluate(snapshot: SystemSnapshot, apps: [AppActivity], rules: [AlertRule]) -> [AlertEvent] {
        let now = snapshot.date
        if let last = lastEvaluation, now < last || now.timeIntervalSince(last) > maxSampleGap {
            streaks.removeAll()
        }
        lastEvaluation = now
        recordMemory(apps: apps, rules: rules, now: now)

        var events: [AlertEvent] = []
        var active = Set<Key>()
        for rule in rules where rule.isEnabled {
            if rule.metric.isAppMetric {
                for app in apps where rule.appFilter.map({ app.bundleIdentifier == $0 || app.id == $0 }) ?? true {
                    guard let reading = read(rule, app: app, now: now) else { continue }
                    let key = Key(rule: rule.id, app: app.id)
                    active.insert(key)
                    if advance(key, rule: rule, value: reading.value, now: now) {
                        events.append(makeEvent(rule, reading: reading, now: now, appName: app.name))
                    }
                }
            } else if let value = rule.metric.value(in: snapshot) {
                let key = Key(rule: rule.id, app: nil)
                active.insert(key)
                if advance(key, rule: rule, value: value, now: now) {
                    events.append(makeEvent(rule, reading: Reading(value: value), now: now, appName: nil))
                }
            }
        }

        streaks = streaks.filter { active.contains($0.key) }
        let cooldowns = Dictionary(rules.map { ($0.id, $0.cooldown) }, uniquingKeysWith: { first, _ in first })
        lastFired = lastFired.filter { key, date in
            guard let cooldown = cooldowns[key.rule] else { return false }
            return now.timeIntervalSince(date) < cooldown
        }
        return events
    }

    /// Returns true when the rule should fire for `key` at `now`.
    private mutating func advance(_ key: Key, rule: AlertRule, value: Double, now: Date) -> Bool {
        guard rule.comparison.matches(value, threshold: rule.threshold) else {
            streaks[key] = nil
            return false
        }
        var streak = streaks[key] ?? Streak(since: now, fired: false)
        defer { streaks[key] = streak }
        guard !streak.fired, now.timeIntervalSince(streak.since) >= rule.duration else { return false }
        if let last = lastFired[key], now.timeIntervalSince(last) < rule.cooldown { return false }
        streak.fired = true
        lastFired[key] = now
        return true
    }

    // MARK: - App readings

    private func read(_ rule: AlertRule, app: AppActivity, now: Date) -> Reading? {
        switch rule.metric {
        case .appCPU:
            return Reading(value: app.cpu)
        case .appMemory:
            return Reading(value: Double(app.memory))
        case .appMemoryGrowth:
            guard let history = memoryHistory[app.id] else { return nil }
            let windowStart = now.addingTimeInterval(-rule.effectiveWindow)
            let low = history.points
                .lazy
                .filter { Date(timeIntervalSince1970: Double($0.minute + 1) * 60) > windowStart }
                .map(\.low)
                .min() ?? app.memory
            let growth = app.memory > low ? app.memory - low : 0
            return Reading(value: Double(growth), from: low, to: app.memory)
        default:
            return nil
        }
    }

    /// Keeps one low-water mark per minute per app for the longest enabled growth window.
    private mutating func recordMemory(apps: [AppActivity], rules: [AlertRule], now: Date) {
        let window = rules.lazy
            .filter { $0.isEnabled && $0.metric == .appMemoryGrowth }
            .map(\.effectiveWindow)
            .max()
        guard let window else {
            memoryHistory.removeAll()
            return
        }
        let minute = MinuteAggregator.minute(of: now)
        let oldestMinute = MinuteAggregator.minute(of: now.addingTimeInterval(-window))
        for app in apps {
            var history = memoryHistory.removeValue(forKey: app.id) ?? MemoryHistory(points: [], lastSeen: now)
            history.lastSeen = now
            if let last = history.points.last, last.minute == minute {
                history.points[history.points.count - 1].low = min(last.low, app.memory)
            } else {
                history.points.append(MemoryMinute(minute: minute, low: app.memory))
            }
            if let firstKept = history.points.firstIndex(where: { $0.minute >= oldestMinute }), firstKept > 0 {
                history.points.removeFirst(firstKept)
            }
            memoryHistory[app.id] = history
        }
        let cutoff = now.addingTimeInterval(-window)
        memoryHistory = memoryHistory.filter { $0.value.lastSeen >= cutoff }
    }

    // MARK: - Messages

    private func makeEvent(_ rule: AlertRule, reading: Reading, now: Date, appName: String?) -> AlertEvent {
        let metric = rule.metric
        let value = metric.format(reading.value)
        let threshold = metric.format(rule.threshold)
        let comparison = rule.comparison == .above ? "Above" : "Below"
        let sustained = rule.duration > 0 ? " for at least \(formatDuration(rule.duration))" : ""
        let app = appName ?? "An app"
        let title: String
        let detail: String
        switch metric {
        case .appCPU:
            title = rule.comparison == .above
                ? (rule.duration > 0 ? "\(app) is using sustained CPU" : "\(app) is using \(value) CPU")
                : "\(app) CPU dropped below \(threshold)"
            detail = "\(comparison) \(threshold) of one core\(sustained)."
        case .appMemory:
            title = "\(app) used \(value)"
            detail = "\(comparison) \(threshold)\(sustained)."
        case .appMemoryGrowth:
            let window = rule.effectiveWindow == 3600 ? "hour" : formatDuration(rule.effectiveWindow)
            title = "\(app) grew by \(value) in the last \(window)"
            detail = "Memory went from \(metric.format(Double(reading.from ?? 0))) to \(metric.format(Double(reading.to ?? 0)))."
        case .memoryPressure:
            title = "Memory pressure is \(value)"
            detail = "\(rule.comparison == .above ? "At or above" : "At or below") \(threshold)\(sustained)."
        case .cpu:
            title = rule.comparison == .above
                ? (rule.duration > 0 ? "CPU is under sustained load" : "CPU usage is high")
                : "CPU usage is low"
            detail = "\(comparison) \(threshold)\(sustained) (now \(value))."
        case .batteryLevel where rule.comparison == .below:
            title = "Battery is low"
            detail = "\(value) remaining."
        default:
            title = "\(metric.displayName) is \(rule.comparison.displayName) \(threshold)"
            detail = "\(comparison) \(threshold)\(sustained) (now \(value))."
        }
        return AlertEvent(ruleID: rule.id, date: now, metric: metric, value: reading.value, title: title, detail: detail, appName: appName)
    }

    // MARK: - State

    private struct Key: Hashable, Sendable {
        var rule: UUID
        var app: String?
    }

    private struct Streak: Sendable {
        var since: Date
        var fired: Bool
    }

    private struct MemoryMinute: Sendable {
        var minute: Int64
        var low: UInt64
    }

    private struct MemoryHistory: Sendable {
        var points: [MemoryMinute]
        var lastSeen: Date
    }

    private struct Reading {
        var value: Double
        var from: UInt64?
        var to: UInt64?

        init(value: Double, from: UInt64? = nil, to: UInt64? = nil) {
            self.value = value
            self.from = from
            self.to = to
        }
    }
}

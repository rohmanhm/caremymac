import Foundation

/// Everything measured in one tick.
public struct MonitorTick: Sendable {
    public var snapshot: SystemSnapshot
    public var apps: [AppActivity]
    public var processCount: Int
    /// Processes whose task info the kernel refused.
    public var restrictedProcessCount: Int
    /// nil when projects weren't scanned this tick.
    public var projects: [ProjectActivity]?
    /// Alerts that fired this tick (already persisted).
    public var newAlerts: [AlertEvent]
}

/// Owns the samplers, the minute aggregator, the alert engine and the history store.
/// All of them are single-threaded; the actor is their only owner.
public actor MonitorEngine {
    private let system = SystemMetricsSampler()
    private let activity = ActivitySampler()
    private let store: HistoryStore?
    private var aggregator = MinuteAggregator()
    private var alertEngine = AlertEngine()
    private var rules: [AlertRule]
    private var lastPrune: Date?

    /// Why the history store couldn't open, if it couldn't. Monitoring still works without it.
    nonisolated public let storeError: String?

    public init(storeURL: URL? = HistoryStore.defaultURL) {
        var store: HistoryStore?
        var storeError: String?
        do {
            store = try storeURL.map(HistoryStore.init(url:)) ?? HistoryStore.inMemory()
        } catch {
            storeError = error.localizedDescription
        }
        self.store = store
        self.storeError = storeError
        rules = (try? store?.alertRules()) ?? AlertRule.defaults
    }

    // MARK: Sampling

    public func tick(now: Date = .now, includeProjects: Bool, alertsEnabled: Bool) -> MonitorTick {
        let snapshot = system.sample(now: now)
        let sample = activity.sample(now: now, includeProjects: includeProjects)

        if let record = aggregator.add(snapshot, apps: sample.apps) {
            try? store?.insert(record)
        }

        var fired: [AlertEvent] = []
        if alertsEnabled {
            fired = alertEngine.evaluate(snapshot: snapshot, apps: sample.apps, rules: rules)
            for event in fired { try? store?.append(event) }
        }

        if lastPrune.map({ now.timeIntervalSince($0) > 3600 }) ?? true {
            lastPrune = now
            try? store?.pruneExpired(now: now)
        }

        return MonitorTick(
            snapshot: snapshot,
            apps: sample.apps,
            processCount: sample.processes.count,
            restrictedProcessCount: sample.processes.reduce(0) { $0 + ($1.isRestricted ? 1 : 0) },
            projects: includeProjects ? sample.projects : nil,
            newAlerts: fired
        )
    }

    /// Writes the partially filled minute, e.g. before pausing or quitting.
    public func flush() {
        if let record = aggregator.flush() { try? store?.insert(record) }
    }

    public func volumes() -> [VolumeStats] { system.volumes() }
    public func accessoryBatteries() -> [AccessoryBattery] { system.accessoryBatteries() }

    // MARK: History

    public func records(from: Date, to: Date) -> [HistoryRecord] {
        (try? store?.records(from: from, to: to)) ?? []
    }

    // MARK: Moments

    public func moments() -> [SavedMoment] { (try? store?.moments()) ?? [] }
    public func save(_ moment: SavedMoment) { try? store?.save(moment) }
    public func update(_ moment: SavedMoment) { try? store?.updateMoment(moment) }
    public func deleteMoment(id: UUID) { try? store?.deleteMoment(id: id) }

    // MARK: Alerts

    public func alertRules() -> [AlertRule] { rules }

    public func saveAlertRule(_ rule: AlertRule) {
        if let index = rules.firstIndex(where: { $0.id == rule.id }) { rules[index] = rule } else { rules.append(rule) }
        try? store?.saveAlertRule(rule)
    }

    public func deleteAlertRule(id: UUID) {
        rules.removeAll { $0.id == id }
        try? store?.deleteAlertRule(id: id)
    }

    public func alertEvents(limit: Int = 200) -> [AlertEvent] { (try? store?.events(limit: limit)) ?? [] }
    public func unreadAlertCount() -> Int { (try? store?.unreadCount()) ?? 0 }
    public func markAlertsRead() { try? store?.markAllRead() }
    public func deleteAlertEvent(id: UUID) { try? store?.deleteEvent(id: id) }
}

import Foundation
import SQLite3
import Testing
@testable import CareMyMacKit

private let base = Date(timeIntervalSince1970: 1_800_000_000) // a minute start (divisible by 60)

private func snapshot(
    at date: Date,
    cpu: Double = 0.1,
    used: UInt64 = 1_000,
    pressure: MemoryPressure = .normal,
    gpu: Double? = nil,
    battery: Double? = nil
) -> SystemSnapshot {
    SystemSnapshot(
        date: date,
        cpu: CPUStats(user: cpu * 0.75, system: cpu * 0.25, cores: [], performanceCoreCount: nil, efficiencyCoreCount: nil, loadAverage: []),
        memory: MemoryStats(physical: 16_000, app: used, active: 0, inactive: 0, wired: 0, compressed: 0, cachedFiles: 0, free: 0, swapUsed: 0, swapTotal: 0, pressure: pressure),
        disk: .zero,
        network: .zero,
        gpu: gpu.map { GPUStats(name: "GPU", coreCount: nil, utilization: $0, rendererUtilization: nil, tilerUtilization: nil, memoryInUse: nil) },
        battery: battery.map { BatteryStats(level: $0, state: .discharging, isPluggedIn: false, timeRemaining: nil, cycleCount: nil, health: nil, designCapacity: nil, maxCapacity: nil, temperatureCelsius: nil, powerWatts: nil, adapterWatts: nil, condition: nil) }
    )
}

private func app(_ id: String, cpu: Double = 0, memory: UInt64 = 0, processes: Int = 1) -> AppActivity {
    var stats: [ProcessStats] = []
    for index in 0..<processes {
        let isMain = index == 0
        stats.append(ProcessStats(pid: Int32(index + 1), ppid: 1, name: id, executablePath: nil, cpu: isMain ? cpu : 0, memory: isMain ? memory : 0, threads: 1, uid: 501, startDate: nil, diskReadBytesPerSecond: 0, diskWriteBytesPerSecond: 0, isRestricted: false))
    }
    return AppActivity(id: id, name: id.capitalized, bundleIdentifier: id, bundlePath: nil, kind: .application, mainPID: 1, processes: stats)
}

private func record(minute: Int, cpu: Double = 0.2) -> HistoryRecord {
    HistoryRecord(
        date: base.addingTimeInterval(Double(minute) * 60),
        cpuAverage: cpu, cpuPeak: cpu * 2, cpuUser: cpu * 0.7, cpuSystem: cpu * 0.3,
        memoryUsed: 8_000_000_000, memoryPhysical: 16_000_000_000, memoryPressure: .warning, swapUsed: 1_024,
        diskReadBytesPerSecond: 1.5, diskWriteBytesPerSecond: 2.5, networkInBytesPerSecond: 3.5, networkOutBytesPerSecond: 4.5,
        gpuUtilization: minute.isMultiple(of: 2) ? 0.33 : nil, batteryLevel: 0.8, batteryPluggedIn: true,
        topApps: [AppSummary(id: "com.a", name: "A", bundleIdentifier: "com.a", cpu: 0.5, memory: 42, processCount: 3)],
        sampleCount: 60
    )
}

@Suite struct StoreTests {
    // MARK: TimeSeries

    @Test func ringBufferKeepsNewestInOrderAfterWrapping() {
        var series = TimeSeries<Double>(capacity: 3)
        for index in 1...5 {
            series.append(Double(index), at: base.addingTimeInterval(Double(index)))
        }
        #expect(series.points.map(\.value) == [3, 4, 5])
        #expect(series.points.map(\.date) == [3, 4, 5].map { base.addingTimeInterval($0) })
        #expect(series.last?.value == 5)
        #expect(series.first?.value == 3)
        #expect(series.max == 5)
        #expect(series.points(since: base.addingTimeInterval(4)).map(\.value) == [4, 5])
        #expect(series.points(since: base.addingTimeInterval(4.5)).map(\.value) == [5])
        #expect(series.points(since: base.addingTimeInterval(99)).isEmpty)
        #expect(series.points(since: base).map(\.value) == [3, 4, 5])
    }

    // MARK: MinuteAggregator

    @Test func aggregatorEmitsRecordWhenMinuteChanges() throws {
        var aggregator = MinuteAggregator()
        let first = aggregator.add(snapshot(at: base.addingTimeInterval(10), cpu: 0.2, used: 1_000, pressure: .warning, gpu: 0.4, battery: 0.9), apps: [])
        let second = aggregator.add(snapshot(at: base.addingTimeInterval(59.9), cpu: 0.6, used: 3_000, gpu: nil, battery: 0.8), apps: [])
        #expect(first == nil && second == nil)

        let crossed = aggregator.add(snapshot(at: base.addingTimeInterval(60), cpu: 0.1), apps: [])
        let finished = try #require(crossed)
        #expect(finished.date == base)
        #expect(finished.sampleCount == 2)
        #expect(abs(finished.cpuAverage - 0.4) < 1e-9)
        #expect(abs(finished.cpuPeak - 0.6) < 1e-9)
        #expect(finished.memoryUsed == 2_000)
        #expect(finished.memoryPressure == .warning)
        #expect(finished.gpuUtilization == 0.4) // averaged over samples that reported it
        #expect(finished.batteryLevel == 0.8) // last value

        let flushed = aggregator.flush()
        let next = try #require(flushed)
        #expect(next.date == base.addingTimeInterval(60))
        #expect(next.sampleCount == 1)
        #expect(next.gpuUtilization == nil)
        let empty = aggregator.flush()
        #expect(empty == nil)
    }

    @Test func aggregatorDoesNotFabricateMinutesAcrossSleep() throws {
        var aggregator = MinuteAggregator()
        _ = aggregator.add(snapshot(at: base.addingTimeInterval(5)), apps: [])
        _ = aggregator.add(snapshot(at: base.addingTimeInterval(6)), apps: [])
        let woke = aggregator.add(snapshot(at: base.addingTimeInterval(3 * 3600 + 5)), apps: [])
        let beforeSleep = try #require(woke)
        #expect(beforeSleep.date == base)
        #expect(beforeSleep.sampleCount == 2)
        let sameMinute = aggregator.add(snapshot(at: base.addingTimeInterval(3 * 3600 + 6)), apps: [])
        #expect(sameMinute == nil)
        let flushed = aggregator.flush()
        let afterWake = try #require(flushed)
        #expect(afterWake.date == base.addingTimeInterval(3 * 3600))
        #expect(afterWake.sampleCount == 2)
    }

    @Test func topAppsUnionCPUAndMemoryLeaders() throws {
        var aggregator = MinuteAggregator()
        let busy = (1...6).map { app("cpu\($0)", cpu: Double($0) / 10, memory: 10) }
        let hog = app("hog", cpu: 0, memory: 10_000, processes: 4)
        // "late" runs in only one of two samples: CPU is averaged over the whole minute, memory over presence.
        let late = app("late", cpu: 2.0, memory: 500)
        _ = aggregator.add(snapshot(at: base), apps: busy + [hog])
        _ = aggregator.add(snapshot(at: base.addingTimeInterval(1)), apps: busy + [hog, late])
        let flushed = aggregator.flush()
        let result = try #require(flushed)

        // CPU top 5 ∪ memory top 5 (hog, late, then 10-byte ties by id: cpu1, cpu2, cpu3), sorted by CPU.
        #expect(result.topApps.map(\.id) == ["late", "cpu6", "cpu5", "cpu4", "cpu3", "cpu2", "cpu1", "hog"])
        let lateSummary = try #require(result.topApps.first { $0.id == "late" })
        #expect(lateSummary.cpu == 1.0)
        #expect(lateSummary.memory == 500)
        #expect(result.topApps.first { $0.id == "hog" }?.processCount == 4)
    }

    // MARK: HistoryStore

    @Test func storeRoundTripsUpsertsAndPrunesRecords() throws {
        let store = try HistoryStore.inMemory()
        for minute in 0..<5 {
            try store.insert(record(minute: minute))
        }
        #expect(try store.records(from: base, to: base.addingTimeInterval(240)) == (0..<5).map { record(minute: $0) })
        // Range bounds apply to minute starts.
        #expect(try store.records(from: base.addingTimeInterval(30), to: base.addingTimeInterval(150)).map(\.date)
            == [base.addingTimeInterval(60), base.addingTimeInterval(120)])

        try store.insert(record(minute: 2, cpu: 0.9))
        #expect(try store.recordCount() == 5)
        #expect(try store.records(from: base.addingTimeInterval(120), to: base.addingTimeInterval(120)) == [record(minute: 2, cpu: 0.9)])
        #expect(try store.latestRecordDate() == base.addingTimeInterval(240))

        #expect(try store.prune(olderThan: base.addingTimeInterval(150)) == 3)
        #expect(try store.records(from: .distantPast, to: .distantFuture).map(\.date) == [base.addingTimeInterval(180), base.addingTimeInterval(240)])

        try store.pruneExpired(now: base.addingTimeInterval(240 + HistoryStore.retention))
        #expect(try store.recordCount() == 1)
        try store.pruneExpired(now: base.addingTimeInterval(241 + HistoryStore.retention))
        #expect(try store.recordCount() == 0)
        #expect(try store.latestRecordDate() == nil)
    }

    @Test func reopeningMigratedStoreIsANoOp() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "mck-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(components: "nested", "history.sqlite")

        do {
            let store = try HistoryStore(url: url)
            #expect(try store.userVersion() == HistoryStore.schemaVersion)
            try store.insert(record(minute: 0))
            let custom = AlertRule(metric: .gpu, threshold: 0.95)
            try store.saveAlertRule(custom)
        }
        let reopened = try HistoryStore(url: url)
        #expect(try reopened.userVersion() == HistoryStore.schemaVersion)
        #expect(try reopened.recordCount() == 1)
        #expect(try reopened.alertRules().count == AlertRule.defaults.count + 1) // defaults not re-seeded
    }

    @Test func newerSchemaVersionIsRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "mck-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "history.sqlite")
        _ = try HistoryStore(url: url)
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path(percentEncoded: false), &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "PRAGMA user_version = 99", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        #expect(throws: StoreError.unsupportedSchemaVersion(99)) { try HistoryStore(url: url) }
    }

    @Test func momentsUpdateDeleteAndCap() throws {
        let store = try HistoryStore.inMemory()
        var moment = SavedMoment(
            date: base, title: "Spike", snapshot: snapshot(at: base, gpu: 0.5, battery: 0.4),
            topApps: [AppSummary(app("slack", cpu: 0.3, memory: 99))],
            cpuSeries: [SeriesPoint(date: base, value: 0.25)]
        )
        try store.save(moment)
        #expect(try store.moments() == [moment])

        moment.note = "Xcode indexing"
        try store.updateMoment(moment)
        #expect(try store.moments().first?.note == "Xcode indexing")

        try store.deleteMoment(id: moment.id)
        #expect(try store.moments().isEmpty)
        #expect(throws: StoreError.notFound) { try store.updateMoment(moment) }

        for index in 0...HistoryStore.maxMoments {
            try store.save(SavedMoment(date: base.addingTimeInterval(Double(index)), title: "\(index)", snapshot: snapshot(at: base)))
        }
        let kept = try store.moments()
        #expect(kept.count == HistoryStore.maxMoments)
        #expect(kept.first?.title == "\(HistoryStore.maxMoments)")
        #expect(kept.last?.title == "1") // oldest deleted
    }

    @Test func alertRulesAndEventsPersist() throws {
        let store = try HistoryStore.inMemory()
        #expect(try store.alertRules().map(\.metric) == AlertRule.defaults.map(\.metric))

        var rule = AlertRule(metric: .swapUsed, threshold: 1_000)
        try store.saveAlertRule(rule)
        rule.isEnabled = false
        try store.saveAlertRule(rule)
        let rules = try store.alertRules()
        #expect(rules.last == rule) // updated in place, order kept
        #expect(rules.count == AlertRule.defaults.count + 1)
        try store.deleteAlertRule(id: rule.id)
        #expect(try store.alertRules().count == AlertRule.defaults.count)

        let events = (0..<3).map { index in
            AlertEvent(ruleID: rule.id, date: base.addingTimeInterval(Double(index) * 60), metric: .cpu, value: 0.95, title: "t\(index)", detail: "d")
        }
        for event in events { try store.append(event) }
        #expect(try store.unreadCount() == 3)
        #expect(try store.events(limit: 2).map(\.title) == ["t2", "t1"])

        try store.markAllRead()
        #expect(try store.unreadCount() == 0)
        #expect(try store.events(limit: 10).allSatisfy(\.isRead))

        #expect(try store.deleteEvents(before: base.addingTimeInterval(60)) == 1)
        #expect(try store.events(limit: 10).map(\.title) == ["t2", "t1"])
    }

    // MARK: AlertEngine

    @Test func alertFiresAfterSustainOnceAndRearms() {
        var engine = AlertEngine()
        let rule = AlertRule(metric: .cpu, threshold: 0.9, duration: 3, cooldown: 0)
        func tick(_ second: Double, _ cpu: Double) -> Int {
            engine.evaluate(snapshot: snapshot(at: base.addingTimeInterval(second), cpu: cpu), apps: [], rules: [rule]).count
        }
        #expect(tick(0, 0.95) == 0)
        #expect(tick(1, 0.95) == 0)
        #expect(tick(2, 0.5) == 0) // streak broken
        #expect(tick(3, 0.95) == 0)
        #expect(tick(5, 0.95) == 0)
        #expect(tick(6, 0.95) == 1) // held 3 s
        #expect(tick(7, 0.95) == 0) // once per breach
        #expect(tick(8, 0.2) == 0)  // clears, re-arms
        #expect(tick(9, 0.95) == 0)
        #expect(tick(12, 0.95) == 1)
    }

    @Test func alertCooldownDelaysNextBreach() {
        var engine = AlertEngine(maxSampleGap: 1_000)
        let rule = AlertRule(metric: .cpu, threshold: 0.9, duration: 0, cooldown: 100)
        func tick(_ second: Double, _ cpu: Double) -> Int {
            engine.evaluate(snapshot: snapshot(at: base.addingTimeInterval(second), cpu: cpu), apps: [], rules: [rule]).count
        }
        #expect(tick(0, 0.95) == 1)
        #expect(tick(10, 0.1) == 0)
        #expect(tick(20, 0.95) == 0) // new breach inside cooldown
        #expect(tick(99, 0.95) == 0)
        #expect(tick(100, 0.95) == 1) // still breaching when cooldown ends
        #expect(tick(150, 0.95) == 0)
    }

    @Test func missingMeasurementNeverFiresAndResetsStreak() {
        var engine = AlertEngine()
        let gpuRule = AlertRule(metric: .gpu, threshold: 0.5, duration: 2)
        let batteryRule = AlertRule(metric: .batteryLevel, comparison: .below, threshold: 0.15)
        func tick(_ second: Double, gpu: Double?) -> [AlertEvent] {
            engine.evaluate(snapshot: snapshot(at: base.addingTimeInterval(second), gpu: gpu, battery: nil), apps: [], rules: [gpuRule, batteryRule])
        }
        #expect(tick(0, gpu: 0.9).isEmpty)
        #expect(tick(1, gpu: nil).isEmpty)
        #expect(tick(2, gpu: 0.9).isEmpty) // streak restarted at 2
        #expect(tick(3, gpu: 0.9).isEmpty)
        #expect(tick(4, gpu: 0.9).map(\.ruleID) == [gpuRule.id])
    }

    @Test func memoryPressureUsesOrdinalAndSleepGapResetsStreak() {
        var engine = AlertEngine(maxSampleGap: 30)
        let rule = AlertRule(metric: .memoryPressure, threshold: 2, duration: 60)
        func tick(_ second: Double, _ pressure: MemoryPressure) -> Int {
            engine.evaluate(snapshot: snapshot(at: base.addingTimeInterval(second), pressure: pressure), apps: [], rules: [rule]).count
        }
        #expect(tick(0, .warning) == 0)
        #expect(tick(20, .critical) == 0)
        #expect(tick(40, .critical) == 0)
        #expect(tick(3_600, .critical) == 0) // woke from sleep: streak restarts
        #expect(tick(3_630, .critical) == 0)
        #expect(tick(3_660, .critical) == 1)
    }

    @Test func appRulesTrackEachAppIndependently() {
        var engine = AlertEngine()
        let rule = AlertRule(metric: .appCPU, threshold: 0.8, duration: 2)
        #expect(rule.cooldown == AlertRule.defaultAppCooldown)
        func tick(_ second: Double, _ apps: [AppActivity]) -> [String?] {
            engine.evaluate(snapshot: snapshot(at: base.addingTimeInterval(second)), apps: apps, rules: [rule]).map(\.appName)
        }
        #expect(tick(0, [app("chrome", cpu: 1.2), app("slack", cpu: 0.1)]).isEmpty)
        #expect(tick(1, [app("chrome", cpu: 1.2), app("slack", cpu: 0.9)]).isEmpty)
        #expect(tick(2, [app("chrome", cpu: 1.2), app("slack", cpu: 0.9)]) == ["Chrome"])
        #expect(tick(3, [app("slack", cpu: 0.9)]) == ["Slack"])
        // Chrome quit and relaunched: streak restarts, and its cooldown still applies.
        #expect(tick(4, [app("chrome", cpu: 1.2)]).isEmpty)
        #expect(tick(10, [app("chrome", cpu: 1.2)]).isEmpty)

        var filtered = AlertEngine()
        let slackOnly = AlertRule(metric: .appMemory, threshold: 100, appFilter: "slack")
        let events = filtered.evaluate(snapshot: snapshot(at: base), apps: [app("chrome", memory: 500), app("slack", memory: 500)], rules: [slackOnly])
        #expect(events.map(\.appName) == ["Slack"])
    }

    @Test func appMemoryGrowthWithinWindow() {
        var engine = AlertEngine(maxSampleGap: 1_000)
        let gb: UInt64 = 1 << 30
        let rule = AlertRule(metric: .appMemoryGrowth, threshold: Double(gb), window: 3_600)
        func tick(_ minute: Double, _ memory: UInt64) -> [AlertEvent] {
            engine.evaluate(snapshot: snapshot(at: base.addingTimeInterval(minute * 60)), apps: [app("slack", memory: memory)], rules: [rule])
        }
        #expect(tick(0, gb).isEmpty)
        #expect(tick(30, gb + gb / 2).isEmpty)
        let fired = tick(50, 2 * gb + gb / 10)
        #expect(fired.count == 1)
        #expect(fired.first?.value == Double(gb + gb / 10))
        #expect(tick(55, 2 * gb + gb / 5).isEmpty) // same breach
        // Minute 0 left the window; low is now 1.5 GB so growth < 1 GB: re-armed.
        #expect(tick(62, 2 * gb).isEmpty)
        #expect(tick(90, 3 * gb).count == 1)
    }
}

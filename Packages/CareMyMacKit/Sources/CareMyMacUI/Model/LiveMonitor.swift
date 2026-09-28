import AppKit
import CareMyMacKit
import Observation

/// Live series kept in memory for the charts. One point per tick.
public struct LiveSeries: Sendable {
    public static let capacity = 600

    public var cpu = TimeSeries<Double>(capacity: capacity)
    public var cpuUser = TimeSeries<Double>(capacity: capacity)
    public var cpuSystem = TimeSeries<Double>(capacity: capacity)
    /// Memory used as a share of installed RAM.
    public var memory = TimeSeries<Double>(capacity: capacity)
    public var memoryBytes = TimeSeries<Double>(capacity: capacity)
    public var diskRead = TimeSeries<Double>(capacity: capacity)
    public var diskWrite = TimeSeries<Double>(capacity: capacity)
    public var networkIn = TimeSeries<Double>(capacity: capacity)
    public var networkOut = TimeSeries<Double>(capacity: capacity)
    /// Empty when the GPU counter isn't exposed.
    public var gpu = TimeSeries<Double>(capacity: capacity)
    /// Empty without a battery.
    public var battery = TimeSeries<Double>(capacity: capacity)

    mutating func append(_ snapshot: SystemSnapshot) {
        let date = snapshot.date
        cpu.append(snapshot.cpu.total, at: date)
        cpuUser.append(snapshot.cpu.user, at: date)
        cpuSystem.append(snapshot.cpu.system, at: date)
        let physical = Double(max(snapshot.memory.physical, 1))
        memory.append(Double(snapshot.memory.used) / physical, at: date)
        memoryBytes.append(Double(snapshot.memory.used), at: date)
        diskRead.append(snapshot.disk.readBytesPerSecond, at: date)
        diskWrite.append(snapshot.disk.writeBytesPerSecond, at: date)
        networkIn.append(snapshot.network.receivedBytesPerSecond, at: date)
        networkOut.append(snapshot.network.sentBytesPerSecond, at: date)
        if let utilization = snapshot.gpu?.utilization { gpu.append(utilization, at: date) }
        if let level = snapshot.battery?.level { battery.append(level, at: date) }
    }
}

/// One app's recent CPU, memory and disk, for the app detail charts. One point per tick.
public struct AppTrail: Sendable {
    /// 10 minutes at the default 2 s refresh.
    public static let capacity = 300

    public var cpu = TimeSeries<Double>(capacity: capacity)
    public var memory = TimeSeries<Double>(capacity: capacity)
    public var diskRead = TimeSeries<Double>(capacity: capacity)
    public var diskWrite = TimeSeries<Double>(capacity: capacity)

    mutating func append(_ app: AppActivity, at date: Date) {
        cpu.append(app.cpu, at: date)
        memory.append(Double(app.memory), at: date)
        diskRead.append(app.diskReadBytesPerSecond, at: date)
        diskWrite.append(app.diskWriteBytesPerSecond, at: date)
    }
}

/// The app's single source of live state. Sampling runs on `MonitorEngine`; this object publishes results on the main actor.
@MainActor
@Observable
public final class LiveMonitor {
    public private(set) var snapshot: SystemSnapshot?
    public private(set) var apps: [AppActivity] = []
    public private(set) var processCount = 0
    public private(set) var restrictedProcessCount = 0
    /// nil until the first project scan finishes.
    public private(set) var projects: [ProjectActivity]?
    public private(set) var volumes: [VolumeStats] = []
    public private(set) var accessoryBatteries: [AccessoryBattery] = []
    public private(set) var series = LiveSeries()
    /// Not observed: views that chart a trail already re-render on every tick through `apps`.
    @ObservationIgnored private var trails: [String: AppTrail] = [:]
    public private(set) var thermalState = ProcessInfo.processInfo.thermalState
    public private(set) var isPaused = false
    public let sessionStart = Date()
    public let machine: MachineInfo

    public private(set) var alertEvents: [AlertEvent] = []
    public private(set) var unreadAlertCount = 0
    public private(set) var alertRules: [AlertRule] = []
    public private(set) var moments: [SavedMoment] = []
    /// Set while a moment waits for its 30 seconds of "after" data.
    public private(set) var pendingMomentDate: Date?

    /// Refresh interval while a window is visible, and while every window is hidden.
    /// Changes (and becoming visible) take effect immediately instead of after the current wait.
    public var visibleInterval: TimeInterval = 2 { didSet { if visibleInterval != oldValue { wake() } } }
    public var hiddenInterval: TimeInterval = 10 { didSet { if hiddenInterval != oldValue { wake() } } }
    public var isAppVisible = true { didSet { if isAppVisible, !oldValue { wake() } } }
    public var alertsEnabled = true
    /// Called with alerts that fired on a tick, e.g. to post notifications.
    public var onNewAlerts: (([AlertEvent]) -> Void)?

    public var interval: TimeInterval { isAppVisible ? visibleInterval : hiddenInterval }
    public var storeError: String? { engine.storeError }

    static let momentLeadIn: TimeInterval = 120
    static let momentTail: TimeInterval = 30
    static let projectInterval: TimeInterval = 10

    private let engine: MonitorEngine
    private var loop: Task<Void, Never>?
    /// The wait between ticks; cancelling it runs the next tick now.
    private var sleeper: Task<Void, Never>?
    private var projectDemand = 0
    private var lastProjectScan: Date?
    private var lastVolumeRefresh: Date?

    public init(engine: MonitorEngine = MonitorEngine()) {
        self.engine = engine
        machine = MachineInfoProvider.current()
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.reloadStoredState()
            while !Task.isCancelled {
                guard let self else { return }
                if !self.isPaused { await self.tick() }
                await self.waitForNextTick()
            }
        }
    }

    private func waitForNextTick() async {
        let seconds = interval
        let sleeper = Task<Void, Never> { try? await Task.sleep(for: .seconds(seconds)) }
        self.sleeper = sleeper
        await sleeper.value
    }

    private func wake() {
        sleeper?.cancel()
    }

    /// Writes the partially recorded minute to history.
    public func flush() async {
        await engine.flush()
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        wake()
        Task { await engine.flush() }
    }

    public func togglePause() {
        isPaused.toggle()
        if isPaused {
            Task { await engine.flush() }
        } else {
            wake()
        }
    }

    // MARK: Projects

    /// Project scans (file-descriptor walks) run only while something shows them.
    public func beginProjectMonitoring() {
        projectDemand += 1
        if projectDemand == 1 {
            lastProjectScan = nil
            wake()
        }
    }

    public func endProjectMonitoring() {
        projectDemand = max(0, projectDemand - 1)
    }

    // MARK: Tick

    private func tick() async {
        let now = Date()
        let wantsProjects = projectDemand > 0 && (lastProjectScan.map { now.timeIntervalSince($0) >= Self.projectInterval } ?? true)
        if wantsProjects { lastProjectScan = now }
        let result = await engine.tick(now: now, includeProjects: wantsProjects, alertsEnabled: alertsEnabled)

        snapshot = result.snapshot
        apps = result.apps
        recordTrails(result.apps, at: result.snapshot.date)
        processCount = result.processCount
        restrictedProcessCount = result.restrictedProcessCount
        if let projects = result.projects { self.projects = projects }
        series.append(result.snapshot)
        thermalState = ProcessInfo.processInfo.thermalState

        if !result.newAlerts.isEmpty {
            alertEvents.insert(contentsOf: result.newAlerts, at: 0)
            unreadAlertCount += result.newAlerts.count
            onNewAlerts?(result.newAlerts)
        }

        if lastVolumeRefresh.map({ now.timeIntervalSince($0) >= 30 }) ?? true {
            lastVolumeRefresh = now
            volumes = await engine.volumes()
            accessoryBatteries = await engine.accessoryBatteries()
        }
    }

    private func reloadStoredState() async {
        alertRules = await engine.alertRules()
        alertEvents = await engine.alertEvents()
        unreadAlertCount = await engine.unreadAlertCount()
        moments = await engine.moments()
    }

    /// Extends every running app's trail and drops trails of apps that exited.
    private func recordTrails(_ apps: [AppActivity], at date: Date) {
        for app in apps {
            trails[app.id, default: AppTrail()].append(app, at: date)
        }
        // Every running app now has a trail, so any surplus belongs to apps that exited.
        guard trails.count > apps.count else { return }
        let running = Set(apps.lazy.map(\.id))
        let exited = trails.keys.filter { !running.contains($0) }
        for id in exited { trails[id] = nil }
    }

    /// Recent history of one app, if it has been seen since launch.
    public func trail(for appID: String) -> AppTrail? {
        trails[appID]
    }

    // MARK: History

    public func records(from: Date, to: Date) async -> [HistoryRecord] {
        await engine.records(from: from, to: to)
    }

    // MARK: Moments

    /// Captures 2 minutes before now and, after a 30 second wait, the 30 seconds after.
    public func saveMoment() {
        guard pendingMomentDate == nil, let snapshot else { return }
        let date = Date()
        pendingMomentDate = date
        let topApps = apps.prefix(8).map(AppSummary.init)
        let title = apps.first?.name ?? "Moment"
        Task {
            try? await Task.sleep(for: .seconds(Self.momentTail))
            let start = date.addingTimeInterval(-Self.momentLeadIn)
            let end = date.addingTimeInterval(Self.momentTail + 1)
            func slice(_ series: TimeSeries<Double>) -> [SeriesPoint] {
                series.points(since: start).filter { $0.date <= end }.map { SeriesPoint(date: $0.date, value: $0.value) }
            }
            let moment = SavedMoment(
                date: date,
                title: title,
                snapshot: snapshot,
                topApps: topApps,
                cpuSeries: slice(series.cpu),
                memorySeries: slice(series.memoryBytes),
                networkInSeries: slice(series.networkIn),
                networkOutSeries: slice(series.networkOut),
                diskReadSeries: slice(series.diskRead),
                diskWriteSeries: slice(series.diskWrite),
                gpuSeries: slice(series.gpu)
            )
            await engine.save(moment)
            moments = await engine.moments()
            pendingMomentDate = nil
        }
    }

    public func update(_ moment: SavedMoment) {
        if let index = moments.firstIndex(where: { $0.id == moment.id }) { moments[index] = moment }
        Task { await engine.update(moment) }
    }

    public func deleteMoment(id: UUID) {
        moments.removeAll { $0.id == id }
        Task { await engine.deleteMoment(id: id) }
    }

    // MARK: Alerts

    public func saveAlertRule(_ rule: AlertRule) {
        if let index = alertRules.firstIndex(where: { $0.id == rule.id }) { alertRules[index] = rule } else { alertRules.append(rule) }
        Task { await engine.saveAlertRule(rule) }
    }

    public func deleteAlertRule(id: UUID) {
        alertRules.removeAll { $0.id == id }
        Task { await engine.deleteAlertRule(id: id) }
    }

    public func markAlertsRead() {
        guard unreadAlertCount > 0 else { return }
        unreadAlertCount = 0
        for index in alertEvents.indices { alertEvents[index].isRead = true }
        Task { await engine.markAlertsRead() }
    }

    public func dismissAlert(id: UUID) {
        alertEvents.removeAll { $0.id == id }
        Task { await engine.deleteAlertEvent(id: id) }
    }
}

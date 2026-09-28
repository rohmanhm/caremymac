import CareMyMacKit
import CareMyMacUI
import SwiftUI

/// The app list for one source and the selected app beside it, like Mail's message list and message.
struct AppBrowser: View {
    let screen: Screen
    let filter: AppFilter
    @Environment(LiveMonitor.self) private var monitor
    @Environment(AppModel.self) private var appModel
    @State private var search = ""

    var body: some View {
        @Bindable var appModel = appModel
        let apps = visibleApps
        HStack(spacing: 0) {
            AppList(
                title: screen.title,
                apps: apps,
                emptyState: emptyState,
                selection: $appModel.selectedAppID,
                sort: $appModel.appSort
            )
            .frame(width: 300)
            Divider()
            AppDetailPane(appID: appModel.selectedAppID)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search Apps")
        .onChange(of: screen, initial: true) { keepSelection(in: apps) }
        .onChange(of: apps.isEmpty) { keepSelection(in: apps) }
    }

    private var visibleApps: [AppActivity] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let matching = monitor.apps.filter { filter.includes($0) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
        return appModel.appSort.sorted(matching)
    }

    /// A source opens on its top app unless the selected app is already listed.
    private func keepSelection(in apps: [AppActivity]) {
        if let id = appModel.selectedAppID, apps.contains(where: { $0.id == id }) { return }
        if let first = apps.first { appModel.selectedAppID = first.id }
    }

    private var emptyState: AppList.EmptyState {
        let query = search.trimmingCharacters(in: .whitespaces)
        if monitor.snapshot == nil { return .measuring }
        if !query.isEmpty { return .message("No Results for “\(query)”", "Try another name, or look in another source.") }
        return switch filter {
        case .busy: .message("Nothing Busy", "No app is using more than 1% of a core or 1 MB/s of disk right now.")
        case .applications: .message("No Apps Open", "Apps you open appear here.")
        case .background: .message("No Background Processes", "Agents, helpers and system processes appear here.")
        }
    }
}

// MARK: - List

private struct AppList: View {
    enum EmptyState {
        case measuring
        case message(String, String)
    }

    let title: String
    let apps: [AppActivity]
    let emptyState: EmptyState
    @Binding var selection: String?
    @Binding var sort: AppSort
    @State private var pendingQuit: PendingAction?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.headline)
                Text(Format.integer(apps.count))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: 8)
                Menu {
                    Picker("Sort By", selection: $sort) {
                        ForEach(AppSort.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Text("By \(sort.title)")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Sort the list")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if apps.isEmpty {
                switch emptyState {
                case .measuring:
                    ProgressView("Measuring…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case let .message(title, message):
                    EmptyStateView(title, symbol: "app.dashed", message: message)
                }
            } else {
                List(apps, selection: $selection) { app in
                    AppListRow(app: app, sort: sort)
                        .contextMenu { AppActionsMenu(app: app, pendingQuit: $pendingQuit) }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds(.disabled)
            }
        }
        .background(.background)
        .quitConfirmation($pendingQuit)
    }
}

private struct AppListRow: View {
    let app: AppActivity
    let sort: AppSort

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(app: app, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(Format.processes(app.processes.count)) · \(sort == .memory ? Format.percent(app.cpu) : Format.memory(app.memory))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(value)
                    .fontWeight(.medium)
                    .monospacedDigit()
                ImpactMeter(level: level)
            }
        }
        .padding(.vertical, 4)
        .help(app.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(app.name), \(value), \(Format.processes(app.processes.count))")
    }

    private var diskRate: Double { app.diskReadBytesPerSecond + app.diskWriteBytesPerSecond }

    private var value: String {
        switch sort {
        case .cpu, .name: Format.percent(app.cpu)
        case .memory: Format.memory(app.memory)
        case .disk: Format.rate(diskRate)
        }
    }

    /// 0–5 bars for the sorted resource. Thresholds follow what reads as idle, light, busy and heavy on a Mac.
    private var level: Int {
        let (amount, steps): (Double, [Double]) = switch sort {
        case .cpu, .name: (app.cpu, [0.005, 0.05, 0.2, 0.5, 1])
        case .memory: (Double(app.memory), [50e6, 250e6, 1e9, 2e9, 4e9])
        case .disk: (diskRate, [1e3, 1e5, 1e6, 1e7, 5e7])
        }
        return steps.lastIndex { amount >= $0 }.map { $0 + 1 } ?? 0
    }
}

private struct ImpactMeter: View {
    let level: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...5, id: \.self) { bar in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(bar <= level ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
                    .frame(width: 3, height: 3 + CGFloat(bar) * 1.6)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Detail

private struct AppDetailPane: View {
    let appID: String?
    @Environment(LiveMonitor.self) private var monitor
    /// Name of the last app shown, so the pane can say which app quit.
    @State private var lastName: String?

    var body: some View {
        let app = appID.flatMap { id in monitor.apps.first { $0.id == id } }
        Group {
            if let app {
                AppDetail(app: app, trail: monitor.trail(for: app.id))
                    .id(app.id)
            } else if appID != nil {
                EmptyStateView("\(lastName ?? "This App") Quit", symbol: "xmark.app", message: "Its processes have exited. Pick another app from the list.")
            } else {
                EmptyStateView("No App Selected", symbol: "app.dashed", message: "Pick an app to see its processes and what it uses.")
            }
        }
        .onChange(of: app?.name, initial: true) { _, name in
            if let name { lastName = name }
        }
    }
}

private struct AppDetail: View {
    let app: AppActivity
    let trail: AppTrail?
    @Environment(LiveMonitor.self) private var monitor
    @AppStorage("liveRange") private var range: LiveRange = .fiveMinutes
    @State private var scrub = ScrubState()
    @State private var pendingQuit: PendingAction?

    var body: some View {
        let domain = monitor.domain(range)
        let since = domain.lowerBound
        // One scroll surface for the whole detail, like every other page.
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                header

                HStack(alignment: .firstTextBaseline) {
                    Text("Activity").font(.headline)
                    Spacer()
                    RangePicker()
                }

                HStack(spacing: Metrics.gap) {
                    AppMetricCard(
                        title: "CPU", resource: .cpu,
                        primary: trail?.cpu.points(since: since) ?? [],
                        format: { Format.percent($0) },
                        domain: domain, scrub: scrub
                    )
                    AppMetricCard(
                        title: "Memory", resource: .memory,
                        primary: trail?.memory.points(since: since) ?? [],
                        format: { Format.memory($0) },
                        domain: domain, scrub: scrub
                    )
                    AppMetricCard(
                        title: "Disk", resource: .disk,
                        primary: trail?.diskRead.points(since: since) ?? [],
                        secondary: trail?.diskWrite.points(since: since) ?? [],
                        primaryLabel: "read", secondaryLabel: "write",
                        format: Format.rate,
                        domain: domain, scrub: scrub
                    )
                }
                .fixedSize(horizontal: false, vertical: true)

                ProcessList(app: app)
            }
            .padding(Metrics.pagePadding)
        }
        .pageBackground()
        .quitConfirmation($pendingQuit)
    }

    private var header: some View {
        HStack(spacing: 14) {
            AppIcon(app: app, size: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.title.weight(.bold))
                    .lineLimit(1)
                    .help(app.name)
                Text("\(app.kind.label) · \(Format.processes(app.processes.count))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .help(app.bundleIdentifier ?? app.bundlePath ?? app.name)
            }
            Spacer(minLength: 12)
            if let path = app.bundlePath {
                Button("Show in Finder") { ProcessActions.revealInFinder(path: path) }
            }
            Menu("Quit…") {
                Button("Force Quit…") { pendingQuit = PendingAction(app: app, force: true) }
            } primaryAction: {
                pendingQuit = PendingAction(app: app, force: false)
            }
            .fixedSize()
            .help("Quit \(app.name); the arrow offers Force Quit")
        }
    }
}

/// Title, live value (or the hovered value) and a small chart for one of the app's resources.
private struct AppMetricCard: View {
    let title: String
    let resource: Resource
    let primary: [ChartPoint]
    var secondary: [ChartPoint] = []
    var primaryLabel: String?
    var secondaryLabel: String?
    let format: (Double) -> String
    let domain: ClosedRange<Date>
    let scrub: ScrubState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: resource.symbol)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            AppMetricReadout(primary: primary, secondary: secondary, primaryLabel: primaryLabel, secondaryLabel: secondaryLabel, resource: resource, format: format, scrub: scrub)
            SeriesChart(
                primary: primary,
                secondary: secondary,
                color: resource.color,
                secondaryColor: resource.secondaryColor,
                domain: domain,
                scrub: scrub
            )
            .frame(height: 64)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
        .card(padding: 14)
    }
}

/// Reads the scrub cursor so hovering re-renders only this label, never the chart.
private struct AppMetricReadout: View {
    let primary: [ChartPoint]
    let secondary: [ChartPoint]
    let primaryLabel: String?
    let secondaryLabel: String?
    let resource: Resource
    let format: (Double) -> String
    let scrub: ScrubState

    var body: some View {
        let date = scrub.date
        let value = date.map { SeriesMath.value(in: primary, at: $0) } ?? primary.last?.value
        let other = secondary.isEmpty ? nil : (date.map { SeriesMath.value(in: secondary, at: $0) } ?? secondary.last?.value)
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value.map(format) ?? Format.unavailable)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(resource.textColor)
                if let primaryLabel { Text(primaryLabel).font(.caption).foregroundStyle(.secondary) }
            }
            // Second line: the other series for disk, otherwise the peak in view.
            Group {
                if let secondaryLabel, !secondary.isEmpty {
                    Text("\(other.map(format) ?? Format.unavailable) \(secondaryLabel)")
                } else {
                    Text("Peak \(SeriesMath.peak(primary).map(format) ?? Format.unavailable)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .monospacedDigit()
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

/// Every process grouped under the app, busiest first, each with a stop button. Rows scroll with the page.
private struct ProcessList: View {
    let app: AppActivity
    @State private var pendingStop: ProcessStats?
    @State private var stopError: String?

    var body: some View {
        let processes = app.processes.sorted { $0.cpu == $1.cpu ? $0.memory > $1.memory : $0.cpu > $1.cpu }
        let restricted = processes.contains(where: \.isRestricted)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Processes").font(.headline)
                Text(Format.integer(processes.count)).foregroundStyle(.secondary).monospacedDigit()
            }

            VStack(spacing: 0) {
                ProcessHeader()
                Divider()
                LazyVStack(spacing: 0) {
                    ForEach(processes) { process in
                        ProcessRow(process: process) { pendingStop = process }
                    }
                }
            }
            .card(padding: nil)

            Text(restricted
                ? "CPU: 100% is one full core. Helpers are grouped under the app by bundle, parent process, or the process macOS holds responsible. A dash means macOS needs admin rights to measure that process."
                : "CPU: 100% is one full core. Helpers are grouped under the app by bundle, parent process, or the process macOS holds responsible.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .confirmationDialog(
            pendingStop.map { "Stop \($0.name)?" } ?? "",
            isPresented: Binding(get: { pendingStop != nil }, set: { if !$0 { pendingStop = nil } }),
            presenting: pendingStop
        ) { process in
            Button("Stop Process", role: .destructive) { run { try ProcessActions.terminate(pid: process.pid) } }
            Button("Force Stop", role: .destructive) { run { try ProcessActions.forceTerminate(pid: process.pid) } }
        } message: { process in
            Text("PID \(Format.integer(process.pid)). Stopping a helper can make \(app.name) reload or misbehave.")
        }
        .alert("Couldn’t Stop the Process", isPresented: Binding(get: { stopError != nil }, set: { if !$0 { stopError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(stopError ?? "")
        }
    }

    private func run(_ action: () throws -> Void) {
        do { try action() } catch { stopError = error.localizedDescription }
    }
}

private enum ProcessColumns {
    static let pid: CGFloat = 64
    static let cpu: CGFloat = 64
    static let memory: CGFloat = 80
    static let threads: CGFloat = 60
    static let stop: CGFloat = 28
}

private struct ProcessHeader: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("Process").frame(maxWidth: .infinity, alignment: .leading)
            Text("PID").frame(width: ProcessColumns.pid, alignment: .trailing)
            Text("CPU").frame(width: ProcessColumns.cpu, alignment: .trailing)
            Text("Memory").frame(width: ProcessColumns.memory, alignment: .trailing)
            Text("Threads").frame(width: ProcessColumns.threads, alignment: .trailing)
            Color.clear.frame(width: ProcessColumns.stop, height: 1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

private struct ProcessRow: View {
    let process: ProcessStats
    let stop: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(process.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(process.executablePath ?? process.name)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(Format.integer(process.pid))
                .foregroundStyle(.secondary)
                .frame(width: ProcessColumns.pid, alignment: .trailing)
            Text(process.isRestricted ? Format.unavailable : Format.percent(process.cpu))
                .frame(width: ProcessColumns.cpu, alignment: .trailing)
            Text(process.isRestricted ? Format.unavailable : Format.memory(process.memory))
                .frame(width: ProcessColumns.memory, alignment: .trailing)
            Text(process.isRestricted ? Format.unavailable : Format.integer(process.threads))
                .foregroundStyle(.secondary)
                .frame(width: ProcessColumns.threads, alignment: .trailing)
            Button("Stop \(process.name)", systemImage: "stop.circle", action: stop)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .frame(width: ProcessColumns.stop, height: 24)
                .contentShape(Rectangle())
                .opacity(hovering ? 1 : 0.35)
                .help("Stop this process")
        }
        .font(.callout)
        .monospacedDigit()
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(hovering ? AnyShapeStyle(.fill.quaternary) : AnyShapeStyle(.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Stop \(process.name)…", action: stop)
            if let path = process.executablePath {
                Button("Show in Finder") { ProcessActions.revealInFinder(path: path) }
            }
        }
    }
}

// MARK: - Quitting

/// Show in Finder and the quit commands, for any context menu that lists an app.
struct AppActionsMenu: View {
    let app: AppActivity
    @Binding var pendingQuit: PendingAction?

    var body: some View {
        if let path = app.bundlePath {
            Button("Show in Finder") { ProcessActions.revealInFinder(path: path) }
            Divider()
        }
        Button("Quit \(app.name)…") { pendingQuit = PendingAction(app: app, force: false) }
        Button("Force Quit \(app.name)…") { pendingQuit = PendingAction(app: app, force: true) }
    }
}

struct PendingAction: Identifiable {
    let app: AppActivity
    let force: Bool
    var id: String { "\(app.id)-\(force)" }
    var title: String { force ? "Force quit \(app.name)?" : "Quit \(app.name)?" }
    var confirmLabel: String { force ? "Force Quit" : "Quit" }
    var message: String {
        force
            ? "All \(Format.processes(app.processes.count)) stop immediately. Unsaved changes will be lost."
            : "\(app.name) will be asked to quit and can save your work first."
    }
}

private struct QuitConfirmation: ViewModifier {
    @Binding var pending: PendingAction?
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(pending?.title ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { action in
                Button(action.confirmLabel, role: .destructive) { perform(action) }
            } message: { action in
                Text(action.message)
            }
            .alert("Couldn’t Quit the App", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
    }

    private func perform(_ action: PendingAction) {
        do {
            if action.force { try ProcessActions.forceQuit(app: action.app) } else { try ProcessActions.quit(app: action.app) }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension View {
    /// Confirms, then runs, a pending quit or force quit.
    func quitConfirmation(_ pending: Binding<PendingAction?>) -> some View {
        modifier(QuitConfirmation(pending: pending))
    }
}

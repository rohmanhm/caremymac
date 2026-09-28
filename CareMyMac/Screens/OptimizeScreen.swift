import AppKit
import CareMyMacKit
import CareMyMacUI
import SwiftUI

/// What starts with your Mac, fixed maintenance commands, and apps using a lot right now.
struct OptimizeScreen: View {
    @State private var model = OptimizeModel.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                PageHeader("Optimize", subtitle: "What starts with your Mac, maintenance tasks, and apps using a lot right now.")

                LaunchItemsSection(model: model)
                MaintenanceSection(model: model)
                HeavyConsumersSection()

                PageFooter()
            }
            .padding(Metrics.pagePadding)
        }
        .pageBackground()
        .onAppear { model.scan() }
        .onDisappear { model.cancelScan() }
    }
}

// MARK: - Login & Background Items

private struct LaunchItemsSection: View {
    let model: OptimizeModel
    @State private var pendingRemoval: LaunchItem?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            SectionCard("Login & Background Items", subtitle: "Launch agents and daemons start helpers when you log in or when your Mac starts up.") {
                HStack(spacing: 8) {
                    if model.isScanning {
                        ProgressView().controlSize(.small)
                    }
                    Button {
                        model.scan()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isScanning)
                    .help("Read the launch agent and daemon folders again")
                }
            } content: {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Apps that register with Login Items, such as those that ask to “Open at Login”, are listed and turned off in System Settings, not here. Turning off an agent can stop features of its app, like updates or sync.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Button("Open Login Items Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .fixedSize()
                }
                if !model.launchWarnings.isEmpty {
                    Label {
                        Text("Some launchd status couldn’t be read, so states may show as unknown. \(model.launchWarnings.joined(separator: " "))")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
                    }
                    .font(.callout)
                }
            }

            if let items = model.launchItems {
                ForEach(LaunchItemDomain.allCases, id: \.self) { domain in
                    LaunchDomainCard(
                        domain: domain,
                        items: items.filter { $0.domain == domain },
                        busyIDs: model.busyItemIDs,
                        perform: { action, item in
                            if action == .remove { pendingRemoval = item } else { model.perform(action, on: item) }
                        }
                    )
                }
            } else {
                ProgressView("Reading launch agents…")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                    .card()
            }
        }
        .confirmationDialog(
            pendingRemoval.map { "Remove “\($0.label)”?" } ?? "",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { item in
            Button("Move to Trash", role: .destructive) { model.perform(.remove, on: item) }
        } message: { item in
            Text("CareMyMac stops the agent and moves 1 item (\(Format.bytes(UInt64(clamping: item.fileSize)))) to the Trash: \((item.plistPath as NSString).lastPathComponent). \(item.owner.map { "\($0.name) may add it back the next time it opens." } ?? "The app that installed it may add it back.")")
        }
        .alert(
            model.actionError?.title ?? "",
            isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } }),
            presenting: model.actionError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.message)
        }
    }
}

private extension LaunchItemDomain {
    var title: String {
        switch self {
        case .user: "Your Launch Agents"
        case .allUsers: "Launch Agents for All Users"
        case .system: "Launch Daemons"
        }
    }

    var note: String {
        switch self {
        case .user: "In ~/Library/LaunchAgents. They start when you log in, and you can change them."
        case .allUsers: "In /Library/LaunchAgents. They start for everyone who logs in. Changing them needs an administrator."
        case .system: "In /Library/LaunchDaemons. They run as root from startup. Changing them needs an administrator."
        }
    }

    var emptyMessage: String {
        switch self {
        case .user: "No launch agents in your Library folder."
        case .allUsers: "No launch agents for all users."
        case .system: "No third-party launch daemons."
        }
    }
}

private struct LaunchDomainCard: View {
    let domain: LaunchItemDomain
    let items: [LaunchItem]
    let busyIDs: Set<String>
    let perform: (OptimizeModel.LaunchAction, LaunchItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(domain.title).font(.headline)
                    Text(domain.note).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Text(items.count == 1 ? "1 item" : "\(Format.integer(items.count)) items")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, Metrics.cardPadding)
            .padding(.vertical, 12)

            Divider()

            if items.isEmpty {
                Text(domain.emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Metrics.cardPadding)
                    .padding(.vertical, 12)
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().padding(.leading, Metrics.cardPadding + 34) }
                    LaunchItemRow(item: item, isBusy: busyIDs.contains(item.id)) { perform($0, item) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(domain.title)
    }
}

private struct LaunchItemRow: View {
    let item: LaunchItem
    let isBusy: Bool
    let perform: (OptimizeModel.LaunchAction) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            AppIcon(path: item.owner?.appPath, size: 24)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.owner?.name ?? "Unknown")
                        .lineLimit(1)
                        .foregroundStyle(item.owner == nil ? .secondary : .primary)
                    Text(item.label)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.label)
                }
                Text(item.program.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "No program listed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(([item.program].compactMap(\.self) + [item.plistPath]).joined(separator: "\n"))
                HStack(spacing: 6) {
                    ForEach(traits, id: \.self) { trait in
                        Text(trait)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.fill.tertiary, in: Capsule())
                    }
                }
            }
            Spacer(minLength: 12)
            StateLabel(item: item)
            controls
        }
        .font(.callout)
        .padding(.horizontal, Metrics.cardPadding)
        .padding(.vertical, 8)
        .contextMenu {
            Button("Reveal in Finder") { ProcessActions.revealInFinder(path: item.plistPath) }
            Button("Copy Label") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.label, forType: .string)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var controls: some View {
        if item.domain.isEditable {
            Menu(item.isEnabled ? "Disable" : "Enable") {
                Button("Reveal in Finder") { ProcessActions.revealInFinder(path: item.plistPath) }
                Divider()
                Button("Remove…") { perform(.remove) }
            } primaryAction: {
                perform(item.isEnabled ? .disable : .enable)
            }
            .controlSize(.small)
            .fixedSize()
            .frame(width: 88, alignment: .trailing)
            .disabled(isBusy)
            .help(item.isEnabled
                ? "Stop \(item.label) and keep it from starting at your next login; the arrow offers Remove"
                : "Allow \(item.label) to start again and load it now; the arrow offers Remove")
        } else {
            Button("Reveal") { ProcessActions.revealInFinder(path: item.plistPath) }
                .buttonStyle(.link)
                .frame(width: 88, alignment: .trailing)
                .help("Show \((item.plistPath as NSString).lastPathComponent) in Finder. Changing it needs an administrator.")
        }
    }

    private var traits: [String] {
        var traits: [String] = []
        if item.runAtLoad { traits.append(item.domain == .system ? "Starts at startup" : "Starts at login") }
        switch item.keepAlive {
        case .always: traits.append("Restarts if it quits")
        case .conditional: traits.append("Restarts on conditions")
        case .never: break
        }
        return traits
    }
}

/// "Running · PID 123", "Loaded", "Not loaded", "Disabled".
private struct StateLabel: View {
    let item: LaunchItem

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isRunning ? AnyShapeStyle(Palette.live) : AnyShapeStyle(.quaternary))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(width: 150, alignment: .leading)
        .help(help)
    }

    private var isRunning: Bool {
        if case .running = item.state { true } else { false }
    }

    private var text: String {
        switch item.state {
        case .running(let pid): item.isEnabled ? "Running · PID \(pid)" : "Disabled · running"
        case .loaded: item.isEnabled ? "Loaded" : "Disabled · loaded"
        case .notLoaded: item.isEnabled ? "Not loaded" : "Disabled"
        case .unknown: item.isEnabled ? "Status unknown" : "Disabled"
        }
    }

    private var help: String {
        switch item.state {
        case .running: "launchd is running this job now."
        case .loaded(let status):
            "launchd has this job loaded; it starts on demand." + (status.map { $0 == 0 ? "" : " Last exit status \($0)." } ?? "")
        case .notLoaded: item.isEnabled ? "launchd doesn’t have this job loaded right now." : "Turned off; launchd won’t load it."
        case .unknown: "launchctl couldn’t report this job’s state."
        }
    }
}

// MARK: - Maintenance

private struct MaintenanceSection: View {
    let model: OptimizeModel
    @State private var pendingTask: MaintenanceTask?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Maintenance").font(.headline)
                Text("Fixed macOS commands for specific problems. None of them needs to run on a schedule.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.cardPadding)
            .padding(.vertical, 12)

            Divider()

            ForEach(Array(MaintenanceTask.all.enumerated()), id: \.element.id) { index, task in
                if index > 0 { Divider().padding(.leading, Metrics.cardPadding + 34) }
                MaintenanceRow(task: task, isRunning: model.runningTasks.contains(task.id), result: model.taskResults[task.id]) {
                    if task.confirmation != nil { pendingTask = task } else { model.run(task) }
                }
            }
        }
        .card(padding: nil)
        .confirmationDialog(
            pendingTask?.confirmation?.title ?? "",
            isPresented: Binding(get: { pendingTask != nil }, set: { if !$0 { pendingTask = nil } }),
            presenting: pendingTask
        ) { task in
            Button(task.confirmation?.button ?? "Run", role: task.confirmation?.isDestructive == true ? .destructive : nil) { model.run(task) }
        } message: { task in
            Text(task.confirmation?.message ?? "")
        }
    }
}

private struct MaintenanceRow: View {
    let task: MaintenanceTask
    let isRunning: Bool
    let result: OptimizeModel.TaskResult?
    let run: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: task.symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(task.title)
                    if task.needsAdministrator {
                        Label("Administrator", systemImage: "lock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("macOS asks for an administrator password before this runs")
                    }
                }
                Text(task.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                status
            }
            Spacer(minLength: 12)
            Button(task.needsAdministrator || task.confirmation != nil ? "Run…" : "Run", action: run)
                .controlSize(.small)
                .disabled(isRunning)
                .frame(width: 88, alignment: .trailing)
                .help(task.needsAdministrator ? "Run \(task.title); macOS asks for an administrator password" : "Run \(task.title)")
        }
        .padding(.horizontal, Metrics.cardPadding)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var status: some View {
        if isRunning {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Running…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            switch result {
            case .succeeded(let date, let detail):
                Label {
                    Text(["Done \(Self.time(date))", detail].compactMap(\.self).joined(separator: ". "))
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.live)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            case .failed(let date, let message):
                Label {
                    Text("Failed \(Self.time(date)): \(message)")
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.critical)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            case nil:
                EmptyView()
            }
        }
    }

    private static func time(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        return Calendar.current.isDateInToday(date) ? "at \(time)" : "on \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}

// MARK: - Heavy Consumers

private struct HeavyConsumersSection: View {
    @Environment(LiveMonitor.self) private var monitor
    @Environment(AppModel.self) private var appModel
    @State private var pendingQuit: PendingAction?

    var body: some View {
        let apps = HeavyConsumers.filter(monitor.apps)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Heavy Consumers").font(.headline)
                Text("Apps using at least \(Format.percent(HeavyConsumers.cpuThreshold, digits: 0)) of a CPU core or \(Format.memory(HeavyConsumers.memoryThreshold)) of memory right now.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.cardPadding)
            .padding(.vertical, 12)

            Divider()

            if apps.isEmpty {
                EmptyStateView("Nothing is using a lot right now.", symbol: "checkmark.circle", message: "Apps appear here while they use a lot of CPU or memory.")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else {
                ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                    if index > 0 { Divider().padding(.leading, Metrics.cardPadding + 34) }
                    HeavyConsumerRow(app: app, show: { appModel.show(app) }, quit: { pendingQuit = PendingAction(app: app, force: false) })
                }
            }
        }
        .card(padding: nil)
        .quitConfirmation($pendingQuit)
    }
}

private struct HeavyConsumerRow: View {
    let app: AppActivity
    let show: () -> Void
    let quit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(app: app, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).lineLimit(1).help(app.name)
                Text("\(app.kind.label) · \(Format.processes(app.processes.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Text("\(Format.percent(app.cpu)) CPU")
                .monospacedDigit()
                .foregroundStyle(app.cpu >= HeavyConsumers.cpuThreshold ? .primary : .secondary)
                .frame(width: 96, alignment: .trailing)
            Text(Format.memory(app.memory))
                .monospacedDigit()
                .foregroundStyle(app.memory >= HeavyConsumers.memoryThreshold ? .primary : .secondary)
                .frame(width: 84, alignment: .trailing)
            Button("Show", action: show)
                .controlSize(.small)
                .help("Open \(app.name) in the app list")
            if app.kind == .system {
                Button("Quit…") {}
                    .controlSize(.small)
                    .disabled(true)
                    .help("\(app.name) is part of macOS and restarts on its own")
            } else {
                Button("Quit…", action: quit)
                    .controlSize(.small)
                    .help("Quit \(app.name)")
            }
        }
        .font(.callout)
        .padding(.horizontal, Metrics.cardPadding)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }
}

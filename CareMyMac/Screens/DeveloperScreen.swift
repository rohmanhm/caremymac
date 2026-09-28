import AppKit
import CareMyMacKit
import CareMyMacUI
import SwiftUI

/// Local development runtimes grouped by the folder they run in, with their listening ports.
struct DeveloperScreen: View {
    @Environment(LiveMonitor.self) private var monitor
    @AppStorage(SettingsKey.projectsIncludeWithoutPorts) private var includeWithoutPorts = false
    @State private var pendingStop: PendingStop?
    @State private var stopError: String?
    @State private var portQuery = ""
    @State private var portLookup: PortLookup?
    @State private var portQueryError: String?
    @State private var isLookingUpPorts = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                PageHeader("Developer", subtitle: "Local runtimes by working folder, with their listening ports.")

                FreePortCard(
                    query: $portQuery,
                    lookup: portLookup,
                    error: portQueryError,
                    isSearching: isLookingUpPorts,
                    find: findPorts,
                    stop: { holders in pendingStop = PendingStop(holders: holders) }
                )

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Label("Listening ports refresh every 10 seconds", systemImage: "arrow.clockwise")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Toggle("Include runtimes without ports", isOn: $includeWithoutPorts)
                        .toggleStyle(.checkbox)
                        .help("Also list runtimes that aren’t listening on a network port, such as scripts and build tools")
                }

                content

                Text("Folders are each process’s working directory, or the nearest folder above it with a project file, not necessarily a Git root. Low CPU alone doesn’t prove that a server is safe to stop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                PageFooter()
            }
            .padding(Metrics.pagePadding)
        }
        .pageBackground()
        .onAppear { monitor.beginProjectMonitoring() }
        .onDisappear { monitor.endProjectMonitoring() }
        .confirmationDialog(
            pendingStop?.title ?? "",
            isPresented: Binding(get: { pendingStop != nil }, set: { if !$0 { pendingStop = nil } }),
            presenting: pendingStop
        ) { stop in
            Button(stop.pids.count == 1 ? "Stop Process" : "Stop Processes", role: .destructive) {
                run { try ProcessActions.terminate(pids: stop.pids) }
            }
            Button("Force Stop", role: .destructive) {
                run { try ProcessActions.forceTerminate(pids: stop.pids) }
            }
        } message: { stop in
            Text("\(stop.detail) Stop asks \(stop.pids.count == 1 ? "it" : "them") to shut down cleanly; Force Stop ends \(stop.pids.count == 1 ? "it" : "them") immediately and unsaved work is lost.")
        }
        .alert("Couldn’t stop the process", isPresented: Binding(get: { stopError != nil }, set: { if !$0 { stopError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(stopError ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let projects = monitor.projects {
            let shown = includeWithoutPorts ? projects : projects.filter { !$0.ports.isEmpty }
            if shown.isEmpty {
                emptyState(hidden: projects.count - shown.count)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                    .card()
            } else {
                LazyVStack(alignment: .leading, spacing: Metrics.gap) {
                    ForEach(shown) { project in
                        ProjectCard(project: project) { process in
                            pendingStop = PendingStop(process: process, projectName: project.name)
                        }
                    }
                }
            }
        } else {
            ProgressView("Finding local projects…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
                .card()
        }
    }

    @ViewBuilder
    private func emptyState(hidden: Int) -> some View {
        if hidden > 0 {
            EmptyStateView(
                "No runtimes are listening on a port",
                symbol: "network.slash",
                message: hidden == 1
                    ? "1 project has runtimes running without a listening port. Include them to see it."
                    : "\(Format.integer(hidden)) projects have runtimes running without a listening port. Include them to see them."
            ) {
                Button("Include runtimes without ports") { includeWithoutPorts = true }
            }
        } else {
            let names = DevRuntime.allCases.map(\.displayName)
            EmptyStateView(
                "No local runtimes running",
                symbol: "terminal",
                message: "CareMyMac looks for \(names.dropLast().joined(separator: ", ")) and \(names.last ?? "") processes started from your folders. Start a dev server and it appears here within 10 seconds."
            )
        }
    }

    /// Stops, then looks the ports up again once the processes had a moment to exit.
    private func run(_ action: () throws -> Void) {
        do { try action() } catch { stopError = error.localizedDescription }
        guard let ports = portLookup?.ports else { return }
        Task {
            try? await Task.sleep(for: .seconds(1))
            lookUp(ports)
        }
    }

    private func findPorts() {
        do {
            lookUp(try PortList.parse(portQuery))
        } catch {
            portLookup = nil
            portQueryError = switch error {
            case .empty: "Enter a port number, like 3000."
            case let .invalid(text): "“\(text)” isn’t a port. Use numbers from 1 to 65535, like 3000 or 8000-8010."
            case .tooMany: "Look up at most \(Format.integer(PortList.maxCount)) ports at a time."
            }
        }
    }

    private func lookUp(_ ports: [UInt16]) {
        portQueryError = nil
        isLookingUpPorts = true
        Task {
            let lookup = await Task.detached(priority: .userInitiated) { PortLookup.find(ports) }.value
            portLookup = lookup
            isLookingUpPorts = false
        }
    }
}

private struct PendingStop: Identifiable {
    let pids: [Int32]
    let title: String
    /// First sentence of the confirmation: which processes, and why they were picked.
    let detail: String
    var id: [Int32] { pids }

    init(process: ProcessStats, projectName: String) {
        pids = [process.pid]
        title = "Stop \(process.name)?"
        detail = "PID \(Format.integer(process.pid)) in \(projectName)."
    }

    init(holders: [PortHolder]) {
        pids = holders.map(\.pid)
        let ports = Set(holders.flatMap { $0.ports.map(\.port) }).sorted().map { ":\($0)" }
        let listening = "Listening on \(ListFormatter.localizedString(byJoining: ports))."
        if let holder = holders.first, holders.count == 1 {
            title = "Stop \(holder.name.isEmpty ? "PID \(Format.integer(holder.pid))" : holder.name)?"
            detail = "PID \(Format.integer(holder.pid)). \(listening)"
        } else {
            title = "Stop \(Format.integer(holders.count)) processes?"
            detail = "\(ListFormatter.localizedString(byJoining: holders.map { $0.name.isEmpty ? "PID \($0.pid)" : $0.name })). \(listening)"
        }
    }
}

private struct ProjectCard: View {
    let project: ProjectActivity
    let stop: (ProcessStats) -> Void
    @State private var expanded = false

    var body: some View {
        let portsByPID = Dictionary(grouping: project.ports, by: \.pid)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text(project.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(project.name)
                        .layoutPriority(1)
                    ForEach(project.runtimes, id: \.self) { runtime in
                        Text(runtime.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.fill.tertiary, in: Capsule())
                    }
                    Spacer(minLength: 12)
                    Text("\(Format.percent(project.cpu)) CPU · \(Format.memory(project.memory))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                    Button("Reveal") { ProcessActions.revealInFinder(path: project.id) }
                        .buttonStyle(.link)
                        .help("Show \(project.id) in Finder")
                }
                Text((project.id as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(project.id)
                    .padding(.leading, 26)
            }
            .padding(.horizontal, Metrics.cardPadding)
            .padding(.vertical, 12)

            Divider()

            let processes = expanded ? project.processes : Self.leading(project.processes, portsByPID: portsByPID)
            VStack(spacing: 0) {
                ForEach(Array(processes.enumerated()), id: \.element.id) { index, process in
                    if index > 0 { Divider().padding(.leading, Metrics.cardPadding) }
                    ProjectProcessRow(process: process, ports: Self.uniquePorts(portsByPID[process.pid] ?? [])) {
                        stop(process)
                    }
                }
                if project.processes.count > Self.collapsedCount {
                    Divider()
                    Button(expanded ? "Show fewer processes" : "Show all \(Format.processes(project.processes.count))") {
                        expanded.toggle()
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Metrics.cardPadding)
                    .padding(.vertical, 10)
                }
            }
        }
        .card(padding: nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(project.name), \(project.runtimes.map(\.displayName).joined(separator: ", "))")
    }

    static let collapsedCount = 5

    /// Collapsed list: every process with a listening port, then the busiest others, in CPU order.
    private static func leading(_ processes: [ProcessStats], portsByPID: [Int32: [ListeningPort]]) -> [ProcessStats] {
        guard processes.count > collapsedCount else { return processes }
        let listening = processes.filter { portsByPID[$0.pid] != nil }.count
        var others = max(collapsedCount - listening, 0)
        return processes.filter { process in
            if portsByPID[process.pid] != nil { return true }
            guard others > 0 else { return false }
            others -= 1
            return true
        }
    }

    /// One chip per port and protocol; IPv4 and IPv6 listeners on the same port collapse.
    static func uniquePorts(_ ports: [ListeningPort]) -> [ListeningPort] {
        var seen = Set<String>()
        return ports
            .sorted { ($0.port, $0.proto.rawValue) < ($1.port, $1.proto.rawValue) }
            .filter { seen.insert("\($0.proto.rawValue):\($0.port)").inserted }
    }
}

private struct ProjectProcessRow: View {
    let process: ProcessStats
    let ports: [ListeningPort]
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(process.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(process.executablePath ?? process.name)
                HStack(spacing: 6) {
                    Text("PID \(Format.integer(process.pid))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    ForEach(ports) { port in
                        PortChip(port: port)
                    }
                }
                .frame(minHeight: 19)
            }
            Spacer(minLength: 12)
            Text(process.isRestricted ? Format.unavailable : Format.percent(process.cpu))
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
            Text(process.isRestricted ? Format.unavailable : Format.memory(process.memory))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)
            Button("Stop…", action: stop)
                .controlSize(.small)
                .help("Stop \(process.name) (PID \(Format.integer(process.pid)))")
        }
        .font(.callout)
        .padding(.horizontal, Metrics.cardPadding)
        .padding(.vertical, 8)
    }
}

/// ":4183" chip. TCP ports open http://localhost:<port> in the browser.
private struct PortChip: View {
    let port: ListeningPort
    @State private var hovering = false

    var body: some View {
        let number = String(port.port)
        if port.proto == .tcp, let url = URL(string: "http://localhost:\(number)") {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                chip(number)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(Text(verbatim: "Open http://localhost:\(number) in your browser. Listening on \(port.address)."))
            .accessibilityLabel(Text(verbatim: "Port \(number)"))
            .accessibilityHint(Text(verbatim: "Opens http://localhost:\(number) in your browser"))
        } else {
            chip(number)
                .help(Text(verbatim: "UDP port \(number), bound to \(port.address)"))
                .accessibilityLabel(Text(verbatim: "UDP port \(number)"))
        }
    }

    private func chip(_ number: String) -> some View {
        Text(verbatim: port.proto == .tcp ? ":\(number)" : ":\(number) UDP")
            .font(.caption.monospaced())
            .foregroundStyle(port.proto == .tcp ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(hovering ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.fill.tertiary), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// Looks up what listens on typed ports, across every process of this user, and offers to stop it.
private struct FreePortCard: View {
    @Binding var query: String
    let lookup: PortLookup?
    let error: String?
    let isSearching: Bool
    let find: () -> Void
    let stop: ([PortHolder]) -> Void

    var body: some View {
        SectionCard("Free a Port", subtitle: "Find what’s listening on a port, in any app you run, and stop it.") {
            HStack(spacing: 8) {
                TextField("Ports", text: $query, prompt: Text(verbatim: "3000, 5173 or 8000-8010"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .onSubmit(find)
                Button("Find", action: find)
                    .disabled(query.allSatisfy(\.isWhitespace) || isSearching)
                if isSearching {
                    ProgressView().controlSize(.small)
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if let lookup {
                results(lookup)
            }
        }
    }

    @ViewBuilder
    private func results(_ lookup: PortLookup) -> some View {
        if !lookup.holders.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(lookup.holders.enumerated()), id: \.element.id) { index, holder in
                    if index > 0 { Divider() }
                    PortHolderRow(holder: holder) { stop([holder]) }
                }
            }
            if lookup.holders.count > 1 {
                Button("Stop All…") { stop(lookup.holders) }
            }
        }
        let held = Set(lookup.holders.flatMap { $0.ports.map(\.port) }).union(lookup.hiddenInUse)
        let free = lookup.ports.filter { !held.contains($0) }
        if !free.isEmpty {
            Label(
                held.isEmpty && free.count > 1
                    ? "Nothing is listening on any of the \(Format.integer(free.count)) ports."
                    : "Nothing is listening on \(Self.names(free)).",
                systemImage: "checkmark.circle"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        if !lookup.hiddenInUse.isEmpty {
            Label(
                "\(Self.names(lookup.hiddenInUse)) \(lookup.hiddenInUse.count == 1 ? "is" : "are") in use outside your account: by the system or another user, or just released. CareMyMac can only stop your own processes.",
                systemImage: "lock"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "3000", "3000 and 5173", or "12 ports" for long lists.
    private static func names(_ ports: [UInt16]) -> String {
        ports.count <= 6 ? ListFormatter.localizedString(byJoining: ports.map(String.init)) : "\(Format.integer(ports.count)) ports"
    }
}

private struct PortHolderRow: View {
    let holder: PortHolder
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(holder.name.isEmpty ? "Unknown process" : holder.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(holder.executablePath ?? holder.name)
                HStack(spacing: 6) {
                    Text("PID \(Format.integer(holder.pid))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    ForEach(ProjectCard.uniquePorts(holder.ports)) { port in
                        PortChip(port: port)
                    }
                }
                .frame(minHeight: 19)
            }
            Spacer(minLength: 12)
            Button("Stop…", action: stop)
                .controlSize(.small)
                .help("Stop \(holder.name) (PID \(Format.integer(holder.pid)))")
        }
        .font(.callout)
        .padding(.vertical, 8)
        .contextMenu {
            if let path = holder.executablePath {
                Button("Show in Finder") { ProcessActions.revealInFinder(path: path) }
            }
            Button("Stop…", action: stop)
        }
    }
}

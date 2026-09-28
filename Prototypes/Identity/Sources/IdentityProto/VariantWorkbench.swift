import CareMyMacKit
import CareMyMacUI
import SwiftUI

/// Direction 1 — Workbench. Axis: app-first navigation. The sidebar is your apps, ranked live;
/// resources are toolbar tabs. "This Mac" is one row among them.
struct WorkbenchVariant: View {
    @Environment(LiveMonitor.self) private var monitor
    @State private var selection: String? = "mac"
    @State private var resource: Resource = .cpu

    private let rankable: [Resource] = [.cpu, .memory, .disk]

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                MacRow(resource: resource).tag("mac")
                Section("Busiest by \(resource == .cpu ? "CPU" : resource.title.lowercased())") {
                    ForEach(rankedApps) { app in
                        WorkbenchAppRow(app: app, resource: resource, scale: scale).tag(app.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
        } detail: {
            Group {
                if let id = selection, id != "mac", let app = monitor.apps.first(where: { $0.id == id }) {
                    WorkbenchAppDetail(app: app)
                } else {
                    WorkbenchMacDetail(resource: $resource)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Rank apps by", selection: $resource) {
                        ForEach(rankable) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .help("Rank apps by this resource")
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(monitor.isPaused ? "Resume" : "Pause", systemImage: monitor.isPaused ? "play.fill" : "pause.fill") { monitor.togglePause() }
                    Button("Save moment", systemImage: "bookmark") { monitor.saveMoment() }
                        .disabled(monitor.pendingMomentDate != nil)
                }
            }
        }
    }

    private var rankedApps: [AppActivity] {
        let r = resource
        return monitor.apps.filter { $0.kind == .application }.sorted { $0.value(for: r) > $1.value(for: r) }.prefix(30).map { $0 }
    }

    private var scale: Double {
        max(rankedApps.first?.value(for: resource) ?? 0, resource == .cpu ? 1 : 1)
    }
}

private struct MacRow: View {
    @Environment(LiveMonitor.self) private var monitor
    let resource: Resource

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "laptopcomputer")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("This Mac").font(.headline)
                Text(monitor.statusSentence).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct WorkbenchAppRow: View {
    let app: AppActivity
    let resource: Resource
    let scale: Double

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(app: app, size: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(app.name).lineLimit(1).truncationMode(.tail).help(app.name)
                    Spacer(minLength: 6)
                    Text(app.formatted(for: resource)).monospacedDigit().foregroundStyle(.secondary)
                }
                Capsule()
                    .fill(.fill.tertiary)
                    .frame(height: 3)
                    .overlay(alignment: .leading) {
                        GeometryReader { geometry in
                            Capsule().fill(resource.color).frame(width: max(3, geometry.size.width * min(app.value(for: resource) / max(scale, 0.0001), 1)))
                        }
                    }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// Whole-Mac view: one big chart for the chosen resource, the others as switchable strips.
private struct WorkbenchMacDetail: View {
    @Environment(LiveMonitor.self) private var monitor
    @Binding var resource: Resource
    @State private var scrub = ScrubState()

    var body: some View {
        let domain = monitor.domain(.fiveMinutes)
        let readings = monitor.readings(since: domain.lowerBound)
        let focus = readings.first { $0.resource == resource } ?? readings[0]
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("This Mac").font(.largeTitle.weight(.bold))
                    Text("\(monitor.machine.chipName) · \(monitor.machine.coreCount) cores · \(Format.memory(monitor.machine.physicalMemory)) · \(Format.processes(monitor.processCount))")
                        .foregroundStyle(.secondary).monospacedDigit()
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Label(focus.resource.title, systemImage: focus.resource.symbol).font(.headline).foregroundStyle(focus.resource.textColor)
                        Text(focus.value).font(.system(size: 30, weight: .semibold)).monospacedDigit()
                        Text(focus.detail).foregroundStyle(.secondary).monospacedDigit()
                    }
                    SeriesChart(primary: focus.primary, secondary: focus.secondary, color: focus.resource.color, secondaryColor: focus.resource.secondaryColor,
                                domain: domain, yMax: focus.yMax, showsAxes: true, yLabel: focus.yMax == 1 ? { Format.percent($0, digits: 0) } : focus.format, scrub: scrub)
                        .frame(height: 220)
                }
                .padding(18)
                .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(readings, id: \.resource) { reading in
                        Button {
                            if [.cpu, .memory, .disk].contains(reading.resource) { resource = reading.resource }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Image(systemName: reading.resource.symbol).foregroundStyle(reading.resource.color)
                                    Text(reading.resource.title).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(reading.value).monospacedDigit().fontWeight(.semibold)
                                }
                                SeriesChart(primary: reading.primary, secondary: reading.secondary, color: reading.resource.color,
                                            secondaryColor: reading.resource.secondaryColor, domain: domain, yMax: reading.yMax)
                                    .frame(height: 38)
                            }
                            .padding(12)
                            .background(reading.resource == resource ? AnyShapeStyle(reading.resource.wash) : AnyShapeStyle(.background),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help([.cpu, .memory, .disk].contains(reading.resource) ? "Rank apps by \(reading.resource.title)" : reading.detail)
                    }
                }
            }
            .padding(28)
            .padding(.bottom, 60)
        }
        .background(.background.secondary)
    }
}

/// One app, front and center: its own CPU and memory trails and its processes.
private struct WorkbenchAppDetail: View {
    @Environment(AppTrails.self) private var trails
    @Environment(LiveMonitor.self) private var monitor
    let app: AppActivity

    var body: some View {
        let domain = monitor.domain(.fiveMinutes)
        let cpu = trails.cpu[app.id]?.points(since: domain.lowerBound) ?? []
        let memory = trails.memory[app.id]?.points(since: domain.lowerBound) ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    AppIcon(app: app, size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(.largeTitle.weight(.bold)).lineLimit(1).help(app.name)
                        Text("\(app.kind.label) · \(Format.processes(app.processes.count))").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Quit", role: .destructive) { try? ProcessActions.quit(app: app) }
                        .help("Ask \(app.name) to quit")
                }
                HStack(spacing: 12) {
                    trail("CPU", value: Format.percent(app.cpu), points: cpu, resource: .cpu, domain: domain, yMax: max(SeriesMath.peak(cpu) ?? 0, 1))
                    trail("Memory", value: Format.memory(app.memory), points: memory, resource: .memory, domain: domain, yMax: nil)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("Processes").font(.headline).padding(.bottom, 8)
                    ForEach(app.processes.prefix(40)) { process in
                        HStack {
                            Text(process.name).lineLimit(1).truncationMode(.middle).help(process.executablePath ?? process.name)
                            Spacer()
                            Text(Format.percent(process.cpu)).monospacedDigit().frame(width: 70, alignment: .trailing)
                            Text(Format.memory(process.memory)).monospacedDigit().foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                        }
                        .padding(.vertical, 6)
                        Divider()
                    }
                }
                .padding(18)
                .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(28)
            .padding(.bottom, 60)
        }
        .background(.background.secondary)
    }

    private func trail(_ title: String, value: String, points: [ChartPoint], resource: Resource, domain: ClosedRange<Date>, yMax: Double?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            }
            SeriesChart(primary: points, color: resource.color, domain: domain, yMax: yMax)
                .frame(height: 90)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

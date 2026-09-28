import AppKit
import Charts
import CareMyMacKit
import CareMyMacUI
import SwiftUI

/// One marker: editable title and note, the captured charts with the marker time flagged, and the busiest apps.
struct MarkerDetail: View {
    @Environment(LiveMonitor.self) private var monitor
    @Environment(AppModel.self) private var appModel
    let moment: SavedMoment

    @State private var title: String
    @State private var note: String
    @State private var confirmsDelete = false
    @State private var scrub = ScrubState()

    init(moment: SavedMoment) {
        self.moment = moment
        _title = State(initialValue: moment.title)
        _note = State(initialValue: moment.note)
    }

    var body: some View {
        let domain = moment.window
        let memory = moment.snapshot.memory
        let physical = Double(memory.physical)
        // Memory is drawn as a share of installed RAM so the axis reads 0–100%.
        let memoryPoints = physical > 0 ? moment.memorySeries.map { SeriesPoint(date: $0.date, value: $0.value / physical) }.chartPoints : []
        VStack(alignment: .leading, spacing: Metrics.gap) {
            header

            HStack(alignment: .top, spacing: Metrics.gap) {
                StatTile("CPU at marker", value: Format.percent(moment.snapshot.cpu.total), detail: "Peak \(Format.percent(moment.cpuSeries.lazy.map(\.value).max()))")
                StatTile("Memory used", value: Format.memory(memory.used), detail: "\(memory.pressure.label) pressure")
                StatTile("Busiest app", value: moment.topApps.first?.name ?? Format.unavailable, detail: moment.topApps.first.map { "\(Format.percent($0.cpu)) CPU · \(Format.memory($0.memory))" })
                StatTile("Captured", value: capturedLength(domain), detail: "\(domain.lowerBound.formatted(date: .omitted, time: .shortened)) – \(domain.upperBound.formatted(date: .omitted, time: .shortened))")
            }
            .fixedSize(horizontal: false, vertical: true)

            Grid(horizontalSpacing: Metrics.gap, verticalSpacing: Metrics.gap) {
                GridRow {
                    MarkerChartCard(
                        title: "CPU",
                        resource: .cpu,
                        primary: ("CPU", moment.cpuSeries.chartPoints),
                        yMax: 1,
                        format: { Format.percent($0) },
                        yLabel: { Format.percent($0, digits: 0) },
                        domain: domain, saveDate: moment.date, scrub: scrub
                    )
                    MarkerChartCard(
                        title: "Memory",
                        resource: .memory,
                        primary: ("Used", memoryPoints),
                        yMax: 1,
                        format: { Format.memory($0 * physical) },
                        yLabel: { Format.percent($0, digits: 0) },
                        domain: domain, saveDate: moment.date, scrub: scrub
                    )
                }
                GridRow {
                    MarkerChartCard(
                        title: "Network",
                        resource: .network,
                        primary: ("Download", moment.networkInSeries.chartPoints),
                        secondary: ("Upload", moment.networkOutSeries.chartPoints),
                        format: { Format.rate($0) },
                        yLabel: { Format.rate($0) },
                        domain: domain, saveDate: moment.date, scrub: scrub
                    )
                    MarkerChartCard(
                        title: "Disk",
                        resource: .disk,
                        primary: ("Read", moment.diskReadSeries.chartPoints),
                        secondary: ("Write", moment.diskWriteSeries.chartPoints),
                        format: { Format.rate($0) },
                        yLabel: { Format.rate($0) },
                        domain: domain, saveDate: moment.date, scrub: scrub
                    )
                }
            }

            MarkerAppsCard(apps: moment.topApps)
        }
        .task(id: [title, note]) {
            guard (try? await Task.sleep(for: .milliseconds(600))) != nil else { return }
            commit()
        }
        .onDisappear(perform: commit)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Title", text: $title, prompt: Text("Name this marker"))
                        .textFieldStyle(.plain)
                        .font(.title2.weight(.semibold))
                        .accessibilityLabel("Marker title")
                    Text("Marked \(moment.date.formatted(.dateTime.weekday(.wide).month(.wide).day().hour().minute().second()))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 12)
                Button("Delete Marker…", systemImage: "trash", role: .destructive) { confirmsDelete = true }
                    .confirmationDialog("Delete “\(moment.displayTitle)”?", isPresented: $confirmsDelete) {
                        Button("Delete Marker", role: .destructive) {
                            appModel.selectedMarkerID = nil
                            monitor.deleteMoment(id: moment.id)
                        }
                    } message: {
                        Text("Its charts, note, and busiest apps are removed. This can't be undone.")
                    }
            }
            TextField("Note", text: $note, prompt: Text("Add a note — what were you doing, what felt slow?"), axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityLabel("Note")
        }
        .card()
    }

    /// "2m 30s": markers are short, so seconds matter.
    private func capturedLength(_ domain: ClosedRange<Date>) -> String {
        let seconds = Int(domain.upperBound.timeIntervalSince(domain.lowerBound).rounded())
        let minutes = seconds / 60, rest = seconds % 60
        return minutes == 0 ? "\(rest)s" : rest == 0 ? "\(minutes)m" : "\(minutes)m \(rest)s"
    }

    private func commit() {
        guard title != moment.title || note != moment.note else { return }
        var updated = moment
        updated.title = title
        updated.note = note
        monitor.update(updated)
    }
}

// MARK: - Charts

private struct MarkerChartCard: View {
    let title: String
    let resource: Resource
    let primary: (label: String, points: [ChartPoint])
    var secondary: (label: String, points: [ChartPoint])?
    var yMax: Double?
    let format: (Double) -> String
    let yLabel: (Double) -> String
    let domain: ClosedRange<Date>
    let saveDate: Date
    let scrub: ScrubState

    var body: some View {
        SectionCard(title) {
            MarkerReadout(primary: primary.points, secondary: secondary?.points, format: format, saveDate: saveDate, scrub: scrub)
        } content: {
            if primary.points.isEmpty {
                Text("Nothing was recorded for this part of the marker.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                SeriesChart(
                    primary: primary.points,
                    secondary: secondary?.points ?? [],
                    color: resource.color,
                    secondaryColor: resource.secondaryColor,
                    domain: domain,
                    yMax: yMax,
                    showsAxes: true,
                    yLabel: yLabel,
                    scrub: scrub
                )
                .chartBackground { proxy in
                    SaveMarker(proxy: proxy, date: saveDate)
                }
                .frame(height: 120)
                .accessibilityLabel("\(title) around the marker")
            }
            HStack(spacing: 16) {
                LegendSwatch(primary.label, color: resource.color)
                if let secondary {
                    LegendSwatch(secondary.label, color: resource.secondaryColor, dashed: true)
                }
                Spacer(minLength: 8)
                LegendSwatch("Marker", color: .secondary, dashed: true)
            }
        }
    }
}

/// Dashed vertical line at the save time, drawn behind the chart marks.
private struct SaveMarker: View {
    let proxy: ChartProxy
    let date: Date

    var body: some View {
        GeometryReader { geometry in
            if let frame = proxy.plotFrame, let x = proxy.position(forX: date) {
                let plot = geometry[frame]
                Path { path in
                    path.move(to: CGPoint(x: plot.minX + x, y: plot.minY))
                    path.addLine(to: CGPoint(x: plot.minX + x, y: plot.maxY))
                }
                .stroke(.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Value under the cursor, or at the save time; the only view that reads the scrub date.
private struct MarkerReadout: View {
    let primary: [ChartPoint]
    let secondary: [ChartPoint]?
    let format: (Double) -> String
    let saveDate: Date
    let scrub: ScrubState

    var body: some View {
        let date = scrub.date ?? saveDate
        let value = SeriesMath.value(in: primary, at: date, tolerance: 5)
        let secondValue = secondary.flatMap { SeriesMath.value(in: $0, at: date, tolerance: 5) }
        HStack(spacing: 6) {
            Text(scrub.date == nil ? "At marker" : date.formatted(date: .omitted, time: .standard))
                .foregroundStyle(.secondary)
            Text(value.map(format) ?? Format.unavailable)
            if let secondValue {
                Text("/ \(format(secondValue))").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .monospacedDigit()
        .lineLimit(1)
    }
}

// MARK: - Apps

private struct MarkerAppsCard: View {
    let apps: [AppSummary]

    var body: some View {
        SectionCard("Busiest apps", subtitle: "What was running hardest at the marker.") {
            EmptyView()
        } content: {
            if apps.isEmpty {
                Text("No app activity was recorded with this marker.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
                    GridRow {
                        Text("App")
                        Text("CPU").gridColumnAlignment(.trailing)
                        Text("Memory").gridColumnAlignment(.trailing)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
                    ForEach(apps) { app in
                        Divider().gridCellUnsizedAxes(.horizontal)
                        GridRow {
                            HStack(spacing: 8) {
                                AppIcon(path: BundlePathCache.path(for: app.bundleIdentifier), size: 20)
                                Text(app.name).lineLimit(1).help(app.name)
                                if app.processCount > 1 {
                                    Text("\(app.processCount) processes")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(Format.percent(app.cpu)).monospacedDigit()
                            Text(Format.memory(app.memory)).monospacedDigit()
                        }
                        .padding(.vertical, 6)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

/// Bundle identifier → app bundle path, resolved once per identifier.
@MainActor
private enum BundlePathCache {
    private static var paths: [String: String?] = [:]

    static func path(for bundleIdentifier: String?) -> String? {
        guard let bundleIdentifier else { return nil }
        if let cached = paths[bundleIdentifier] { return cached }
        let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)?.path(percentEncoded: false)
        paths[bundleIdentifier] = path
        return path
    }
}

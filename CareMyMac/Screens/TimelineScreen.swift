import AppKit
import Charts
import CareMyMacKit
import CareMyMacUI
import Observation
import SwiftUI

/// Timeline: thirty days of minute records — one metric on a period chart, a period summary, and the busiest apps at any sample.
struct TimelineScreen: View {
    @Environment(LiveMonitor.self) private var monitor
    @AppStorage("history.period") private var period: HistoryPeriod = .day
    @AppStorage("history.metric") private var metric: HistoryMetric = .cpu
    @State private var records: [HistoryRecord]?
    @State private var domain: ClosedRange<Date> = Date.now.addingTimeInterval(-86_400)...Date.now
    @State private var plot = HistoryPlot()
    @State private var cursor = HistoryCursor()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                PageHeader("Timeline", subtitle: "One sample per minute for the last 30 days, kept only on this Mac.") {
                    Picker("Timeline period", selection: $period) {
                        ForEach(HistoryPeriod.allCases) { period in
                            Text(period.label).tag(period)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("How far back the chart and summary reach")
                }

                if let records {
                    if records.isEmpty {
                        EmptyStateView(
                            "Nothing recorded in the last \(period.label)",
                            symbol: "clock.arrow.circlepath",
                            message: "CareMyMac records one sample per minute while it runs and keeps 30 days. Nothing is recorded while monitoring is paused, the Mac is asleep, or CareMyMac is quit — leave it running and this fills in minute by minute."
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                        .card()
                    } else {
                        chartCard
                        summary(records: records)
                        HistoryAppsCard(records: records, plot: plot, cursor: cursor)
                    }
                } else {
                    ProgressView("Loading timeline…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                        .card()
                }

                Text("One sample per minute while CareMyMac runs, kept for 30 days. Longer periods show the busiest sample in each interval, so spikes stay visible. Nothing is recorded while paused, asleep, or quit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                PageFooter()
            }
            .padding(Metrics.pagePadding)
        }
        .pageBackground()
        .task(id: period) { await follow(period) }
        .onChange(of: metric) { rebuild() }
    }

    private var chartCard: some View {
        SectionCard(metric.chartTitle, subtitle: plot.caption) {
            Picker("Metric", selection: $metric) {
                ForEach(HistoryMetric.allCases) { metric in
                    Text(metric.title).tag(metric)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
        } content: {
            HistoryReadout(plot: plot, metric: metric, cursor: cursor)
            if plot.samples.isEmpty {
                VStack(spacing: 6) {
                    Text("No \(metric.title) measurements in the last \(period.label)")
                        .font(.callout)
                    Text(metric.missingReason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 220)
            } else {
                HistoryChart(plot: plot, domain: domain, metric: metric, period: period, cursor: cursor)
                    .frame(height: 220)
                    .accessibilityLabel("\(metric.chartTitle) over the last \(period.label)")
            }
            HStack(spacing: 16) {
                LegendSwatch(metric.title, color: metric.resource.color)
                Spacer()
                Text("Hover to inspect · click to keep a time selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func summary(records: [HistoryRecord]) -> some View {
        let expected = max(period.seconds / 60, 1)
        return HStack(alignment: .top, spacing: Metrics.gap) {
            StatTile("Average", value: plot.average.map(metric.format) ?? Format.unavailable, detail: "Across the last \(period.label)")
            StatTile(
                "Peak",
                value: plot.peak.map { metric.format($0.value) } ?? Format.unavailable,
                detail: plot.peak.map { HistoryTime.label($0.date) } ?? "No measurements"
            )
            StatTile(
                "Samples recorded",
                value: Format.integer(records.count),
                detail: "\(Format.percent(min(Double(records.count) / expected, 1), digits: 0)) of the period covered"
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Loads the period, then appends new minutes once a minute while the page is visible.
    private func follow(_ period: HistoryPeriod) async {
        cursor.hover = nil
        cursor.pinned = nil
        var now = Date.now
        var loaded = await monitor.records(from: now.addingTimeInterval(-period.seconds), to: now)
        guard !Task.isCancelled else { return }
        apply(loaded, now: now, period: period)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            now = .now
            let start = now.addingTimeInterval(-period.seconds)
            let since = loaded.last.map { $0.date.addingTimeInterval(1) } ?? start
            let fresh = await monitor.records(from: since, to: now)
            guard !Task.isCancelled else { return }
            loaded = Array(loaded.drop { $0.date < start }) + fresh
            apply(loaded, now: now, period: period)
        }
    }

    private func apply(_ loaded: [HistoryRecord], now: Date, period: HistoryPeriod) {
        records = loaded
        domain = now.addingTimeInterval(-period.seconds)...now
        rebuild()
    }

    private func rebuild() {
        plot = HistoryPlot(records: records ?? [], metric: metric, period: period, start: domain.lowerBound)
    }
}

// MARK: - Period & metric

enum HistoryPeriod: String, CaseIterable, Identifiable {
    case twelveHours = "12h"
    case day = "24h"
    case week = "7d"
    case month = "30d"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .twelveHours: "12 hours"
        case .day: "24 hours"
        case .week: "7 days"
        case .month: "30 days"
        }
    }

    var seconds: TimeInterval {
        switch self {
        case .twelveHours: 12 * 3600
        case .day: 24 * 3600
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        }
    }

    /// Width of one plotted interval; keeps the chart at or under 720 points.
    var bucket: TimeInterval { max(60, seconds / HistoryPlot.maxPoints) }

    /// Hour or day boundaries inside `domain`, skipping any so close to either edge that the label would clip.
    func axisDates(in domain: ClosedRange<Date>) -> [Date] {
        let calendar = Calendar.current
        let (component, count): (Calendar.Component, Int) = switch self {
        case .twelveHours: (.hour, 2)
        case .day: (.hour, 4)
        case .week: (.day, 1)
        case .month: (.day, 5)
        }
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        let first = domain.lowerBound.addingTimeInterval(span * 0.02)
        let last = domain.upperBound.addingTimeInterval(-span * 0.04)
        var date = calendar.startOfDay(for: domain.lowerBound)
        var dates: [Date] = []
        while date <= last {
            if date >= first { dates.append(date) }
            guard let next = calendar.date(byAdding: component, value: count, to: date) else { break }
            date = next
        }
        return dates
    }

    var axisFormat: Date.FormatStyle {
        switch self {
        case .twelveHours, .day: .dateTime.hour()
        case .week: .dateTime.weekday(.abbreviated)
        case .month: .dateTime.day().month(.abbreviated)
        }
    }
}

enum HistoryMetric: String, CaseIterable, Identifiable {
    case cpu, memory, gpu, download, upload, diskRead, diskWrite, battery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .gpu: "GPU"
        case .download: "Download"
        case .upload: "Upload"
        case .diskRead: "Disk read"
        case .diskWrite: "Disk write"
        case .battery: "Battery"
        }
    }

    var chartTitle: String {
        switch self {
        case .cpu: "CPU activity"
        case .memory: "Memory in use"
        case .gpu: "GPU activity"
        case .download: "Download rate"
        case .upload: "Upload rate"
        case .diskRead: "Disk reads"
        case .diskWrite: "Disk writes"
        case .battery: "Battery charge"
        }
    }

    var resource: Resource {
        switch self {
        case .cpu: .cpu
        case .memory: .memory
        case .gpu: .graphics
        case .download, .upload: .network
        case .diskRead, .diskWrite: .disk
        case .battery: .battery
        }
    }

    var isFraction: Bool { self == .cpu || self == .gpu || self == .battery }

    var missingReason: String {
        switch self {
        case .gpu: "This Mac didn’t report GPU activity while these minutes were recorded."
        case .battery: "No battery level was reported. Desktop Macs have no internal battery."
        default: "Nothing was recorded for this metric in the selected period."
        }
    }

    func value(_ record: HistoryRecord) -> Double? {
        switch self {
        case .cpu: record.cpuAverage
        case .memory: Double(record.memoryUsed)
        case .gpu: record.gpuUtilization
        case .download: record.networkInBytesPerSecond
        case .upload: record.networkOutBytesPerSecond
        case .diskRead: record.diskReadBytesPerSecond
        case .diskWrite: record.diskWriteBytesPerSecond
        case .battery: record.batteryLevel
        }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .cpu, .gpu, .battery: Format.percent(value)
        case .memory: Format.memory(value)
        case .download, .upload, .diskRead, .diskWrite: Format.rate(value)
        }
    }

    func axisLabel(_ value: Double) -> String {
        isFraction ? Format.percent(value, digits: 0) : format(value)
    }
}

// MARK: - Plot data

/// What the chart draws for one metric: at most one sample per interval (the interval's peak record,
/// so spikes survive downsampling), split into runs wherever recording stopped.
struct HistoryPlot: Equatable {
    static let maxPoints: Double = 720

    struct Sample: Equatable, Identifiable {
        let date: Date
        let value: Double
        /// Contiguous stretch of recording; each run is its own line.
        let run: Int
        /// Alone in its run, so drawn as a dot.
        var isolated = false
        /// Index into the records the plot was built from.
        let record: Int
        var id: Date { date }
    }

    struct Reading: Equatable {
        let date: Date
        let value: Double
    }

    var samples: [Sample] = []
    var average: Double?
    var peak: Reading?
    /// Newest record with a value; may be hidden inside its interval's peak on long periods.
    var latest: Reading?
    var ceiling: Double = 1
    var yTicks: [Double]?
    var bucket: TimeInterval = 60

    init() {}

    init(records: [HistoryRecord], metric: HistoryMetric, period: HistoryPeriod, start: Date) {
        bucket = period.bucket
        let gapLimit = max(180, 2 * bucket)

        var peaks: [(record: Int, value: Double)] = []
        peaks.reserveCapacity(Int(Self.maxPoints) + 2)
        var currentBucket = Int.min
        var sum = 0.0
        var count = 0
        var best: (record: Int, value: Double)?
        for (index, record) in records.enumerated() {
            guard let value = metric.value(record), value.isFinite else { continue }
            sum += value
            count += 1
            if best.map({ value > $0.value }) ?? true { best = (index, value) }
            latest = Reading(date: record.date, value: value)
            let bucketIndex = Int((record.date.timeIntervalSince(start) / bucket).rounded(.down))
            if bucketIndex != currentBucket {
                peaks.append((index, value))
                currentBucket = bucketIndex
            } else if value > peaks[peaks.count - 1].value {
                peaks[peaks.count - 1] = (index, value)
            }
        }

        var run = 0
        samples.reserveCapacity(peaks.count)
        for peak in peaks {
            let date = records[peak.record].date
            if let previous = samples.last, date.timeIntervalSince(previous.date) > gapLimit { run += 1 }
            samples.append(Sample(date: date, value: peak.value, run: run, record: peak.record))
        }
        for index in samples.indices {
            let joinsPrevious = index > 0 && samples[index - 1].run == samples[index].run
            let joinsNext = index < samples.count - 1 && samples[index + 1].run == samples[index].run
            samples[index].isolated = !joinsPrevious && !joinsNext
        }

        average = count > 0 ? sum / Double(count) : nil
        peak = best.map { Reading(date: records[$0.record].date, value: $0.value) }

        let dataMax = peak?.value ?? 0
        switch metric {
        case .cpu, .gpu, .battery:
            ceiling = 1
            yTicks = [0, 0.25, 0.5, 0.75, 1]
        case .memory:
            let installed = Double(records.lazy.map(\.memoryPhysical).max() ?? 0)
            ceiling = max(installed, dataMax, 1)
            yTicks = installed >= dataMax && installed > 0 ? [0, 0.25, 0.5, 0.75, 1].map { $0 * installed } : nil
        case .download, .upload, .diskRead, .diskWrite:
            ceiling = SeriesMath.niceCeiling(max(dataMax * 1.1, 1000))
            yTicks = nil
        }
    }

    /// "217 samples shown · busiest per 14 minutes".
    var caption: String {
        let shown = samples.count == 1 ? "1 sample shown" : "\(Format.integer(samples.count)) samples shown"
        guard bucket > 60 else { return "\(shown) · one per minute" }
        let minutes = Int(bucket / 60)
        let interval = minutes % 60 == 0 ? (minutes == 60 ? "hour" : "\(minutes / 60) hours") : "\(minutes) minutes"
        return "\(shown) · busiest minute per \(interval)"
    }

    /// Nearest sample within half a gap of `date`.
    func sample(near date: Date) -> Sample? {
        guard !samples.isEmpty else { return nil }
        var low = 0
        var high = samples.count - 1
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].date < date { low = mid + 1 } else { high = mid }
        }
        var best = samples[low]
        if low > 0, abs(samples[low - 1].date.timeIntervalSince(date)) < abs(best.date.timeIntervalSince(date)) {
            best = samples[low - 1]
        }
        return abs(best.date.timeIntervalSince(date)) <= max(bucket, 120) ? best : nil
    }
}

/// Hovered and clicked sample dates. Only the cursor overlay, readout, and apps card read it,
/// so hovering never re-renders the chart marks.
@MainActor
@Observable
final class HistoryCursor {
    var hover: Date?
    var pinned: Date?
}

enum HistoryTime {
    /// "12:09 PM" today, "Sat 12:09 PM" this week, "12 Sep, 12:09 PM" further back.
    static func label(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: .now)).day, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
}

// MARK: - Chart

private struct HistoryChart: View {
    let plot: HistoryPlot
    let domain: ClosedRange<Date>
    let metric: HistoryMetric
    let period: HistoryPeriod
    let cursor: HistoryCursor

    var body: some View {
        let color = metric.resource.color
        Chart {
            ForEach(plot.samples) { sample in
                if sample.isolated {
                    PointMark(x: .value("Time", sample.date), y: .value("Value", sample.value))
                        .foregroundStyle(color)
                        .symbolSize(18)
                } else {
                    AreaMark(
                        x: .value("Time", sample.date),
                        yStart: .value("Base", 0),
                        yEnd: .value("Value", sample.value),
                        series: .value("Run", "run \(sample.run)")
                    )
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.24), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", sample.date), y: .value("Value", sample.value), series: .value("Run", "run \(sample.run)"))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...plot.ceiling)
        .chartXAxis {
            AxisMarks(values: period.axisDates(in: domain)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                AxisValueLabel(format: period.axisFormat)
            }
        }
        .chartYAxis {
            if let ticks = plot.yTicks {
                AxisMarks(position: .trailing, values: ticks) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    AxisValueLabel {
                        if let number = value.as(Double.self) { Text(metric.axisLabel(number)).monospacedDigit() }
                    }
                }
            } else {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    AxisValueLabel {
                        if let number = value.as(Double.self) { Text(metric.axisLabel(number)).monospacedDigit() }
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            HistoryCursorOverlay(proxy: proxy, plot: plot, color: color, domain: domain, cursor: cursor)
        }
    }
}

/// Hover snaps to the nearest plotted sample; click keeps it selected. Reads the cursor, the chart doesn't.
private struct HistoryCursorOverlay: View {
    let proxy: ChartProxy
    let plot: HistoryPlot
    let color: Color
    let domain: ClosedRange<Date>
    let cursor: HistoryCursor

    var body: some View {
        GeometryReader { geometry in
            let frame = proxy.plotFrame.map { geometry[$0] } ?? .zero
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location):
                            let date = sample(at: location, in: frame)?.date
                            if cursor.hover != date { cursor.hover = date }
                        case .ended:
                            if cursor.hover != nil { cursor.hover = nil }
                        }
                    }
                    .gesture(SpatialTapGesture().onEnded { value in
                        if let date = sample(at: value.location, in: frame)?.date { cursor.pinned = date }
                    })

                if let pinned = cursor.pinned, pinned != cursor.hover, let x = proxy.position(forX: pinned) {
                    Rectangle()
                        .fill(.tertiary)
                        .frame(width: 1, height: frame.height)
                        .offset(x: frame.minX + x - 0.5, y: frame.minY)
                        .allowsHitTesting(false)
                }
                if let hover = cursor.hover, let sample = plot.sample(near: hover),
                   let x = proxy.position(forX: sample.date), let y = proxy.position(forY: sample.value) {
                    Path { path in
                        path.move(to: CGPoint(x: frame.minX + x, y: frame.minY))
                        path.addLine(to: CGPoint(x: frame.minX + x, y: frame.maxY))
                    }
                    .stroke(.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .allowsHitTesting(false)
                    Circle()
                        .fill(color)
                        .overlay(Circle().stroke(.background, lineWidth: 1.5))
                        .frame(width: 8, height: 8)
                        .offset(x: frame.minX + x - 4, y: frame.minY + y - 4)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func sample(at location: CGPoint, in frame: CGRect) -> HistoryPlot.Sample? {
        let x = min(max(location.x - frame.minX, 0), frame.width)
        guard let date = proxy.value(atX: x, as: Date.self) else { return nil }
        return plot.sample(near: min(max(date, domain.lowerBound), domain.upperBound))
    }
}

/// "12:09 PM · CPU 31.4%" for the hovered, selected, or latest sample.
private struct HistoryReadout: View {
    let plot: HistoryPlot
    let metric: HistoryMetric
    let cursor: HistoryCursor

    var body: some View {
        let hovered = cursor.hover.flatMap(plot.sample(near:))
        let pinned = cursor.pinned.flatMap(plot.sample(near:))
        let reading = (hovered ?? pinned).map { HistoryPlot.Reading(date: $0.date, value: $0.value) } ?? plot.latest
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let sample = reading {
                Text(HistoryTime.label(sample.date))
                    .foregroundStyle(.secondary)
                Text("·").foregroundStyle(.tertiary)
                Text("\(metric.title) \(metric.format(sample.value))")
                    .fontWeight(.semibold)
                Spacer(minLength: 12)
                Text(hovered != nil ? "Hovered" : pinned != nil ? "Selected" : "Latest")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No measurement").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .font(.callout)
        .monospacedDigit()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Apps at the selected time

private struct HistoryAppsCard: View {
    let records: [HistoryRecord]
    let plot: HistoryPlot
    let cursor: HistoryCursor

    var body: some View {
        let record = selectedRecord
        let apps = record?.topApps ?? []
        let scale = max(apps.map(\.cpu).max() ?? 0, 1)
        SectionCard(
            "Apps at the selected time",
            subtitle: record.map { "\($0.date.formatted(date: .abbreviated, time: .shortened)) · busiest by CPU and memory" }
        ) {
            if cursor.pinned != nil {
                Button("Show latest") { cursor.pinned = nil }
                    .buttonStyle(.link)
            }
        } content: {
            if apps.isEmpty {
                Text("No app activity was recorded for this minute.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text("App").frame(maxWidth: .infinity, alignment: .leading)
                        Text("CPU").frame(width: 64, alignment: .trailing)
                        Text("Memory").frame(width: 84, alignment: .trailing)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)
                    ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                        if index > 0 { Divider().padding(.leading, 40) }
                        HistoryAppRow(app: app, scale: scale)
                    }
                }
            }
        }
    }

    /// Hovered sample, else the clicked one, else the latest minute.
    private var selectedRecord: HistoryRecord? {
        let date = cursor.hover ?? cursor.pinned
        if let date, let sample = plot.sample(near: date), records.indices.contains(sample.record), records[sample.record].date == sample.date {
            return records[sample.record]
        }
        return records.last
    }
}

private struct HistoryAppRow: View {
    let app: AppSummary
    let scale: Double

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(path: BundlePaths.path(for: app.bundleIdentifier), size: 22)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(app.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(app.name)
                    Text(Format.processes(app.processCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer(minLength: 12)
                    Text(Format.percent(app.cpu))
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                    Text(Format.memory(app.memory))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 84, alignment: .trailing)
                }
                Capsule()
                    .fill(.fill.tertiary)
                    .frame(height: 3)
                    .overlay(alignment: .leading) {
                        GeometryReader { geometry in
                            Capsule()
                                .fill(Resource.cpu.color)
                                .frame(width: max(3, geometry.size.width * min(app.cpu / scale, 1)))
                        }
                    }
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(app.name), \(Format.percent(app.cpu)) CPU, \(Format.memory(app.memory))")
    }
}

/// Bundle identifier → installed app path, looked up once per identifier.
@MainActor
private enum BundlePaths {
    private static var paths: [String: String?] = [:]

    static func path(for bundleIdentifier: String?) -> String? {
        guard let bundleIdentifier else { return nil }
        if let cached = paths[bundleIdentifier] { return cached }
        let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)?.path(percentEncoded: false)
        paths[bundleIdentifier] = .some(path)
        return path
    }
}

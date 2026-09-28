import CareMyMacKit
import CareMyMacUI
import SwiftUI

/// Direction 2 — Journal. Axis: time-first narrative. No sidebar: a ticker of live readings on top,
/// then a written timeline of what the Mac did today (live events, hourly history, alerts, moments).
struct JournalVariant: View {
    @Environment(LiveMonitor.self) private var monitor
    @State private var journal = JournalModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(monitor.statusSentence)
                        .font(.system(size: 32, weight: .bold))
                        .tracking(-0.3)
                    if let app = monitor.apps.first {
                        Text("\(app.name) is the busiest app right now, at \(Format.percent(app.cpu)) CPU and \(Format.memory(app.memory)).")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(journal.entries.enumerated()), id: \.element.id) { index, entry in
                        JournalRow(entry: entry, isLast: index == journal.entries.count - 1)
                    }
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 80)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .top, spacing: 0) { Ticker() }
        .background(.background)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(monitor.isPaused ? "Resume" : "Pause", systemImage: monitor.isPaused ? "play.fill" : "pause.fill") { monitor.togglePause() }
                Button("Save moment", systemImage: "bookmark") { monitor.saveMoment() }
                    .disabled(monitor.pendingMomentDate != nil)
            }
        }
        .task { await journal.loadHistory(monitor) }
        .onChange(of: monitor.snapshot?.date) { journal.observe(monitor) }
    }
}

/// Live readings as a compact strip docked under the toolbar.
private struct Ticker: View {
    @Environment(LiveMonitor.self) private var monitor

    var body: some View {
        let domain = monitor.domain(.oneMinute)
        HStack(spacing: 0) {
            ForEach(monitor.readings(since: domain.lowerBound), id: \.resource) { reading in
                HStack(spacing: 8) {
                    Image(systemName: reading.resource.symbol).foregroundStyle(reading.resource.color).imageScale(.small)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(reading.resource.title).font(.caption2).foregroundStyle(.secondary)
                        Text(reading.value).font(.callout.weight(.semibold)).monospacedDigit().lineLimit(1).fixedSize()
                    }
                    SeriesChart(primary: reading.primary, secondary: reading.secondary, color: reading.resource.color,
                                secondaryColor: reading.resource.secondaryColor, domain: domain, yMax: reading.yMax)
                        .frame(width: 40, height: 22)
                }
                .frame(maxWidth: .infinity)
                .help("\(reading.resource.title): \(reading.value), \(reading.detail)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct JournalEntry: Identifiable {
    enum Kind { case live, hour, gap, alert, moment, start }
    let id = UUID()
    let date: Date
    var end: Date?
    let kind: Kind
    let symbol: String
    let tint: Color
    let title: String
    let detail: String?
    var appPath: String?
}

@MainActor
@Observable
final class JournalModel {
    private(set) var entries: [JournalEntry] = []
    private var hotApps: [String: Date] = [:]
    private var lastPressure: MemoryPressure?
    private var downloading: Date?
    private var historyLoaded = false

    func loadHistory(_ monitor: LiveMonitor) async {
        guard !historyLoaded else { return }
        historyLoaded = true
        let start = Calendar.current.startOfDay(for: .now)
        let records = await monitor.records(from: start, to: .now)
        var result: [JournalEntry] = []

        // Hour summaries.
        let byHour = Dictionary(grouping: records) { Calendar.current.dateInterval(of: .hour, for: $0.date)?.start ?? $0.date }
        for (hour, rows) in byHour {
            let average = rows.map(\.cpuAverage).reduce(0, +) / Double(rows.count)
            let peak = rows.max { $0.cpuPeak < $1.cpuPeak }
            var appTotals: [String: Double] = [:]
            for row in rows { for app in row.topApps { appTotals[app.name, default: 0] += app.cpu } }
            let busiest = appTotals.max { $0.value < $1.value }
            let end = hour.addingTimeInterval(3600)
            let title = busiest.map { "\($0.key) was the busiest app" } ?? "A quiet hour"
            var detail = "CPU averaged \(Format.percent(average, digits: 0))"
            if let peak { detail += " and peaked at \(Format.percent(peak.cpuPeak, digits: 0)) around \(peak.date.formatted(date: .omitted, time: .shortened))" }
            detail += ". \(rows.count) minutes recorded."
            result.append(JournalEntry(date: hour, end: min(end, .now), kind: .hour, symbol: "clock", tint: .secondary, title: title, detail: detail))
        }

        // Gaps (asleep or not running) longer than 20 minutes.
        for (previous, next) in zip(records, records.dropFirst()) where next.date.timeIntervalSince(previous.date) > 20 * 60 {
            result.append(JournalEntry(date: previous.date.addingTimeInterval(60), end: next.date, kind: .gap, symbol: "moon.zzz", tint: .secondary,
                                       title: "Nothing recorded", detail: "Your Mac was asleep, or CareMyMac wasn’t running."))
        }

        let today = Calendar.current.startOfDay(for: .now)
        for event in monitor.alertEvents where event.date >= today {
            result.append(JournalEntry(date: event.date, kind: .alert, symbol: "bell.fill", tint: Palette.warning, title: event.title, detail: event.detail))
        }
        for moment in monitor.moments where moment.date >= today {
            result.append(JournalEntry(date: moment.date, kind: .moment, symbol: "bookmark.fill", tint: .accentColor,
                                       title: "You saved a moment", detail: "\(moment.title) · CPU \(Format.percent(moment.snapshot.cpu.total, digits: 0))"))
        }
        result.append(JournalEntry(date: monitor.sessionStart, kind: .start, symbol: "play.circle", tint: Palette.live,
                                   title: "CareMyMac started watching", detail: "Live events below this line are from this session."))
        entries = (entries + result).sorted { $0.date > $1.date }
    }

    func observe(_ monitor: LiveMonitor) {
        guard let snapshot = monitor.snapshot else { return }
        let now = snapshot.date
        var fresh: [JournalEntry] = []

        for app in monitor.apps.prefix(20) where app.kind == .application {
            if app.cpu >= 0.8, hotApps[app.id] == nil {
                hotApps[app.id] = now
                fresh.append(JournalEntry(date: now, kind: .live, symbol: Resource.cpu.symbol, tint: Resource.cpu.color,
                                          title: "\(app.name) started working hard", detail: "\(Format.percent(app.cpu)) CPU across \(Format.processes(app.processes.count)).", appPath: app.bundlePath))
            }
        }
        for (id, since) in hotApps {
            let app = monitor.apps.first { $0.id == id }
            if (app?.cpu ?? 0) < 0.3 {
                hotApps[id] = nil
                let name = app?.name ?? "An app"
                fresh.append(JournalEntry(date: now, kind: .live, symbol: "checkmark.circle", tint: Palette.live,
                                          title: "\(name) calmed down", detail: "It was busy for \(Format.duration(now.timeIntervalSince(since))).", appPath: app?.bundlePath))
            }
        }
        if let lastPressure, lastPressure != snapshot.memory.pressure {
            fresh.append(JournalEntry(date: now, kind: .live, symbol: Resource.memory.symbol, tint: Resource.memory.color,
                                      title: "Memory pressure is now \(snapshot.memory.pressure.label.lowercased())",
                                      detail: "\(Format.memory(snapshot.memory.used)) in use, \(Format.memory(snapshot.memory.swapUsed)) swapped."))
        }
        lastPressure = snapshot.memory.pressure
        let download = snapshot.network.receivedBytesPerSecond
        if download > 5_000_000, downloading == nil {
            downloading = now
            fresh.append(JournalEntry(date: now, kind: .live, symbol: Resource.network.symbol, tint: Resource.network.color,
                                      title: "A big download started", detail: "Receiving \(Format.rate(download))."))
        } else if download < 500_000, let since = downloading {
            downloading = nil
            fresh.append(JournalEntry(date: now, kind: .live, symbol: Resource.network.symbol, tint: Resource.network.color,
                                      title: "The download finished", detail: "It ran for \(Format.duration(now.timeIntervalSince(since)))."))
        }
        if !fresh.isEmpty { entries.insert(contentsOf: fresh.reversed(), at: 0) }
    }
}

private struct JournalRow: View {
    let entry: JournalEntry
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(timeLabel)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 92, alignment: .trailing)
                .padding(.top, 2)
            VStack(spacing: 0) {
                Image(systemName: entry.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(entry.tint)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.background).overlay(Circle().strokeBorder(.separator, lineWidth: 0.5)))
                if !isLast {
                    Rectangle().fill(.separator).frame(width: 1).frame(maxHeight: .infinity)
                }
            }
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title).font(.headline)
                    if let detail = entry.detail {
                        Text(detail).foregroundStyle(.secondary).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if let path = entry.appPath { AppIcon(path: path, size: 28) }
            }
            .padding(.bottom, 22)
            .padding(.top, 2)
        }
        .foregroundStyle(entry.kind == .gap ? .secondary : .primary)
        .accessibilityElement(children: .combine)
    }

    private var timeLabel: String {
        let start = entry.date.formatted(date: .omitted, time: .shortened)
        guard let end = entry.end else { return start }
        return "\(start)–\(end.formatted(date: .omitted, time: .shortened))"
    }
}

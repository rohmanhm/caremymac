import CareMyMacKit
import CareMyMacUI
import SwiftUI

/// Overview: the whole Mac at a glance. One tile per resource (each opens its page), the busiest apps,
/// and the latest alerts and markers.
struct OverviewScreen: View {
    @Environment(LiveMonitor.self) private var monitor
    @Environment(AppModel.self) private var appModel
    @AppStorage("liveRange") private var range: LiveRange = .fiveMinutes

    var body: some View {
        let domain = monitor.domain(range)
        let tiles = tiles(since: domain.lowerBound)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.gap) {
                    VStack(alignment: .leading, spacing: 6) {
                        PageHeader("Overview", subtitle: MacStatus.sentence(for: monitor)) {
                            ThermalBadge()
                            RangePicker()
                        }
                        MachineLine()
                    }

                    tileRow(tiles.live, domain: domain)
                    tileRow(tiles.more, domain: domain)

                    TopApps(sort: .cpu, limit: 5)

                    HStack(alignment: .top, spacing: Metrics.gap) {
                        RecentAlerts()
                        RecentMarkers()
                    }

                    PageFooter()
                        .id(Self.endAnchor)
                }
                .padding(Metrics.pagePadding)
            }
            #if DEBUG
            // The first page of a launch appears before the window is laid out, so wait for it.
            .task {
                guard UserDefaults.standard.bool(forKey: "CareMyMacSnapshotScrollToEnd") else { return }
                try? await Task.sleep(for: .seconds(1))
                proxy.scrollTo(Self.endAnchor, anchor: .bottom)
            }
            #endif
        }
        .pageBackground()
    }

    private static let endAnchor = "overview-end"

    private func tileRow(_ tiles: [OverviewTile], domain: ClosedRange<Date>) -> some View {
        HStack(alignment: .top, spacing: Metrics.gap) {
            ForEach(tiles) { tile in
                OverviewTileView(tile: tile, domain: domain) { open(tile.destination) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func open(_ destination: OverviewTile.Destination) {
        switch destination {
        case .thisMac(let tab):
            appModel.thisMacTab = tab
            appModel.screen = .thisMac
        case .storage:
            appModel.screen = .storage
        }
    }

    /// CPU, Memory, Disk and Network always fill the first row; Storage, then Graphics and Battery when
    /// this Mac reports them, fill the second.
    private func tiles(since: Date) -> (live: [OverviewTile], more: [OverviewTile]) {
        let s = monitor.snapshot
        let series = monitor.series
        let unavailable = Format.unavailable

        let memoryColor: Color? = switch s?.memory.pressure {
        case .critical: Palette.critical
        case .warning: Palette.warningText
        default: nil
        }
        let live = [
            OverviewTile(
                resource: .cpu,
                value: Format.percent(s?.cpu.total),
                detail: s.map { "User \(Format.percent($0.cpu.user)) · System \(Format.percent($0.cpu.system))" } ?? unavailable,
                chart: .series(series.cpu.points(since: since), yMax: 1),
                destination: .thisMac(.cpu)
            ),
            OverviewTile(
                resource: .memory,
                value: s.map { Format.memory($0.memory.used) } ?? unavailable,
                detail: s.map { "of \(Format.memory($0.memory.physical)) · \($0.memory.pressure.label) pressure" } ?? unavailable,
                valueColor: memoryColor,
                chart: .series(series.memoryBytes.points(since: since), yMax: Double(max(monitor.machine.physicalMemory, 1))),
                destination: .thisMac(.memory)
            ),
            OverviewTile(
                resource: .disk,
                value: s.map { Format.rate($0.disk.readBytesPerSecond) } ?? unavailable,
                detail: s.map { "read · \(Format.rate($0.disk.writeBytesPerSecond)) write" } ?? unavailable,
                chart: .series(series.diskRead.points(since: since), secondary: series.diskWrite.points(since: since)),
                destination: .thisMac(.disk)
            ),
            OverviewTile(
                resource: .network,
                value: s.map { Format.rate($0.network.receivedBytesPerSecond) } ?? unavailable,
                detail: s.map { "down · \(Format.rate($0.network.sentBytesPerSecond)) up" } ?? unavailable,
                chart: .series(series.networkIn.points(since: since), secondary: series.networkOut.points(since: since)),
                destination: .thisMac(.network)
            ),
        ]

        let root = monitor.volumes.first(where: \.isRoot)
        var more = [
            OverviewTile(
                resource: .storage,
                value: root.map { "\(Format.bytes($0.availableForImportantUsage)) free" } ?? unavailable,
                detail: root.map { "of \(Format.bytes($0.totalBytes)) · \(Format.percent($0.usedShare, digits: 0)) used" } ?? "Measuring capacity…",
                chart: .capacity(root?.usedShare ?? 0),
                destination: .storage
            ),
        ]
        if let gpu = s?.gpu, let utilization = gpu.utilization {
            more.append(OverviewTile(
                resource: .graphics,
                value: Format.percent(utilization),
                detail: gpu.name,
                chart: .series(series.gpu.points(since: since), yMax: 1),
                destination: .thisMac(.graphics)
            ))
        }
        if let battery = s?.battery {
            let remaining = battery.timeRemaining.flatMap { $0 > 0 ? " · \(Format.duration($0)) left" : nil } ?? ""
            more.append(OverviewTile(
                resource: .battery,
                value: Format.percent(battery.level, digits: 0),
                detail: battery.state.label + remaining,
                chart: .series(series.battery.points(since: since), yMax: 1),
                destination: .thisMac(.battery)
            ))
        }
        return (live, more)
    }
}

/// Model, chip, memory, macOS and uptime, under the title.
private struct MachineLine: View {
    @Environment(LiveMonitor.self) private var monitor

    var body: some View {
        let machine = monitor.machine
        let text = [
            machine.modelName,
            machine.chipName,
            "\(Format.memory(machine.physicalMemory)) memory",
            machine.osVersion,
            "Up \(Format.duration(ProcessInfo.processInfo.systemUptime))",
        ].joined(separator: " · ")
        Label(text, systemImage: machine.symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .help(text)
    }
}

// MARK: - Resource tiles

private struct OverviewTile: Identifiable {
    enum Chart {
        case series(_ primary: [ChartPoint], secondary: [ChartPoint] = [], yMax: Double? = nil)
        /// Used share of a volume, drawn as a bar.
        case capacity(Double)
    }

    enum Destination {
        case thisMac(ThisMacTab)
        case storage
    }

    let resource: Resource
    let value: String
    let detail: String
    var valueColor: Color?
    let chart: Chart
    let destination: Destination

    var id: Resource { resource }
}

/// Current value over the recent trail; the whole tile opens the resource's page.
private struct OverviewTileView: View {
    let tile: OverviewTile
    let domain: ClosedRange<Date>
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        let resource = tile.resource
        Button(action: open) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: resource.symbol)
                        .foregroundStyle(resource.color)
                        .imageScale(.small)
                        .frame(width: 16)
                    Text(resource.title)
                        .foregroundStyle(hovering ? .primary : .secondary)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.forward")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .opacity(hovering ? 1 : 0)
                }
                .font(.callout)

                Text(tile.value)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(tile.valueColor ?? .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(tile.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(tile.detail)

                chart
                    .frame(height: 40)
                    .padding(.top, 6)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .monospacedDigit()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .card(padding: 14)
            .contentShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open \(resource.title)")
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens \(resource.title)")
    }

    @ViewBuilder
    private var chart: some View {
        switch tile.chart {
        case let .series(primary, secondary, yMax):
            SeriesChart(
                primary: primary,
                secondary: secondary,
                color: tile.resource.color,
                secondaryColor: tile.resource.secondaryColor,
                domain: domain,
                yMax: yMax
            )
        case .capacity(let share):
            CapacityBar(share: share)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

// MARK: - Watch

/// The three newest alerts; the page itself marks them read.
private struct RecentAlerts: View {
    @Environment(LiveMonitor.self) private var monitor
    @Environment(AppModel.self) private var appModel
    @AppStorage(SettingsKey.alertsEnabled) private var alertsEnabled = true

    var body: some View {
        let events = monitor.alertEvents.prefix(3)
        SectionCard("Alerts", subtitle: subtitle) {
            Button("Show All") { appModel.screen = .alerts }
                .buttonStyle(.link)
        } content: {
            if events.isEmpty {
                Placeholder(alertsEnabled ? "No alerts. Sustained activity shows up here." : "Alerts are turned off in Settings.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                        if index > 0 { Divider().padding(.leading, 40) }
                        let resource = event.metric.pageResource
                        OverviewEventRow(
                            symbol: event.metric.pageSymbol,
                            resource: resource,
                            title: event.title,
                            date: event.date,
                            isUnread: !event.isRead
                        ) {
                            appModel.screen = .alerts
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var subtitle: String {
        guard alertsEnabled else { return "Turned off" }
        let unread = monitor.unreadAlertCount
        let rules = monitor.alertRules.lazy.filter(\.isEnabled).count
        let watching = rules == 1 ? "1 rule watching" : "\(rules) rules watching"
        return unread > 0 ? "\(unread) unread · \(watching)" : watching
    }
}

/// The three newest markers; a row opens that marker.
private struct RecentMarkers: View {
    @Environment(LiveMonitor.self) private var monitor
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let moments = monitor.moments.prefix(3)
        SectionCard("Markers", subtitle: subtitle) {
            Button("Show All") { appModel.screen = .markers }
                .buttonStyle(.link)
        } content: {
            if moments.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Placeholder("Add Marker (⇧⌘S) keeps the 2 minutes before and 30 seconds after.")
                    Button("Add Marker") { monitor.saveMoment() }
                        .disabled(monitor.pendingMomentDate != nil)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(moments.enumerated()), id: \.element.id) { index, moment in
                        if index > 0 { Divider().padding(.leading, 40) }
                        OverviewEventRow(symbol: "flag", resource: nil, title: moment.displayTitle, date: moment.date, isUnread: false) {
                            appModel.selectedMarkerID = moment.id
                            appModel.screen = .markers
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var subtitle: String {
        if monitor.pendingMomentDate != nil { return "Adding a marker…" }
        let count = monitor.moments.count
        return count == 1 ? "1 marker kept" : "\(count) markers kept"
    }
}

private struct Placeholder: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }
}

/// Icon, title and time; the row opens where the item lives. Items without a resource get a neutral icon.
private struct OverviewEventRow: View {
    let symbol: String
    let resource: Resource?
    let title: String
    let date: Date
    let isUnread: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(resource.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.secondary))
                    .frame(width: 26, height: 26)
                    .background(resource.map { AnyShapeStyle($0.wash) } ?? AnyShapeStyle(.fill.tertiary), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if isUnread {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 7, height: 7)
                                .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                                .offset(x: -2, y: -2)
                        }
                    }
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(title)
                Spacer(minLength: 8)
                Text(stamp)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .background(hovering ? AnyShapeStyle(.fill.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isUnread ? "Unread, \(title), \(stamp)" : "\(title), \(stamp)")
    }

    /// Time today, otherwise the day and time.
    private var stamp: String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

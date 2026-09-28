import AppKit
import CareMyMacKit
import CareMyMacUI
import SwiftUI

// MARK: - Panel

/// The menu bar panel: a one-line status, the last minute of every resource, the busiest apps, and quick actions.
struct MenuBarContent: View {
    @Environment(LiveMonitor.self) private var monitor
    @Environment(Updater.self) private var updater

    var body: some View {
        VStack(spacing: 0) {
            MenuBarHeader()
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)
            Divider()
            MenuBarResources()
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            MenuBarApps()
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            Divider()
            if let version = updater.availableVersion {
                MenuBarUpdate(version: version)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                Divider()
            }
            MenuBarActions()
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(width: 320)
    }
}

private struct MenuBarHeader: View {
    @Environment(LiveMonitor.self) private var monitor

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("CareMyMac").font(.headline)
                Text(MacStatus.sentence(for: monitor))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(MacStatus.sentence(for: monitor))
            }
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                Circle()
                    .fill(monitor.isPaused ? Color.secondary : Palette.live)
                    .frame(width: 6, height: 6)
                Text(monitor.isPaused ? "Paused" : "Live · \(Format.decimal(monitor.interval, digits: 0)) s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// Shown while an update Sparkle found is waiting for the user; Install brings its prompt to the front.
private struct MenuBarUpdate: View {
    let version: String
    @Environment(Updater.self) private var updater

    var body: some View {
        HStack(spacing: 8) {
            Label("CareMyMac \(version) is available", systemImage: "arrow.down.circle")
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Install…") { updater.checkForUpdates() }
                .controlSize(.small)
        }
    }
}

private struct MenuBarResources: View {
    @Environment(LiveMonitor.self) private var monitor

    var body: some View {
        let domain = monitor.domain(.oneMinute)
        let since = domain.lowerBound
        let series = monitor.series
        let snapshot = monitor.snapshot
        VStack(spacing: 8) {
            ResourceRow(resource: .cpu, value: Format.percent(snapshot?.cpu.total), primary: series.cpu.points(since: since), yMax: 1, domain: domain)
            ResourceRow(resource: .memory, value: snapshot.map { Format.memory($0.memory.used) } ?? Format.unavailable,
                        primary: series.memory.points(since: since), yMax: 1, domain: domain)
            ResourceRow(resource: .disk, value: snapshot.map { Format.rate($0.disk.readBytesPerSecond + $0.disk.writeBytesPerSecond) } ?? Format.unavailable,
                        primary: series.diskRead.points(since: since), secondary: series.diskWrite.points(since: since), domain: domain)
            ResourceRow(resource: .network, value: snapshot.map { Format.rate($0.network.receivedBytesPerSecond + $0.network.sentBytesPerSecond) } ?? Format.unavailable,
                        primary: series.networkIn.points(since: since), secondary: series.networkOut.points(since: since), domain: domain)
            if let gpu = snapshot?.gpu {
                ResourceRow(resource: .graphics, title: "GPU", value: Format.percent(gpu.utilization), primary: series.gpu.points(since: since), yMax: 1, domain: domain)
            }
            if let battery = snapshot?.battery {
                ResourceRow(resource: .battery, value: Format.percent(battery.level, digits: 0), primary: series.battery.points(since: since), yMax: 1, domain: domain)
            }
        }
    }
}

private struct ResourceRow: View {
    let resource: Resource
    var title: String?
    let value: String
    let primary: [ChartPoint]
    var secondary: [ChartPoint] = []
    var yMax: Double?
    let domain: ClosedRange<Date>

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: resource.symbol)
                    .foregroundStyle(resource.color)
                    .frame(width: 18)
                Text(title ?? resource.title)
            }
            .font(.callout)
            .frame(width: 92, alignment: .leading)

            SeriesChart(primary: primary, secondary: secondary, color: resource.color, secondaryColor: resource.secondaryColor, domain: domain, yMax: yMax)
                .frame(height: 22)
                .accessibilityHidden(true)

            Text(value)
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .frame(width: 76, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MenuBarApps: View {
    @Environment(LiveMonitor.self) private var monitor
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let apps = Array(monitor.apps.prefix(5))
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Busiest apps")
                Spacer()
                Text("CPU")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.bottom, 2)

            if apps.isEmpty {
                Text("Measuring…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ForEach(apps) { app in
                    MenuBarAppRow(app: app) {
                        appModel.show(app)
                        openWindow(id: WindowID.main)
                        NSApp.activate()
                    }
                }
            }
        }
    }
}

private struct MenuBarAppRow: View {
    let app: AppActivity
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                AppIcon(app: app, size: 18)
                Text(app.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text(Format.percent(app.cpu))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(isHovered ? AnyShapeStyle(.fill.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("\(app.name) · show details in CareMyMac")
    }
}

private struct MenuBarActions: View {
    @Environment(LiveMonitor.self) private var monitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 6) {
            Button("Open CareMyMac") {
                openWindow(id: WindowID.main)
                NSApp.activate()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)

            Button(monitor.isPaused ? "Resume" : "Pause", systemImage: monitor.isPaused ? "play.fill" : "pause.fill") {
                monitor.togglePause()
            }
            .help(monitor.isPaused ? "Resume monitoring" : "Pause monitoring")

            Button("Add Marker", systemImage: monitor.pendingMomentDate == nil ? "flag" : "flag.fill") {
                monitor.saveMoment()
            }
            .help(monitor.pendingMomentDate == nil ? "Flag this point in time, keeping the 2 minutes before it" : "Adding marker… capturing the next 30 seconds")
            .disabled(monitor.pendingMomentDate != nil || monitor.snapshot == nil)

            Spacer(minLength: 0)

            SettingsLink {
                Label("Settings…", systemImage: "gearshape")
            }
            .help("CareMyMac settings")

            Button("Quit CareMyMac", systemImage: "power") {
                NSApp.terminate(nil)
            }
            .help("Quit CareMyMac")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }
}

// MARK: - Status item label

/// The status item: the chosen metric as a figure, a tiny graph, or just the icon.
struct MenuBarLabel: View {
    @AppStorage(SettingsKey.menuBarMetric) private var metric: MenuBarMetric = .cpu
    @AppStorage(SettingsKey.menuBarStyle) private var style: MenuBarStyle = .figure

    var body: some View {
        switch style {
        case .icon:
            Image(systemName: "waveform.path.ecg")
                .accessibilityLabel("CareMyMac")
        case .figure:
            MenuBarFigure(metric: metric)
        case .graph:
            MenuBarGraph(metric: metric)
        }
    }
}

private struct MenuBarFigure: View {
    @Environment(LiveMonitor.self) private var monitor
    let metric: MenuBarMetric

    var body: some View {
        let value = MenuBarReading.value(of: metric, in: monitor.snapshot)
        HStack(spacing: 4) {
            Image(systemName: metric.resource.symbol)
            Text(value).monospacedDigit()
        }
        .accessibilityLabel("CareMyMac, \(metric.title) \(value)")
    }
}

private struct MenuBarGraph: View {
    @Environment(LiveMonitor.self) private var monitor
    let metric: MenuBarMetric
    @State private var image: NSImage?

    var body: some View {
        // Only the latest sample date is read here, so the image is rebuilt at most once per tick.
        Image(nsImage: image ?? MenuBarReading.graph([]))
            .accessibilityLabel("CareMyMac, \(metric.title) graph")
            .task(id: GraphKey(metric: metric, date: monitor.snapshot?.date)) {
                image = MenuBarReading.graph(MenuBarReading.recent(metric, in: monitor.series))
            }
    }

    private struct GraphKey: Equatable {
        let metric: MenuBarMetric
        let date: Date?
    }
}

/// Values and the template graph drawn in the status item.
@MainActor
enum MenuBarReading {
    static let graphSamples = 18
    static let graphSize = CGSize(width: 36, height: 16)

    static func value(of metric: MenuBarMetric, in snapshot: SystemSnapshot?) -> String {
        guard let s = snapshot else { return Format.unavailable }
        switch metric {
        case .cpu: return Format.percent(s.cpu.total, digits: 0)
        case .memory: return Format.memory(s.memory.used)
        case .gpu: return Format.percent(s.gpu?.utilization, digits: 0)
        case .network: return Format.rate(s.network.receivedBytesPerSecond + s.network.sentBytesPerSecond)
        case .battery: return Format.percent(s.battery?.level, digits: 0)
        }
    }

    /// Last samples scaled to 0...1: fractions as is, network against its own recent peak.
    static func recent(_ metric: MenuBarMetric, in series: LiveSeries) -> [Double] {
        func tail(_ s: TimeSeries<Double>) -> [Double] {
            s.points.suffix(graphSamples).map(\.value)
        }
        switch metric {
        case .cpu: return tail(series.cpu)
        case .memory: return tail(series.memory)
        case .gpu: return tail(series.gpu)
        case .battery: return tail(series.battery)
        case .network:
            let down = tail(series.networkIn)
            let up = tail(series.networkOut)
            let total = zip(down, up).map { $0 + $1 }
            // Floor keeps an idle network flat instead of amplifying noise.
            let peak = max(total.max() ?? 0, 50_000)
            return total.map { $0 / peak }
        }
    }

    /// Bars on a faint baseline, as a template image so macOS tints it for the menu bar.
    static func graph(_ values: [Double]) -> NSImage {
        let size = graphSize
        let image = NSImage(size: size, flipped: false) { rect in
            let slot = rect.width / CGFloat(graphSamples)
            let barWidth = slot - 0.5
            NSColor.black.withAlphaComponent(0.35).setFill()
            NSRect(x: 0, y: 0, width: rect.width, height: 1).fill()
            NSColor.black.setFill()
            let offset = graphSamples - values.count
            for (index, value) in values.enumerated() {
                let height = max(1, CGFloat(min(max(value, 0), 1)) * (rect.height - 1))
                let x = CGFloat(offset + index) * slot
                NSRect(x: x, y: 1, width: barWidth, height: height).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Recent activity"
        return image
    }
}

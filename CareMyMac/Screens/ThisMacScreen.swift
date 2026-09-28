import CareMyMacKit
import CareMyMacUI
import SwiftUI

/// This Mac: every resource on one clock ("All"), or one resource in depth.
/// The tabs ride in a bar above the page, so the toolbar keeps room for pause and Add Marker at any width.
struct ThisMacScreen: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel
        Group {
            switch appModel.thisMacTab {
            case .all: ThisMacSummary()
            case .cpu: CPUScreen()
            case .memory: MemoryScreen()
            case .disk: DiskScreen()
            case .network: NetworkScreen()
            case .graphics: GraphicsScreen()
            case .battery: BatteryScreen()
            }
        }
        .safeAreaBar(edge: .top) {
            Picker("Resource", selection: $appModel.thisMacTab) {
                ForEach(ThisMacTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }
}

/// Every resource on one shared clock; one cursor scrubs them all. The top apps sit right underneath.
private struct ThisMacSummary: View {
    @Environment(LiveMonitor.self) private var monitor
    @AppStorage("liveRange") private var range: LiveRange = .fiveMinutes
    @State private var scrub = ScrubState()

    var body: some View {
        let domain = monitor.domain(range)
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                PageHeader("This Mac", subtitle: MacStatus.sentence(for: monitor)) {
                    ThermalBadge()
                    RangePicker()
                }

                VStack(spacing: 0) {
                    ScrubClock(scrub: scrub, domain: domain)
                    ForEach(lanes(domain: domain)) { lane in
                        Divider().padding(.leading, 16)
                        LaneRow(lane: lane, domain: domain, scrub: scrub)
                    }
                }
                .card(padding: nil)

                TopApps(sort: .cpu)

                PageFooter()
            }
            .padding(Metrics.pagePadding)
        }
        .pageBackground()
    }

    private func lanes(domain: ClosedRange<Date>) -> [Lane] {
        let since = domain.lowerBound
        let series = monitor.series
        var lanes = [
            Lane(resource: .cpu, primary: series.cpu.points(since: since), yMax: 1, format: { Format.percent($0) }, tab: .cpu),
            Lane(resource: .memory, primary: series.memoryBytes.points(since: since), yMax: Double(max(monitor.machine.physicalMemory, 1)), format: { Format.memory($0) }, tab: .memory),
            Lane(resource: .disk, primary: series.diskRead.points(since: since), secondary: series.diskWrite.points(since: since), primaryLabel: "read", secondaryLabel: "write", format: Format.rate, tab: .disk),
            Lane(resource: .network, primary: series.networkIn.points(since: since), secondary: series.networkOut.points(since: since), primaryLabel: "down", secondaryLabel: "up", format: Format.rate, tab: .network),
        ]
        if !series.gpu.isEmpty {
            lanes.append(Lane(resource: .graphics, primary: series.gpu.points(since: since), yMax: 1, format: { Format.percent($0) }, tab: .graphics))
        }
        if !series.battery.isEmpty {
            lanes.append(Lane(resource: .battery, primary: series.battery.points(since: since), yMax: 1, format: { Format.percent($0, digits: 0) }, tab: .battery))
        }
        return lanes
    }
}

private struct Lane: Identifiable {
    let resource: Resource
    let primary: [ChartPoint]
    var secondary: [ChartPoint] = []
    var yMax: Double?
    var primaryLabel: String?
    var secondaryLabel: String?
    let format: (Double) -> String
    let tab: ThisMacTab

    var id: Resource { resource }
}

/// "Now" or the hovered time, above the lanes.
private struct ScrubClock: View {
    let scrub: ScrubState
    let domain: ClosedRange<Date>

    var body: some View {
        HStack {
            if let date = scrub.date {
                Text(date, format: .dateTime.hour().minute().second())
                    .foregroundStyle(.primary)
            } else {
                Text("Now · hover a lane to look back")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(domain.lowerBound.formatted(date: .omitted, time: .shortened)) – \(domain.upperBound.formatted(date: .omitted, time: .shortened))")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .monospacedDigit()
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct LaneRow: View {
    let lane: Lane
    let domain: ClosedRange<Date>
    let scrub: ScrubState
    @Environment(AppModel.self) private var appModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button {
                appModel.thisMacTab = lane.tab
            } label: {
                LaneReadout(lane: lane, scrub: scrub, emphasized: hovering)
                    .frame(width: 200, alignment: .leading)
                    .padding(.leading, 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Open \(lane.resource.title)")

            SeriesChart(
                primary: lane.primary,
                secondary: lane.secondary,
                color: lane.resource.color,
                secondaryColor: lane.resource.secondaryColor,
                domain: domain,
                yMax: lane.yMax,
                scrub: scrub
            )
            .padding(.vertical, 10)
            .padding(.trailing, 16)
            .accessibilityHidden(true)
        }
        .frame(height: 72)
    }
}

/// Lane label and value; reads the scrub cursor so only this re-renders on hover.
private struct LaneReadout: View {
    let lane: Lane
    let scrub: ScrubState
    let emphasized: Bool

    var body: some View {
        let date = scrub.date
        let primary = date.map { SeriesMath.value(in: lane.primary, at: $0) } ?? lane.primary.last?.value
        let secondary = lane.secondary.isEmpty ? nil : (date.map { SeriesMath.value(in: lane.secondary, at: $0) } ?? lane.secondary.last?.value)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: lane.resource.symbol)
                    .foregroundStyle(lane.resource.color)
                    .imageScale(.small)
                    .frame(width: 16)
                Text(lane.resource.title)
                    .foregroundStyle(emphasized ? .primary : .secondary)
                Image(systemName: "chevron.forward")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(emphasized ? 1 : 0)
            }
            .font(.callout)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(primary.map(lane.format) ?? Format.unavailable)
                    .font(.title3.weight(.semibold))
                if let label = lane.primaryLabel {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                }
                if let secondary, let label = lane.secondaryLabel {
                    Text("· \(lane.format(secondary)) \(label)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

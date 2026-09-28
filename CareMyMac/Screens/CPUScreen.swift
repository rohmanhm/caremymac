import CareMyMacKit
import CareMyMacUI
import SwiftUI

/// Reference layout for resource pages: header, chart card, tiles, then the top apps.
struct CPUScreen: View {
    @Environment(LiveMonitor.self) private var monitor
    @AppStorage("liveRange") private var range: LiveRange = .fiveMinutes
    @State private var scrub = ScrubState()

    var body: some View {
        let s = monitor.snapshot
        let domain = monitor.domain(range)
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                PageHeader("CPU", subtitle: "Processor activity, with every helper included.") {
                    ThermalBadge()
                }

                ResourceChartCard(
                    title: "CPU activity",
                    subtitle: "Across all \(monitor.machine.coreCount) cores",
                    resource: .cpu,
                    primary: ChartSeries(label: "CPU", points: monitor.series.cpu.points(since: domain.lowerBound)),
                    yMax: 1,
                    format: { Format.percent($0) },
                    scrub: scrub,
                    domain: domain
                )

                HStack(alignment: .top, spacing: Metrics.gap) {
                    StatTile("Total", value: Format.percent(s?.cpu.total))
                    StatTile("User", value: Format.percent(s?.cpu.user))
                    StatTile("System", value: Format.percent(s?.cpu.system))
                    StatTile("Load", value: s?.cpu.loadAverage.first.map { Format.decimal($0) } ?? Format.unavailable, detail: "1-minute average")
                    CoresCard(cpu: s?.cpu)
                        .frame(minWidth: 260)
                }
                .fixedSize(horizontal: false, vertical: true)

                TopApps(sort: .cpu)

                PageFooter()
            }
            .padding(Metrics.pagePadding)
        }
        .pageBackground()
    }
}

/// One bar per core, performance cores first.
private struct CoresCard: View {
    let cpu: CPUStats?

    var body: some View {
        let cores = cpu?.cores ?? []
        let performance = cpu?.performanceCoreCount
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Cores").font(.callout).foregroundStyle(.secondary)
                Spacer()
                if let performance, let efficiency = cpu?.efficiencyCoreCount {
                    Text("\(performance) performance · \(efficiency) efficiency")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(cores.enumerated()), id: \.offset) { index, core in
                    CoreBar(load: core.total, isEfficiency: performance.map { index >= $0 } ?? false)
                }
            }
            .frame(height: 34)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .card(padding: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Per-core load")
        .accessibilityValue(cores.map { Format.percent($0.total, digits: 0) }.joined(separator: ", "))
    }
}

private struct CoreBar: View {
    let load: Double
    let isEfficiency: Bool

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(isEfficiency ? Resource.cpu.secondaryColor : Resource.cpu.color)
                    .frame(height: max(2, geometry.size.height * min(max(load, 0), 1)))
            }
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 2, style: .continuous).fill(.fill.tertiary))
        }
    }
}

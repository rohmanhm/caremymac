import CareMyMacKit
import CareMyMacUI
import SwiftUI

/// GPU activity, when the driver reports it.
struct GraphicsScreen: View {
    @Environment(LiveMonitor.self) private var monitor
    @AppStorage("liveRange") private var range: LiveRange = .fiveMinutes
    @State private var scrub = ScrubState()

    var body: some View {
        let gpu = monitor.snapshot?.gpu
        let domain = monitor.domain(range)
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                PageHeader("Graphics", subtitle: "Graphics activity reported by this Mac.") {
                    ThermalBadge()
                }

                if let gpu, let utilization = gpu.utilization {
                    ResourceChartCard(
                        title: "GPU activity",
                        subtitle: gpu.name,
                        resource: .graphics,
                        primary: ChartSeries(label: "GPU", points: monitor.series.gpu.points(since: domain.lowerBound)),
                        yMax: 1,
                        format: { Format.percent($0) },
                        scrub: scrub,
                        domain: domain
                    )

                    HStack(alignment: .top, spacing: Metrics.gap) {
                        StatTile("GPU activity", value: Format.percent(utilization))
                        if let renderer = gpu.rendererUtilization {
                            StatTile("Renderer", value: Format.percent(renderer))
                        }
                        if let tiler = gpu.tilerUtilization {
                            StatTile("Tiler", value: Format.percent(tiler))
                        }
                        StatTile("GPU memory", value: gpu.memoryInUse.map { Format.memory($0) } ?? Format.unavailable, detail: "Driver-reported")
                        StatTile("Thermal state", value: monitor.thermalState.label)
                    }
                    .fixedSize(horizontal: false, vertical: true)

                    SectionCard("Device") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) {
                                Image(systemName: Resource.graphics.symbol)
                                    .font(.title2)
                                    .foregroundStyle(Resource.graphics.color)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(gpu.name).font(.headline)
                                    Text(gpu.coreCount.map { "\($0) GPU cores" } ?? "Core count not reported")
                                        .font(.callout)
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text("GPU memory is unified memory reported by the graphics driver — it's part of your installed RAM, not extra. macOS doesn't attribute GPU time to individual apps, so there's no app list here.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    EmptyStateView(
                        "GPU activity isn't available",
                        symbol: Resource.graphics.symbol,
                        message: "This Mac's graphics driver doesn't expose an activity counter, so there's nothing to chart. Other pages keep working as usual."
                    )
                    .card()
                }

                PageFooter()
            }
            .padding(Metrics.pagePadding)
        }
        .pageBackground()
    }
}

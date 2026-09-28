import CareMyMacKit
import CareMyMacUI
import SwiftUI

/// Disk throughput and mounted volumes.
struct DiskScreen: View {
    @Environment(LiveMonitor.self) private var monitor
    @AppStorage("liveRange") private var range: LiveRange = .fiveMinutes
    @State private var scrub = ScrubState()

    var body: some View {
        let d = monitor.snapshot?.disk
        let domain = monitor.domain(range)
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                PageHeader("Disk", subtitle: "Storage capacity and live read/write activity.") {
                    ThermalBadge()
                }

                ResourceChartCard(
                    title: "Disk activity",
                    subtitle: "Reads and writes across all disks",
                    resource: .disk,
                    primary: ChartSeries(label: "Read", points: monitor.series.diskRead.points(since: domain.lowerBound)),
                    secondary: ChartSeries(label: "Write", points: monitor.series.diskWrite.points(since: domain.lowerBound)),
                    yMax: nil,
                    format: { Format.rate($0) },
                    scrub: scrub,
                    domain: domain
                )

                HStack(alignment: .top, spacing: Metrics.gap) {
                    StatTile("Reading", value: d.map { Format.rate($0.readBytesPerSecond) } ?? Format.unavailable,
                             detail: d.map { "\(Format.bytes($0.totalRead)) since startup" })
                    StatTile("Writing", value: d.map { Format.rate($0.writeBytesPerSecond) } ?? Format.unavailable,
                             detail: d.map { "\(Format.bytes($0.totalWritten)) since startup" })
                    StatTile("Mounted volumes", value: Format.integer(monitor.volumes.count),
                             detail: "\(monitor.volumes.filter(\.isInternal).count) internal")
                }
                .fixedSize(horizontal: false, vertical: true)

                SectionCard("Volumes", subtitle: "Capacity of every mounted volume") {
                    if monitor.volumes.isEmpty {
                        EmptyStateView("No volumes yet", symbol: "internaldrive", message: "Mounted disks appear here after the first sample, a few seconds after launch.")
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(monitor.volumes.enumerated()), id: \.element.id) { index, volume in
                                if index > 0 { Divider() }
                                VolumeRow(volume: volume)
                            }
                            Text("APFS volumes in one container share free space, so their available amounts can overlap.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 10)
                        }
                    }
                }

                TopApps(sort: .disk)

                PageFooter()
            }
            .padding(Metrics.pagePadding)
        }
        .pageBackground()
    }
}

private struct VolumeRow: View {
    let volume: VolumeStats

    var body: some View {
        let share = volume.totalBytes > 0 ? Double(volume.usedBytes) / Double(volume.totalBytes) : 0
        HStack(spacing: 12) {
            Image(systemName: volume.isRemovable ? "externaldrive" : "internaldrive")
                .font(.title2)
                .foregroundStyle(Resource.disk.color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(volume.name).font(.headline).lineLimit(1).help(volume.name)
                    Spacer()
                    Text("\(Format.bytes(volume.availableForImportantUsage)) available of \(Format.bytes(volume.totalBytes))")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                LevelBar(value: share, color: Resource.disk.color)
                    .accessibilityLabel("\(volume.name) used")
                HStack {
                    Text(volume.id).lineLimit(1).truncationMode(.middle).help(volume.id)
                    Spacer()
                    Text([volume.format, volume.isInternal ? "Internal" : "External"].compactMap { $0 }.joined(separator: " · "))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
    }
}

/// Capsule capacity bar tinted with the resource color.
private struct LevelBar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.fill.tertiary)
                Capsule().fill(color)
                    .frame(width: geometry.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 6)
        .accessibilityValue(Format.percent(value, digits: 0))
    }
}

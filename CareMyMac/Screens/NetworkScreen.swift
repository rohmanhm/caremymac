import CareMyMacKit
import CareMyMacUI
import SwiftUI

/// Network throughput and per-interface traffic.
struct NetworkScreen: View {
    @Environment(LiveMonitor.self) private var monitor
    @AppStorage("liveRange") private var range: LiveRange = .fiveMinutes
    @State private var scrub = ScrubState()

    var body: some View {
        let n = monitor.snapshot?.network
        let domain = monitor.domain(range)
        let interfaces = (n?.interfaces ?? [])
            .filter { $0.kind != .loopback }
            .sorted { lhs, rhs in
                let l = Self.isPhysical(lhs), r = Self.isPhysical(rhs)
                if l != r { return l }
                if lhs.isUp != rhs.isUp { return lhs.isUp }
                return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
            }
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                PageHeader("Network", subtitle: "Traffic across your active network interfaces.") {
                    ThermalBadge()
                }

                ResourceChartCard(
                    title: "Network traffic",
                    subtitle: "Download and upload across all interfaces",
                    resource: .network,
                    primary: ChartSeries(label: "Download", points: monitor.series.networkIn.points(since: domain.lowerBound)),
                    secondary: ChartSeries(label: "Upload", points: monitor.series.networkOut.points(since: domain.lowerBound)),
                    yMax: nil,
                    format: { Format.rate($0) },
                    scrub: scrub,
                    domain: domain
                )

                HStack(alignment: .top, spacing: Metrics.gap) {
                    StatTile("Download", value: n.map { Format.rate($0.receivedBytesPerSecond) } ?? Format.unavailable)
                    StatTile("Upload", value: n.map { Format.rate($0.sentBytesPerSecond) } ?? Format.unavailable)
                    StatTile("Active interfaces", value: Format.integer(interfaces.filter(\.isUp).count),
                             detail: "\(interfaces.count) total")
                }
                .fixedSize(horizontal: false, vertical: true)

                SectionCard("Interfaces", subtitle: "Physical first, then virtual") {
                    if interfaces.isEmpty {
                        EmptyStateView("No interfaces yet", symbol: "network", message: "Network interfaces appear here after the first sample, a few seconds after launch.")
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            InterfaceColumns {
                                Text("Interface")
                                Text("Address")
                                Text("Download").frame(maxWidth: .infinity, alignment: .trailing)
                                Text("Upload").frame(maxWidth: .infinity, alignment: .trailing)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 6)
                            Divider()
                            LazyVStack(spacing: 0) {
                                ForEach(interfaces) { interface in
                                    InterfaceRow(interface: interface)
                                    Divider()
                                }
                            }
                            Text("Traffic is measured per interface. macOS doesn't expose per-app network usage without a network extension, so there's no app list here.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 10)
                        }
                    }
                }

                PageFooter()
            }
            .padding(Metrics.pagePadding)
        }
        .pageBackground()
    }

    private static func isPhysical(_ interface: NetworkInterfaceStats) -> Bool {
        interface.kind == .wifi || interface.kind == .ethernet || interface.kind == .cellular
    }
}

/// Shared column widths for the header and rows.
private struct InterfaceColumns<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Group(subviews: content) { subviews in
                ForEach(Array(subviews.enumerated()), id: \.offset) { index, subview in
                    subview.frame(width: index < 2 ? nil : 110, alignment: index < 2 ? .leading : .trailing)
                        .frame(maxWidth: index < 2 ? .infinity : nil, alignment: .leading)
                }
            }
        }
    }
}

private struct InterfaceRow: View {
    let interface: NetworkInterfaceStats

    var body: some View {
        let ipv4 = interface.addresses.first { !$0.contains(":") }
        let ipv6 = interface.addresses.first { $0.contains(":") }
        InterfaceColumns {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(interface.isUp ? Resource.network.color : Color.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(interface.displayName).lineLimit(1).help(interface.displayName)
                    Text(([interface.displayName == interface.id ? nil : interface.id, interface.kind.label, interface.isUp ? nil : "Inactive"] as [String?]).compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(ipv4 ?? ipv6 ?? "No address")
                    .foregroundStyle(ipv4 ?? ipv6 == nil ? .secondary : .primary)
                if ipv4 != nil, let ipv6 {
                    Text(ipv6).font(.caption).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .truncationMode(.middle)
            .help(interface.addresses.joined(separator: "\n"))
            RateCell(rate: interface.receivedBytesPerSecond, total: interface.totalReceived)
            RateCell(rate: interface.sentBytesPerSecond, total: interface.totalSent)
        }
        .font(.callout)
        .padding(.vertical, 8)
    }

    private var symbol: String {
        switch interface.kind {
        case .wifi: "wifi"
        case .ethernet: "cable.connector"
        case .cellular: "antenna.radiowaves.left.and.right"
        case .vpn: "lock.shield"
        case .bridge: "point.3.connected.trianglepath.dotted"
        case .loopback, .other: "network"
        }
    }
}

private struct RateCell: View {
    let rate: Double
    let total: UInt64

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(Format.rate(rate))
            Text("\(Format.bytes(total)) total").font(.caption).foregroundStyle(.secondary)
        }
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

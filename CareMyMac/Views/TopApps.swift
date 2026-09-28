import CareMyMacKit
import CareMyMacUI
import SwiftUI

/// The few apps using the most of one resource. Rows open the app; "Show All" opens the sorted app list.
struct TopApps: View {
    let sort: AppSort
    var limit = 6
    @Environment(LiveMonitor.self) private var monitor
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let apps = Array(sort.sorted(monitor.apps).prefix(limit))
        let scale = max(apps.first.map(amount) ?? 0, floor)
        SectionCard("Top Apps", subtitle: subtitle) {
            Button("Show All") { appModel.showApps(sortedBy: sort) }
                .buttonStyle(.link)
        } content: {
            if apps.isEmpty {
                Text("Measuring…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                        if index > 0 { Divider().padding(.leading, 34) }
                        TopAppRow(
                            app: app,
                            value: value(app),
                            detail: detail(app),
                            fraction: min(amount(app) / scale, 1),
                            color: resource.color
                        ) {
                            appModel.show(app)
                        }
                    }
                }
            }
        }
    }

    private var resource: Resource {
        switch sort {
        case .cpu, .name: .cpu
        case .memory: .memory
        case .disk: .disk
        }
    }

    private var subtitle: String {
        switch sort {
        case .cpu, .name: "By CPU right now, helpers included"
        case .memory: "By memory right now, helpers included"
        case .disk: "By disk reads and writes right now"
        }
    }

    /// Bars are relative to the top app, but never stretch a tiny top value to full width.
    private var floor: Double {
        switch sort {
        case .cpu, .name: 1
        case .memory: 1e9
        case .disk: 1e6
        }
    }

    private func amount(_ app: AppActivity) -> Double {
        switch sort {
        case .cpu, .name: app.cpu
        case .memory: Double(app.memory)
        case .disk: app.diskReadBytesPerSecond + app.diskWriteBytesPerSecond
        }
    }

    private func value(_ app: AppActivity) -> String {
        switch sort {
        case .cpu, .name: Format.percent(app.cpu)
        case .memory: Format.memory(app.memory)
        case .disk: Format.rate(amount(app))
        }
    }

    private func detail(_ app: AppActivity) -> String {
        switch sort {
        case .cpu, .name: Format.memory(app.memory)
        case .memory: Format.percent(app.cpu)
        case .disk: "\(Format.rate(app.diskWriteBytesPerSecond)) write"
        }
    }
}

private struct TopAppRow: View {
    let app: AppActivity
    let value: String
    let detail: String
    let fraction: Double
    let color: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AppIcon(app: app, size: 22)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(app.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(app.name)
                        Text(Format.processes(app.processes.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Text(value)
                            .monospacedDigit()
                            .frame(width: 84, alignment: .trailing)
                        Text(detail)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 96, alignment: .trailing)
                    }
                    ShareBar(fraction: fraction, color: color)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .background(hovering ? AnyShapeStyle(.fill.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(app.name), \(value), \(detail)")
        .accessibilityHint("Shows the app and its processes")
    }
}

private struct ShareBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        Capsule()
            .fill(.fill.tertiary)
            .frame(height: 3)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule()
                        .fill(color)
                        .frame(width: max(3, geometry.size.width * fraction))
                }
            }
            .accessibilityHidden(true)
    }
}

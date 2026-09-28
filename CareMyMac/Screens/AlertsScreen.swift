import CareMyMacKit
import CareMyMacUI
import SwiftUI

/// Alert events grouped by day, the rules that produce them, and the rules editor.
struct AlertsScreen: View {
    @Environment(LiveMonitor.self) private var monitor
    @AppStorage(SettingsKey.alertsEnabled) private var alertsEnabled = true
    @State private var showsEditor = false
    /// Events that were unread when they reached this page; they keep their dot until the page closes.
    @State private var unseen: Set<UUID> = []

    var body: some View {
        let events = monitor.alertEvents
        let enabledRules = monitor.alertRules.filter(\.isEnabled)
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                PageHeader("Alerts", subtitle: "Sustained activity that may need your attention.") {
                    Button("Configure alerts…", systemImage: "slider.horizontal.3") { showsEditor = true }
                }

                if !alertsEnabled {
                    AlertsOffNotice()
                } else if !enabledRules.isEmpty {
                    RulesSummary(rules: enabledRules)
                }

                if events.isEmpty {
                    EmptyStateView("No alerts", symbol: "bell", message: emptyMessage(enabledCount: enabledRules.count)) {
                        Button("Configure alerts…") { showsEditor = true }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .card()
                } else {
                    ForEach(AlertDay.group(events)) { day in
                        AlertDayCard(day: day, unseen: unseen) { monitor.dismissAlert(id: $0) }
                    }
                }

                PageFooter(note: "Alerts for the same app and condition are limited to one every 10 minutes.")
            }
            .padding(Metrics.pagePadding)
        }
        .pageBackground()
        .sheet(isPresented: $showsEditor) {
            AlertRulesEditor()
                .frame(width: 560, height: 520)
        }
        .onAppear {
            markSeen()
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "CareMyMacOpenRuleEditor") { showsEditor = true }
            #endif
        }
        .onChange(of: monitor.unreadAlertCount) { markSeen() }
    }

    private func markSeen() {
        unseen.formUnion(monitor.alertEvents.lazy.filter { !$0.isRead }.map(\.id))
        monitor.markAlertsRead()
    }

    private func emptyMessage(enabledCount: Int) -> String {
        switch enabledCount {
        case 0: "No alert rules are turned on. Turn one on to hear about sustained CPU, memory growth, or low battery."
        case 1: "1 rule is watching for sustained activity. When it holds long enough, the alert appears here."
        default: "\(enabledCount) rules are watching for sustained activity. When one holds long enough, the alert appears here."
        }
    }
}

// MARK: - Grouping

private struct AlertDay: Identifiable {
    let id: Date
    let events: [AlertEvent]

    var title: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(id) { return "Today" }
        if calendar.isDateInYesterday(id) { return "Yesterday" }
        let sameYear = calendar.isDate(id, equalTo: .now, toGranularity: .year)
        return sameYear
            ? id.formatted(.dateTime.weekday(.wide).month(.wide).day())
            : id.formatted(.dateTime.month(.wide).day().year())
    }

    /// Events arrive newest first; days keep that order.
    static func group(_ events: [AlertEvent]) -> [AlertDay] {
        let calendar = Calendar.current
        var days: [AlertDay] = []
        var current: (day: Date, events: [AlertEvent])?
        for event in events {
            let day = calendar.startOfDay(for: event.date)
            if current?.day == day {
                current?.events.append(event)
            } else {
                if let current { days.append(AlertDay(id: current.day, events: current.events)) }
                current = (day, [event])
            }
        }
        if let current { days.append(AlertDay(id: current.day, events: current.events)) }
        return days
    }
}

// MARK: - Cards

private struct AlertDayCard: View {
    let day: AlertDay
    let unseen: Set<UUID>
    let dismiss: (UUID) -> Void

    var body: some View {
        SectionCard(day.title) {
            Text(day.events.count == 1 ? "1 alert" : "\(day.events.count) alerts")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        } content: {
            VStack(spacing: 0) {
                ForEach(Array(day.events.enumerated()), id: \.element.id) { index, event in
                    if index > 0 { Divider().padding(.leading, 44) }
                    AlertEventRow(event: event, isUnread: unseen.contains(event.id)) { dismiss(event.id) }
                }
            }
        }
    }
}

private struct AlertEventRow: View {
    let event: AlertEvent
    let isUnread: Bool
    let dismiss: () -> Void

    var body: some View {
        let resource = event.metric.pageResource
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.metric.pageSymbol)
                .font(.body.weight(.medium))
                .foregroundStyle(resource.color)
                .frame(width: 32, height: 32)
                .background(resource.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if isUnread {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 8, height: 8)
                            .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                            .offset(x: -3, y: -3)
                            .accessibilityLabel("Unread")
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .help(event.title)
                Text(event.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(2)
                    .help(event.detail)
            }
            Spacer(minLength: 12)
            Text(event.date, format: .dateTime.hour().minute())
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .padding(.top, 1)
            Button("Dismiss alert", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Dismiss alert")
                .padding(.top, 1)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

/// One line listing what is being watched.
private struct RulesSummary: View {
    let rules: [AlertRule]

    var body: some View {
        let text = rules.map(\.summary).joined(separator: " · ")
        Label {
            Text("Watching: \(text)")
                .lineLimit(2)
                .help(text)
        } icon: {
            Image(systemName: "checklist")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
}

private struct AlertsOffNotice: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.slash")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("Alerts are turned off").fontWeight(.medium)
                Text("CareMyMac isn't checking your rules. Turn alerts on in Settings to hear about sustained activity again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            SettingsLink { Text("Open Settings…") }
        }
        .card(padding: 14)
    }
}

// MARK: - Metric presentation

extension AlertMetric {
    /// Resource whose hue tints this metric's icon.
    var pageResource: Resource {
        switch self {
        case .cpu, .appCPU: .cpu
        case .memoryPressure, .memoryUsedFraction, .swapUsed, .appMemory, .appMemoryGrowth: .memory
        case .gpu: .graphics
        case .batteryLevel: .battery
        case .diskWrite: .disk
        case .networkIn: .network
        }
    }

    var pageSymbol: String {
        switch self {
        case .cpu: "cpu"
        case .appCPU: "waveform.path.ecg"
        case .memoryPressure: "gauge.with.dots.needle.67percent"
        case .memoryUsedFraction, .appMemory: "memorychip"
        case .swapUsed: "arrow.left.arrow.right"
        case .appMemoryGrowth: "chart.line.uptrend.xyaxis"
        case .gpu: "cube.transparent"
        case .batteryLevel: "battery.25percent"
        case .diskWrite: "internaldrive"
        case .networkIn: "arrow.down.circle"
        }
    }
}

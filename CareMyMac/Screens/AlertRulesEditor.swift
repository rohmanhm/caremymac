import CareMyMacKit
import CareMyMacUI
import SwiftUI

/// Sheet listing every alert rule with inline editing. Each change is saved immediately; text fields debounce.
struct AlertRulesEditor: View {
    @Environment(LiveMonitor.self) private var monitor
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let rules = monitor.alertRules
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Alert rules").font(.title3.weight(.semibold))
                Text("CareMyMac checks these on every sample and adds an alert when one holds long enough.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if rules.isEmpty {
                            EmptyStateView("No rules", symbol: "bell.slash", message: "Add a rule to hear about sustained CPU, memory growth, or low battery.")
                                .padding(.vertical, 40)
                        }
                        ForEach(rules) { rule in
                            AlertRuleRow(rule: rule)
                                .id(rule.id)
                        }
                    }
                    .padding(20)
                }
                .background(.background.secondary)
                .onChange(of: rules.count) { old, new in
                    guard new > old, let last = rules.last else { return }
                    if reduceMotion {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    } else {
                        withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()

            HStack(spacing: 12) {
                Button("Add rule", systemImage: "plus") {
                    monitor.saveAlertRule(AlertRule(metric: .appCPU, threshold: AlertMetric.appCPU.defaultThreshold, duration: 120))
                }
                Text("The same alert repeats at most every 10 minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }
}

// MARK: - Row

private struct AlertRuleRow: View {
    @Environment(LiveMonitor.self) private var monitor
    let rule: AlertRule

    @State private var thresholdText = ""
    @State private var appText = ""
    @State private var confirmsDelete = false

    var body: some View {
        let metric = rule.metric
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Toggle("Enabled", isOn: binding(\.isEnabled))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .accessibilityLabel("\(rule.summary) enabled")
                Image(systemName: metric.pageSymbol)
                    .foregroundStyle(metric.pageResource.color)
                    .frame(width: 18)
                Text(rule.summary)
                    .fontWeight(.medium)
                    .foregroundStyle(rule.isEnabled ? .primary : .secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(rule.summary)
                Spacer(minLength: 8)
                Button("Delete rule…", systemImage: "trash") { confirmsDelete = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Delete rule")
                    .confirmationDialog("Delete the rule “\(rule.summary)”?", isPresented: $confirmsDelete) {
                        Button("Delete rule", role: .destructive) { monitor.deleteAlertRule(id: rule.id) }
                    } message: {
                        Text("Alerts it already added stay on the Alerts page.")
                    }
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    FieldLabel("When")
                    HStack(spacing: 8) {
                        Picker("Metric", selection: metricBinding) {
                            ForEach(AlertMetric.allCases) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        if metric == .appMemoryGrowth {
                            Text("grows by").foregroundStyle(.secondary)
                        } else {
                            Picker("Comparison", selection: binding(\.comparison)) {
                                ForEach(AlertComparison.allCases, id: \.self) { comparison in
                                    Text(metric.comparisonLabel(comparison)).tag(comparison)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        thresholdControl(metric)
                    }
                }
                GridRow {
                    if metric == .appMemoryGrowth {
                        FieldLabel("Within")
                        Picker("Window", selection: windowBinding) {
                            ForEach(RuleDurations.windows(including: rule.effectiveWindow), id: \.self) {
                                Text(RuleDurations.label($0)).tag($0)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    } else {
                        FieldLabel("For")
                        Picker("Duration", selection: binding(\.duration)) {
                            ForEach(RuleDurations.durations(including: rule.duration), id: \.self) {
                                Text(RuleDurations.label($0)).tag($0)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                if metric.isAppMetric {
                    GridRow {
                        FieldLabel("App")
                        HStack(spacing: 8) {
                            TextField("App", text: $appText, prompt: Text("Any app, or a bundle ID like com.apple.Safari"))
                                .labelsHidden()
                                .frame(maxWidth: 300)
                            RunningAppMenu { appText = $0 }
                        }
                    }
                }
            }
            .controlSize(.small)
            .padding(.leading, 4)
        }
        .card(padding: 14)
        .onAppear(perform: loadText)
        .onChange(of: rule.metric) { loadText() }
        .task(id: thresholdText) {
            guard (try? await Task.sleep(for: .milliseconds(500))) != nil else { return }
            commitThreshold()
        }
        .task(id: appText) {
            guard (try? await Task.sleep(for: .milliseconds(500))) != nil else { return }
            let trimmed = appText.trimmingCharacters(in: .whitespacesAndNewlines)
            let filter = trimmed.isEmpty ? nil : trimmed
            if rule.metric.isAppMetric, filter != rule.appFilter { save { $0.appFilter = filter } }
        }
    }

    @ViewBuilder
    private func thresholdControl(_ metric: AlertMetric) -> some View {
        if metric.unit == .pressureLevel {
            Picker("Pressure", selection: binding(\.threshold)) {
                Text("Normal").tag(0.0)
                Text("Warning").tag(1.0)
                Text("Critical").tag(2.0)
            }
            .labelsHidden()
            .fixedSize()
        } else {
            HStack(spacing: 6) {
                TextField("Threshold", text: $thresholdText)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 64)
                    .onSubmit(commitThreshold)
                Text(metric.unit.editorUnit)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                if metric.unit == .coreShare {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .help("100% is one full core; 200% is two.")
                        .accessibilityLabel("100% is one full core; 200% is two.")
                }
            }
        }
    }

    // MARK: Editing

    private func save(_ change: (inout AlertRule) -> Void) {
        var updated = rule
        change(&updated)
        guard updated != rule else { return }
        monitor.saveAlertRule(updated)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AlertRule, Value>) -> Binding<Value> {
        Binding(get: { rule[keyPath: keyPath] }, set: { value in save { $0[keyPath: keyPath] = value } })
    }

    private var metricBinding: Binding<AlertMetric> {
        Binding(get: { rule.metric }, set: { metric in
            save { rule in
                guard rule.metric != metric else { return }
                let wasApp = rule.metric.isAppMetric
                rule.metric = metric
                rule.threshold = metric.defaultThreshold
                rule.comparison = metric.defaultComparison
                if wasApp != metric.isAppMetric {
                    rule.cooldown = metric.isAppMetric ? AlertRule.defaultAppCooldown : AlertRule.defaultSystemCooldown
                }
                if !metric.isAppMetric { rule.appFilter = nil }
                rule.window = metric == .appMemoryGrowth ? rule.effectiveWindow : nil
            }
        })
    }

    private var windowBinding: Binding<TimeInterval> {
        Binding(get: { rule.effectiveWindow }, set: { value in save { $0.window = value } })
    }

    private func loadText() {
        thresholdText = rule.metric.unit.editorText(rule.threshold)
        appText = rule.appFilter ?? ""
    }

    private func commitThreshold() {
        let unit = rule.metric.unit
        guard unit != .pressureLevel, thresholdText != unit.editorText(rule.threshold),
              let value = unit.editorValue(thresholdText) else { return }
        save { $0.threshold = value }
    }
}

private struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }
}

/// Fills the app filter with a running app. Its own view so live app updates don't re-render the row.
private struct RunningAppMenu: View {
    @Environment(LiveMonitor.self) private var monitor
    let choose: (String) -> Void

    var body: some View {
        Menu("Choose app") {
            Button("Any app") { choose("") }
            Divider()
            ForEach(monitor.apps.prefix(20)) { app in
                Button(app.name) { choose(app.bundleIdentifier ?? app.id) }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

// MARK: - Units and choices

private enum RuleDurations {
    static let standardDurations: [TimeInterval] = [0, 30, 60, 120, 300, 600]
    static let standardWindows: [TimeInterval] = [900, 1800, 3600, 7200, 21_600]

    static func durations(including value: TimeInterval) -> [TimeInterval] {
        standardDurations.contains(value) ? standardDurations : (standardDurations + [value]).sorted()
    }

    static func windows(including value: TimeInterval) -> [TimeInterval] {
        standardWindows.contains(value) ? standardWindows : (standardWindows + [value]).sorted()
    }

    static func label(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<1: "Instantly"
        case ..<60: "\(Int(seconds)) s"
        case ..<3600: "\(Int(seconds / 60)) min"
        default:
            seconds == 3600 ? "1 hour" : "\(Format.decimal(seconds / 3600, digits: seconds.truncatingRemainder(dividingBy: 3600) == 0 ? 0 : 1)) hours"
        }
    }
}

private let gibibyte = 1_073_741_824.0
private let megabyte = 1_000_000.0

private extension AlertUnit {
    /// Unit shown after the threshold field. Byte sizes follow `AlertMetric.format` (binary GB, decimal MB/s).
    var editorUnit: String {
        switch self {
        case .fraction: "%"
        case .coreShare: "% of one core"
        case .bytes: "GB"
        case .bytesPerSecond: "MB/s"
        case .pressureLevel: ""
        }
    }

    func editorText(_ value: Double) -> String {
        let shown: Double = switch self {
        case .fraction, .coreShare: value * 100
        case .bytes: value / gibibyte
        case .bytesPerSecond: value / megabyte
        case .pressureLevel: value
        }
        return shown.formatted(.number.precision(.fractionLength(0...2)).grouping(.never))
    }

    /// Parses the field in human units; nil for text that isn't a usable number.
    func editorValue(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let number = Double(cleaned), number.isFinite, number >= 0 else { return nil }
        switch self {
        case .fraction: return min(number, 100) / 100
        case .coreShare: return number / 100
        case .bytes: return number * gibibyte
        case .bytesPerSecond: return number * megabyte
        case .pressureLevel: return number
        }
    }
}

private extension AlertMetric {
    var defaultThreshold: Double {
        switch self {
        case .cpu, .memoryUsedFraction, .gpu: 0.9
        case .memoryPressure: 2
        case .swapUsed: 4 * gibibyte
        case .batteryLevel: 0.15
        case .diskWrite: 100 * megabyte
        case .networkIn: 50 * megabyte
        case .appCPU: 0.8
        case .appMemory: 4 * gibibyte
        case .appMemoryGrowth: gibibyte
        }
    }

    var defaultComparison: AlertComparison {
        self == .batteryLevel ? .below : .above
    }

    func comparisonLabel(_ comparison: AlertComparison) -> String {
        if self == .memoryPressure { return comparison == .above ? "at or above" : "at or below" }
        return comparison.displayName
    }
}

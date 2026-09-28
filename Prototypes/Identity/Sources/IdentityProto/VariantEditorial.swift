import CareMyMacKit
import CareMyMacUI
import SwiftUI

/// Direction 3 — Editorial. Axis: typographic identity. Warm paper, ink, one vermilion accent,
/// New York serif headlines and numerals, hairline rules and dotted leaders; a masthead with text tabs.
struct EditorialVariant: View {
    enum Tab: String, CaseIterable { case today = "Today", apps = "Apps", resources = "Resources" }
    @Environment(LiveMonitor.self) private var monitor
    @State private var tab: Tab = .today

    var body: some View {
        VStack(spacing: 0) {
            Masthead(tab: $tab)
            ScrollView {
                Group {
                    switch tab {
                    case .today: EditorialToday()
                    case .apps: EditorialApps()
                    case .resources: EditorialResources()
                    }
                }
                .frame(maxWidth: 1040, alignment: .leading)
                .padding(.horizontal, 40)
                .padding(.top, 28)
                .padding(.bottom, 90)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Ink.paper)
        .foregroundStyle(Ink.text)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(monitor.isPaused ? "Resume" : "Pause", systemImage: monitor.isPaused ? "play.fill" : "pause.fill") { monitor.togglePause() }
                Button("Save moment", systemImage: "bookmark") { monitor.saveMoment() }
                    .disabled(monitor.pendingMomentDate != nil)
            }
        }
    }
}

enum Ink {
    static let paper = Color(light: OKLCH(0.975, 0.012, 85), dark: OKLCH(0.19, 0.008, 70))
    static let text = Color(light: OKLCH(0.24, 0.02, 60), dark: OKLCH(0.93, 0.012, 85))
    static let muted = Color(light: OKLCH(0.48, 0.015, 70), dark: OKLCH(0.72, 0.012, 80))
    static let rule = Color(light: OKLCH(0.86, 0.012, 80), dark: OKLCH(0.33, 0.01, 70))
    static let accent = Color(light: OKLCH(0.55, 0.17, 35), dark: OKLCH(0.72, 0.13, 38))
    /// Chart ink: the text color, so charts read like print; the accent marks what's notable.
    static let line = text
}

private struct Rule: View {
    var heavy = false
    var body: some View {
        Rectangle().fill(heavy ? Ink.text : Ink.rule).frame(height: heavy ? 2 : 0.5)
    }
}

private struct Masthead: View {
    @Environment(LiveMonitor.self) private var monitor
    @Binding var tab: EditorialVariant.Tab

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .lastTextBaseline) {
                Text("CareMyMac")
                    .font(.system(size: 30, weight: .bold, design: .serif))
                    .italic()
                Spacer()
                Text("\(Date.now.formatted(date: .complete, time: .omitted)) · \(monitor.machine.chipName)")
                    .font(.system(.callout, design: .serif))
                    .foregroundStyle(Ink.muted)
            }
            .padding(.horizontal, 40)
            .padding(.top, 8)
            .padding(.bottom, 10)
            Rule(heavy: true).padding(.horizontal, 40)
            HStack(spacing: 28) {
                ForEach(EditorialVariant.Tab.allCases, id: \.self) { item in
                    Button {
                        tab = item
                    } label: {
                        Text(item.rawValue.uppercased())
                            .font(.system(size: 12, weight: .semibold))
                            .tracking(1.4)
                            .foregroundStyle(item == tab ? Ink.accent : Ink.muted)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(item == tab ? .isSelected : [])
                }
                Spacer()
            }
            .padding(.horizontal, 40)
            Rule().padding(.horizontal, 40)
        }
        .background(Ink.paper)
    }
}

private struct EditorialToday: View {
    @Environment(LiveMonitor.self) private var monitor

    var body: some View {
        let domain = monitor.domain(.fiveMinutes)
        let readings = monitor.readings(since: domain.lowerBound)
        VStack(alignment: .leading, spacing: 30) {
            VStack(alignment: .leading, spacing: 10) {
                Text(monitor.statusSentence)
                    .font(.system(size: 46, weight: .bold, design: .serif))
                    .tracking(-0.6)
                if let app = monitor.apps.first {
                    Text("\(app.name) leads the machine at \(Format.percent(app.cpu)) of a core and \(Format.memory(app.memory)), with \(Format.processes(app.processes.count)) working under it.")
                        .font(.system(.title3, design: .serif))
                        .foregroundStyle(Ink.muted)
                        .monospacedDigit()
                        .frame(maxWidth: 680, alignment: .leading)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 28), count: 3), alignment: .leading, spacing: 28) {
                ForEach(readings, id: \.resource) { reading in
                    VStack(alignment: .leading, spacing: 6) {
                        Rule()
                        Text(reading.resource.title.uppercased())
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(1.3)
                            .foregroundStyle(Ink.muted)
                            .padding(.top, 4)
                        Text(reading.value)
                            .font(.system(size: 40, weight: .semibold, design: .serif))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(reading.detail)
                            .font(.system(.callout, design: .serif))
                            .italic()
                            .foregroundStyle(Ink.muted)
                            .monospacedDigit()
                            .lineLimit(1)
                        SeriesChart(primary: reading.primary, secondary: reading.secondary, color: Ink.line, secondaryColor: Ink.accent,
                                    domain: domain, yMax: reading.yMax)
                            .frame(height: 44)
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Most active").font(.system(size: 24, weight: .bold, design: .serif))
                    Spacer()
                    Text("CPU · MEMORY").font(.system(size: 11, weight: .semibold)).tracking(1.3).foregroundStyle(Ink.muted)
                }
                Rule(heavy: true)
                ForEach(Array(monitor.apps.prefix(8).enumerated()), id: \.element.id) { index, app in
                    LeaderRow(rank: index + 1, app: app)
                }
            }
        }
    }
}

/// "3  Slack ················ 12.4%  884 MB"
private struct LeaderRow: View {
    let rank: Int
    let app: AppActivity

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(rank)")
                .font(.system(.title3, design: .serif))
                .foregroundStyle(Ink.accent)
                .monospacedDigit()
                .frame(width: 26, alignment: .trailing)
            Text(app.name)
                .font(.system(.title3, design: .serif))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
                .help(app.name)
            DottedLeader()
            Text(Format.percent(app.cpu))
                .font(.system(.title3, design: .serif))
                .monospacedDigit()
                .frame(width: 84, alignment: .trailing)
            Text(Format.memory(app.memory))
                .font(.system(.body, design: .serif))
                .foregroundStyle(Ink.muted)
                .monospacedDigit()
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Rule() }
        .accessibilityElement(children: .combine)
    }
}

private struct DottedLeader: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                path.move(to: CGPoint(x: 0, y: geometry.size.height - 4))
                path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height - 4))
            }
            .stroke(Ink.rule, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [0.1, 5]))
        }
        .frame(height: 14)
        .frame(minWidth: 20)
        .accessibilityHidden(true)
    }
}

private struct EditorialApps: View {
    @Environment(LiveMonitor.self) private var monitor
    @State private var byMemory = false

    var body: some View {
        let apps = monitor.apps.filter { $0.kind == .application }.sorted { byMemory ? $0.memory > $1.memory : $0.cpu > $1.cpu }
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Every app, ranked").font(.system(size: 34, weight: .bold, design: .serif))
                Spacer()
                Picker("Rank by", selection: $byMemory) {
                    Text("By CPU").tag(false)
                    Text("By memory").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            Text("\(apps.count) apps, with every helper counted under the app that owns it.")
                .font(.system(.title3, design: .serif))
                .italic()
                .foregroundStyle(Ink.muted)
            Rule(heavy: true).padding(.top, 8)
            LazyVStack(spacing: 0) {
                ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                    LeaderRow(rank: index + 1, app: app)
                }
            }
        }
    }
}

private struct EditorialResources: View {
    @Environment(LiveMonitor.self) private var monitor
    @State private var scrub = ScrubState()

    var body: some View {
        let domain = monitor.domain(.tenMinutes)
        VStack(alignment: .leading, spacing: 34) {
            Text("The last ten minutes").font(.system(size: 34, weight: .bold, design: .serif))
            ForEach(monitor.readings(since: domain.lowerBound), id: \.resource) { reading in
                VStack(alignment: .leading, spacing: 8) {
                    Rule(heavy: true)
                    HStack(alignment: .firstTextBaseline) {
                        Text(reading.resource.title).font(.system(size: 22, weight: .bold, design: .serif))
                        Text(reading.detail).font(.system(.callout, design: .serif)).italic().foregroundStyle(Ink.muted).monospacedDigit()
                        Spacer()
                        Text(reading.value).font(.system(size: 26, weight: .semibold, design: .serif)).monospacedDigit()
                    }
                    SeriesChart(primary: reading.primary, secondary: reading.secondary, color: Ink.line, secondaryColor: Ink.accent,
                                domain: domain, yMax: reading.yMax, showsAxes: true,
                                yLabel: reading.yMax == 1 ? { Format.percent($0, digits: 0) } : reading.format, scrub: scrub)
                        .frame(height: 130)
                }
            }
        }
    }
}

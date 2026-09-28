import AppKit
import CareMyMacKit
import CareMyMacUI
import SwiftUI

// Illustrations for the introduction steps. Each plays once every time its step becomes current, in numbered
// beats, and animates only opacity and transforms. They're decorative: the step's heading carries the meaning,
// so VoiceOver skips them.

// MARK: - Choreography

private struct Choreography: ViewModifier {
    let isActive: Bool
    /// Wait before each beat, counted from the previous one.
    let beats: [Duration]
    @Binding var phase: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.task(id: isActive) {
            // A page that stops being current keeps its last frame while it fades out.
            guard isActive else { return }
            var instant = Transaction()
            instant.disablesAnimations = true
            if reduceMotion {
                withTransaction(instant) { phase = beats.count }
                return
            }
            // The page is still transparent here, so rewinding is invisible.
            withTransaction(instant) { phase = 0 }
            for beat in beats {
                try? await Task.sleep(for: beat)
                if Task.isCancelled { return }
                phase += 1
            }
        }
    }
}

private extension View {
    func choreography(_ phase: Binding<Int>, isActive: Bool, beats: [Duration]) -> some View {
        modifier(Choreography(isActive: isActive, beats: beats, phase: phase))
    }

    /// Rises 8 pt into place and fades in once `shown` turns true.
    func arrives(_ shown: Bool, delay: Double = 0) -> some View {
        opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 8)
            .animation(.spring(duration: 0.5, bounce: 0).delay(delay), value: shown)
    }
}

// MARK: - Welcome

/// The app icon over a soft glow of every resource hue, beside the busiest apps on this Mac right now as Busy Now
/// lists them.
struct WelcomeIllustration: View {
    let isActive: Bool
    @Environment(LiveMonitor.self) private var monitor
    @State private var rows: [Row] = []
    @State private var phase = 0

    struct Row: Identifiable {
        let id: String
        let name: String
        let iconPath: String?
        let detail: String
        let value: String
        let level: Int
    }

    var body: some View {
        HStack(spacing: 40) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 112, height: 112)
                .scaleEffect(phase >= 1 ? 1 : 0.92)
                .arrives(phase >= 1)
                // Every resource hue fading out from the icon. A radial mask instead of a blur: no filter to render,
                // and it never adds to the illustration's size.
                .background {
                    Circle()
                        .fill(AngularGradient(colors: Resource.allCases.map(\.color) + [Resource.cpu.color], center: .center))
                        .mask(RadialGradient(colors: [.white, .white.opacity(0.35), .clear], center: .center, startRadius: 16, endRadius: 115))
                        .frame(width: 230, height: 230)
                        .opacity(phase >= 1 ? 0.45 : 0)
                        .scaleEffect(phase >= 1 ? 1 : 0.6)
                        .animation(.easeOut(duration: 1.1), value: phase >= 1)
                }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Busy Now").font(.headline)
                    Spacer()
                    Label("CPU", systemImage: "arrow.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                Divider()
                VStack(spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        RowView(row: row, isSelected: index == 0, filled: phase >= 3, delay: Double(index) * 0.06)
                            .arrives(phase >= 2, delay: Double(index) * 0.06)
                    }
                }
                .padding(6)
            }
            .frame(width: 360)
            .card(padding: 0)
            .arrives(phase >= 1, delay: 0.08)
        }
        .frame(maxHeight: .infinity)
        .task(id: isActive) {
            if isActive { rows = Self.rows(from: monitor.apps) }
        }
        .choreography($phase, isActive: isActive, beats: [.milliseconds(250), .milliseconds(250), .milliseconds(300)])
        .accessibilityHidden(true)
    }

    /// The four busiest regular apps; well-known Apple apps until the first measurement lands.
    private static func rows(from apps: [AppActivity]) -> [Row] {
        let busiest = apps.filter { $0.kind == .application }.sorted { $0.cpu > $1.cpu }.prefix(4)
        guard busiest.count == 4 else { return samples }
        return busiest.map { app in
            Row(id: app.id, name: app.name, iconPath: app.bundlePath,
                detail: "\(Format.processes(app.processes.count)) · \(Format.memory(app.memory))",
                value: Format.percent(app.cpu), level: level(cpu: app.cpu))
        }
    }

    /// Bars for a share of one core, on the thresholds the app lists use.
    private static func level(cpu: Double) -> Int {
        [0.005, 0.05, 0.2, 0.5, 1].lastIndex { cpu >= $0 }.map { $0 + 1 } ?? 0
    }

    private static let samples: [Row] = [
        Row(id: "maps", name: "Maps", iconPath: "/System/Applications/Maps.app", detail: "9 processes · 1.4 GB", value: "38%", level: 4),
        Row(id: "photos", name: "Photos", iconPath: "/System/Applications/Photos.app", detail: "4 processes · 820 MB", value: "21%", level: 4),
        Row(id: "music", name: "Music", iconPath: "/System/Applications/Music.app", detail: "3 processes · 310 MB", value: "6%", level: 3),
        Row(id: "mail", name: "Mail", iconPath: "/System/Applications/Mail.app", detail: "2 processes · 190 MB", value: "1%", level: 1),
    ]

    private struct RowView: View {
        let row: Row
        let isSelected: Bool
        let filled: Bool
        let delay: Double

        var body: some View {
            HStack(spacing: 10) {
                AppIcon(path: row.iconPath, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name).fontWeight(.semibold).lineLimit(1)
                    Text(row.detail).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(row.value).fontWeight(.medium).monospacedDigit()
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(1...5, id: \.self) { bar in
                            let on = filled && bar <= row.level
                            RoundedRectangle(cornerRadius: 1, style: .continuous)
                                .fill(on ? AnyShapeStyle(Resource.cpu.color) : AnyShapeStyle(.quaternary))
                                .frame(width: 3, height: 3 + CGFloat(bar) * 1.6)
                                .animation(.easeOut(duration: 0.2).delay(delay + Double(bar) * 0.05), value: on)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isSelected ? AnyShapeStyle(.quaternary.opacity(0.7)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: Metrics.cardRadius - 6, style: .continuous))
        }
    }
}

// MARK: - One clock

/// CPU, memory and disk lanes on one clock. They record left to right, the cursor slides to the moment all three
/// moved, their values switch to that moment, and a marker drops there.
struct TimelineIllustration: View {
    let isActive: Bool
    @State private var phase = 0

    private struct Lane: Identifiable {
        let resource: Resource
        let values: [Double]
        let before: String
        let after: String
        var id: Resource { resource }
    }

    private static let count = 48
    private static let spike = 32
    private static let labelWidth: CGFloat = 92
    private static let inset: CGFloat = 16
    private static let headerHeight: CGFloat = 40
    private static let start: CGFloat = 0.12

    private static let lanes: [Lane] = [
        Lane(resource: .cpu, values: series { i in 0.16 + 0.05 * sin(Double(i) * 0.55) + bump(i, height: 0.66, width: 2.2) },
             before: "18%", after: "84%"),
        Lane(resource: .memory, values: series { i in 0.42 + 0.015 * sin(Double(i) * 0.4) + 0.2 / (1 + exp(-Double(i - spike + 1) * 1.4)) },
             before: "43%", after: "62%"),
        Lane(resource: .disk, values: series { i in 0.07 + 0.03 * abs(sin(Double(i) * 0.9)) + bump(i, height: 0.75, width: 1.6) },
             before: "2 MB/s", after: "214 MB/s"),
    ]

    var body: some View {
        let spikeFraction = CGFloat(Self.spike) / CGFloat(Self.count - 1)
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("This Mac").font(.headline)
                Spacer()
                Text("5 Min").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, Self.inset)
            .frame(height: Self.headerHeight)
            Divider()
            ForEach(Array(Self.lanes.enumerated()), id: \.element.id) { index, lane in
                if index > 0 { Divider().padding(.leading, Self.inset) }
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Circle().fill(lane.resource.color).frame(width: 6, height: 6)
                            Text(lane.resource.title).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(phase >= 2 ? lane.after : lane.before)
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .animation(.smooth(duration: 0.35).delay(0.3), value: phase >= 2)
                    }
                    .frame(width: Self.labelWidth, alignment: .leading)
                    LaneChart(values: lane.values, color: lane.resource.color, recorded: phase >= 1, delay: Double(index) * 0.08)
                        .frame(height: 40)
                }
                .padding(.horizontal, Self.inset)
                .padding(.vertical, 10)
            }
        }
        .frame(width: 460)
        .overlay(alignment: .topLeading) {
            GeometryReader { proxy in
                let chartStart = Self.inset + Self.labelWidth + 12
                let chartWidth = proxy.size.width - chartStart - Self.inset
                let x = chartStart + chartWidth * (phase >= 2 ? spikeFraction : Self.start)
                // What the marker keeps: the two minutes before it and 30 seconds after, of the five on screen.
                let keptFrom = max(spikeFraction - 0.4, 0)
                let keptTo = min(spikeFraction + 0.1, 1)
                Rectangle()
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: chartWidth * (keptTo - keptFrom), height: proxy.size.height - Self.headerHeight)
                    .scaleEffect(x: phase >= 3 ? 1 : 0.001, anchor: UnitPoint(x: (spikeFraction - keptFrom) / (keptTo - keptFrom), y: 0.5))
                    .offset(x: chartStart + chartWidth * keptFrom, y: Self.headerHeight)
                    .animation(.spring(duration: 0.6, bounce: 0), value: phase >= 3)
                ZStack(alignment: .top) {
                    Rectangle()
                        .fill(.primary.opacity(0.35))
                        .frame(width: 1, height: proxy.size.height - Self.headerHeight)
                        .offset(y: Self.headerHeight)
                    Image(systemName: "flag.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .offset(x: 5, y: 13)
                        .scaleEffect(phase >= 3 ? 1 : 0.6, anchor: .bottomLeading)
                        .opacity(phase >= 3 ? 1 : 0)
                        .animation(.spring(duration: 0.4, bounce: 0.25), value: phase >= 3)
                        .symbolEffect(.bounce, value: phase >= 3)
                }
                .frame(width: 1)
                .offset(x: x)
                .opacity(phase >= 1 ? 1 : 0)
                .animation(.spring(duration: 0.8, bounce: 0), value: phase)
            }
        }
        .card(padding: 0)
        .frame(maxHeight: .infinity)
        .choreography($phase, isActive: isActive, beats: [.milliseconds(200), .milliseconds(1000), .milliseconds(700)])
        .accessibilityHidden(true)
    }

    private static func series(_ value: (Int) -> Double) -> [Double] {
        (0..<count).map { min(max(value($0), 0.02), 0.98) }
    }

    private static func bump(_ i: Int, height: Double, width: Double) -> Double {
        let d = Double(i - spike) / width
        return height * exp(-d * d)
    }

    /// Line and fill, revealed left to right like a lane recording.
    private struct LaneChart: View {
        let values: [Double]
        let color: Color
        let recorded: Bool
        let delay: Double

        var body: some View {
            ZStack {
                SeriesShape(values: values, closed: true)
                    .fill(LinearGradient(colors: [color.opacity(0.28), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                SeriesShape(values: values, closed: false)
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            .mask(alignment: .leading) {
                Rectangle().scaleEffect(x: recorded ? 1 : 0.001, anchor: .leading)
            }
            .animation(.easeOut(duration: 0.9).delay(delay), value: recorded)
        }
    }

    private struct SeriesShape: Shape {
        let values: [Double]
        let closed: Bool

        func path(in rect: CGRect) -> Path {
            Path { path in
                guard values.count > 1 else { return }
                let step = rect.width / CGFloat(values.count - 1)
                let points = values.enumerated().map { index, value in
                    CGPoint(x: rect.minX + CGFloat(index) * step, y: rect.maxY - CGFloat(value) * rect.height)
                }
                path.move(to: points[0])
                for point in points.dropFirst() { path.addLine(to: point) }
                if closed {
                    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                    path.closeSubpath()
                }
            }
        }
    }
}

// MARK: - Alerts

/// Alerts arriving as macOS notifications, newest on top, over a soft desktop that the banners' material picks up.
struct AlertsIllustration: View {
    let isActive: Bool
    @State private var phase = 0

    private struct Alert: Identifiable {
        let title: String
        let detail: String
        let time: String
        var id: String { title }
    }

    /// Worded the way `AlertEngine` words its events; oldest first.
    private static let alerts: [Alert] = [
        Alert(title: "Safari grew by 1.2 GB in the last hour", detail: "Memory went from 820 MB to 2 GB.", time: "4m ago"),
        Alert(title: "Battery is low", detail: "10% remaining.", time: "1m ago"),
        Alert(title: "Xcode is using sustained CPU", detail: "Above 80% of one core for at least 2 min.", time: "now"),
    ]

    var body: some View {
        let desktop = RoundedRectangle(cornerRadius: 18, style: .continuous)
        VStack(spacing: 8) {
            ForEach(Self.alerts.prefix(phase).reversed()) { alert in
                Banner(alert: alert)
                    .transition(.asymmetric(
                        insertion: .offset(y: -24).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: .top)),
                        removal: .opacity))
            }
        }
        .animation(.spring(duration: 0.55, bounce: 0), value: phase)
        .padding(.top, 22)
        .frame(width: 460, height: 240, alignment: .top)
        .background {
            desktop.fill(LinearGradient(colors: [Resource.network.color, Resource.memory.color, Resource.graphics.color].map { $0.opacity(0.3) },
                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                .background(.background.secondary, in: desktop)
        }
        .clipShape(desktop)
        .overlay(desktop.strokeBorder(.separator, lineWidth: 0.5))
        .frame(maxHeight: .infinity)
        .choreography($phase, isActive: isActive, beats: [.milliseconds(300), .milliseconds(650), .milliseconds(650)])
        .accessibilityHidden(true)
    }

    private struct Banner: View {
        let alert: Alert

        var body: some View {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(alert.title).font(.callout.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(alert.time).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(alert.detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: 390)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        }
    }
}

// MARK: - Developer

/// Free a Port finding two dev servers on the typed ports, then Stop All freeing both.
struct PortsIllustration: View {
    let isActive: Bool
    @State private var phase = 0

    private struct Holder: Identifiable {
        let port: String
        let name: String
        let detail: String
        var id: String { port }
    }

    private static let holders: [Holder] = [
        Holder(port: "3000", name: "node", detail: "shop-web · next dev"),
        Holder(port: "5173", name: "bun", detail: "dashboard · vite"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Free a Port").font(.headline)
                Spacer()
                Text("Any app you run").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    Text(verbatim: "3000, 5173").monospaced()
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(width: 220)
                .background(.background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
                Spacer()
                FakeButton("Stop All…")
                    .opacity(phase >= 2 ? 1 : 0.5)
                    .animation(.easeOut(duration: 0.2), value: phase >= 2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            ForEach(Array(Self.holders.enumerated()), id: \.element.id) { index, holder in
                let freed = phase >= 3
                Divider().padding(.leading, 16)
                HStack(spacing: 10) {
                    Text(verbatim: ":\(holder.port)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(holder.name).fontWeight(.semibold)
                        Text(holder.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    .opacity(freed ? 0.45 : 1)
                    Spacer()
                    ZStack(alignment: .trailing) {
                        FakeButton("Stop")
                            .opacity(freed ? 0 : 1)
                            .scaleEffect(freed ? 0.9 : 1)
                        Label {
                            Text("Port free")
                        } icon: {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.live)
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .opacity(freed ? 1 : 0)
                        .scaleEffect(freed ? 1 : 0.9, anchor: .trailing)
                    }
                }
                .animation(.spring(duration: 0.4, bounce: 0).delay(Double(index) * 0.2), value: freed)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .arrives(phase >= 2, delay: Double(index) * 0.08)
            }
        }
        .frame(width: 440)
        .card(padding: 0)
        .frame(maxHeight: .infinity)
        .choreography($phase, isActive: isActive, beats: [.milliseconds(200), .milliseconds(400), .milliseconds(1000)])
        .accessibilityHidden(true)
    }
}

/// A button's shape inside an illustration; nothing to press.
private struct FakeButton: View {
    private let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.quaternary, in: .capsule)
    }
}

// MARK: - Care

/// Three Cleanup finds that get checked one by one while the total adds up, then the Trash they'd move to.
struct CareIllustration: View {
    let isActive: Bool
    @State private var phase = 0

    private struct Item: Identifiable {
        let name: String
        let symbol: String
        let bytes: Double
        var id: String { name }
    }

    private static let items: [Item] = [
        Item(name: "Xcode Derived Data", symbol: "hammer", bytes: 4.2e9),
        Item(name: "npm cache", symbol: "shippingbox", bytes: 1.3e9),
        Item(name: "Installers in Downloads", symbol: "arrow.down.circle", bytes: 0.86e9),
    ]

    var body: some View {
        let total = Self.items.reduce(0) { $0 + $1.bytes }
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Cleanup").font(.headline)
                Spacer()
                Text("Moves to the Trash").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            VStack(spacing: 0) {
                ForEach(Array(Self.items.enumerated()), id: \.element.id) { index, item in
                    let checked = phase >= 2
                    HStack(spacing: 10) {
                        Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 16))
                            .foregroundStyle(checked ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                            .contentTransition(.symbolEffect(.replace))
                            .animation(.snappy(duration: 0.25).delay(Double(index) * 0.18), value: checked)
                        Image(systemName: item.symbol)
                            .foregroundStyle(Resource.storage.color)
                            .frame(width: 20)
                        Text(item.name)
                        Spacer(minLength: 8)
                        Text(Format.bytes(item.bytes))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .arrives(phase >= 1, delay: Double(index) * 0.06)
                }
            }
            .padding(.vertical, 4)
            Divider()
            HStack(spacing: 10) {
                Image(systemName: "trash")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .symbolEffect(.bounce, value: phase >= 3)
                CountingBytes(value: phase >= 2 ? total : 0)
                    .fontWeight(.semibold)
                    .animation(.easeOut(duration: 0.7), value: phase >= 2)
                Text("selected").foregroundStyle(.secondary)
                Spacer()
                FakeButton("Move to Trash…")
                    .opacity(phase >= 2 ? 1 : 0.5)
                    .animation(.easeOut(duration: 0.3).delay(0.5), value: phase >= 2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 420)
        .card(padding: 0)
        .frame(maxHeight: .infinity)
        .choreography($phase, isActive: isActive, beats: [.milliseconds(200), .milliseconds(450), .milliseconds(800)])
        .accessibilityHidden(true)
    }

    /// A byte count that counts up to its value when animated.
    private struct CountingBytes: View, Animatable {
        var value: Double
        var animatableData: Double {
            get { value }
            set { value = newValue }
        }

        var body: some View {
            Text(Format.bytes(value)).monospacedDigit()
        }
    }
}

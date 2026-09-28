import SwiftUI

public extension LiveMonitor {
    /// The visible time window ending at the latest sample.
    func domain(_ range: LiveRange) -> ClosedRange<Date> {
        let end = snapshot?.date ?? .now
        return end.addingTimeInterval(-range.seconds)...end
    }
}

/// 1 Min / 5 Min / 10 Min segmented control. Every page shares the stored choice.
public struct RangePicker: View {
    @AppStorage("liveRange") private var range: LiveRange = .fiveMinutes

    public init() {}

    public var body: some View {
        Picker("Time range", selection: $range) {
            ForEach(LiveRange.allCases) { range in
                Text(range.shortLabel).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Time range shown by the live charts")
    }
}

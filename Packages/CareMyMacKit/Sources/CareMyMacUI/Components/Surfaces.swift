import SwiftUI

public enum Metrics {
    /// Corner radius of every card.
    public static let cardRadius: CGFloat = 12
    public static let cardPadding: CGFloat = 16
    /// Gap between cards and page sections.
    public static let gap: CGFloat = 16
    public static let pagePadding: CGFloat = 24
}

private struct CardSurface: ViewModifier {
    let padding: CGFloat?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
        content
            .padding(padding ?? 0)
            .background(.background, in: shape)
            .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
    }
}

public extension View {
    /// The one card surface: content background, hairline edge, 12 pt continuous corners.
    func card(padding: CGFloat? = Metrics.cardPadding) -> some View {
        modifier(CardSurface(padding: padding))
    }

    /// Background for scrolling pages, one step below cards so cards read as raised.
    func pageBackground() -> some View {
        background(.background.secondary)
    }
}

/// Titled card. `trailing` holds a caption or a control aligned to the title's baseline.
public struct SectionCard<Content: View, Trailing: View>: View {
    private let title: String
    private let subtitle: String?
    private let content: Content
    private let trailing: Trailing

    public init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
        self.trailing = trailing()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let subtitle {
                        Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                trailing
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// One headline number with a label.
public struct StatTile: View {
    private let title: String
    private let value: String
    private let detail: String?
    private let valueColor: Color?

    public init(_ title: String, value: String, detail: String? = nil, valueColor: Color? = nil) {
        self.title = title
        self.value = value
        self.detail = detail
        self.valueColor = valueColor
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(valueColor ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(padding: 14)
        .accessibilityElement(children: .combine)
    }
}

/// Page title block. `trailing` sits on the title's baseline (badges, pickers).
public struct PageHeader<Trailing: View>: View {
    private let title: String
    private let subtitle: String
    private let trailing: Trailing

    public init(_ title: String, subtitle: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.largeTitle.weight(.bold))
                Text(subtitle).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 12)
            trailing
        }
        .accessibilityElement(children: .contain)
    }
}

/// Small "● Label" legend entry; dashed for secondary series.
public struct LegendSwatch: View {
    private let label: String
    private let color: Color
    private let dashed: Bool

    public init(_ label: String, color: Color, dashed: Bool = false) {
        self.label = label
        self.color = color
        self.dashed = dashed
    }

    public var body: some View {
        HStack(spacing: 6) {
            SwatchLine()
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dashed ? [3, 3] : []))
                .frame(width: 16, height: 8)
            Text(label)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct SwatchLine: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX + 1, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX - 1, y: rect.midY))
        }
    }
}

/// Centered empty state that explains what belongs here and how to get it.
public struct EmptyStateView<Actions: View>: View {
    private let title: String
    private let symbol: String
    private let message: String
    private let actions: Actions

    public init(_ title: String, symbol: String, message: String, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.title = title
        self.symbol = symbol
        self.message = message
        self.actions = actions()
    }

    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            actions
        }
    }
}

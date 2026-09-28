import CareMyMacUI
import SwiftUI

/// The welcome sheet: five introduction steps, then setup. The intro can be skipped; setup can't be missed.
enum WelcomeStep: Int, CaseIterable, Identifiable {
    case welcome, timeline, alerts, developer, care, setup

    var id: Int { rawValue }

    /// Short name for the step indicator.
    var name: String {
        switch self {
        case .welcome: "Welcome"
        case .timeline: "Timeline and markers"
        case .alerts: "Alerts"
        case .developer: "Free a Port"
        case .care: "Care"
        case .setup: "Setup"
        }
    }

    var title: String {
        switch self {
        case .welcome: "Welcome to CareMyMac"
        case .timeline: "Find the spike, keep the moment"
        case .alerts: "Hear about it as it happens"
        case .developer: "Free a port in one step"
        case .care: "Tidy up without surprises"
        case .setup: "Choose how it keeps watch"
        }
    }

    var message: String {
        switch self {
        case .welcome:
            "An activity monitor organized around apps: pick one for its CPU, memory and disk, and every helper process it runs. Nothing it measures leaves this Mac."
        case .timeline:
            "Every resource shares one clock, and the timeline keeps 30 days. A marker (⇧⌘S) saves the two minutes before it and the top apps, to look at later."
        case .alerts:
            "Alerts watch for an app stuck on a core, memory that keeps growing, low battery and more. The rules are yours, and each can show a macOS notification."
        case .developer:
            "Developer groups Node, Python, Bun and Go runtimes by project with their ports. Free a Port finds whatever holds 3000 or 8000-8010, in any app you run, and stops it."
        case .care:
            "Cleanup, Uninstaller and Optimize show the count and size first, then move what you pick to the Trash. Only Empty Trash deletes for good."
        case .setup:
            "Four optional choices. CareMyMac works without any of them."
        }
    }

    var next: WelcomeStep? { WelcomeStep(rawValue: rawValue + 1) }
    var previous: WelcomeStep? { WelcomeStep(rawValue: rawValue - 1) }

    /// `.welcome`; Debug builds accept `-CareMyMacOnboardingStep <name>` (`welcome`, `timeline`, `alerts`, `developer`,
    /// `care`, `setup`).
    static var first: WelcomeStep {
        #if DEBUG
        let requested = UserDefaults.standard.string(forKey: "CareMyMacOnboardingStep")
        if let step = allCases.first(where: { "\($0)" == requested }) { return step }
        #endif
        return .welcome
    }
}

/// Every step stays in one stack, placed by its distance from the current one: earlier steps wait off to the leading
/// side, later ones to the trailing side. One critically damped spring moves them, so Back retraces the path Continue
/// took and a click mid-transition reverses from wherever the pages are. Reduce Motion cross-fades in place.
struct WelcomeSheet: View {
    @Environment(Onboarding.self) private var onboarding
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = WelcomeStep.first

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                ForEach(WelcomeStep.allCases) { page in
                    let distance = page.rawValue - step.rawValue
                    content(for: page, isActive: distance == 0)
                        .padding(.horizontal, 40)
                        .padding(.top, 32)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .opacity(distance == 0 ? 1 : 0)
                        .offset(x: reduceMotion ? 0 : CGFloat(distance.signum()) * 64)
                        .allowsHitTesting(distance == 0)
                        .disabled(distance != 0)
                }
            }
            .clipped()
            stepper
        }
        .frame(width: 640, height: 560)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.5, bounce: 0), value: step)
    }

    @ViewBuilder
    private func content(for page: WelcomeStep, isActive: Bool) -> some View {
        switch page {
        // Hidden per part, never on the page: an ancestor's `accessibilityHidden(false)` would expose the
        // decorative illustrations again.
        case .setup:
            WelcomeSetup()
                .accessibilityHidden(!isActive)
        default:
            VStack(spacing: 28) {
                Group {
                    switch page {
                    case .welcome: WelcomeIllustration(isActive: isActive)
                    case .timeline: TimelineIllustration(isActive: isActive)
                    case .alerts: AlertsIllustration(isActive: isActive)
                    case .developer: PortsIllustration(isActive: isActive)
                    default: CareIllustration(isActive: isActive)
                    }
                }
                .frame(height: 260)
                WelcomeHeading(page)
                    .accessibilityHidden(!isActive)
            }
        }
    }

    private var stepper: some View {
        ZStack {
            StepIndicator(current: step) { step = $0 }
            HStack(spacing: 12) {
                if let previous = step.previous {
                    Button("Back") { step = previous }
                        .controlSize(.large)
                }
                Spacer()
                if step.next != nil, step.next != .setup {
                    Button("Skip Intro") { step = .setup }
                        .buttonStyle(.borderless)
                        .controlSize(.large)
                        .foregroundStyle(.secondary)
                }
                Button(step.next == nil ? "Get Started" : "Continue") {
                    if let next = step.next { step = next } else { onboarding.isPresented = false }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 24)
    }
}

/// A step's title and one paragraph, centered under its illustration.
struct WelcomeHeading: View {
    private let step: WelcomeStep

    init(_ step: WelcomeStep) {
        self.step = step
    }

    var body: some View {
        VStack(spacing: 10) {
            Text(step.title)
                .font(.largeTitle.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Text(step.message)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 480)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One dot per step; the current one stretches into a capsule. Each dot jumps to its step.
private struct StepIndicator: View {
    let current: WelcomeStep
    let select: (WelcomeStep) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(WelcomeStep.allCases) { step in
                Button { select(step) } label: {
                    Capsule()
                        .fill(step == current ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                        .frame(width: step == current ? 20 : 7, height: 7)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 8)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(step.name)
                .accessibilityLabel("\(step.name), step \(step.rawValue + 1) of \(WelcomeStep.allCases.count)")
                .accessibilityAddTraits(step == current ? .isSelected : [])
            }
        }
    }
}

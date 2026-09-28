import AppKit
import CareMyMacUI
import SwiftUI

/// Last welcome step: the four choices that change what CareMyMac does when you aren't looking. Each is also in
/// Settings, none is required, and a permission is asked for only when its switch is turned on.
struct WelcomeSetup: View {
    @Environment(AlertNotifier.self) private var notifier
    @Environment(LoginItem.self) private var loginItem

    @AppStorage(SettingsKey.menuBarEnabled) private var menuBarEnabled = true
    @AppStorage(SettingsKey.alertsEnabled) private var alertsEnabled = true
    @AppStorage(SettingsKey.notificationsEnabled) private var notificationsEnabled = false
    @State private var hasFullDiskAccess = FullDiskAccess.isGranted

    var body: some View {
        VStack(spacing: 24) {
            WelcomeHeading(WelcomeStep.setup)
            VStack(alignment: .leading, spacing: 8) {
                choices
                Label("Nothing leaves this Mac. No account, no telemetry. You can change these anytime in Settings.", systemImage: "hand.raised")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            .frame(maxWidth: 540)
        }
        .task { await refresh() }
        // Coming back from System Settings is when a permission changes.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private var choices: some View {
        VStack(spacing: 0) {
            ChoiceRow("Open at login", symbol: "power", detail: loginDetail, isWarning: loginItem.lastError != nil) {
                Toggle("Open at login", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
                    .labelsHidden()
            }
            Divider().padding(.leading, choiceTextInset)
            ChoiceRow("Keep running in the menu bar", symbol: "menubar.rectangle",
                      detail: "Closing the window leaves CareMyMac measuring.") {
                Toggle("Keep running in the menu bar", isOn: $menuBarEnabled)
                    .labelsHidden()
            }
            Divider().padding(.leading, choiceTextInset)
            ChoiceRow("Notify me about alerts", symbol: "bell.badge", detail: notificationsDetail) {
                if notifier.isDenied {
                    Button("Open Notifications…") { AlertNotifier.openSystemSettings() }
                } else {
                    Toggle("Notify me about alerts", isOn: Binding(get: { notificationsEnabled }, set: { setNotifications($0) }))
                        .labelsHidden()
                        .disabled(!alertsEnabled)
                }
            }
            Divider().padding(.leading, choiceTextInset)
            ChoiceRow("Full Disk Access", symbol: "lock.open",
                      detail: "Optional. Lets Cleanup, Storage and Uninstaller see protected folders.") {
                if hasFullDiskAccess {
                    Label {
                        Text("On")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.live)
                    }
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
                } else {
                    Button("Open Full Disk Access") { FullDiskAccess.openSystemSettings() }
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.3), value: hasFullDiskAccess)
        }
        .toggleStyle(.switch)
        .card(padding: 0)
    }

    // MARK: Copy

    private var loginDetail: String {
        if let error = loginItem.lastError { return error }
        if loginItem.requiresApproval { return "Allow CareMyMac in System Settings › General › Login Items." }
        return "The timeline records only while CareMyMac is running."
    }

    private var notificationsDetail: String {
        notifier.isDenied
            ? "Notifications for CareMyMac are off in System Settings."
            : "A banner when an app stays busy or its memory keeps growing."
    }

    // MARK: Actions

    private func refresh() async {
        loginItem.refresh()
        hasFullDiskAccess = FullDiskAccess.isGranted
        await notifier.refresh()
        if notifier.isDenied { notificationsEnabled = false }
    }

    private func setNotifications(_ enabled: Bool) {
        guard enabled else {
            notificationsEnabled = false
            return
        }
        Task { notificationsEnabled = await notifier.requestAuthorization() }
    }
}

/// Leading edge of a row's text, where the dividers between rows start.
private let choiceTextInset: CGFloat = 16 + 28 + 12

/// Symbol, title and one line of explanation, with the control on the trailing edge.
private struct ChoiceRow<Control: View>: View {
    private let title: String
    private let symbol: String
    private let detail: String
    private let isWarning: Bool
    private let control: Control

    init(_ title: String, symbol: String, detail: String, isWarning: Bool = false, @ViewBuilder control: () -> Control) {
        self.title = title
        self.symbol = symbol
        self.detail = detail
        self.isWarning = isWarning
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(isWarning ? AnyShapeStyle(Palette.warningText) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }
}

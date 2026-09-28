import AppKit
import CareMyMacKit
import CareMyMacUI
import SwiftUI

/// CareMyMac Settings: a native grouped form. Every change applies to the running monitor immediately.
struct SettingsView: View {
    @Environment(LiveMonitor.self) private var monitor
    @Environment(AppModel.self) private var appModel
    @Environment(AlertNotifier.self) private var notifier
    @Environment(LoginItem.self) private var loginItem
    @Environment(Updater.self) private var updater
    @Environment(\.openWindow) private var openWindow

    @AppStorage(SettingsKey.visibleInterval) private var visibleInterval = 2.0
    @AppStorage(SettingsKey.hiddenInterval) private var hiddenInterval = 10.0
    @AppStorage(SettingsKey.menuBarEnabled) private var menuBarEnabled = true
    @AppStorage(SettingsKey.menuBarMetric) private var menuBarMetric: MenuBarMetric = .cpu
    @AppStorage(SettingsKey.menuBarStyle) private var menuBarStyle: MenuBarStyle = .figure
    @AppStorage(SettingsKey.alertsEnabled) private var alertsEnabled = true
    @AppStorage(SettingsKey.notificationsEnabled) private var notificationsEnabled = false

    var body: some View {
        Form {
            monitoring
            menuBar
            alerts
            storage
            updates
            about
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(minHeight: 400, idealHeight: 720, maxHeight: .infinity)
        .onChange(of: visibleInterval) { MonitorPreferences.apply(to: monitor) }
        .onChange(of: hiddenInterval) { MonitorPreferences.apply(to: monitor) }
        .onChange(of: alertsEnabled) { MonitorPreferences.apply(to: monitor) }
        .task {
            loginItem.refresh()
            await notifier.refresh()
            if notifier.isDenied { notificationsEnabled = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
            Task {
                await notifier.refresh()
                if notifier.isDenied { notificationsEnabled = false }
            }
        }
    }

    // MARK: Sections

    private var monitoring: some View {
        Section {
            Picker("Refresh while visible", selection: $visibleInterval) {
                ForEach([1.0, 2, 5], id: \.self) { Text(Self.every($0)).tag($0) }
            }
            Picker("Refresh while hidden", selection: $hiddenInterval) {
                ForEach([5.0, 10, 30], id: \.self) { Text(Self.every($0)).tag($0) }
            }
            Toggle("Open CareMyMac at login", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
            if loginItem.requiresApproval {
                LabeledContent {
                    Button("Open Login Items…") { LoginItem.openSystemSettings() }
                } label: {
                    Text("Waiting for approval")
                    Text("Allow CareMyMac in System Settings → General → Login Items.")
                }
            }
            if let error = loginItem.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Palette.warningText)
                    .font(.callout)
            }
        } header: {
            Text("Monitoring")
        } footer: {
            Text("Markers capture at the visible rate. The timeline records one sample per minute for up to 30 days.")
                .settingsFootnote()
        }
    }

    private var menuBar: some View {
        Section {
            Toggle("Show in menu bar", isOn: $menuBarEnabled)
            Picker("Metric", selection: $menuBarMetric) {
                ForEach(MenuBarMetric.allCases) { Text($0.title).tag($0) }
            }
            .disabled(!menuBarEnabled)
            Picker("Appearance", selection: $menuBarStyle) {
                ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0) }
            }
            .disabled(!menuBarEnabled)
        } header: {
            Text("Menu bar")
        } footer: {
            Text(menuBarEnabled
                ? "CareMyMac keeps running in the menu bar after you close its window."
                : "CareMyMac quits when you close its window.")
                .settingsFootnote()
        }
    }

    private var alerts: some View {
        Section {
            Toggle("Watch for sustained activity", isOn: $alertsEnabled)
            Toggle("Show macOS notifications", isOn: Binding(get: { notificationsEnabled }, set: { setNotifications($0) }))
                .disabled(!alertsEnabled)
            if notifier.isDenied {
                LabeledContent {
                    Button("Open Notifications…") { AlertNotifier.openSystemSettings() }
                } label: {
                    Text("Notifications are off")
                    Text("Allow CareMyMac in System Settings → Notifications to see alerts as banners.")
                }
            }
            LabeledContent("Rules") {
                Button("Configure alerts…", action: configureAlerts)
            }
        } header: {
            Text("Alerts")
        } footer: {
            Text("Alerts for the same app and condition repeat at most once every 10 minutes.")
                .settingsFootnote()
        }
    }

    private var storage: some View {
        Section {
            LabeledContent("Timeline", value: "30 days · one sample per minute")
            LabeledContent("Markers", value: "Up to \(HistoryStore.maxMoments) · 2 min before, 30 s after")
            if let error = monitor.storeError {
                Label {
                    Text("The timeline can't be saved: \(error)")
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Palette.warning)
                }
                .font(.callout)
            }
            LabeledContent("Data folder") {
                Button("Show data folder", action: showDataFolder)
            }
        } header: {
            Text("Local storage")
        } footer: {
            Text("Everything CareMyMac measures is stored in ~/Library/Application Support/CareMyMac.")
                .settingsFootnote()
        }
    }

    private var updates: some View {
        Section {
            Toggle("Check for updates automatically", isOn: Bindable(updater).automaticallyChecks)
            Toggle("Download and install updates automatically", isOn: Bindable(updater).automaticallyDownloads)
                .disabled(!updater.automaticallyChecks)
            LabeledContent {
                Button(updater.availableVersion == nil ? "Check Now" : "Install…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates && updater.availableVersion == nil)
            } label: {
                if let version = updater.availableVersion {
                    Text("CareMyMac \(version) is available")
                } else {
                    Text("Last checked")
                }
                Text(updater.lastCheckDate?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("CareMyMac looks for new releases on GitHub once a day and verifies each update’s signature before installing it.")
                .settingsFootnote()
        }
    }

    private var about: some View {
        Section {
            LabeledContent("Version", value: Self.version)
                .monospacedDigit()
        } header: {
            Text("About")
        } footer: {
            Text("No telemetry. Your measurements never leave this Mac.")
                .settingsFootnote()
        }
    }

    // MARK: Actions

    private func setNotifications(_ enabled: Bool) {
        guard enabled else {
            notificationsEnabled = false
            return
        }
        Task {
            notificationsEnabled = await notifier.requestAuthorization()
        }
    }

    private func configureAlerts() {
        appModel.screen = .alerts
        openWindow(id: WindowID.main)
        NSApp.activate()
    }

    private func showDataFolder() {
        let store = AppDelegate.storeURL
        let folder = store.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: store.path(percentEncoded: false)) {
            NSWorkspace.shared.activateFileViewerSelecting([store])
        } else {
            NSWorkspace.shared.open(folder)
        }
    }

    // MARK: Formatting

    private static func every(_ seconds: Double) -> String {
        seconds == 1 ? "Every second" : "Every \(Format.decimal(seconds, digits: 0)) seconds"
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return build == short ? short : "\(short) (\(build))"
    }
}

private extension Text {
    func settingsFootnote() -> some View {
        font(.callout).foregroundStyle(.secondary)
    }
}

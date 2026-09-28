import AppKit
import CareMyMacKit
import Observation
import UserNotifications

/// Posts macOS notifications for alerts and tracks the authorization Settings shows.
@MainActor
@Observable
final class AlertNotifier {
    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    var isDenied: Bool { authorization == .denied }

    /// Reads the current authorization; call when Settings appears or the app becomes active.
    func refresh() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Asks macOS for permission. Returns whether notifications can be shown.
    func requestAuthorization() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        await refresh()
        return granted
    }

    /// Posts one notification per alert when the user opted in and macOS allows it.
    func post(_ events: [AlertEvent]) {
        guard !events.isEmpty, UserDefaults.standard.bool(forKey: SettingsKey.notificationsEnabled) else { return }
        Task {
            await refresh()
            guard authorization == .authorized || authorization == .provisional else { return }
            let center = UNUserNotificationCenter.current()
            for event in events {
                let content = UNMutableNotificationContent()
                content.title = event.title
                content.body = event.detail
                content.sound = .default
                content.threadIdentifier = event.metric.rawValue
                try? await center.add(UNNotificationRequest(identifier: event.id.uuidString, content: content, trigger: nil))
            }
        }
    }

    /// Notification settings for CareMyMac in System Settings.
    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }
}

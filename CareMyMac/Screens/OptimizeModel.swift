import AppKit
import Foundation
import CareMyMacKit
import Observation

/// State for the Optimize page. One instance lives for the app session so a running maintenance task
/// and its last result survive switching pages; the launch item scan is cancelled when the page goes away.
@Observable
@MainActor
final class OptimizeModel {
    static let shared = OptimizeModel()

    enum LaunchAction {
        case disable, enable, remove
    }

    struct ActionError: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    enum TaskResult {
        case succeeded(at: Date, detail: String?)
        case failed(at: Date, message: String)
    }

    /// Nil until the first scan finishes.
    private(set) var launchItems: [LaunchItem]?
    /// launchctl queries that failed during the last scan.
    private(set) var launchWarnings: [String] = []
    private(set) var isScanning = false
    /// Items with a launchctl action in flight.
    private(set) var busyItemIDs: Set<String> = []
    var actionError: ActionError?

    private(set) var runningTasks: Set<MaintenanceTask.ID> = []
    private(set) var taskResults: [MaintenanceTask.ID: TaskResult] = [:]

    private let scanner = LaunchItemScanner()
    private var scanTask: Task<LaunchItemScan, Error>?

    private init() {}

    // MARK: Launch items

    func scan() {
        scanTask?.cancel()
        let scanner = scanner
        let task = Task.detached(priority: .userInitiated) {
            try await scanner.scan { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        }
        scanTask = task
        isScanning = true
        Task {
            let result = await task.result
            guard scanTask == task else { return }
            scanTask = nil
            isScanning = false
            if case .success(let scan) = result {
                launchItems = scan.items
                launchWarnings = scan.warnings
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    /// Runs a launchctl action on one of your agents, then rescans. Failures go to `actionError`.
    func perform(_ action: LaunchAction, on item: LaunchItem) {
        guard !busyItemIDs.contains(item.id) else { return }
        busyItemIDs.insert(item.id)
        let scanner = scanner
        Task {
            do {
                switch action {
                case .disable:
                    try await scanner.disable(item)
                case .enable:
                    try await scanner.enable(item)
                case .remove:
                    if let failure = try await scanner.remove(item).first {
                        actionError = ActionError(title: "Couldn’t move “\(item.label)” to the Trash", message: failure.message)
                    }
                }
            } catch {
                actionError = ActionError(title: Self.failureTitle(action, item), message: error.localizedDescription)
            }
            busyItemIDs.remove(item.id)
            scan()
        }
    }

    private static func failureTitle(_ action: LaunchAction, _ item: LaunchItem) -> String {
        switch action {
        case .disable: "Couldn’t disable “\(item.label)”"
        case .enable: "Couldn’t enable “\(item.label)”"
        case .remove: "Couldn’t remove “\(item.label)”"
        }
    }

    // MARK: Maintenance

    /// Runs a maintenance task off the main actor. Cancelling the password dialog leaves the last result as it was.
    func run(_ task: MaintenanceTask) {
        guard !runningTasks.contains(task.id) else { return }
        runningTasks.insert(task.id)
        Task {
            do {
                if case .finished(let detail) = try await Maintenance.run(task) {
                    taskResults[task.id] = .succeeded(at: .now, detail: detail)
                }
            } catch {
                taskResults[task.id] = .failed(at: .now, message: error.localizedDescription)
            }
            runningTasks.remove(task.id)
        }
    }
}

import Foundation

/// One fixed maintenance command with a plain explanation of what it does.
public struct MaintenanceTask: Sendable, Hashable, Identifiable {
    public enum ID: String, Sendable, Hashable, CaseIterable {
        case flushDNS, freeMemory, reindexSpotlight, rebuildLaunchServices, thinSnapshots
    }

    public struct Confirmation: Sendable, Hashable {
        public var title: String
        public var message: String
        public var button: String
        /// The task removes something that can't be put back.
        public var isDestructive = false
    }

    public var id: ID
    public var title: String
    public var summary: String
    public var symbol: String
    /// Runs as root through `osascript … with administrator privileges`; macOS asks for a password.
    public var needsAdministrator: Bool
    /// Asked before running, for tasks with a lasting side effect.
    public var confirmation: Confirmation?
    /// Fixed argument vectors, run in order until one fails. Never contains user input.
    public var commands: [[String]]

    public static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    public static let tmutil = "/usr/bin/tmutil"
    /// Bytes asked of `tmutil thinlocalsnapshots`: more than any disk holds, so every removable snapshot goes.
    public static let thinPurgeBytes: Int64 = 999_999_999_999
    /// Highest urgency `thinlocalsnapshots` accepts.
    public static let thinUrgency = 4

    public static let all: [MaintenanceTask] = [
        MaintenanceTask(
            id: .flushDNS,
            title: "Flush DNS Cache",
            summary: "Forgets the website addresses your Mac has already looked up, so the next visit asks the network again. Helps when a site moved to a new server, or when pages stop loading after you change Wi‑Fi, VPN or DNS settings.",
            symbol: "network",
            needsAdministrator: true,
            confirmation: nil,
            commands: [["/usr/bin/dscacheutil", "-flushcache"], ["/usr/bin/killall", "-HUP", "mDNSResponder"]]
        ),
        MaintenanceTask(
            id: .freeMemory,
            title: "Free Up Memory",
            summary: "Runs purge, which empties the file cache macOS keeps in memory. macOS already hands that memory to apps whenever they need it, so this rarely makes anything faster, and apps may reload data from disk for a moment. Useful before a benchmark or a memory measurement.",
            symbol: "memorychip",
            needsAdministrator: true,
            confirmation: nil,
            commands: [["/usr/sbin/purge"]]
        ),
        MaintenanceTask(
            id: .reindexSpotlight,
            title: "Reindex Spotlight",
            summary: "Erases the Spotlight index of your startup disk and builds it again. Helps when searches miss files you know are there. Indexing takes a while, and search results are incomplete until it finishes.",
            symbol: "magnifyingglass",
            needsAdministrator: true,
            confirmation: Confirmation(
                title: "Reindex Spotlight?",
                message: "Spotlight rebuilds its index of your startup disk. This can take an hour or more, and searches in Spotlight, Finder and Mail miss results until it’s done.",
                button: "Reindex"
            ),
            commands: [["/usr/bin/mdutil", "-E", "/"]]
        ),
        MaintenanceTask(
            id: .rebuildLaunchServices,
            title: "Rebuild Launch Services Database",
            summary: "Registers the apps on this Mac again and clears out entries for apps that are gone. Fixes duplicate or missing apps in “Open With” menus and documents opening in the wrong app.",
            symbol: "arrow.up.forward.app",
            needsAdministrator: false,
            confirmation: nil,
            commands: [[lsregister, "-gc", "-r", "-f", "-all", "local,system,user"]]
        ),
        MaintenanceTask(
            id: .thinSnapshots,
            title: "Thin Time Machine Local Snapshots",
            summary: "Removes the snapshots Time Machine keeps on your startup disk between backups. macOS deletes them by itself when space runs low, so this only helps when you need the space right away.",
            symbol: "clock.arrow.circlepath",
            needsAdministrator: false,
            confirmation: Confirmation(
                title: "Thin local snapshots?",
                message: "Time Machine removes the local snapshots on your startup disk. Files changed since your last backup can no longer be restored from them. Your backups on other disks aren’t touched.",
                button: "Thin Snapshots",
                isDestructive: true
            ),
            commands: [[tmutil, "thinlocalsnapshots", "/", String(thinPurgeBytes), String(thinUrgency)]]
        ),
    ]

    /// Executable and arguments that run this task: the commands themselves, or one `osascript` call for administrator tasks.
    public var invocations: [(executable: String, arguments: [String])] {
        if needsAdministrator {
            return [(OptimizeCommand.osascript, OptimizeCommand.administratorArguments(commands))]
        }
        return commands.compactMap { argv in argv.first.map { ($0, Array(argv.dropFirst())) } }
    }
}

public enum MaintenanceOutcome: Sendable, Hashable {
    /// Finished; `detail` describes what changed when the command reports it.
    case finished(detail: String?)
    /// The administrator password dialog was cancelled.
    case cancelled
}

public enum Maintenance {
    /// Runs a task off the main actor. Throws when a command fails; cancelling the password dialog isn't a failure.
    public static func run(_ task: MaintenanceTask) async throws(CommandError) -> MaintenanceOutcome {
        let before = task.id == .thinSnapshots ? try await localSnapshots() : nil
        if before?.isEmpty == true { return .finished(detail: "There were no local snapshots to remove.") }

        for invocation in task.invocations {
            let result = try await OptimizeCommand.run(invocation.executable, invocation.arguments)
            if task.needsAdministrator {
                if OptimizeCommand.isUserCancel(result) { return .cancelled }
                guard result.succeeded else {
                    throw CommandError(command: task.title, status: result.status, message: OptimizeCommand.scriptErrorMessage(result))
                }
            } else if !result.succeeded {
                throw CommandError(command: task.title, status: result.status, message: result.message)
            }
        }

        guard let before else { return .finished(detail: nil) }
        let after = try await localSnapshots()
        return .finished(detail: thinningSummary(before: before.count, after: after.count))
    }

    /// Snapshot names from `tmutil listlocalsnapshots /`.
    static func localSnapshots() async throws(CommandError) -> [String] {
        let result = try await OptimizeCommand.run(MaintenanceTask.tmutil, ["listlocalsnapshots", "/"])
        guard result.succeeded else {
            throw CommandError(command: "tmutil listlocalsnapshots", status: result.status, message: result.message)
        }
        return parseLocalSnapshots(result.output)
    }

    /// `tmutil listlocalsnapshots` output: a "Snapshots for disk /:" header, then one snapshot name per line.
    public static func parseLocalSnapshots(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasSuffix(":") }
    }

    public static func thinningSummary(before: Int, after: Int) -> String {
        let removed = max(before - after, 0)
        let noun = { (count: Int) in count == 1 ? "1 snapshot" : "\(count.formatted()) snapshots" }
        if removed == 0 { return before == 1 ? "Time Machine kept its only snapshot." : "Time Machine kept all \(noun(before))." }
        if after == 0 { return "Removed \(noun(removed))." }
        return "Removed \(noun(removed)); Time Machine kept \(after.formatted())."
    }
}

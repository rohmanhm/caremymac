import Darwin
import Foundation

/// Where a launchd property list lives, which decides who it runs for and who can change it.
public enum LaunchItemDomain: String, Sendable, Hashable, CaseIterable {
    /// `~/Library/LaunchAgents`: runs when you log in; you can change it.
    case user
    /// `/Library/LaunchAgents`: runs for every user who logs in; changing it needs an administrator.
    case allUsers
    /// `/Library/LaunchDaemons`: runs as root at startup; changing it needs an administrator.
    case system

    public var isEditable: Bool { self == .user }

    /// Folder of this domain's property lists.
    public func directory(home: URL) -> URL {
        switch self {
        case .user: home.appending(path: "Library/LaunchAgents", directoryHint: .isDirectory)
        case .allUsers: URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true)
        case .system: URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true)
        }
    }
}

public enum LaunchItemKeepAlive: Sendable, Hashable {
    case never
    /// `KeepAlive = true`: launchd restarts it whenever it exits.
    case always
    /// `KeepAlive` is a dictionary: restarted only under the conditions it lists.
    case conditional
}

/// Whether launchd has the job loaded right now.
public enum LaunchItemState: Sendable, Hashable {
    case running(pid: Int32)
    /// Loaded but not running; `lastExitStatus` is launchd's last exit code (negative for a signal).
    case loaded(lastExitStatus: Int32?)
    case notLoaded
    /// launchctl couldn't be asked.
    case unknown

    public var isLoaded: Bool {
        switch self {
        case .running, .loaded: true
        case .notLoaded, .unknown: false
        }
    }
}

/// The app a launch item belongs to.
public struct LaunchItemOwner: Sendable, Hashable {
    public var name: String
    /// The `.app` bundle, for its icon and Reveal in Finder.
    public var appPath: String

    public init(name: String, appPath: String) {
        self.name = name
        self.appPath = appPath
    }

    /// Outermost `.app` bundle containing an absolute program path, e.g.
    /// "/Applications/Docker.app/Contents/MacOS/com.docker.backend" → "/Applications/Docker.app".
    public static func appBundlePath(containing program: String) -> String? {
        guard program.hasPrefix("/") else { return nil }
        var path = ""
        for component in program.split(separator: "/", omittingEmptySubsequences: true) {
            path += "/" + component
            if component.count > 4, component.lowercased().hasSuffix(".app") { return path }
        }
        return nil
    }

    /// Bundle identifiers a label could belong to, longest first: "com.google.keystone.agent" →
    /// "com.google.keystone.agent", "com.google.keystone", "com.google".
    public static func bundleIdentifierCandidates(label: String) -> [String] {
        let parts = label.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, !parts.contains(where: \.isEmpty) else { return [] }
        return (2...parts.count).reversed().map { parts.prefix($0).joined(separator: ".") }
    }

    /// App display name from its bundle path: "/Applications/Docker.app" → "Docker".
    public static func name(appPath: String) -> String {
        let file = (appPath as NSString).lastPathComponent
        return file.lowercased().hasSuffix(".app") ? String(file.dropLast(4)) : file
    }

    /// Attribution order: the program lives inside an app; else the plist's `AssociatedBundleIdentifiers`;
    /// else an installed app whose bundle ID is a prefix of the label; else nil (unknown).
    public static func resolve(
        program: String?,
        associatedBundleIdentifiers: [String],
        label: String,
        appURLForBundleIdentifier: (String) -> URL?
    ) -> LaunchItemOwner? {
        if let program, let app = appBundlePath(containing: program) {
            return LaunchItemOwner(name: name(appPath: app), appPath: app)
        }
        for identifier in associatedBundleIdentifiers + bundleIdentifierCandidates(label: label) {
            if let url = appURLForBundleIdentifier(identifier) {
                return LaunchItemOwner(name: name(appPath: url.path), appPath: url.path)
            }
        }
        return nil
    }
}

/// One launchd job defined by a property list in a LaunchAgents or LaunchDaemons folder.
public struct LaunchItem: Sendable, Hashable, Identifiable {
    public var id: String { plistPath }
    public var label: String
    public var plistPath: String
    public var domain: LaunchItemDomain
    /// `Program`, else `ProgramArguments[0]`.
    public var program: String?
    public var arguments: [String]
    public var runAtLoad: Bool
    public var keepAlive: LaunchItemKeepAlive
    public var associatedBundleIdentifiers: [String]
    /// The plist's own `Disabled` key; launchctl's override (if any) wins.
    public var disabledInPlist: Bool
    public var owner: LaunchItemOwner?
    public var isEnabled: Bool
    public var state: LaunchItemState
    /// Allocated size of the property list, for the removal confirmation.
    public var fileSize: Int64

    public init(label: String, plistPath: String, domain: LaunchItemDomain, program: String?, arguments: [String], runAtLoad: Bool, keepAlive: LaunchItemKeepAlive, associatedBundleIdentifiers: [String], disabledInPlist: Bool, owner: LaunchItemOwner? = nil, isEnabled: Bool? = nil, state: LaunchItemState = .unknown, fileSize: Int64 = 0) {
        self.label = label
        self.plistPath = plistPath
        self.domain = domain
        self.program = program
        self.arguments = arguments
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
        self.associatedBundleIdentifiers = associatedBundleIdentifiers
        self.disabledInPlist = disabledInPlist
        self.owner = owner
        self.isEnabled = isEnabled ?? !disabledInPlist
        self.state = state
        self.fileSize = fileSize
    }

    /// Parses a launchd property list (XML or binary). Nil when it isn't a dictionary with a non-empty `Label`.
    public static func parse(_ data: Data, plistPath: String, domain: LaunchItemDomain) -> LaunchItem? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = plist["Label"] as? String, !label.isEmpty else { return nil }
        let arguments = plist["ProgramArguments"] as? [String] ?? []
        let program = (plist["Program"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? arguments.first
        let keepAlive: LaunchItemKeepAlive = switch plist["KeepAlive"] {
        case let value as Bool: value ? .always : .never
        case is [String: Any]: .conditional
        default: .never
        }
        let associated: [String] = switch plist["AssociatedBundleIdentifiers"] {
        case let value as String: [value]
        case let value as [String]: value
        default: []
        }
        return LaunchItem(
            label: label,
            plistPath: plistPath,
            domain: domain,
            program: program,
            arguments: arguments,
            runAtLoad: plist["RunAtLoad"] as? Bool ?? false,
            keepAlive: keepAlive,
            associatedBundleIdentifiers: associated,
            disabledInPlist: plist["Disabled"] as? Bool ?? false
        )
    }
}

/// Status of one job in `launchctl list` or `launchctl print`.
public struct LaunchJobStatus: Sendable, Hashable {
    public var pid: Int32?
    public var lastExitStatus: Int32?

    public init(pid: Int32?, lastExitStatus: Int32?) {
        self.pid = pid
        self.lastExitStatus = lastExitStatus
    }

    public var state: LaunchItemState {
        if let pid { .running(pid: pid) } else { .loaded(lastExitStatus: lastExitStatus) }
    }
}

/// `/bin/launchctl` invocations and output parsing.
public enum Launchctl {
    public static let path = "/bin/launchctl"

    public static func userDomain(uid: uid_t) -> String { "gui/\(uid)" }

    public static func userService(label: String, uid: uid_t) -> String { "gui/\(uid)/\(label)" }

    /// `launchctl print-disabled <domain>`: label → disabled. Accepts "enabled"/"disabled" and the older "false"/"true".
    public static func parseDisabled(_ output: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("\""), let arrow = text.range(of: "\" => ") else { continue }
            let label = String(text[text.index(after: text.startIndex)..<arrow.lowerBound])
            switch text[arrow.upperBound...].trimmingCharacters(in: .whitespaces) {
            case "disabled", "true": result[label] = true
            case "enabled", "false": result[label] = false
            default: continue
            }
        }
        return result
    }

    /// `launchctl list`: "PID\tStatus\tLabel" rows; PID "-" means loaded but not running.
    public static func parseList(_ output: String) -> [String: LaunchJobStatus] {
        var result: [String: LaunchJobStatus] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            let pidField = fields[0].trimmingCharacters(in: .whitespaces)
            let label = fields[2].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, pidField == "-" || Int32(pidField) != nil else { continue }
            result[label] = LaunchJobStatus(pid: Int32(pidField).flatMap { $0 > 0 ? $0 : nil }, lastExitStatus: Int32(fields[1].trimmingCharacters(in: .whitespaces)))
        }
        return result
    }

    /// The `services = { … }` block of `launchctl print <domain>`: "PID  last-exit  label" rows, PID 0 when not running.
    public static func parsePrintServices(_ output: String) -> [String: LaunchJobStatus] {
        var result: [String: LaunchJobStatus] = [:]
        var inServices = false
        for line in output.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if !inServices {
                inServices = text == "services = {"
                continue
            }
            if text == "}" { break }
            let fields = text.split(whereSeparator: \.isWhitespace)
            guard fields.count == 3, let pid = Int32(fields[0]) else { continue }
            result[String(fields[2])] = LaunchJobStatus(pid: pid > 0 ? pid : nil, lastExitStatus: Int32(fields[1]))
        }
        return result
    }

    static func run(_ arguments: [String]) async throws(CommandError) -> CommandResult {
        try await OptimizeCommand.run(path, arguments)
    }

    static func runChecked(_ arguments: [String], allowing allowed: Set<Int32> = []) async throws(CommandError) {
        let result = try await run(arguments)
        guard result.succeeded || allowed.contains(result.status) else {
            throw CommandError(command: "launchctl \(arguments.first ?? "")", status: result.status, message: result.message)
        }
    }

    /// Exit statuses of `bootout` for a job that isn't loaded (ESRCH, "Could not find specified service").
    static let notLoadedStatuses: Set<Int32> = [3, 113]
}

/// Launch items on disk plus their launchd state.
public struct LaunchItemScan: Sendable, Hashable {
    public var items: [LaunchItem]
    /// launchctl queries that failed; items then show an unknown state.
    public var warnings: [String]

    public init(items: [LaunchItem], warnings: [String]) {
        self.items = items
        self.warnings = warnings
    }
}

/// Finds launchd property lists and changes the current user's own agents.
public struct LaunchItemScanner: Sendable {
    public var home: URL
    public var uid: uid_t
    public var domains: [LaunchItemDomain]

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, uid: uid_t = getuid(), domains: [LaunchItemDomain] = LaunchItemDomain.allCases) {
        self.home = home
        self.uid = uid
        self.domains = domains
    }

    /// Parsed property lists of every domain, sorted by label; unreadable or malformed files are skipped.
    public func definitions() throws -> [LaunchItem] {
        var items: [LaunchItem] = []
        for domain in domains {
            let directory = domain.directory(home: home)
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
            for file in files where file.pathExtension == "plist" {
                try Task.checkCancellation()
                guard let data = try? Data(contentsOf: file),
                      var item = LaunchItem.parse(data, plistPath: file.path, domain: domain) else { continue }
                item.fileSize = try CareFiles.allocatedSize(of: file)
                items.append(item)
            }
        }
        return items.sorted { lhs, rhs in
            switch lhs.label.localizedStandardCompare(rhs.label) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: lhs.plistPath < rhs.plistPath
            }
        }
    }

    /// Definitions with owner, enabled override and loaded state. Call off the main actor.
    public func scan(appURLForBundleIdentifier: @Sendable (String) -> URL?) async throws -> LaunchItemScan {
        var items = try definitions()
        var warnings: [String] = []

        func query(_ arguments: [String]) async -> String? {
            do {
                let result = try await Launchctl.run(arguments)
                if result.succeeded { return result.output }
                warnings.append("launchctl \(arguments.joined(separator: " ")): \(result.message)")
            } catch {
                warnings.append("launchctl \(arguments.joined(separator: " ")): \(error.localizedDescription)")
            }
            return nil
        }

        let userDomain = Launchctl.userDomain(uid: uid)
        let needsSystem = items.contains { $0.domain == .system }
        let userDisabled = await query(["print-disabled", userDomain]).map(Launchctl.parseDisabled)
        let userJobs = await query(["list"]).map(Launchctl.parseList)
        var systemDisabled: [String: Bool]? = [:]
        var systemJobs: [String: LaunchJobStatus]? = [:]
        if needsSystem {
            systemDisabled = await query(["print-disabled", "system"]).map(Launchctl.parseDisabled)
            systemJobs = await query(["print", "system"]).map(Launchctl.parsePrintServices)
        }
        try Task.checkCancellation()

        for index in items.indices {
            let item = items[index]
            let disabled = item.domain == .system ? systemDisabled : userDisabled
            let jobs = item.domain == .system ? systemJobs : userJobs
            items[index].isEnabled = !(disabled?[item.label] ?? item.disabledInPlist)
            if let jobs {
                items[index].state = jobs[item.label]?.state ?? .notLoaded
            }
            items[index].owner = LaunchItemOwner.resolve(
                program: item.program,
                associatedBundleIdentifiers: item.associatedBundleIdentifiers,
                label: item.label,
                appURLForBundleIdentifier: appURLForBundleIdentifier
            )
        }
        return LaunchItemScan(items: items, warnings: warnings)
    }

    // MARK: Actions (your own agents only)

    /// Unloads the agent, then records it as disabled so it doesn't load at the next login.
    public func disable(_ item: LaunchItem) async throws(CommandError) {
        try requireEditable(item)
        let service = Launchctl.userService(label: item.label, uid: uid)
        if item.state.isLoaded || item.state == .unknown {
            try await Launchctl.runChecked(["bootout", service], allowing: Launchctl.notLoadedStatuses)
        }
        try await Launchctl.runChecked(["disable", service])
    }

    /// Records the agent as enabled, then loads it now.
    public func enable(_ item: LaunchItem) async throws(CommandError) {
        try requireEditable(item)
        try await Launchctl.runChecked(["enable", Launchctl.userService(label: item.label, uid: uid)])
        if !item.state.isLoaded {
            try await Launchctl.runChecked(["bootstrap", Launchctl.userDomain(uid: uid), item.plistPath])
        }
    }

    /// Unloads the agent and moves its property list to the Trash. Returns files that couldn't be moved.
    public func remove(_ item: LaunchItem) async throws(CommandError) -> [CareFailure] {
        try requireEditable(item)
        if item.state.isLoaded || item.state == .unknown {
            try await Launchctl.runChecked(["bootout", Launchctl.userService(label: item.label, uid: uid)], allowing: Launchctl.notLoadedStatuses)
        }
        return CareFiles.moveToTrash([URL(fileURLWithPath: item.plistPath)])
    }

    private func requireEditable(_ item: LaunchItem) throws(CommandError) {
        guard item.domain.isEditable else {
            throw CommandError(command: "launchctl", status: -1, message: "Changing \(item.label) needs an administrator.")
        }
    }
}

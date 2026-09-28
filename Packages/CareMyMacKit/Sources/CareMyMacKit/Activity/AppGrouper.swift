import Foundation

/// A running application as reported by the window server (NSRunningApplication), as plain data.
public struct RunningAppInfo: Sendable, Hashable {
    public enum ActivationPolicy: Sendable, Hashable {
        /// Dock app.
        case regular
        /// Menu bar / UI element app.
        case accessory
        /// Background-only app.
        case prohibited
    }

    public var pid: Int32
    public var bundleIdentifier: String?
    /// Path of the .app bundle, without trailing slash.
    public var bundlePath: String?
    /// Localized display name.
    public var name: String
    public var activationPolicy: ActivationPolicy

    public init(pid: Int32, bundleIdentifier: String?, bundlePath: String?, name: String, activationPolicy: ActivationPolicy) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
        self.name = name
        self.activationPolicy = activationPolicy
    }
}

/// Identity of an .app bundle that is not running as a regular app.
public struct BundleMetadata: Sendable, Hashable {
    public var name: String
    public var bundleIdentifier: String?

    public init(name: String, bundleIdentifier: String?) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
    }
}

/// Attributes processes to apps. Pure: all system facts arrive as arguments.
///
/// Rules, in order, per process:
/// 1. It is a running regular app, or its executable lies inside the bundle of one
///    (the innermost enclosing .app that is a running regular app, so helper apps in
///    `Contents/Frameworks/*.app` map to their parent app).
/// 2. The app of its nearest ancestor (below launchd) that these rules attribute to an app.
/// 3. The app of its responsible process (`ProcessStats.responsiblePID`), e.g. WebKit XPC services
///    launchd starts for a browser. Ancestry wins over responsibility so an app's own children stay
///    with it even when the app itself was launched by (and is "responsible to") Xcode or a terminal.
/// 4. Its executable lies inside any .app: a background app for the outermost bundle.
/// 5. Standalone, keyed by executable path: `.system` for root or OS paths, else `.background`.
public struct AppGrouper: Sendable {
    public var bundleMetadata: @Sendable (String) -> BundleMetadata?

    /// - Parameter bundleMetadata: Name and identifier for a bundle path; `nil` falls back to the file name.
    public init(bundleMetadata: @escaping @Sendable (String) -> BundleMetadata? = { _ in nil }) {
        self.bundleMetadata = bundleMetadata
    }

    private static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/"]

    private enum Owner: Hashable {
        case regular(Int32)
        case bundle(String)
    }

    public func group(processes: [ProcessStats], runningApps: [RunningAppInfo]) -> [AppActivity] {
        var regularByPID: [Int32: RunningAppInfo] = [:]
        var regularByBundle: [String: RunningAppInfo] = [:]
        var anyByBundle: [String: RunningAppInfo] = [:]
        for app in runningApps {
            if let path = app.bundlePath.map(Self.normalized) {
                if anyByBundle[path] == nil || app.activationPolicy == .regular { anyByBundle[path] = app }
                if app.activationPolicy == .regular { regularByBundle[path] = app }
            }
            if app.activationPolicy == .regular { regularByPID[app.pid] = app }
        }

        // Direct attribution from the process's own identity (rules 1 and 4).
        var direct: [Int32: Owner] = [:]
        var regularDirect = Set<Int32>()
        var parent: [Int32: Int32] = [:]
        var responsible: [Int32: Int32] = [:]
        for process in processes {
            parent[process.pid] = process.ppid
            if let pid = process.responsiblePID, pid != process.pid { responsible[process.pid] = pid }
            if let app = regularByPID[process.pid] {
                direct[process.pid] = .regular(app.pid)
                regularDirect.insert(process.pid)
                continue
            }
            let bundles = process.executablePath.map(Self.appBundles(in:)) ?? []
            if let app = bundles.reversed().lazy.compactMap({ regularByBundle[$0] }).first {
                direct[process.pid] = .regular(app.pid)
                regularDirect.insert(process.pid)
            } else if let outermost = bundles.first {
                direct[process.pid] = .bundle(outermost)
            }
        }

        var apps: [AppActivity] = []
        var indexByKey: [String: Int] = [:]
        func add(_ process: ProcessStats, key: String, make: () -> AppActivity) {
            if let index = indexByKey[key] {
                apps[index].processes.append(process)
            } else {
                var app = make()
                app.processes.append(process)
                indexByKey[key] = apps.count
                apps.append(app)
            }
        }

        var resolved: [Int32: Owner?] = [:]
        func owner(of pid: Int32, depth: Int) -> Owner? {
            if let hit = resolved[pid] { return hit }
            var answer: Owner?
            if regularDirect.contains(pid) {
                answer = direct[pid]
            } else if depth < 64 {
                if let ppid = parent[pid], ppid > 1, ppid != pid {
                    answer = owner(of: ppid, depth: depth + 1)
                }
                if answer == nil, let rpid = responsible[pid] {
                    answer = owner(of: rpid, depth: depth + 1)
                }
                answer = answer ?? direct[pid]
            } else {
                answer = direct[pid]
            }
            resolved[pid] = .some(answer)
            return answer
        }

        for process in processes {
            switch owner(of: process.pid, depth: 0) {
            case .regular(let appPID):
                guard let app = regularByPID[appPID] else { continue }
                let id = app.bundleIdentifier ?? app.bundlePath.map(Self.normalized) ?? "pid:\(app.pid)"
                add(process, key: id) {
                    AppActivity(id: id, name: app.name, bundleIdentifier: app.bundleIdentifier,
                                bundlePath: app.bundlePath.map(Self.normalized), kind: .application,
                                mainPID: app.pid, processes: [])
                }
            case .bundle(let path):
                // Keyed by path first so metadata is resolved once per bundle.
                add(process, key: bundleKeyPrefix + path) {
                    let running = anyByBundle[path]
                    let metadata = running.map { BundleMetadata(name: $0.name, bundleIdentifier: $0.bundleIdentifier) }
                        ?? bundleMetadata(path)
                    return AppActivity(id: metadata?.bundleIdentifier ?? path, name: metadata?.name ?? Self.bundleFileName(path),
                                       bundleIdentifier: metadata?.bundleIdentifier, bundlePath: path, kind: .background,
                                       mainPID: running?.pid, processes: [])
                }
            case nil:
                let id = process.executablePath ?? "pid:\(process.pid)"
                add(process, key: id) {
                    let isSystem = process.uid == 0
                        || process.executablePath.map { path in Self.systemPrefixes.contains { path.hasPrefix($0) } } == true
                    return AppActivity(id: id, name: process.name, bundleIdentifier: nil, bundlePath: process.executablePath,
                                       kind: isSystem ? .system : .background, mainPID: nil, processes: [])
                }
            }
        }

        apps = Self.mergingDuplicateIDs(apps)
        for index in apps.indices {
            apps[index].processes.sort { ($0.cpu, $1.pid) > ($1.cpu, $0.pid) }
            let app = apps[index]
            guard app.mainPID == nil else { continue }
            if app.kind == .background, let bundle = app.bundlePath, bundle.hasSuffix(".app") {
                let mainDir = bundle + "/Contents/MacOS/"
                apps[index].mainPID = app.processes
                    .filter { $0.executablePath?.hasPrefix(mainDir) == true }
                    .min { $0.pid < $1.pid }?.pid
            } else if app.processes.count == 1 {
                apps[index].mainPID = app.processes[0].pid
            }
        }
        // CPU desc, memory desc, then name.
        return apps
            .map { (cpu: $0.cpu, memory: $0.memory, name: $0.name.lowercased(), app: $0) }
            .sorted { lhs, rhs in
                if lhs.cpu != rhs.cpu { return lhs.cpu > rhs.cpu }
                if lhs.memory != rhs.memory { return lhs.memory > rhs.memory }
                return (lhs.name, lhs.app.id) < (rhs.name, rhs.app.id)
            }
            .map(\.app)
    }

    private let bundleKeyPrefix = "bundle:"

    /// Groups must have unique ids; a background bundle sharing an id with another group joins it.
    private static func mergingDuplicateIDs(_ apps: [AppActivity]) -> [AppActivity] {
        var indexByID: [String: Int] = [:]
        var merged: [AppActivity] = []
        merged.reserveCapacity(apps.count)
        for app in apps {
            if let index = indexByID[app.id] {
                if app.kind == .application {
                    let absorbed = merged[index].processes
                    merged[index] = app
                    merged[index].processes += absorbed
                } else {
                    merged[index].processes += app.processes
                }
            } else {
                indexByID[app.id] = merged.count
                merged.append(app)
            }
        }
        return merged
    }

    /// Every enclosing `.app` bundle path of `path`, outermost first.
    public static func appBundles(in path: String) -> [String] {
        var result: [String] = []
        var path = path
        path.withUTF8 { bytes in
            guard bytes.count >= 5 else { return }
            for end in 4..<bytes.count where bytes[end] == UInt8(ascii: "/") {
                // ".app" in any case immediately before the slash.
                if bytes[end - 4] == UInt8(ascii: "."),
                   bytes[end - 3] | 0x20 == UInt8(ascii: "a"),
                   bytes[end - 2] | 0x20 == UInt8(ascii: "p"),
                   bytes[end - 1] | 0x20 == UInt8(ascii: "p") {
                    result.append(String(decoding: UnsafeBufferPointer(rebasing: bytes[..<end]), as: UTF8.self))
                }
            }
        }
        return result
    }

    static func normalized(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    static func bundleFileName(_ path: String) -> String {
        let file = (path as NSString).lastPathComponent
        return file.lowercased().hasSuffix(".app") ? String(file.dropLast(4)) : file
    }
}

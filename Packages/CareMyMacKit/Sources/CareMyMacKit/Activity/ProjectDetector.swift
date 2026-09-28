import Darwin
import Foundation

/// Groups development runtime processes (and their descendants) by the project folder they run in.
public final class ProjectDetector {
    private let homeDirectory: String
    private let directoryEntries: (String) -> [String]?
    private var rootCache: [String: String?] = [:]
    private var rootCacheDate: Date?
    private static let rootCacheLifetime: TimeInterval = 30

    /// - Parameters:
    ///   - homeDirectory: Marker search stops below this folder.
    ///   - directoryEntries: File names in a folder, `nil` when unreadable.
    public init(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        directoryEntries: @escaping (String) -> [String]? = ProjectDetector.directoryEntries
    ) {
        self.homeDirectory = Self.normalized(homeDirectory)
        self.directoryEntries = directoryEntries
    }

    private static let markerNames: Set<String> = [
        "package.json", "pyproject.toml", "requirements.txt", "Gemfile", "go.mod", "Cargo.toml",
        "pom.xml", "composer.json", "mix.exs", "Package.swift", ".git", "deno.json", "deno.jsonc",
    ]

    public static func isProjectMarker(_ fileName: String) -> Bool {
        markerNames.contains(fileName) || fileName.hasPrefix("build.gradle") || fileName.hasSuffix(".csproj")
    }

    /// Runtime of a process judged by its executable, or nil for anything else.
    ///
    /// Runtimes embedded in app bundles or under Application Support belong to editors and apps,
    /// not projects, and are ignored (framework Python and Xcode toolchains excepted).
    public static func runtime(executablePath: String?, name: String) -> DevRuntime? {
        let path = executablePath ?? ""
        let isFrameworkPython = path.contains("/Python.framework/")
        if !isFrameworkPython, !path.contains("/Contents/Developer/"),
           path.contains(".app/") || path.contains("/Library/Application Support/") {
            return nil
        }
        if isFrameworkPython { return .python }
        if path.contains("/go-build") { return .go }

        let base = ProcessSampler.displayName(path: executablePath, fallback: name).lowercased()
        switch base {
        case "node", "nodejs": return .node
        case "bun": return .bun
        case "deno": return .deno
        case "go": return .go
        case "java": return .java
        case "cargo", "rustc": return .rust
        case "dotnet": return .dotnet
        case "beam.smp", "erl", "elixir": return .elixir
        case "swift", "swiftc", "swift-frontend", "swift-driver", "swift-build", "swift-run", "swift-test", "swift-package":
            return .swift
        default: break
        }
        if matches(base, prefix: "python", allowing: "0123456789.w") { return .python }
        if matches(base, prefix: "ruby", allowing: "0123456789.") { return .ruby }
        if matches(base, prefix: "php", allowing: "0123456789.") || base == "php-fpm" || base == "php-cgi" { return .php }
        return nil
    }

    private static func matches(_ name: String, prefix: String, allowing suffixCharacters: String) -> Bool {
        name.hasPrefix(prefix) && name.dropFirst(prefix.count).allSatisfy { suffixCharacters.contains($0) }
    }

    /// Folders where runtimes run as OS or toolchain services, never as projects.
    private static let nonProjectPrefixes = ["/System/", "/Library/", "/usr/", "/bin/", "/sbin/", "/opt/homebrew/", "/Applications/"]

    /// Nearest folder at or above `workingDirectory` (and below home) holding a project marker,
    /// else the working directory itself; nil for "/" and OS/toolchain folders.
    public func projectRoot(forWorkingDirectory workingDirectory: String) -> String? {
        let cwd = Self.normalized(workingDirectory)
        guard cwd.hasPrefix("/"), cwd != "/",
              !Self.nonProjectPrefixes.contains(where: { (cwd + "/").hasPrefix($0) }) else { return nil }
        if let cached = rootCache[cwd] { return cached }
        var root = cwd
        var directory = cwd
        while directory != "/", directory != homeDirectory {
            if directoryEntries(directory)?.contains(where: Self.isProjectMarker) == true {
                root = directory
                break
            }
            directory = (directory as NSString).deletingLastPathComponent
        }
        rootCache[cwd] = .some(root)
        return root
    }

    /// Projects from a process list. `workingDirectory` and `ports` are only called for runtime processes
    /// and project members respectively.
    public func projects(
        processes: [ProcessStats],
        now: Date = .now,
        workingDirectory: (Int32) -> String?,
        ports: ([Int32]) -> [ListeningPort]
    ) -> [ProjectActivity] {
        let cacheExpired = rootCacheDate.map { now < $0 || now.timeIntervalSince($0) >= Self.rootCacheLifetime } ?? true
        if cacheExpired {
            rootCache.removeAll(keepingCapacity: true)
            rootCacheDate = now
        }

        var parent: [Int32: Int32] = [:]
        var ownRoot: [Int32: String] = [:]
        var runtimes: [Int32: DevRuntime] = [:]
        for process in processes {
            parent[process.pid] = process.ppid
            guard !process.isRestricted, let runtime = Self.runtime(executablePath: process.executablePath, name: process.name) else { continue }
            runtimes[process.pid] = runtime
            if let cwd = workingDirectory(process.pid), let root = projectRoot(forWorkingDirectory: cwd) {
                ownRoot[process.pid] = root
            }
        }
        guard !runtimes.isEmpty else { return [] }

        var resolved: [Int32: String?] = [:]
        func root(of pid: Int32, depth: Int) -> String? {
            if let hit = resolved[pid] { return hit }
            var answer = ownRoot[pid]
            if answer == nil, depth < 64, let ppid = parent[pid], ppid > 1, ppid != pid {
                answer = root(of: ppid, depth: depth + 1)
            }
            resolved[pid] = .some(answer)
            return answer
        }

        var members: [String: [ProcessStats]] = [:]
        for process in processes {
            if let root = root(of: process.pid, depth: 0) {
                members[root, default: []].append(process)
            }
        }

        var projects = members.map { root, processes in
            let kinds = Set(processes.compactMap { runtimes[$0.pid] })
            return ProjectActivity(
                id: root,
                name: (root as NSString).lastPathComponent,
                runtimes: DevRuntime.allCases.filter(kinds.contains),
                processes: processes.sorted { ($0.cpu, $1.pid) > ($1.cpu, $0.pid) },
                ports: ports(processes.map(\.pid))
            )
        }
        projects.sort { lhs, rhs in
            let (lc, rc) = (lhs.cpu, rhs.cpu)
            if lc != rc { return lc > rc }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return projects
    }

    /// Current working directory of a process, when we may inspect it.
    public static func workingDirectory(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return ProcessSampler.string(fromTuple: info.pvi_cdir.vip_path).nonEmptyPath
    }

    public static func directoryEntries(_ path: String) -> [String]? {
        guard let directory = opendir(path) else { return nil }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = ProcessSampler.string(fromTuple: entry.pointee.d_name)
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    static func normalized(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

private extension String {
    var nonEmptyPath: String? { isEmpty ? nil : self }
}

import Foundation

public struct ProcessStats: Sendable, Hashable, Codable, Identifiable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var ppid: Int32
    public var name: String
    public var executablePath: String?
    /// Share of ONE core (1.0 = 100%, can exceed 1 on multi-core).
    public var cpu: Double
    /// Physical footprint in bytes (what Activity Monitor calls "Memory").
    public var memory: UInt64
    public var threads: Int
    public var uid: UInt32
    public var startDate: Date?
    public var diskReadBytesPerSecond: Double
    public var diskWriteBytesPerSecond: Double
    /// True when the kernel refused task info (other users' processes without privileges).
    public var isRestricted: Bool
    /// Process macOS holds responsible for this one (e.g. the app an XPC service runs for); nil when it is itself or unknown.
    public var responsiblePID: Int32?

    public init(pid: Int32, ppid: Int32, name: String, executablePath: String?, cpu: Double, memory: UInt64, threads: Int, uid: UInt32, startDate: Date?, diskReadBytesPerSecond: Double, diskWriteBytesPerSecond: Double, isRestricted: Bool, responsiblePID: Int32? = nil) {
        self.pid = pid
        self.ppid = ppid
        self.name = name
        self.executablePath = executablePath
        self.cpu = cpu
        self.memory = memory
        self.threads = threads
        self.uid = uid
        self.startDate = startDate
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
        self.isRestricted = isRestricted
        self.responsiblePID = responsiblePID
    }
}

public enum AppKind: String, Sendable, Hashable, Codable {
    /// Regular app with a Dock presence.
    case application
    /// Agents, helpers, login items, and user daemons owned by a bundle.
    case background
    /// Unattributed system processes.
    case system
}

/// One app with all processes attributed to it.
public struct AppActivity: Sendable, Hashable, Codable, Identifiable {
    /// Bundle identifier, else bundle path, else "pid:<n>".
    public var id: String
    public var name: String
    public var bundleIdentifier: String?
    /// Path of the .app bundle (or the executable for unbundled processes).
    public var bundlePath: String?
    public var kind: AppKind
    /// PID of the main process (the app itself), if running.
    public var mainPID: Int32?
    public var processes: [ProcessStats]

    public var cpu: Double { processes.reduce(0) { $0 + $1.cpu } }
    public var memory: UInt64 { processes.reduce(0) { $0 + $1.memory } }
    public var diskReadBytesPerSecond: Double { processes.reduce(0) { $0 + $1.diskReadBytesPerSecond } }
    public var diskWriteBytesPerSecond: Double { processes.reduce(0) { $0 + $1.diskWriteBytesPerSecond } }

    public init(id: String, name: String, bundleIdentifier: String?, bundlePath: String?, kind: AppKind, mainPID: Int32?, processes: [ProcessStats]) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
        self.kind = kind
        self.mainPID = mainPID
        self.processes = processes
    }
}

public enum DevRuntime: String, Sendable, Hashable, Codable, CaseIterable {
    case node, bun, deno, python, ruby, go, java, php, rust, dotnet, elixir, swift

    public var displayName: String {
        switch self {
        case .node: "Node.js"
        case .bun: "Bun"
        case .deno: "Deno"
        case .python: "Python"
        case .ruby: "Ruby"
        case .go: "Go"
        case .java: "Java"
        case .php: "PHP"
        case .rust: "Rust"
        case .dotnet: ".NET"
        case .elixir: "Elixir"
        case .swift: "Swift"
        }
    }
}

public enum PortProtocol: String, Sendable, Hashable, Codable {
    case tcp, udp
}

public struct ListeningPort: Sendable, Hashable, Codable, Identifiable {
    public var id: String { "\(proto.rawValue):\(address):\(port):\(pid)" }
    public var port: UInt16
    public var proto: PortProtocol
    /// Bound address, e.g. "127.0.0.1", "::", "*".
    public var address: String
    public var pid: Int32

    public init(port: UInt16, proto: PortProtocol, address: String, pid: Int32) {
        self.port = port
        self.proto = proto
        self.address = address
        self.pid = pid
    }
}

/// Development runtimes grouped by the folder they run in.
public struct ProjectActivity: Sendable, Hashable, Codable, Identifiable {
    /// Project root folder path.
    public var id: String
    public var name: String
    public var runtimes: [DevRuntime]
    public var processes: [ProcessStats]
    public var ports: [ListeningPort]

    public var cpu: Double { processes.reduce(0) { $0 + $1.cpu } }
    public var memory: UInt64 { processes.reduce(0) { $0 + $1.memory } }

    public init(id: String, name: String, runtimes: [DevRuntime], processes: [ProcessStats], ports: [ListeningPort]) {
        self.id = id
        self.name = name
        self.runtimes = runtimes
        self.processes = processes
        self.ports = ports
    }
}

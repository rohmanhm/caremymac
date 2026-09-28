import Darwin

/// Ports typed by the user: "3000", ":3000", "3000, 5173", "8000-8010", separated by commas or spaces.
public enum PortList {
    /// Largest lookup, so a typo like "1-65535" doesn't walk every port.
    public static let maxCount = 1024

    public enum ParseError: Error, Equatable {
        case empty
        /// A part that isn't a port or a range of ports 1–65535.
        case invalid(String)
        case tooMany
    }

    /// Unique ports in ascending order.
    public static func parse(_ text: String) throws(ParseError) -> [UInt16] {
        let parts = text.split { $0 == "," || $0.isWhitespace }
        guard !parts.isEmpty else { throw .empty }
        var ports = Set<UInt16>()
        for part in parts {
            let token = part.hasPrefix(":") ? part.dropFirst() : part[...]
            let bounds = token.split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(bounds.count),
                  let low = bounds.first.flatMap(port), let high = bounds.last.flatMap(port), low <= high else {
                throw .invalid(String(part))
            }
            guard ports.count + Int(high - low) < maxCount else { throw .tooMany }
            ports.formUnion(low...high)
        }
        return ports.sorted()
    }

    private static func port(_ text: Substring) -> UInt16? {
        guard let value = UInt16(text), value > 0 else { return nil }
        return value
    }
}

/// A process listening on one or more of the looked-up ports.
public struct PortHolder: Sendable, Hashable, Identifiable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var name: String
    public var executablePath: String?
    /// Its listeners on the looked-up ports, by port.
    public var ports: [ListeningPort]

    public init(pid: Int32, name: String, executablePath: String?, ports: [ListeningPort]) {
        self.pid = pid
        self.name = name
        self.executablePath = executablePath
        self.ports = ports
    }
}

/// Who holds a set of ports, across every process CareMyMac may inspect (not only dev runtimes).
public struct PortLookup: Sendable, Hashable {
    public var ports: [UInt16]
    /// Holders CareMyMac can see, lowest port first.
    public var holders: [PortHolder]
    /// TCP ports with no visible holder that still can't be bound: held by root, another user, or just released.
    public var hiddenInUse: [UInt16]

    public init(ports: [UInt16], holders: [PortHolder], hiddenInUse: [UInt16]) {
        self.ports = ports
        self.holders = holders
        self.hiddenInUse = hiddenInUse
    }

    /// Walks every process's sockets; call off the main actor.
    public static func find(_ ports: [UInt16]) -> PortLookup {
        let wanted = Set(ports)
        let listeners = PortScanner().ports(for: PortScanner.allPIDs()).filter { wanted.contains($0.port) }
        let holders = Dictionary(grouping: listeners, by: \.pid)
            .map { pid, ports in
                PortHolder(pid: pid, name: ProcessActions.processName(pid), executablePath: ProcessActions.executablePath(pid), ports: ports)
            }
            .sorted { ($0.ports.map(\.port).min() ?? 0, $0.pid) < ($1.ports.map(\.port).min() ?? 0, $1.pid) }
        let visible = Set(listeners.lazy.filter { $0.proto == .tcp }.map(\.port))
        let hidden = ports.filter { !visible.contains($0) && PortScanner.isTCPPortInUse($0) }
        return PortLookup(ports: ports, holders: holders, hiddenInUse: hidden)
    }
}

extension PortScanner {
    /// Every PID on the system, including ones we can't inspect.
    public static func allPIDs() -> [Int32] {
        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(needed) + 64)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        return Array(pids.prefix(max(0, min(Int(count), pids.count))).filter { $0 > 0 })
    }

    /// True when a wildcard TCP bind to `port` fails with EADDRINUSE on IPv4 or IPv6, so some socket holds it,
    /// including sockets of processes we can't inspect.
    public static func isTCPPortInUse(_ port: UInt16) -> Bool {
        bindFails(family: AF_INET, port: port) || bindFails(family: AF_INET6, port: port)
    }

    private static func bindFails(family: Int32, port: UInt16) -> Bool {
        let fd = socket(family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let result: Int32
        if family == AF_INET6 {
            var on: Int32 = 1
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            address.sin6_addr = in6addr_any
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = INADDR_ANY
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        return result != 0 && errno == EADDRINUSE
    }
}

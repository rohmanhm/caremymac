import Darwin

/// Lists listening TCP sockets and bound UDP sockets of processes we may inspect.
public final class PortScanner {
    private var fds: [proc_fdinfo] = []

    public init() {}

    public func ports(for pids: some Sequence<Int32>) -> [ListeningPort] {
        var seen = Set<ListeningPort>()
        var result: [ListeningPort] = []
        for pid in pids {
            for port in ports(of: pid) where seen.insert(port).inserted {
                result.append(port)
            }
        }
        return result.sorted { ($0.port, $0.proto.rawValue, $0.address, $0.pid) < ($1.port, $1.proto.rawValue, $1.address, $1.pid) }
    }

    private func ports(of pid: Int32) -> [ListeningPort] {
        let entrySize = MemoryLayout<proc_fdinfo>.stride
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        let capacity = Int(needed) / entrySize + 16
        if fds.count < capacity {
            fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        }
        let bytes = fds.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard bytes > 0 else { return [] }
        let count = min(Int(bytes) / entrySize, fds.count)

        var result: [ListeningPort] = []
        let infoSize = Int32(MemoryLayout<socket_fdinfo>.size)
        for index in 0..<count where fds[index].proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            guard proc_pidfdinfo(pid, fds[index].proc_fd, PROC_PIDFDSOCKETINFO, &info, infoSize) == infoSize else { continue }
            let socket = info.psi
            guard socket.soi_family == AF_INET || socket.soi_family == AF_INET6 else { continue }
            let inet: in_sockinfo
            let proto: PortProtocol
            if socket.soi_kind == Int32(SOCKINFO_TCP) {
                guard socket.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { continue }
                inet = socket.soi_proto.pri_tcp.tcpsi_ini
                proto = .tcp
            } else if socket.soi_kind == Int32(SOCKINFO_IN), socket.soi_protocol == IPPROTO_UDP,
                      socket.soi_proto.pri_in.insi_fport == 0 {
                inet = socket.soi_proto.pri_in
                proto = .udp
            } else {
                continue
            }
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: inet.insi_lport))
            guard port != 0 else { continue }
            result.append(ListeningPort(port: port, proto: proto, address: Self.localAddress(inet), pid: pid))
        }
        return result
    }

    /// Local address as text; wildcard binds become "*".
    static func localAddress(_ inet: in_sockinfo) -> String {
        if inet.insi_vflag & UInt8(INI_IPV6) != 0 {
            let address = inet.insi_laddr.ina_6
            let isWildcard = withUnsafeBytes(of: address) { $0.allSatisfy { $0 == 0 } }
            return isWildcard ? "*" : format(family: AF_INET6, address, length: INET6_ADDRSTRLEN)
        }
        let address = inet.insi_laddr.ina_46.i46a_addr4
        return address.s_addr == 0 ? "*" : format(family: AF_INET, address, length: INET_ADDRSTRLEN)
    }

    private static func format<T>(family: Int32, _ address: T, length: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: Int(length))
        let ok = withUnsafeBytes(of: address) { bytes in
            inet_ntop(family, bytes.baseAddress, &buffer, socklen_t(length)) != nil
        }
        guard ok else { return "?" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

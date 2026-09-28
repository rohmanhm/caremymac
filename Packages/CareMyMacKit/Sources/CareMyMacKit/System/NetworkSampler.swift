import Darwin
import Foundation
import SystemConfiguration

/// Samples per-interface byte counters (64-bit, via NET_RT_IFLIST2) and derives rates.
public final class NetworkSampler {
    struct Counters: Equatable {
        var received: UInt64
        var sent: UInt64
        var isUp: Bool
    }

    private struct Descriptor {
        var type: String?
        var displayName: String?
    }

    private var previous: (counters: [String: Counters], date: Date)?
    private var descriptors: [String: Descriptor] = [:]
    private var descriptorsLoadedAt: Date?

    /// SystemConfiguration is re-queried at most this often when unknown interfaces show up.
    private static let descriptorRefreshInterval: TimeInterval = 30

    public init() {}

    public func sample(now: Date = .now) -> NetworkStats {
        let counters = Self.readCounters()
        let addresses = Self.readAddresses()
        refreshDescriptorsIfNeeded(names: counters.keys, now: now)
        defer { previous = (counters, now) }

        let elapsed = previous.map { now.timeIntervalSince($0.date) } ?? 0
        var interfaces: [NetworkInterfaceStats] = []
        var totalReceived = 0.0
        var totalSent = 0.0
        for (name, current) in counters {
            let interfaceAddresses = addresses[name] ?? []
            guard current.received > 0 || current.sent > 0 || !interfaceAddresses.isEmpty else { continue }
            let old = previous?.counters[name]
            let received = old.map { SystemProbe.rate(from: $0.received, to: current.received, elapsed: elapsed) } ?? 0
            let sent = old.map { SystemProbe.rate(from: $0.sent, to: current.sent, elapsed: elapsed) } ?? 0
            let descriptor = descriptors[name]
            let kind = Self.kind(bsdName: name, systemConfigurationType: descriptor?.type)
            if Self.countsTowardTotals(kind) {
                totalReceived += received
                totalSent += sent
            }
            interfaces.append(NetworkInterfaceStats(
                id: name,
                displayName: descriptor?.displayName ?? name,
                kind: kind,
                isUp: current.isUp,
                receivedBytesPerSecond: received,
                sentBytesPerSecond: sent,
                totalReceived: current.received,
                totalSent: current.sent,
                addresses: interfaceAddresses
            ))
        }
        interfaces.sort { lhs, rhs in
            lhs.totalReceived + lhs.totalSent > rhs.totalReceived + rhs.totalSent
        }
        return NetworkStats(receivedBytesPerSecond: totalReceived, sentBytesPerSecond: totalSent, interfaces: interfaces)
    }

    /// Loopback never leaves the machine; VPN tunnels and bridges re-carry bytes already counted on the physical link.
    static func countsTowardTotals(_ kind: NetworkInterfaceKind) -> Bool {
        switch kind {
        case .loopback, .vpn, .bridge: false
        case .wifi, .ethernet, .cellular, .other: true
        }
    }

    /// BSD-name conventions win over SystemConfiguration, which reports tunnels and bridges inconsistently.
    static func kind(bsdName: String, systemConfigurationType: String?) -> NetworkInterfaceKind {
        if bsdName.hasPrefix("lo") { return .loopback }
        if ["utun", "ipsec", "ppp", "tun", "tap"].contains(where: bsdName.hasPrefix) { return .vpn }
        if bsdName.hasPrefix("bridge") { return .bridge }
        // Values of the kSCNetworkInterfaceType* constants (Bridge/VPN aren't exported).
        switch systemConfigurationType {
        case "IEEE80211": return .wifi
        case "Ethernet": return .ethernet
        case "WWAN": return .cellular
        case "Bridge": return .bridge
        case "VPN", "PPP", "IPSec": return .vpn
        default: return .other
        }
    }

    private func refreshDescriptorsIfNeeded(names: Dictionary<String, Counters>.Keys, now: Date) {
        let hasUnknown = names.contains { descriptors[$0] == nil }
        if let loadedAt = descriptorsLoadedAt {
            guard hasUnknown, now.timeIntervalSince(loadedAt) >= Self.descriptorRefreshInterval else { return }
        }
        descriptorsLoadedAt = now
        var fresh: [String: Descriptor] = [:]
        let all = SCNetworkInterfaceCopyAll()
        for index in 0..<CFArrayGetCount(all) {
            guard let raw = CFArrayGetValueAtIndex(all, index) else { continue }
            let interface = unsafeBitCast(raw, to: SCNetworkInterface.self)
            guard let bsdName = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
            fresh[bsdName] = Descriptor(
                type: SCNetworkInterfaceGetInterfaceType(interface) as String?,
                displayName: SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
            )
        }
        // Remember names SystemConfiguration doesn't know so they don't trigger refreshes.
        for name in names where fresh[name] == nil {
            fresh[name] = Descriptor(type: nil, displayName: nil)
        }
        descriptors = fresh
    }

    private static func readCounters() -> [String: Counters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        // The table can grow between the two calls.
        length += length / 8
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else { return [:] }

        var result: [String: Counters] = [:]
        buffer.withUnsafeBytes { raw in
            let headerSize = MemoryLayout<if_msghdr>.size
            let messageSize = MemoryLayout<if_msghdr2>.size
            var offset = 0
            while offset + headerSize <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0 else { return }
                defer { offset += messageLength }
                guard Int32(header.ifm_type) == RTM_IFINFO2, offset + messageSize <= length else { continue }
                let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                guard let name = interfaceName(index: UInt32(message.ifm_index)) else { continue }
                result[name] = Counters(
                    received: message.ifm_data.ifi_ibytes,
                    sent: message.ifm_data.ifi_obytes,
                    isUp: message.ifm_flags & IFF_UP != 0
                )
            }
        }
        return result
    }

    private static func interfaceName(index: UInt32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
        guard if_indextoname(index, &buffer) != nil else { return nil }
        let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return name.isEmpty ? nil : name
    }

    /// IPv4 and non-link-local IPv6 addresses keyed by BSD name.
    private static func readAddresses() -> [String: [String]] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [:] }
        defer { freeifaddrs(list) }

        var result: [String: [String]] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let string = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if family == AF_INET6, string.lowercased().hasPrefix("fe80") { continue }
            let name = String(cString: entry.pointee.ifa_name)
            result[name, default: []].append(string)
        }
        return result
    }
}

import Darwin
import Foundation
import Testing
@testable import CareMyMacKit

@Suite struct PortLookupTests {
    @Test func parsesSinglesListsRangesAndColons() throws {
        #expect(try PortList.parse("3000") == [3000])
        #expect(try PortList.parse(" :5173, 3000 3000 ") == [3000, 5173])
        #expect(try PortList.parse("8000-8002,8001") == [8000, 8001, 8002])
        #expect(try PortList.parse("1 65535") == [1, 65535])
    }

    @Test func rejectsWhatIsNotAPort() {
        #expect(throws: PortList.ParseError.empty) { try PortList.parse(" , ") }
        #expect(throws: PortList.ParseError.invalid("0")) { try PortList.parse("0") }
        #expect(throws: PortList.ParseError.invalid("65536")) { try PortList.parse("80 65536") }
        #expect(throws: PortList.ParseError.invalid("9000-8000")) { try PortList.parse("9000-8000") }
        #expect(throws: PortList.ParseError.invalid("80-")) { try PortList.parse("80-") }
        #expect(throws: PortList.ParseError.invalid("abc")) { try PortList.parse("abc") }
        #expect(throws: PortList.ParseError.invalid("١٢")) { try PortList.parse("١٢") }
    }

    @Test func capsHowManyPortsOneLookupWalks() throws {
        #expect(try PortList.parse("1-\(PortList.maxCount)").count == PortList.maxCount)
        #expect(throws: PortList.ParseError.tooMany) { try PortList.parse("1-\(PortList.maxCount + 1)") }
        #expect(throws: PortList.ParseError.tooMany) { try PortList.parse("1-1000 2000-2100") }
    }

    @Test func findsThisProcessListeningAndForgetsItAfterClose() throws {
        let (fd, port) = try listenOnLoopback()
        let lookup = PortLookup.find([port])
        let holder = try #require(lookup.holders.first { $0.pid == getpid() })
        #expect(holder.ports.map(\.port) == [port])
        #expect(holder.ports.first?.address == "127.0.0.1")
        #expect(lookup.hiddenInUse.isEmpty)
        #expect(PortScanner.isTCPPortInUse(port))

        close(fd)
        #expect(!PortLookup.find([port]).holders.contains { $0.pid == getpid() })
    }

    /// A TCP listener on 127.0.0.1 at a kernel-chosen port.
    private func listenOnLoopback() throws -> (Int32, UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        try #require(fd >= 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                bind(fd, pointer, length) == 0 && listen(fd, 1) == 0 && getsockname(fd, pointer, &length) == 0
            }
        }
        try #require(bound)
        return (fd, UInt16(bigEndian: address.sin_port))
    }
}

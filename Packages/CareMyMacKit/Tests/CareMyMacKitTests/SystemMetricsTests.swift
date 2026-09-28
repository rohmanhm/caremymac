import Foundation
import Testing
@testable import CareMyMacKit

@Suite struct SystemMetricsTests {
    typealias Ticks = CPUSampler.CoreTicks

    @Test func cpuSharesAreWeightedAcrossCores() {
        let previous = [Ticks(user: 0, system: 0, idle: 0, nice: 0), Ticks(user: 0, system: 0, idle: 0, nice: 0)]
        // Core 0: 60 user (50 + 10 nice), 20 system, 20 idle. Core 1: fully idle.
        let current = [Ticks(user: 50, system: 20, idle: 20, nice: 10), Ticks(user: 0, system: 0, idle: 100, nice: 0)]
        let result = CPUSampler.shares(previous: previous, current: current)
        #expect(result.user == 0.3)
        #expect(result.system == 0.1)
        #expect(result.cores[0] == CPUStats.Core(user: 0.6, system: 0.2))
        #expect(result.cores[1] == CPUStats.Core(user: 0, system: 0))
    }

    @Test func cpuTickWraparoundYieldsTrueDelta() {
        let previous = [Ticks(user: .max - 9, system: 0, idle: .max - 9, nice: 0)]
        let current = [Ticks(user: 10, system: 0, idle: 10, nice: 0)]
        let result = CPUSampler.shares(previous: previous, current: current)
        #expect(result.user == 0.5)
        #expect(result.cores[0].total == 0.5)
    }

    @Test func cpuFirstSampleOrCoreCountChangeIsZero() {
        let current = [Ticks(user: 5, system: 5, idle: 5, nice: 5), Ticks(user: 5, system: 5, idle: 5, nice: 5)]
        let first = CPUSampler.shares(previous: [], current: current)
        #expect(first.user == 0 && first.system == 0 && first.cores.count == 2)
        let changed = CPUSampler.shares(previous: [current[0]], current: current)
        #expect(changed.user == 0 && changed.cores.allSatisfy { $0.total == 0 })
    }

    @Test func counterRateClampsResetsAndZeroElapsed() {
        #expect(SystemProbe.rate(from: 100, to: 300, elapsed: 2) == 100)
        #expect(SystemProbe.rate(from: 300, to: 100, elapsed: 2) == 0)
        #expect(SystemProbe.rate(from: 100, to: 300, elapsed: 0) == 0)
        #expect(SystemProbe.rate(from: 100, to: 300, elapsed: -1) == 0)
    }

    @Test func diskFirstSampleHasZeroRatesButTotals() {
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        let counters = DiskIOSampler.Counters(bytesRead: 10, bytesWritten: 20, readOps: 1, writeOps: 2)
        let first = DiskIOSampler.stats(previous: nil, current: counters, now: now)
        #expect(first.readBytesPerSecond == 0 && first.totalRead == 10 && first.totalWritten == 20)

        // A disk being ejected shrinks the sums; rates clamp to 0 instead of going negative.
        let bigger = DiskIOSampler.Counters(bytesRead: 1000, bytesWritten: 2000, readOps: 10, writeOps: 20)
        let shrunk = DiskIOSampler.stats(previous: (bigger, now), current: counters, now: now.addingTimeInterval(1))
        #expect(shrunk.readBytesPerSecond == 0 && shrunk.writeOpsPerSecond == 0)

        let grew = DiskIOSampler.stats(previous: (counters, now), current: bigger, now: now.addingTimeInterval(2))
        #expect(grew.readBytesPerSecond == 495 && grew.writeOpsPerSecond == 9)
    }

    @Test func networkKindPrefersBSDConventions() {
        #expect(NetworkSampler.kind(bsdName: "lo0", systemConfigurationType: nil) == .loopback)
        #expect(NetworkSampler.kind(bsdName: "utun3", systemConfigurationType: "Ethernet") == .vpn)
        #expect(NetworkSampler.kind(bsdName: "ipsec0", systemConfigurationType: nil) == .vpn)
        #expect(NetworkSampler.kind(bsdName: "bridge0", systemConfigurationType: "Ethernet") == .bridge)
        #expect(NetworkSampler.kind(bsdName: "en0", systemConfigurationType: "IEEE80211") == .wifi)
        #expect(NetworkSampler.kind(bsdName: "en5", systemConfigurationType: "Ethernet") == .ethernet)
        #expect(NetworkSampler.kind(bsdName: "pdp_ip0", systemConfigurationType: "WWAN") == .cellular)
        #expect(NetworkSampler.kind(bsdName: "awdl0", systemConfigurationType: nil) == .other)
    }

    @Test func networkTotalsSkipLoopbackAndRecarriedTraffic() {
        #expect(!NetworkSampler.countsTowardTotals(.loopback))
        #expect(!NetworkSampler.countsTowardTotals(.vpn))
        #expect(!NetworkSampler.countsTowardTotals(.bridge))
        #expect(NetworkSampler.countsTowardTotals(.wifi))
        #expect(NetworkSampler.countsTowardTotals(.ethernet))
    }

    @Test func memoryPressureLevels() {
        #expect(MemorySampler.pressure(level: 1) == .normal)
        #expect(MemorySampler.pressure(level: 2) == .warning)
        #expect(MemorySampler.pressure(level: 4) == .critical)
        #expect(MemorySampler.pressure(level: nil) == .normal)
    }

    @Test func batteryStatePrecedence() {
        #expect(BatterySampler.state(isPluggedIn: true, isCharging: true, isCharged: false) == .charging)
        #expect(BatterySampler.state(isPluggedIn: true, isCharging: false, isCharged: true) == .charged)
        #expect(BatterySampler.state(isPluggedIn: true, isCharging: false, isCharged: false) == .notCharging)
        #expect(BatterySampler.state(isPluggedIn: false, isCharging: false, isCharged: false) == .discharging)
    }

    @Test func batteryHealthAndPower() {
        #expect(BatterySampler.health(maxCapacity: 4000, designCapacity: 5000) == 0.8)
        #expect(BatterySampler.health(maxCapacity: 8883, designCapacity: 8579) == 1)
        #expect(BatterySampler.health(maxCapacity: 4000, designCapacity: 0) == nil)
        // 12 V at -1.5 A (discharging) is 18 W drawn; charging reads negative.
        #expect(BatterySampler.powerWatts(millivolts: 12_000, milliamps: -1_500) == 18)
        #expect(BatterySampler.powerWatts(millivolts: 12_000, milliamps: 1_000) == -12)
        #expect(BatterySampler.powerWatts(millivolts: 0, milliamps: 1_000) == nil)
    }

    @Test func gpuPercentClamps() {
        #expect(GPUSampler.percent(NSNumber(value: 38)) == 0.38)
        #expect(GPUSampler.percent(NSNumber(value: 140)) == 1)
        #expect(GPUSampler.percent("38") == nil)
    }

    @Test func volumeSystemMountsAreHidden() {
        #expect(VolumeSampler.isSystemMount("/System/Volumes/Data"))
        #expect(VolumeSampler.isSystemMount("/Volumes/com.apple.TimeMachine.localsnapshots/Backups.backupdb"))
        #expect(!VolumeSampler.isSystemMount("/"))
        #expect(!VolumeSampler.isSystemMount("/Volumes/External"))
    }
}

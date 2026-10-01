import Foundation
import Testing

@testable import AwakeCore

private func clock(_ seconds: Double = 100, wall: Double = 1000) throws -> ClockSnapshot {
    try ClockSnapshot(continuous: seconds, wall: Date(timeIntervalSince1970: wall))
}

private let ac = PowerSnapshot(
    source: .external, battery: .available(percent: 80, isDischarging: false))
private let battery = PowerSnapshot(
    source: .battery, battery: .available(percent: 80, isDischarging: true))

@Test func sourceChangeSuspendsAndResumesWithoutExtendingDuration() throws {
    var registry = SessionRegistry(policy: try UserPolicy(mode: .battery))
    let id = try registry.start(
        .init(end: .after(seconds: 60)), owner: UUID(), kind: .manual, now: clock())
    #expect(registry.evaluate(power: ac, now: try clock()).suspended[id] == .powerSource)
    #expect(registry.evaluate(power: battery, now: try clock(159)).eligible.contains(id))
    #expect(registry.evaluate(power: ac, now: try clock(160)).stopped[id] == .expired)
    #expect(registry.sessions.isEmpty)
    #expect(!registry.evaluate(power: battery, now: try clock(161)).wantsAwake)
}

@Test(arguments: [PowerSource.battery, .external])
func batteryFloorPermanentlyStopsEvenWhenAdapterCannotKeepUp(_ source: PowerSource) throws {
    var registry = SessionRegistry(policy: try UserPolicy())
    let id = try registry.start(.init(), owner: UUID(), kind: .manual, now: clock())
    let low = PowerSnapshot(source: source, battery: .available(percent: 20, isDischarging: true))
    #expect(registry.evaluate(power: low, now: try clock()).stopped[id] == .batteryFloor)
    let cutoff = try #require(registry.batteryCutoff)
    #expect(cutoff.sessionID == id && cutoff.percent == 20 && cutoff.limit == 20)
    #expect(!registry.evaluate(power: ac, now: try clock(200)).wantsAwake)
    #expect(registry.batteryCutoff == cutoff)
    try registry.start(.init(), owner: UUID(), kind: .manual, now: clock(201))
    #expect(registry.batteryCutoff == nil)
}

@Test func chargingLowBatteryDoesNotTriggerDischargeCutoff() throws {
    var registry = SessionRegistry(policy: try UserPolicy())
    try registry.start(.init(), owner: UUID(), kind: .manual, now: clock())
    let charging = PowerSnapshot(
        source: .external, battery: .available(percent: 5, isDischarging: false))
    #expect(registry.evaluate(power: charging, now: try clock()).wantsAwake)
}

@Test func zeroDisablesOnlyCustomBatteryProtection() throws {
    var registry = SessionRegistry(policy: try UserPolicy(batteryFloor: 0))
    let id = try registry.start(.init(), owner: UUID(), kind: .manual, now: clock())
    let empty = PowerSnapshot(
        source: .battery, battery: .available(percent: 0, isDischarging: true))
    #expect(registry.evaluate(power: empty, now: try clock()).eligible.contains(id))
    #expect(
        !registry.evaluate(power: .init(source: .unknown, battery: .unavailable), now: try clock())
            .wantsAwake)
}

@Test func unknownBatterySuspendsRatherThanAssumingOneHundredPercent() throws {
    var registry = SessionRegistry(policy: try UserPolicy())
    let id = try registry.start(.init(), owner: UUID(), kind: .manual, now: clock())
    let unknown = PowerSnapshot(source: .external, battery: .unavailable)
    #expect(registry.evaluate(power: unknown, now: try clock()).suspended[id] == .unreadableBattery)
    #expect(registry.evaluate(power: ac, now: try clock()).wantsAwake)
}

@Test func clientsCannotWeakenAuthorizedPolicy() throws {
    var registry = SessionRegistry(policy: try UserPolicy(mode: .battery, allowsAutomation: true))
    #expect(throws: PolicyError.powerModeNotAuthorized) {
        try registry.start(.init(mode: .all), owner: UUID(), kind: .task, now: clock())
    }
    #expect(throws: PolicyError.batteryFloorNotAuthorized) {
        try registry.start(.init(batteryFloor: 0), owner: UUID(), kind: .task, now: clock())
    }
    #expect(throws: PolicyError.invalidBatteryFloor) {
        try registry.start(.init(batteryFloor: 81), owner: UUID(), kind: .task, now: clock())
    }
    #expect(registry.sessions.isEmpty)
}

@Test func automationRequiresExplicitAuthorization() throws {
    var registry = SessionRegistry(policy: try UserPolicy())
    #expect(throws: PolicyError.automationNotAuthorized) {
        try registry.start(.init(), owner: UUID(), kind: .task, now: clock())
    }
}

@Test func eightyPercentLimitStopsTasksAndCannotBeWeakened() throws {
    var registry = SessionRegistry(policy: try UserPolicy(batteryFloor: 80, allowsAutomation: true))
    let id = try registry.start(
        .init(batteryFloor: 80), owner: UUID(), kind: .task, now: clock())
    #expect(throws: PolicyError.batteryFloorNotAuthorized) {
        try registry.start(.init(batteryFloor: 79), owner: UUID(), kind: .task, now: clock())
    }
    let aboveLimit = PowerSnapshot(
        source: .battery, battery: .available(percent: 81, isDischarging: true))
    #expect(registry.evaluate(power: aboveLimit, now: try clock()).eligible.contains(id))
    #expect(registry.evaluate(power: battery, now: try clock()).stopped[id] == .batteryFloor)
    #expect(!registry.evaluate(power: aboveLimit, now: try clock(101)).wantsAwake)
}

@Test func allTasksMustFinishAndManualDemandIsIndependent() throws {
    var registry = SessionRegistry(policy: try UserPolicy(allowsAutomation: true))
    let first = UUID()
    let second = UUID()
    let manual = UUID()
    let a = try registry.start(.init(), owner: first, kind: .task, now: clock())
    let b = try registry.start(.init(), owner: second, kind: .task, now: clock())
    let c = try registry.start(.init(), owner: manual, kind: .manual, now: clock())
    let foreignRelease = registry.stop(a, owner: second)
    let ownerRelease = registry.stop(a, owner: first)
    #expect(!foreignRelease)
    #expect(ownerRelease)
    #expect(registry.evaluate(power: ac, now: try clock()).eligible == [b, c])
    registry.releaseOwner(second)
    #expect(registry.evaluate(power: ac, now: try clock()).eligible == [c])
    registry.releaseOwner(manual)
    #expect(!registry.evaluate(power: ac, now: try clock()).wantsAwake)
}

@Test func relativeTimeIgnoresWallClockChangesAndAbsoluteTimeDoesNot() throws {
    var registry = SessionRegistry(policy: try UserPolicy())
    let relative = try registry.start(
        .init(end: .after(seconds: 60)), owner: UUID(), kind: .manual, now: clock())
    let absolute = try registry.start(
        .init(end: .at(Date(timeIntervalSince1970: 1060))), owner: UUID(), kind: .manual,
        now: clock())
    let jumped = registry.evaluate(power: ac, now: try clock(110, wall: 2000))
    #expect(jumped.eligible == [relative])
    #expect(jumped.stopped[absolute] == .expired)
    #expect(
        registry.evaluate(power: ac, now: try clock(160, wall: 900)).stopped[relative] == .expired)
}

@Test func originalUserTimeCeilingCannotBeExtendedByLooseningPolicy() throws {
    var registry = SessionRegistry(
        policy: try UserPolicy(maximumDuration: 60, allowsAutomation: true))
    let id = try registry.start(.init(), owner: UUID(), kind: .task, now: clock())
    registry.updatePolicy(try UserPolicy(allowsAutomation: true))
    #expect(registry.evaluate(power: ac, now: try clock(160)).stopped[id] == .expired)
}

@Test func stricterPolicyTakesEffectAgainstOriginalStart() throws {
    var registry = SessionRegistry(policy: try UserPolicy())
    let id = try registry.start(.init(), owner: UUID(), kind: .manual, now: clock())
    registry.updatePolicy(try UserPolicy(maximumDuration: 30))
    #expect(registry.evaluate(power: ac, now: try clock(150)).stopped[id] == .expired)
}

@Test func policyChangeTerminatesIncompatibleExplicitRequest() throws {
    var registry = SessionRegistry(policy: try UserPolicy())
    let id = try registry.start(.init(mode: .battery), owner: UUID(), kind: .manual, now: clock())
    registry.updatePolicy(try UserPolicy(mode: .external))
    #expect(registry.evaluate(power: ac, now: try clock()).stopped[id] == .policyChanged)
}

@Test func stopRetainsConsentWhileFaultsRevokeIt() throws {
    var registry = SessionRegistry(policy: try UserPolicy(allowsAutomation: true))
    let owner = UUID()
    let id = try registry.start(.init(), owner: owner, kind: .task, now: clock())
    registry.stopAll()
    let duplicateRelease = registry.stop(id, owner: owner)
    #expect(!duplicateRelease)
    #expect(registry.policy.allowsAutomation)
    try registry.revokeAutomationAndStop()
    #expect(throws: PolicyError.automationNotAuthorized) {
        try registry.start(.init(), owner: owner, kind: .task, now: clock())
    }
    #expect(!registry.evaluate(power: ac, now: try clock()).wantsAwake)
}

@Test func registryDoesNotRestoreSessionsAndBoundsResources() throws {
    var registry = SessionRegistry(policy: try UserPolicy())
    #expect(registry.sessions.isEmpty)
    let id = UUID()
    try registry.start(.init(), owner: UUID(), kind: .manual, now: clock(), id: id)
    #expect(throws: PolicyError.duplicateSession) {
        try registry.start(.init(), owner: UUID(), kind: .manual, now: clock(), id: id)
    }
    for _ in 1..<SessionRegistry.capacity {
        try registry.start(.init(), owner: UUID(), kind: .manual, now: clock())
    }
    #expect(throws: PolicyError.sessionLimitReached) {
        try registry.start(.init(), owner: UUID(), kind: .manual, now: clock())
    }
}

@Test func unlimitedHasNoHiddenDurationCap() throws {
    var registry = SessionRegistry(policy: try UserPolicy())
    let id = try registry.start(.init(), owner: UUID(), kind: .manual, now: clock())
    #expect(registry.evaluate(power: ac, now: try clock(60 * 60 * 24 * 365 * 20)).eligible == [id])
}

@Test func lidPreferenceChangesDoNotRestartOrExtendTheSession() throws {
    let start = try ClockSnapshot(continuous: 1, wall: Date(timeIntervalSince1970: 1))
    var registry = SessionRegistry(policy: try UserPolicy())
    let id = try registry.start(
        .init(end: .after(seconds: 30)), owner: UUID(), kind: .manual, now: start)
    registry.updatePolicy(try UserPolicy(keepsAwakeWithLidClosed: true))
    let power = PowerSnapshot(source: .external, battery: .notPresent)
    #expect(registry.evaluate(power: power, now: start).eligible == [id])
    let end = try ClockSnapshot(continuous: 31, wall: Date(timeIntervalSince1970: 31))
    #expect(!registry.evaluate(power: power, now: end).wantsAwake)
    #expect(registry.sessions.isEmpty && registry.policy.keepsAwakeWithLidClosed)
    try registry.revokeAutomationAndStop()
    #expect(registry.policy.keepsAwakeWithLidClosed)
}

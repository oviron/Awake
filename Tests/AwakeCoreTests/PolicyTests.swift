import Foundation
import Testing

@testable import AwakeCore

@Test(arguments: Array(0...80))
func batteryFloorAllowsEveryInteger(_ floor: Int) throws {
    #expect(try UserPolicy(batteryFloor: floor).batteryFloor == floor)
}

@Test(arguments: [-1, 81, Int.max, Int.min])
func invalidFloorCannotEnterPolicy(_ floor: Int) {
    #expect(throws: PolicyError.invalidBatteryFloor) { try UserPolicy(batteryFloor: floor) }
}

@Test(arguments: [0.0, -1, .infinity, -.infinity, .nan])
func invalidDurationsAreRejected(_ seconds: Double) {
    #expect(throws: PolicyError.invalidDuration) { try UserPolicy(maximumDuration: seconds) }
}

@Test func decodingCannotBypassPolicyValidation() throws {
    let json = Data(#"{"mode":"all","batteryFloor":-1,"allowsAutomation":true}"#.utf8)
    #expect(throws: PolicyError.invalidBatteryFloor) {
        try JSONDecoder().decode(UserPolicy.self, from: json)
    }
    let original = try UserPolicy(mode: .battery, batteryFloor: 80, maximumDuration: 900)
    let restored = try JSONDecoder().decode(UserPolicy.self, from: JSONEncoder().encode(original))
    #expect(restored == original)
}

@Test func powerModesAreExclusiveAndUnknownNeverQualifies() {
    for mode in PowerMode.allCases { #expect(!mode.allows(.unknown)) }
    #expect(PowerMode.battery.allows(.battery))
    #expect(!PowerMode.battery.allows(.external))
    #expect(PowerMode.external.allows(.external))
    #expect(!PowerMode.external.allows(.battery))
    #expect(PowerMode.all.allows(.battery))
    #expect(PowerMode.all.allows(.external))
    #expect(!PowerMode.all.isWithin(.battery))
}

@Test func telemetryCannotInventAFullBattery() {
    #expect(BatteryReading.measured(percent: 101, isDischarging: false) == .unavailable)
    #expect(
        PowerSnapshot(source: .battery, battery: .notPresent).battery == .unavailable
    )
    #expect(
        PowerSnapshot(source: .external, battery: .available(percent: -1, isDischarging: true))
            .battery == .unavailable
    )
}

@Test func invalidClockAndDatesAreRejected() throws {
    #expect(throws: PolicyError.invalidClock) {
        try ClockSnapshot(continuous: -.infinity, wall: Date())
    }
    let now = try ClockSnapshot(continuous: 10, wall: Date(timeIntervalSince1970: 100))
    #expect(throws: PolicyError.invalidDate) { try SessionEnd.at(now.wall).validate(at: now) }
    #expect(throws: PolicyError.invalidDate) {
        try SessionEnd.at(Date(timeIntervalSince1970: .infinity)).validate(at: now)
    }
    #expect(throws: PolicyError.invalidDuration) {
        try SessionEnd.after(seconds: Double.leastNonzeroMagnitude).validate(at: now)
    }
}

@Test func legacyPreferencesDefaultToNormalLidBehavior() throws {
    let old = Data(#"{"mode":"external","batteryFloor":30,"allowsAutomation":false}"#.utf8)
    let decoded = try JSONDecoder().decode(UserPolicy.self, from: old)
    #expect(
        !decoded.keepsAwakeWithLidClosed && decoded.mode == .external && decoded.batteryFloor == 30)
    let policy = try UserPolicy(keepsAwakeWithLidClosed: true)
    #expect(try JSONDecoder().decode(UserPolicy.self, from: JSONEncoder().encode(policy)) == policy)
}

import AwakeCore
import Foundation
import IOKit.ps
import Testing

@testable import AwakeSystem

private func description(current: Int = 50, maximum: Int = 100, amperage: Int = 0) -> [String: Any]
{
    [
        kIOPSTypeKey: kIOPSInternalBatteryType,
        kIOPSIsPresentKey: true,
        kIOPSCurrentCapacityKey: current,
        kIOPSMaxCapacityKey: maximum,
        kIOPSPowerSourceStateKey: kIOPSACPowerValue,
        kIOPSCurrentKey: amperage,
    ]
}

@Test func batteryChargeIsScaledAndDischargeDetectedOnAC() {
    var reader = PowerSourceReader()
    let power = reader.interpret(
        provider: kIOPMACPowerKey,
        descriptions: [description(current: 150, maximum: 500, amperage: -50)])
    #expect(power.source == .external)
    #expect(power.battery == .available(percent: 30, isDischarging: true))
}

@Test func aReadFailureIsDifferentFromADesktopWithoutABattery() {
    var reader = PowerSourceReader()
    #expect(reader.interpret(provider: kIOPMACPowerKey, descriptions: []).battery == .notPresent)
    #expect(reader.interpret(provider: kIOPMACPowerKey, descriptions: nil).battery == .unavailable)
    #expect(
        reader.interpret(provider: kIOPMBatteryPowerKey, descriptions: []).battery == .unavailable)
    #expect(reader.interpret(provider: nil, descriptions: nil).source == .unknown)
    #expect(reader.interpret(provider: kIOPMUPSPowerKey, descriptions: []).source == .unknown)
}

@Test func aPreviouslySeenBatteryCannotDisappearIntoAnAssumedDesktop() {
    var reader = PowerSourceReader()
    _ = reader.interpret(provider: kIOPMACPowerKey, descriptions: [description()])
    #expect(reader.interpret(provider: kIOPMACPowerKey, descriptions: []).battery == .unavailable)
    var partiallyReadable = PowerSourceReader()
    _ = partiallyReadable.interpret(provider: kIOPMACPowerKey, descriptions: [description(), [:]])
    #expect(
        partiallyReadable.interpret(provider: kIOPMACPowerKey, descriptions: []).battery
            == .unavailable)
}

@Test(arguments: [
    kIOPSIsPresentKey, kIOPSCurrentCapacityKey, kIOPSMaxCapacityKey, kIOPSPowerSourceStateKey,
    kIOPSCurrentKey,
])
func missingBatteryFieldsDoNotInventHealthyTelemetry(_ key: String) {
    var reader = PowerSourceReader()
    var incomplete = description()
    incomplete.removeValue(forKey: key)
    #expect(
        reader.interpret(provider: kIOPMACPowerKey, descriptions: [incomplete]).battery
            == .unavailable)
}

@Test func malformedAndAmbiguousBatteryDataFailClosed() {
    var reader = PowerSourceReader()
    for invalid in [description(current: -1), description(current: 101), description(maximum: 0)] {
        #expect(
            reader.interpret(provider: kIOPMACPowerKey, descriptions: [invalid]).battery
                == .unavailable)
    }
    for invalid in [
        NSNumber(value: true), NSNumber(value: Double.nan), NSNumber(value: 0.5),
        NSNumber(value: Double.greatestFiniteMagnitude),
    ] {
        var value = description()
        value[kIOPSCurrentCapacityKey] = invalid
        #expect(
            reader.interpret(provider: kIOPMACPowerKey, descriptions: [value]).battery
                == .unavailable)
    }
    #expect(
        reader.interpret(provider: kIOPMACPowerKey, descriptions: [description(), description()])
            .battery == .unavailable)
    #expect(
        reader.interpret(provider: kIOPMACPowerKey, descriptions: [[:]]).battery == .unavailable)
    #expect(
        reader.interpret(provider: kIOPMACPowerKey, descriptions: [[kIOPSTypeKey: "Unexpected"]])
            .battery == .unavailable)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["AWAKE_READ_ONLY_INTEGRATION"] == "1"))
func livePowerAPIsExposeUsableStateWithoutChangingSettings() {
    var reader = PowerSourceReader()
    var backend = MacSleepBackend()
    let power = reader.snapshot()
    let observation = backend.observe()
    #expect(power.source != .unknown)
    #expect(power.battery != .unavailable)
    #expect(power.thermal != .unavailable)
    #expect(observation != .unknown)
    #expect(!backend.hasIdleAssertion)
}

@Test func batterySourceIsDischargingEvenWithoutAnAmperageReading() {
    var reader = PowerSourceReader()
    var value = description(current: 20)
    value[kIOPSPowerSourceStateKey] = kIOPSBatteryPowerValue
    value.removeValue(forKey: kIOPSCurrentKey)
    let power = reader.interpret(provider: kIOPMBatteryPowerKey, descriptions: [value])
    #expect(power.battery == .available(percent: 20, isDischarging: true))
}

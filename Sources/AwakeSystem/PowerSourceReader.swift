import AwakeCore
import CoreFoundation
import Foundation
import IOKit.ps

public struct PowerSourceReader: Sendable {
    private var hasSeenInternalBattery = false

    public init() {}

    public mutating func snapshot() -> PowerSnapshot {
        let power = readPowerSnapshot()
        return PowerSnapshot(
            source: power.source, battery: power.battery,
            thermal: Self.thermalReading(ProcessInfo.processInfo.thermalState))
    }

    static func thermalReading(_ state: ProcessInfo.ThermalState) -> ThermalReading {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .unavailable
        }
    }

    private mutating func readPowerSnapshot() -> PowerSnapshot {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return PowerSnapshot(source: .unknown, battery: .unavailable) }
        let provider = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        var descriptions: [[String: Any]] = []
        for source in sources {
            guard
                let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                    as? [String: Any]
            else { return interpret(provider: provider, descriptions: nil) }
            if description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType {
                hasSeenInternalBattery = true
            }
            descriptions.append(description)
        }
        return interpret(provider: provider, descriptions: descriptions)
    }

    mutating func interpret(provider: String?, descriptions: [[String: Any]]?) -> PowerSnapshot {
        let source: PowerSource
        switch provider {
        case kIOPMACPowerKey: source = .external
        case kIOPMBatteryPowerKey: source = .battery
        default: source = .unknown
        }
        let batteries =
            descriptions?.filter {
                $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            } ?? []
        if !batteries.isEmpty { hasSeenInternalBattery = true }
        guard let descriptions,
            descriptions.allSatisfy({
                let type = $0[kIOPSTypeKey] as? String
                return type == kIOPSInternalBatteryType || type == kIOPSUPSType
            })
        else { return PowerSnapshot(source: source, battery: .unavailable) }
        guard !batteries.isEmpty else {
            return PowerSnapshot(
                source: source, battery: hasSeenInternalBattery ? .unavailable : .notPresent)
        }
        guard batteries.count == 1 else {
            return PowerSnapshot(source: source, battery: .unavailable)
        }
        return PowerSnapshot(source: source, battery: Self.battery(batteries[0]))
    }

    private static func battery(_ description: [String: Any]) -> BatteryReading {
        guard let present = description[kIOPSIsPresentKey] as? NSNumber,
            CFGetTypeID(present) == CFBooleanGetTypeID(), present.boolValue,
            let current = number(description[kIOPSCurrentCapacityKey]),
            let maximum = number(description[kIOPSMaxCapacityKey]),
            maximum > 0, current >= 0, current <= maximum,
            let state = description[kIOPSPowerSourceStateKey] as? String
        else { return .unavailable }
        let discharging: Bool
        switch state {
        case kIOPSBatteryPowerValue: discharging = true
        case kIOPSACPowerValue:
            guard let amperage = number(description[kIOPSCurrentKey]) else { return .unavailable }
            discharging = amperage < 0
        default: return .unavailable
        }
        let percent = Int((current / maximum * 100).rounded(.down))
        return .measured(percent: percent, isDischarging: discharging)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let value = number.doubleValue
        return value.isFinite && value.rounded(.towardZero) == value
            && value >= Double(Int32.min) && value <= Double(Int32.max) ? value : nil
    }
}

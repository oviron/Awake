import AwakeCore
import AwakeSystem
import Foundation

enum ProcessSelection {
    static func allFinished(_ identities: inout [ProcessIdentity]) -> Bool {
        identities.removeAll { !$0.isAlive }
        return identities.isEmpty
    }

    static func parse(_ text: String) throws -> [Int32] {
        let pieces = text.split(separator: ";", omittingEmptySubsequences: false)
        guard pieces.count <= 128 else { throw WorkError.invalidProcess }
        var ids: [Int32] = []
        for piece in pieces {
            let value = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
                let pid = Int32(value), pid > 0
            else { throw WorkError.invalidProcess }
            if !ids.contains(pid) { ids.append(pid) }
        }
        return ids
    }
}

enum PowerPresentation: Equatable {
    case active, inactive, suspended, recovering, restoring, attention, unknown, cooling

    init(_ status: ServiceStatus) {
        let sleep = status.sleep
        if sleep.phase == .restoring {
            self = .restoring
        } else if sleep.fault != nil {
            self = .attention
        } else if sleep.observed == .unknown {
            self = .unknown
        } else if !status.power.thermal.allowsAwake {
            self = .cooling
        } else if sleep.phase == .recovering {
            self = .recovering
        } else if sleep.phase == .active && sleep.observed == .disabled && sleep.ownsGlobalHold {
            self = .active
        } else if sleep.ownsGlobalHold || sleep.observed == .disabled {
            self = .attention
        } else if status.sessions.contains(where: { $0.suspension != nil }) {
            self = .suspended
        } else {
            self = .inactive
        }
    }

    var title: String {
        switch self {
        case .active: "Staying awake"
        case .inactive: "Ready when you are"
        case .suspended: "Waiting for power"
        case .recovering: "Verifying protection"
        case .restoring: "Restoring normal sleep"
        case .attention: "Power needs attention"
        case .unknown: "State unavailable"
        case .cooling: "Cooling down"
        }
    }

    var symbol: String {
        switch self {
        case .active: "sun.max.fill"
        case .inactive: "moon.zzz"
        case .suspended: "pause.circle"
        case .recovering, .restoring: "arrow.trianglehead.2.clockwise.rotate.90"
        case .attention: "exclamationmark.triangle"
        case .unknown: "questionmark.circle"
        case .cooling: "thermometer.high"
        }
    }

}

struct PolicyDraft: Equatable {
    var mode: PowerMode = .all
    var batteryFloor = 20
    var limitsDuration = false
    var maximumMinutes: Double = 120

    init() {}
    init(_ policy: UserPolicy) {
        mode = policy.mode
        batteryFloor = policy.batteryFloor
        limitsDuration = policy.maximumDuration != nil
        maximumMinutes = (policy.maximumDuration ?? 7_200) / 60
    }

    func policy(allowsAutomation: Bool) throws -> UserPolicy {
        try UserPolicy(
            mode: mode, batteryFloor: batteryFloor,
            maximumDuration: limitsDuration ? maximumMinutes * 60 : nil,
            allowsAutomation: allowsAutomation)
    }
}

enum StopChoice: Hashable {
    case unlimited
    case preset(Int)
    case custom, date, process
}

enum DurationUnit: String, CaseIterable, Identifiable {
    case seconds, minutes, hours, days
    var id: Self { self }
    var seconds: Double {
        switch self {
        case .seconds: 1
        case .minutes: 60
        case .hours: 3_600
        case .days: 86_400
        }
    }
}

extension PowerMode {
    var label: String {
        switch self {
        case .all: "Both"
        case .battery: "Battery"
        case .external: "Power adapter"
        }
    }
}

extension PowerSource {
    var label: String {
        switch self {
        case .battery: "Battery"
        case .external: "Power adapter"
        case .unknown: "Power source unknown"
        }
    }
    var symbol: String {
        switch self {
        case .battery: "battery.75percent"
        case .external: "powerplug"
        case .unknown: "questionmark.circle"
        }
    }
}

extension SleepFault {
    var guidance: String {
        switch self {
        case .foreignHold:
            "Another tool already disabled sleep. Restore its setting before rearming Awake."
        case .interrupted:
            "A previous session was interrupted. Confirm restoration, then rearm to start a new session."
        case .unreadableState:
            "macOS did not provide a usable state. Retry only after the reading is available."
        case .journalFailure:
            "Awake could not record ownership safely. Check the installation before trying again."
        case .activationFailed:
            "macOS did not confirm activation. No new session will start until you rearm."
        case .recoveryExhausted:
            "Repeated external changes exhausted recovery. Resolve the conflict before rearming."
        case .restorationFailed, .restorationPending:
            "Sleep restoration is not confirmed. Retry restoration and check the result."
        }
    }
}

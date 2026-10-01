import Foundation

public struct ClockSnapshot: Equatable, Sendable {
    public let continuous: TimeInterval
    public let wall: Date

    public init(continuous: TimeInterval, wall: Date) throws {
        guard continuous.isFinite, continuous >= 0, wall.timeIntervalSince1970.isFinite else {
            throw PolicyError.invalidClock
        }
        self.continuous = continuous
        self.wall = wall
    }
}

public enum SessionEnd: Codable, Equatable, Sendable {
    case unlimited
    case after(seconds: TimeInterval)
    case at(Date)

    public static let presetMinutes = [15, 30, 45, 60, 120, 240, 480, 720, 1440]

    public func validate(at now: ClockSnapshot) throws {
        switch self {
        case .unlimited: break
        case .after(let seconds):
            try UserPolicy.validateDuration(seconds)
            let end = now.continuous + seconds
            guard end.isFinite, end > now.continuous else { throw PolicyError.invalidDuration }
        case .at(let date):
            guard date.timeIntervalSince1970.isFinite, date > now.wall else {
                throw PolicyError.invalidDate
            }
        }
    }
}

public enum SessionKind: String, Codable, Sendable {
    case manual, task, agent
}

public struct SessionRequest: Codable, Equatable, Sendable {
    public let mode: PowerMode?
    public let batteryFloor: Int?
    public let end: SessionEnd

    public init(mode: PowerMode? = nil, batteryFloor: Int? = nil, end: SessionEnd = .unlimited) {
        self.mode = mode
        self.batteryFloor = batteryFloor
        self.end = end
    }

    public func validate(policy: UserPolicy, kind: SessionKind, now: ClockSnapshot) throws {
        if kind != .manual, !policy.allowsAutomation { throw PolicyError.automationNotAuthorized }
        if let mode, !mode.isWithin(policy.mode) { throw PolicyError.powerModeNotAuthorized }
        if let batteryFloor {
            guard UserPolicy.batteryFloorRange.contains(batteryFloor) else {
                throw PolicyError.invalidBatteryFloor
            }
            guard batteryFloor >= policy.batteryFloor else {
                throw PolicyError.batteryFloorNotAuthorized
            }
        }
        try end.validate(at: now)
        if let maximum = policy.maximumDuration {
            try SessionEnd.after(seconds: maximum).validate(at: now)
        }
    }
}

public struct Session: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let owner: UUID
    public let kind: SessionKind
    public let request: SessionRequest
    public let started: ClockSnapshot
    public let authorizedDuration: TimeInterval?

    public func hasExpired(at now: ClockSnapshot, policy: UserPolicy) -> Bool {
        guard now.continuous >= started.continuous else { return true }
        let elapsed = now.continuous - started.continuous
        if let authorizedDuration, elapsed >= authorizedDuration { return true }
        if let maximum = policy.maximumDuration, elapsed >= maximum { return true }
        switch request.end {
        case .unlimited: return false
        case .after(let seconds): return elapsed >= seconds
        case .at(let date): return now.wall >= date
        }
    }
}

import Foundation

public enum SessionStopReason: String, Codable, Sendable {
    case expired, batteryFloor, thermalPressure, automationRevoked, policyChanged
}

public enum SuspensionReason: String, Codable, Sendable {
    case powerSource, unknownPowerSource, unreadableBattery
}

public struct SessionEvaluation: Equatable, Sendable {
    public let eligible: Set<UUID>
    public let suspended: [UUID: SuspensionReason]
    public let stopped: [UUID: SessionStopReason]
    public var wantsAwake: Bool { !eligible.isEmpty }
}

public struct BatteryCutoff: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let percent: Int
    public let limit: Int
}

public struct SessionRegistry: Sendable {
    public private(set) var policy: UserPolicy
    public private(set) var sessions: [UUID: Session] = [:]
    public private(set) var batteryCutoff: BatteryCutoff?
    public private(set) var thermalCutoff: ThermalReading?
    public static let capacity = 256

    public init(policy: UserPolicy) { self.policy = policy }

    public mutating func updatePolicy(_ policy: UserPolicy) { self.policy = policy }

    @discardableResult
    public mutating func start(
        _ request: SessionRequest, owner: UUID, kind: SessionKind,
        now: ClockSnapshot, id: UUID = UUID()
    ) throws -> UUID {
        try request.validate(policy: policy, kind: kind, now: now)
        guard sessions[id] == nil else { throw PolicyError.duplicateSession }
        guard sessions.count < Self.capacity else { throw PolicyError.sessionLimitReached }
        if kind == .agent, sessions.values.contains(where: { $0.kind == .manual }) {
            throw ServiceError.sessionRejected
        }
        if kind == .manual { sessions = sessions.filter { $0.value.kind != .agent } }
        sessions[id] = Session(
            id: id, owner: owner, kind: kind, request: request,
            started: now, authorizedDuration: policy.maximumDuration
        )
        batteryCutoff = nil
        thermalCutoff = nil
        return id
    }

    @discardableResult
    public mutating func stop(_ id: UUID, owner: UUID) -> Bool {
        guard sessions[id]?.owner == owner else { return false }
        sessions.removeValue(forKey: id)
        return true
    }

    public mutating func releaseOwner(_ owner: UUID) {
        sessions = sessions.filter { $0.value.owner != owner }
    }

    public mutating func stopAll() {
        sessions.removeAll()
    }

    public mutating func revokeAutomationAndStop() throws {
        stopAll()
        policy = try UserPolicy(
            mode: policy.mode, batteryFloor: policy.batteryFloor,
            maximumDuration: policy.maximumDuration, allowsAutomation: false,
            keepsAwakeWithLidClosed: policy.keepsAwakeWithLidClosed
        )
    }

    public mutating func evaluate(power: PowerSnapshot, now: ClockSnapshot) -> SessionEvaluation {
        var eligible: Set<UUID> = []
        var suspended: [UUID: SuspensionReason] = [:]
        var stopped: [UUID: SessionStopReason] = [:]

        if !power.thermal.allowsAwake {
            if !sessions.isEmpty { thermalCutoff = power.thermal }
            for id in sessions.keys { stopped[id] = .thermalPressure }
            stopAll()
            return SessionEvaluation(eligible: [], suspended: [:], stopped: stopped)
        }

        for session in sessions.values {
            if session.kind != .manual, !policy.allowsAutomation {
                stopped[session.id] = .automationRevoked
                continue
            }
            if session.hasExpired(at: now, policy: policy) {
                stopped[session.id] = .expired
                continue
            }
            let mode = session.request.mode ?? policy.mode
            if mode != .all, policy.mode != .all, mode != policy.mode {
                stopped[session.id] = .policyChanged
                continue
            }
            let floor = max(session.request.batteryFloor ?? 0, policy.batteryFloor)
            if floor > 0 {
                switch power.battery {
                case .available(let percent, let discharging):
                    if power.source == .battery || discharging, percent <= floor {
                        stopped[session.id] = .batteryFloor
                        batteryCutoff = BatteryCutoff(
                            sessionID: session.id, percent: percent, limit: floor)
                        continue
                    }
                case .unavailable:
                    suspended[session.id] = .unreadableBattery
                    continue
                case .notPresent: break
                }
            }
            guard power.source != .unknown else {
                suspended[session.id] = .unknownPowerSource
                continue
            }
            guard mode.allows(power.source), policy.mode.allows(power.source) else {
                suspended[session.id] = .powerSource
                continue
            }
            eligible.insert(session.id)
        }
        for id in stopped.keys { sessions.removeValue(forKey: id) }
        return SessionEvaluation(eligible: eligible, suspended: suspended, stopped: stopped)
    }
}

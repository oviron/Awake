import Foundation

public enum ClientRole: Sendable {
    case application, task
}

public enum ServiceOperation: Codable, Equatable, Sendable {
    case status
    case configure(UserPolicy)
    case start(SessionRequest)
    case startAgent
    case stop(UUID)
    case stopAll
    case heartbeat
    case rearm
    case retryRestoration
    case prepareRemoval
    case prepareUpdate
    case finishRemoval
    case installCLI
    case setSudoTouchID(Bool)

    public var requiresApplication: Bool {
        switch self {
        case .configure, .stopAll, .rearm, .retryRestoration, .prepareRemoval, .prepareUpdate,
            .finishRemoval, .installCLI, .setSudoTouchID:
            true
        case .status, .start, .startAgent, .stop, .heartbeat: false
        }
    }
}

public enum ServiceError: String, Error, Codable, Sendable {
    case invalidMessage, incompatibleVersion, unauthorized, ownerExpired, capacityReached
    case sessionRejected, restorationRequired, removalInProgress, unavailable
    case sudoTouchIDPermissionDenied, sudoTouchIDFailed
    case thermalPressure
}

public enum RemovalState: String, Codable, Equatable, Sendable {
    case none, preparing, ready
}

public enum SudoTouchIDState: String, Codable, Equatable, Sendable {
    case unavailable, disabled, enabled, external
}

public struct ServiceRequest: Codable, Sendable {
    public let version: Int
    public let operation: ServiceOperation
    public init(_ operation: ServiceOperation) {
        version = ServiceWire.version
        self.operation = operation
    }
}

public struct SessionSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let kind: SessionKind
    public let end: SessionEnd
    public let startedAt: Date
    public let remainingSeconds: TimeInterval?
    public let suspension: SuspensionReason?
    public let belongsToClient: Bool

    public init(
        id: UUID, kind: SessionKind, end: SessionEnd, startedAt: Date,
        remainingSeconds: TimeInterval?, suspension: SuspensionReason?, belongsToClient: Bool
    ) {
        self.id = id
        self.kind = kind
        self.end = end
        self.startedAt = startedAt
        self.remainingSeconds = remainingSeconds
        self.suspension = suspension
        self.belongsToClient = belongsToClient
    }
}

public struct ServiceStatus: Codable, Equatable, Sendable {
    public let policy: UserPolicy
    public let power: PowerSnapshot
    public let sleep: SleepReport
    public let sessions: [SessionSummary]
    public let sampledAt: Date
    public let removal: RemovalState
    public let sudoTouchID: SudoTouchIDState
    public let batteryCutoff: BatteryCutoff?
    public let thermalCutoff: ThermalReading?

    public var canRemoveService: Bool {
        removal != .none && sessions.isEmpty && !sleep.restorationPending && !sleep.ownsGlobalHold
            && !sleep.holdsIdleAssertion
            && sleep.observed == .allowed && (sleep.phase == .inactive || sleep.phase == .blocked)
    }

    public func automationPolicyToRestore(_ saved: UserPolicy) throws -> UserPolicy? {
        guard !policy.allowsAutomation, sessions.isEmpty, removal == .none,
            sleep.phase == .inactive, sleep.observed == .allowed, !sleep.ownsGlobalHold,
            !sleep.holdsIdleAssertion,
            sleep.fault == nil
        else { return nil }
        return try UserPolicy(
            mode: policy.mode == .all ? saved.mode : policy.mode,
            batteryFloor: max(policy.batteryFloor, saved.batteryFloor),
            maximumDuration: [policy.maximumDuration, saved.maximumDuration].compactMap { $0 }
                .min(),
            allowsAutomation: true, keepsAwakeWithLidClosed: saved.keepsAwakeWithLidClosed)
    }

    public init(
        policy: UserPolicy, power: PowerSnapshot, sleep: SleepReport,
        sessions: [SessionSummary], sampledAt: Date, removal: RemovalState = .none,
        sudoTouchID: SudoTouchIDState = .unavailable, batteryCutoff: BatteryCutoff? = nil,
        thermalCutoff: ThermalReading? = nil
    ) {
        self.policy = policy
        self.power = power
        self.sleep = sleep
        self.sessions = sessions
        self.sampledAt = sampledAt
        self.removal = removal
        self.sudoTouchID = sudoTouchID
        self.batteryCutoff = batteryCutoff
        self.thermalCutoff = thermalCutoff
    }
}

public struct ServiceReply: Codable, Sendable {
    public let version: Int
    public let status: ServiceStatus?
    public let startedSession: UUID?
    public let error: ServiceError?
    public let sudoTouchID: SudoTouchIDState?

    public init(
        status: ServiceStatus? = nil, startedSession: UUID? = nil, error: ServiceError? = nil,
        sudoTouchID: SudoTouchIDState? = nil
    ) {
        version = ServiceWire.version
        self.status = status
        self.startedSession = startedSession
        self.error = error
        self.sudoTouchID = sudoTouchID
    }
}

public enum ServiceWire {
    public static let version = 12
    public static let maximumMessageBytes = 131_072

    public static func decodeRequest(_ data: Data) throws -> ServiceRequest {
        let request: ServiceRequest = try decode(data)
        guard request.version == version else { throw ServiceError.incompatibleVersion }
        return request
    }

    public static func decodeReply(_ data: Data) throws -> ServiceReply {
        let reply: ServiceReply = try decode(data)
        guard reply.version == version else { throw ServiceError.incompatibleVersion }
        return reply
    }

    public static func encode(_ value: some Encodable) throws -> Data {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximumMessageBytes else { throw ServiceError.invalidMessage }
        return data
    }

    private static func decode<T: Decodable>(_ data: Data) throws -> T {
        guard !data.isEmpty, data.count <= maximumMessageBytes else {
            throw ServiceError.invalidMessage
        }
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            throw ServiceError.invalidMessage
        }
    }
}

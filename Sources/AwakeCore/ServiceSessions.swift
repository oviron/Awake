import Foundation

public struct ServiceSessions: Sendable {
    public static let leaseSeconds: TimeInterval = 30
    public static let heartbeatSeconds: TimeInterval = 5
    public static let clientCapacity = 64
    public private(set) var registry: SessionRegistry
    public private(set) var consoleUser: UInt32?
    public private(set) var isRemoving = false
    private struct Client: Sendable {
        let user: UInt32
        let role: ClientRole
        var lastContact: TimeInterval
        var hasStarted = false
    }
    private var clients: [UUID: Client] = [:]

    public init() throws { registry = SessionRegistry(policy: try UserPolicy()) }

    @discardableResult
    public mutating func expire(now: ClockSnapshot, consoleUser: UInt32?) throws -> Set<UUID> {
        let changedUser = self.consoleUser != consoleUser
        self.consoleUser = consoleUser
        let expired = Set(
            clients.compactMap { id, client in
                changedUser || client.user != consoleUser || now.continuous < client.lastContact
                    || now.continuous - client.lastContact >= Self.leaseSeconds ? id : nil
            })
        for id in expired { disconnect(id) }
        if changedUser { registry = SessionRegistry(policy: try UserPolicy()) }
        return expired
    }

    public mutating func connect(
        owner: UUID, user: UInt32, role: ClientRole, now: ClockSnapshot
    ) throws {
        guard user != 0, user == consoleUser else { throw ServiceError.unauthorized }
        guard clients[owner] == nil, clients.count < Self.clientCapacity else {
            throw ServiceError.capacityReached
        }
        clients[owner] = Client(user: user, role: role, lastContact: now.continuous)
    }

    public mutating func disconnect(_ owner: UUID) {
        clients.removeValue(forKey: owner)
        registry.releaseOwner(owner)
    }

    public mutating func apply(
        _ operation: ServiceOperation, owner: UUID, now: ClockSnapshot
    ) throws -> UUID? {
        guard var client = clients[owner] else { throw ServiceError.ownerExpired }
        guard client.user == consoleUser else { throw ServiceError.unauthorized }
        guard now.continuous >= client.lastContact,
            now.continuous - client.lastContact < Self.leaseSeconds
        else {
            disconnect(owner)
            throw ServiceError.ownerExpired
        }
        guard !operation.requiresApplication || client.role == .application else {
            throw ServiceError.unauthorized
        }
        if isRemoving {
            switch operation {
            case .configure, .start, .startAgent, .rearm, .installCLI, .setSudoTouchID:
                throw ServiceError.removalInProgress
            case .status, .stop, .stopAll, .heartbeat, .retryRestoration, .prepareRemoval,
                .prepareUpdate, .finishRemoval:
                break
            }
        }
        client.lastContact = now.continuous
        clients[owner] = client
        switch operation {
        case .configure(let policy): registry.updatePolicy(policy)
        case .start, .startAgent:
            guard client.role == .application || !client.hasStarted else {
                throw ServiceError.ownerExpired
            }
            guard !registry.sessions.values.contains(where: { $0.owner == owner }) else {
                throw PolicyError.duplicateSession
            }
            let request: SessionRequest
            let kind: SessionKind
            if case .start(let submitted) = operation {
                request = submitted
                kind = client.role == .application ? .manual : .task
            } else {
                guard client.role == .task else { throw ServiceError.unauthorized }
                request = SessionRequest(
                    mode: registry.policy.mode,
                    batteryFloor: max(20, registry.policy.batteryFloor))
                kind = .agent
            }
            if kind == .agent {
                client.hasStarted = true
                clients[owner] = client
            }
            let id = try registry.start(request, owner: owner, kind: kind, now: now)
            client.hasStarted = true
            clients[owner] = client
            return id
        case .stop(let id):
            guard registry.stop(id, owner: owner) else { throw ServiceError.unauthorized }
        case .stopAll: registry.stopAll()
        case .prepareRemoval, .prepareUpdate:
            if operation == .prepareUpdate, !registry.sessions.isEmpty {
                throw ServiceError.sessionRejected
            }
            try registry.revokeAutomationAndStop()
            isRemoving = true
        case .finishRemoval:
            guard isRemoving else { throw ServiceError.restorationRequired }
        case .status, .heartbeat, .rearm, .retryRestoration, .installCLI, .setSudoTouchID: break
        }
        return nil
    }

    public mutating func evaluate(power: PowerSnapshot, now: ClockSnapshot) -> SessionEvaluation {
        registry.evaluate(power: power, now: now)
    }

    public mutating func revokeAutomationAndStop() throws { try registry.revokeAutomationAndStop() }

    public func summaries(
        for owner: UUID, evaluation: SessionEvaluation, now: ClockSnapshot
    ) -> [SessionSummary] {
        registry.sessions.values.map { session in
            var limits: [TimeInterval] = []
            let elapsed = now.continuous - session.started.continuous
            if let maximum = session.authorizedDuration { limits.append(maximum - elapsed) }
            if let maximum = registry.policy.maximumDuration { limits.append(maximum - elapsed) }
            switch session.request.end {
            case .unlimited: break
            case .after(let seconds): limits.append(seconds - elapsed)
            case .at(let date): limits.append(date.timeIntervalSince(now.wall))
            }
            return SessionSummary(
                id: session.id, kind: session.kind, end: session.request.end,
                startedAt: session.started.wall, remainingSeconds: limits.min().map { max(0, $0) },
                suspension: evaluation.suspended[session.id],
                belongsToClient: session.owner == owner)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
}

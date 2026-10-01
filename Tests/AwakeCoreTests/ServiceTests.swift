import Foundation
import Testing

@testable import AwakeCore

private func serviceClock(_ time: TimeInterval) throws -> ClockSnapshot {
    try ClockSnapshot(continuous: time, wall: Date(timeIntervalSince1970: 1_000 + time))
}

private func service() throws -> (ServiceSessions, UUID, UUID) {
    var value = try ServiceSessions()
    let app = UUID()
    let task = UUID()
    let now = try serviceClock(0)
    try value.expire(now: now, consoleUser: 501)
    try value.connect(owner: app, user: 501, role: .application, now: now)
    try value.connect(owner: task, user: 501, role: .task, now: now)
    return (value, app, task)
}

@Test func rememberedAutomationCannotWeakenLiveLimitsOrRestoreDuringFaults() throws {
    let policy = try UserPolicy(mode: .external, batteryFloor: 35, maximumDuration: 60)
    let saved = try UserPolicy(mode: .all, batteryFloor: 20, maximumDuration: 120)
    func snapshot(
        _ phase: SleepPhase = .inactive, observed: SleepObservation = .allowed,
        fault: SleepFault? = nil, removal: RemovalState = .none,
        sessions: [SessionSummary] = []
    ) -> ServiceStatus {
        ServiceStatus(
            policy: policy, power: .init(source: .external, battery: .notPresent),
            sleep: .init(phase: phase, observed: observed, ownsGlobalHold: false, fault: fault),
            sessions: sessions, sampledAt: Date(), removal: removal)
    }
    let proposed = try snapshot().automationPolicyToRestore(saved)
    let restored = try #require(proposed)
    #expect(restored.mode == .external && restored.batteryFloor == 35)
    #expect(restored.maximumDuration == 60 && restored.allowsAutomation)
    #expect(try snapshot(observed: .unknown).automationPolicyToRestore(saved) == nil)
    #expect(try snapshot(fault: .interrupted).automationPolicyToRestore(saved) == nil)
    #expect(try snapshot(removal: .ready).automationPolicyToRestore(saved) == nil)
    let active = SessionSummary(
        id: UUID(), kind: .manual, end: .unlimited, startedAt: Date(),
        remainingSeconds: nil, suspension: nil, belongsToClient: true)
    #expect(try snapshot(sessions: [active]).automationPolicyToRestore(saved) == nil)
}

@Test func taskEndpointCannotChangePolicyOrRearmAndCannotImpersonateApp() throws {
    var (value, app, task) = try service()
    let now = try serviceClock(0)
    for operation in [
        ServiceOperation.configure(try UserPolicy(allowsAutomation: true)),
        .stopAll, .rearm, .retryRestoration, .prepareRemoval, .prepareUpdate, .finishRemoval,
        .installCLI, .setSudoTouchID(true), .setSudoTouchID(false),
    ] {
        #expect(throws: ServiceError.unauthorized) {
            try value.apply(operation, owner: task, now: now)
        }
    }
    #expect(throws: PolicyError.automationNotAuthorized) {
        try value.apply(.start(SessionRequest()), owner: task, now: now)
    }
    _ = try value.apply(.configure(try UserPolicy(allowsAutomation: true)), owner: app, now: now)
    let started = try value.apply(.start(SessionRequest()), owner: task, now: now)
    let id = try #require(started)
    #expect(value.registry.sessions[id]?.kind == .task)
    #expect(throws: ServiceError.unauthorized) { try value.apply(.stop(id), owner: app, now: now) }
}

@Test func stopKeepsCLIEnabledButCannotRestartExistingWork() throws {
    var (value, app, task) = try service()
    let now = try serviceClock(0)
    _ = try value.apply(.configure(try UserPolicy(allowsAutomation: true)), owner: app, now: now)
    _ = try value.apply(.start(SessionRequest()), owner: task, now: now)
    _ = try value.apply(.stopAll, owner: app, now: now)
    #expect(value.registry.policy.allowsAutomation)
    #expect(value.registry.sessions.isEmpty)
    #expect(throws: ServiceError.ownerExpired) {
        try value.apply(.start(SessionRequest()), owner: task, now: now)
    }
    let next = UUID()
    try value.connect(owner: next, user: 501, role: .task, now: now)
    #expect(try value.apply(.start(SessionRequest()), owner: next, now: now) != nil)
}

@Test func agentsShareAwakeTimeAndYieldPermanentlyToManualSessions() throws {
    var (value, app, first) = try service()
    let now = try serviceClock(0)
    _ = try value.apply(.configure(try UserPolicy(allowsAutomation: true)), owner: app, now: now)
    let startedA = try value.apply(.startAgent, owner: first, now: now)
    let a = try #require(startedA)
    let second = UUID()
    try value.connect(owner: second, user: 501, role: .task, now: now)
    let startedB = try value.apply(.startAgent, owner: second, now: now)
    let b = try #require(startedB)
    #expect(value.registry.sessions[a]?.request.mode == .all)
    #expect(value.registry.sessions[a]?.request.batteryFloor == 20)
    _ = try value.apply(.stop(a), owner: first, now: now)
    #expect(value.registry.sessions[b] != nil)
    let startedManual = try value.apply(.start(.init()), owner: app, now: now)
    let manual = try #require(startedManual)
    #expect(value.registry.sessions.count == 1 && value.registry.sessions[manual] != nil)
    #expect(throws: ServiceError.ownerExpired) {
        try value.apply(.startAgent, owner: second, now: now)
    }
    let third = UUID()
    try value.connect(owner: third, user: 501, role: .task, now: now)
    let original = value.registry.policy
    #expect(throws: ServiceError.sessionRejected) {
        try value.apply(.startAgent, owner: third, now: now)
    }
    #expect(value.registry.policy == original && value.registry.sessions[manual] != nil)
    _ = try value.apply(.stop(manual), owner: app, now: now)
    #expect(throws: ServiceError.ownerExpired) {
        try value.apply(.startAgent, owner: third, now: now)
    }
}

@Test func agentsRespectStricterLimitsAndNeverReacquireAfterBatteryCutoff() throws {
    var (value, app, task) = try service()
    let now = try serviceClock(0)
    _ = try value.apply(
        .configure(
            try UserPolicy(
                mode: .battery, batteryFloor: 35,
                maximumDuration: 60, allowsAutomation: true)), owner: app, now: now)
    let started = try value.apply(.startAgent, owner: task, now: now)
    let id = try #require(started)
    #expect(value.registry.sessions[id]?.request.mode == .battery)
    #expect(value.registry.sessions[id]?.request.batteryFloor == 35)
    #expect(value.registry.sessions[id]?.authorizedDuration == 60)
    let power = PowerSnapshot(
        source: .battery, battery: .available(percent: 35, isDischarging: true))
    #expect(value.evaluate(power: power, now: now).stopped[id] == .batteryFloor)
    #expect(throws: ServiceError.ownerExpired) {
        try value.apply(.startAgent, owner: task, now: now)
    }
}

@Test func expiredLeaseCannotBeRenewedOrResurrectWork() throws {
    var (value, app, _) = try service()
    _ = try value.apply(.start(SessionRequest()), owner: app, now: serviceClock(0))
    #expect(throws: ServiceError.ownerExpired) {
        try value.apply(.heartbeat, owner: app, now: serviceClock(30))
    }
    #expect(value.registry.sessions.isEmpty)
    #expect(throws: ServiceError.ownerExpired) {
        try value.apply(.start(SessionRequest()), owner: app, now: serviceClock(31))
    }
}

@Test func heartbeatMaintainsLivenessWithoutExtendingAuthorizedDeadline() throws {
    var (value, app, task) = try service()
    _ = try value.apply(
        .configure(try UserPolicy(maximumDuration: 10, allowsAutomation: true)),
        owner: app, now: serviceClock(0))
    _ = try value.apply(.start(SessionRequest()), owner: task, now: serviceClock(0))
    _ = try value.apply(.heartbeat, owner: task, now: serviceClock(9))
    let evaluation = value.evaluate(
        power: PowerSnapshot(source: .external, battery: .notPresent),
        now: try serviceClock(10))
    #expect(evaluation.stopped.values.first == .expired)
    _ = try value.apply(.heartbeat, owner: task, now: serviceClock(11))
    #expect(value.registry.sessions.isEmpty)
    #expect(throws: ServiceError.ownerExpired) {
        try value.apply(.start(SessionRequest()), owner: task, now: serviceClock(11))
    }
}

@Test func disconnectedTaskReleasesOnlyItsOwnDemand() throws {
    var (value, app, task) = try service()
    _ = try value.apply(
        .configure(try UserPolicy(allowsAutomation: true)), owner: app, now: serviceClock(0))
    let manual = try value.apply(.start(SessionRequest()), owner: app, now: serviceClock(0))
    _ = try value.apply(.start(SessionRequest()), owner: task, now: serviceClock(0))
    value.disconnect(task)
    #expect(value.registry.sessions.count == 1)
    #expect(value.registry.sessions.values.first?.id == manual)
    #expect(throws: PolicyError.duplicateSession) {
        try value.apply(.start(SessionRequest()), owner: app, now: serviceClock(1))
    }
}

@Test func consoleSwitchResetsAuthorizationAndNeverAdmitsRootOrBackgroundUser() throws {
    var (value, app, task) = try service()
    _ = try value.apply(
        .configure(try UserPolicy(batteryFloor: 0, allowsAutomation: true)),
        owner: app, now: serviceClock(0))
    _ = try value.apply(.start(SessionRequest()), owner: task, now: serviceClock(0))
    let revoked = try value.expire(now: serviceClock(1), consoleUser: 502)
    #expect(revoked == [app, task])
    #expect(value.registry.sessions.isEmpty)
    #expect(value.registry.policy == (try UserPolicy()))
    for user: UInt32 in [0, 501] {
        #expect(throws: ServiceError.unauthorized) {
            try value.connect(owner: UUID(), user: user, role: .application, now: serviceClock(1))
        }
    }
}

@Test func watchdogExpiresStaleClientsAndBoundsConnections() throws {
    var value = try ServiceSessions()
    try value.expire(now: serviceClock(0), consoleUser: 501)
    for _ in 0..<ServiceSessions.clientCapacity {
        try value.connect(owner: UUID(), user: 501, role: .task, now: serviceClock(0))
    }
    #expect(throws: ServiceError.capacityReached) {
        try value.connect(owner: UUID(), user: 501, role: .task, now: serviceClock(0))
    }
    #expect(try value.expire(now: serviceClock(30), consoleUser: 501).count == 64)
    try value.connect(owner: UUID(), user: 501, role: .task, now: serviceClock(30))
}

@Test func transportRejectsOversizeMalformedUnknownVersionsAndInvalidPolicy() throws {
    for data in [
        Data(), Data("{}".utf8), Data(repeating: 32, count: ServiceWire.maximumMessageBytes + 1),
        Data(
            #"{"version":10,"operation":{"configure":{"_0":{"mode":"all","batteryFloor":81,"allowsAutomation":true}}}}"#
                .utf8),
    ] {
        #expect(throws: ServiceError.invalidMessage) { try ServiceWire.decodeRequest(data) }
    }
    #expect(throws: ServiceError.incompatibleVersion) {
        try ServiceWire.decodeRequest(Data(#"{"version":1,"operation":{"status":{}}}"#.utf8))
    }
    #expect(throws: ServiceError.incompatibleVersion) {
        try ServiceWire.decodeRequest(
            Data(#"{"version":5,"operation":{"setSudoTouchID":{"_0":false}}}"#.utf8))
    }
    #expect(throws: ServiceError.incompatibleVersion) {
        try ServiceWire.decodeRequest(Data(#"{"version":8,"operation":{"status":{}}}"#.utf8))
    }
    for operation in [
        ServiceOperation.status, .heartbeat, .stop(UUID()), .rearm, .retryRestoration,
        .stopAll, .prepareRemoval, .prepareUpdate, .finishRemoval,
        .configure(try UserPolicy(batteryFloor: 80)),
        .start(SessionRequest(end: .after(seconds: 60))), .setSudoTouchID(true),
    ] {
        #expect(
            try ServiceWire.decodeRequest(ServiceWire.encode(ServiceRequest(operation))).operation
                == operation)
    }
}

@Test func removalRevokesWorkAndCannotBeUndoneByAnotherClientOrConsoleChange() throws {
    var (value, app, task) = try service()
    let now = try serviceClock(0)
    #expect(throws: ServiceError.restorationRequired) {
        try value.apply(.finishRemoval, owner: app, now: now)
    }
    _ = try value.apply(.configure(try UserPolicy(allowsAutomation: true)), owner: app, now: now)
    _ = try value.apply(.start(SessionRequest()), owner: task, now: now)
    _ = try value.apply(.start(SessionRequest()), owner: app, now: now)
    _ = try value.apply(.prepareRemoval, owner: app, now: now)
    #expect(value.isRemoving && value.registry.sessions.isEmpty)
    _ = try value.apply(.finishRemoval, owner: app, now: now)
    #expect(!value.registry.policy.allowsAutomation)
    for operation in [
        ServiceOperation.configure(try UserPolicy(allowsAutomation: true)),
        .start(SessionRequest()), .rearm, .setSudoTouchID(true), .setSudoTouchID(false),
    ] {
        #expect(throws: ServiceError.removalInProgress) {
            try value.apply(operation, owner: app, now: now)
        }
    }
    _ = try value.apply(.heartbeat, owner: task, now: now)
    _ = try value.apply(.prepareRemoval, owner: app, now: now)
    _ = try value.expire(now: serviceClock(1), consoleUser: 502)
    let next = UUID()
    try value.connect(owner: next, user: 502, role: .application, now: serviceClock(1))
    #expect(throws: ServiceError.removalInProgress) {
        try value.apply(.start(SessionRequest()), owner: next, now: serviceClock(1))
    }
    _ = try value.apply(.retryRestoration, owner: next, now: serviceClock(1))
    #expect(value.registry.sessions.isEmpty)
}

@Test func updateWaitsForAllSessionsAndAtomicallyClosesNewAdmission() throws {
    var (value, app, task) = try service()
    let now = try serviceClock(0)
    _ = try value.apply(.configure(try UserPolicy(allowsAutomation: true)), owner: app, now: now)
    _ = try value.apply(.start(SessionRequest()), owner: task, now: now)
    _ = try value.apply(.start(SessionRequest()), owner: app, now: now)
    #expect(throws: ServiceError.sessionRejected) {
        try value.apply(.prepareUpdate, owner: app, now: now)
    }
    #expect(value.registry.sessions.count == 2 && !value.isRemoving)
    _ = try value.apply(.stopAll, owner: app, now: now)
    _ = try value.apply(.prepareUpdate, owner: app, now: now)
    #expect(value.isRemoving && !value.registry.policy.allowsAutomation)
    #expect(throws: ServiceError.removalInProgress) {
        try value.apply(.start(SessionRequest()), owner: app, now: now)
    }
}

@Test func removalNeedsAnExplicitDrainAndConfirmedRestoration() throws {
    let reports: [(SleepPhase, SleepObservation, Bool, Bool)] = [
        (.inactive, .allowed, false, true), (.blocked, .allowed, false, true),
        (.restoring, .allowed, true, false), (.inactive, .unknown, false, false),
        (.inactive, .disabled, false, false), (.active, .allowed, false, false),
    ]
    for (phase, observed, owned, expected) in reports {
        for removal in [RemovalState.none, .preparing, .ready] {
            let value = ServiceStatus(
                policy: try UserPolicy(),
                power: PowerSnapshot(source: .unknown, battery: .unavailable),
                sleep: SleepReport(
                    phase: phase, observed: observed, ownsGlobalHold: owned, fault: nil),
                sessions: [], sampledAt: Date(), removal: removal)
            #expect(value.canRemoveService == (expected && removal != .none))
        }
    }
    let withWork = ServiceStatus(
        policy: try UserPolicy(), power: PowerSnapshot(source: .unknown, battery: .unavailable),
        sleep: SleepReport(phase: .inactive, observed: .allowed, ownsGlobalHold: false, fault: nil),
        sessions: [
            SessionSummary(
                id: UUID(), kind: .task, end: .unlimited, startedAt: Date(), remainingSeconds: nil,
                suspension: .powerSource, belongsToClient: false)
        ],
        sampledAt: Date(), removal: .preparing)
    #expect(!withWork.canRemoveService)
}

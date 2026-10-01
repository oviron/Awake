import Foundation

public enum SleepObservation: String, Codable, Sendable {
    case allowed, disabled, unknown
}

public protocol SleepBackend {
    var hasIdleAssertion: Bool { get }
    mutating func observe() -> SleepObservation
    mutating func setSleepDisabled(_ disabled: Bool) throws
    mutating func setIdleAssertion(_ held: Bool) throws
}

public protocol OwnershipJournal {
    mutating func storeOwned(_ owned: Bool) throws
}

public enum SleepFault: String, Codable, Error, Sendable {
    case interrupted, foreignHold, unreadableState, journalFailure
    case activationFailed, recoveryExhausted, restorationFailed, restorationPending
}

public enum SleepPhase: String, Codable, Sendable {
    case inactive, active, recovering, restoring, blocked
}

public struct SleepReport: Equatable, Codable, Sendable {
    public let phase: SleepPhase
    public let observed: SleepObservation
    public let ownsGlobalHold: Bool
    public let fault: SleepFault?
    public let holdsIdleAssertion: Bool
    public let restorationPending: Bool

    public init(
        phase: SleepPhase, observed: SleepObservation, ownsGlobalHold: Bool, fault: SleepFault?,
        holdsIdleAssertion: Bool = false, restorationPending: Bool? = nil
    ) {
        self.phase = phase
        self.observed = observed
        self.ownsGlobalHold = ownsGlobalHold
        self.fault = fault
        self.holdsIdleAssertion = holdsIdleAssertion
        self.restorationPending = restorationPending ?? (ownsGlobalHold || holdsIdleAssertion)
    }
}

public struct SleepController: Sendable {
    public private(set) var ownsGlobalHold: Bool
    public private(set) var fault: SleepFault?
    public private(set) var recoveryAttempts = 0
    private var restorationAttempts = 0
    private var recoveryAt: TimeInterval = 0
    private var restorationAt: TimeInterval = 0
    private var lastTime: TimeInterval?
    private var ownsIdleHold = false
    private var lastLidProtection: Bool?
    public static let retryLimit = 3

    public init(restoringOwnedHold: Bool) {
        ownsGlobalHold = restoringOwnedHold
        fault = restoringOwnedHold ? .interrupted : nil
    }

    public var hasPendingRestoration: Bool { ownsGlobalHold || ownsIdleHold }

    public mutating func rearm() throws {
        guard !hasPendingRestoration else { throw SleepFault.restorationPending }
        fault = nil
        recoveryAttempts = 0
        restorationAttempts = 0
        recoveryAt = 0
        restorationAt = 0
    }

    public mutating func retryRestoration() {
        restorationAttempts = 0
        restorationAt = 0
    }

    public mutating func reconcile(
        wantsAwake: Bool, preventsLidSleep: Bool = true, now: ClockSnapshot,
        backend: inout some SleepBackend, journal: inout some OwnershipJournal
    ) -> SleepReport {
        if let lastTime, now.continuous < lastTime {
            fault = .interrupted
            recoveryAt = 0
            restorationAt = 0
        }
        lastTime = now.continuous
        let observed = backend.observe()
        if !wantsAwake || fault != nil {
            return restore(now: now.continuous, backend: &backend, journal: &journal)
        }
        guard observed != .unknown else {
            fault = .unreadableState
            return restore(now: now.continuous, backend: &backend, journal: &journal)
        }
        if !preventsLidSleep, ownsGlobalHold {
            do {
                try releaseGlobal(backend: &backend, journal: &journal, assertionReleased: true)
                restorationAttempts = 0
                restorationAt = 0
            } catch {
                fault = .restorationFailed
                return restore(now: now.continuous, backend: &backend, journal: &journal)
            }
        }
        if !ownsGlobalHold {
            guard backend.observe() == .allowed else {
                fault = .foreignHold
                return restore(now: now.continuous, backend: &backend, journal: &journal)
            }
            if preventsLidSleep {
                do {
                    try journal.storeOwned(true)
                    ownsGlobalHold = true
                } catch {
                    fault = .journalFailure
                    return restore(now: now.continuous, backend: &backend, journal: &journal)
                }
            }
        }
        let expected: SleepObservation = preventsLidSleep ? .disabled : .allowed
        if backend.hasIdleAssertion, backend.observe() == expected {
            ownsIdleHold = true
            lastLidProtection = preventsLidSleep
            return report(.active, expected, backend: backend)
        }
        if ownsIdleHold, lastLidProtection == preventsLidSleep {
            guard recoveryAttempts < Self.retryLimit else {
                fault = .recoveryExhausted
                return restore(now: now.continuous, backend: &backend, journal: &journal)
            }
            guard now.continuous >= recoveryAt else {
                return report(.recovering, backend.observe(), backend: backend)
            }
            recoveryAttempts += 1
        }
        do {
            ownsIdleHold = true
            try backend.setIdleAssertion(true)
            guard backend.hasIdleAssertion else { throw SleepFault.activationFailed }
            if preventsLidSleep { try backend.setSleepDisabled(true) }
            let applied = backend.observe()
            guard applied == expected else { throw SleepFault.activationFailed }
            recoveryAt = now.continuous + pow(2, Double(recoveryAttempts))
            lastLidProtection = preventsLidSleep
            return report(.active, applied, backend: backend)
        } catch {
            fault = .activationFailed
            return restore(now: now.continuous, backend: &backend, journal: &journal)
        }
    }

    private mutating func releaseGlobal(
        backend: inout some SleepBackend, journal: inout some OwnershipJournal,
        assertionReleased: Bool
    ) throws {
        guard ownsGlobalHold else { return }
        try backend.setSleepDisabled(false)
        guard backend.observe() == .allowed, assertionReleased else {
            throw SleepFault.restorationFailed
        }
        try journal.storeOwned(false)
        ownsGlobalHold = false
    }

    private mutating func restore(
        now: TimeInterval, backend: inout some SleepBackend, journal: inout some OwnershipJournal
    ) -> SleepReport {
        guard ownsGlobalHold || ownsIdleHold || backend.hasIdleAssertion else {
            return report(fault == nil ? .inactive : .blocked, backend.observe(), backend: backend)
        }
        guard restorationAttempts < Self.retryLimit else {
            return report(.blocked, backend.observe(), backend: backend)
        }
        guard now >= restorationAt else {
            return report(.restoring, backend.observe(), backend: backend)
        }
        restorationAttempts += 1
        restorationAt = now + pow(2, Double(restorationAttempts))
        var assertionReleased = false
        do {
            try backend.setIdleAssertion(false)
            assertionReleased = !backend.hasIdleAssertion
            ownsIdleHold = !assertionReleased
        } catch {
            ownsIdleHold = true
        }
        do {
            try releaseGlobal(
                backend: &backend, journal: &journal, assertionReleased: assertionReleased)
            guard assertionReleased else { throw SleepFault.restorationFailed }
            restorationAttempts = 0
            restorationAt = 0
            lastLidProtection = nil
            return report(fault == nil ? .inactive : .blocked, backend.observe(), backend: backend)
        } catch {
            fault = .restorationFailed
            return report(
                restorationAttempts < Self.retryLimit ? .restoring : .blocked,
                backend.observe(), backend: backend)
        }
    }

    private func report(
        _ phase: SleepPhase, _ observed: SleepObservation, backend: some SleepBackend
    ) -> SleepReport {
        SleepReport(
            phase: phase, observed: observed, ownsGlobalHold: ownsGlobalHold, fault: fault,
            holdsIdleAssertion: backend.hasIdleAssertion, restorationPending: hasPendingRestoration)
    }
}

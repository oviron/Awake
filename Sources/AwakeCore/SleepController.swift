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

    public init(
        phase: SleepPhase, observed: SleepObservation, ownsGlobalHold: Bool, fault: SleepFault?
    ) {
        self.phase = phase
        self.observed = observed
        self.ownsGlobalHold = ownsGlobalHold
        self.fault = fault
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
    public static let retryLimit = 3

    public init(restoringOwnedHold: Bool) {
        ownsGlobalHold = restoringOwnedHold
        fault = restoringOwnedHold ? .interrupted : nil
    }

    public mutating func rearm() throws {
        guard !ownsGlobalHold else { throw SleepFault.restorationPending }
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
        wantsAwake: Bool, now: ClockSnapshot,
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
        if !ownsGlobalHold {
            guard observed == .allowed else {
                fault = .foreignHold
                return report(.blocked, observed)
            }
            do {
                try journal.storeOwned(true)
                ownsGlobalHold = true
            } catch {
                fault = .journalFailure
                return report(.blocked, observed)
            }
        } else if observed == .disabled, backend.hasIdleAssertion {
            return report(.active, observed)
        } else {
            guard recoveryAttempts < Self.retryLimit else {
                fault = .recoveryExhausted
                return restore(now: now.continuous, backend: &backend, journal: &journal)
            }
            guard now.continuous >= recoveryAt else { return report(.recovering, observed) }
            recoveryAttempts += 1
        }

        do {
            try backend.setIdleAssertion(true)
            guard backend.hasIdleAssertion else { throw SleepFault.activationFailed }
            try backend.setSleepDisabled(true)
            let applied = backend.observe()
            guard applied == .disabled else { throw SleepFault.activationFailed }
            recoveryAt = now.continuous + pow(2, Double(recoveryAttempts))
            return report(.active, applied)
        } catch {
            fault = .activationFailed
            return restore(now: now.continuous, backend: &backend, journal: &journal)
        }
    }

    private mutating func restore(
        now: TimeInterval, backend: inout some SleepBackend, journal: inout some OwnershipJournal
    ) -> SleepReport {
        guard ownsGlobalHold else {
            let observed = backend.observe()
            return report(fault == nil ? .inactive : .blocked, observed)
        }
        guard restorationAttempts < Self.retryLimit else {
            return report(.blocked, backend.observe())
        }
        guard now >= restorationAt else {
            return report(.restoring, backend.observe())
        }
        restorationAttempts += 1
        restorationAt = now + pow(2, Double(restorationAttempts))
        var assertionReleased = false
        do {
            try backend.setIdleAssertion(false)
            assertionReleased = !backend.hasIdleAssertion
        } catch {
        }
        do {
            try backend.setSleepDisabled(false)
            guard backend.observe() == .allowed, assertionReleased else {
                throw SleepFault.restorationFailed
            }
            try journal.storeOwned(false)
            ownsGlobalHold = false
            restorationAttempts = 0
            restorationAt = 0
            return report(fault == nil ? .inactive : .blocked, .allowed)
        } catch {
            fault = .restorationFailed
            return report(
                restorationAttempts < Self.retryLimit ? .restoring : .blocked, backend.observe())
        }
    }

    private func report(_ phase: SleepPhase, _ observed: SleepObservation) -> SleepReport {
        SleepReport(phase: phase, observed: observed, ownsGlobalHold: ownsGlobalHold, fault: fault)
    }
}

import Foundation
import Testing

@testable import AwakeCore

private enum SimulatedFailure: Error { case io }

private struct TestBackend: SleepBackend {
    var observation: SleepObservation = .allowed
    var hasIdleAssertion = false
    var writes: [Bool] = []
    var failsEnable = false
    var failsDisable = false
    var ignoresWrites = false
    var failsAssertion = false

    mutating func observe() -> SleepObservation { observation }
    mutating func setSleepDisabled(_ disabled: Bool) throws {
        writes.append(disabled)
        if disabled ? failsEnable : failsDisable { throw SimulatedFailure.io }
        if !ignoresWrites { observation = disabled ? .disabled : .allowed }
    }
    mutating func setIdleAssertion(_ held: Bool) throws {
        if failsAssertion { throw SimulatedFailure.io }
        hasIdleAssertion = held
    }
}

private struct TestJournal: OwnershipJournal {
    var claims: [Bool] = []
    var failsClaim = false
    var failsRelease = false
    mutating func storeOwned(_ owned: Bool) throws {
        if owned ? failsClaim : failsRelease { throw SimulatedFailure.io }
        claims.append(owned)
    }
}

private func instant(_ seconds: Double = 10) throws -> ClockSnapshot {
    try ClockSnapshot(continuous: seconds, wall: Date(timeIntervalSince1970: seconds))
}

@Test func observedActivationAndStopHaveDurableOwnership() throws {
    var controller = SleepController(restoringOwnedHold: false)
    var backend = TestBackend()
    var journal = TestJournal()
    let on = controller.reconcile(
        wantsAwake: true, now: try instant(), backend: &backend, journal: &journal)
    #expect(on.phase == .active && on.observed == .disabled && on.ownsGlobalHold)
    #expect(journal.claims == [true])
    let off = controller.reconcile(
        wantsAwake: false, now: try instant(20), backend: &backend, journal: &journal)
    #expect(off.phase == .inactive && off.observed == .allowed && !off.ownsGlobalHold)
    #expect(journal.claims == [true, false])
    #expect(backend.writes == [true, false])
    #expect(!backend.hasIdleAssertion)
}

@Test(arguments: [SleepObservation.disabled, .unknown])
func unownedStateCannotBeAdoptedOrOverwritten(_ observation: SleepObservation) throws {
    var controller = SleepController(restoringOwnedHold: false)
    var backend = TestBackend(observation: observation)
    var journal = TestJournal()
    let result = controller.reconcile(
        wantsAwake: true, now: try instant(), backend: &backend, journal: &journal)
    #expect(result.phase == .blocked)
    #expect(!result.ownsGlobalHold && backend.writes.isEmpty && journal.claims.isEmpty)
    _ = controller.reconcile(
        wantsAwake: false, now: try instant(20), backend: &backend, journal: &journal)
    #expect(backend.writes.isEmpty)
}

@Test func journalFailurePreventsAnyPowerWrite() throws {
    var controller = SleepController(restoringOwnedHold: false)
    var backend = TestBackend()
    var journal = TestJournal(failsClaim: true)
    let result = controller.reconcile(
        wantsAwake: true, now: try instant(), backend: &backend, journal: &journal)
    #expect(result.fault == .journalFailure)
    #expect(backend.writes.isEmpty && !backend.hasIdleAssertion)
}

@Test func commandSuccessWithoutAppliedStateIsNeverReportedActive() throws {
    var controller = SleepController(restoringOwnedHold: false)
    var backend = TestBackend(ignoresWrites: true)
    var journal = TestJournal()
    let result = controller.reconcile(
        wantsAwake: true, now: try instant(), backend: &backend, journal: &journal)
    #expect(result.phase == .blocked && result.fault == .activationFailed)
    #expect(backend.writes == [true, false])
    #expect(journal.claims == [true, false])
}

@Test func failedActivationRollsBackAndCannotRetryWithoutRearming() throws {
    var controller = SleepController(restoringOwnedHold: false)
    var backend = TestBackend(failsEnable: true)
    var journal = TestJournal()
    _ = controller.reconcile(
        wantsAwake: true, now: try instant(), backend: &backend, journal: &journal)
    backend.failsEnable = false
    let blocked = controller.reconcile(
        wantsAwake: true, now: try instant(20), backend: &backend, journal: &journal)
    #expect(blocked.phase == .blocked && backend.writes == [true, false])
    try controller.rearm()
    let rearmed = controller.reconcile(
        wantsAwake: true, now: try instant(30), backend: &backend, journal: &journal)
    #expect(rearmed.phase == .active)
}

@Test func restartRestoresBeforeAnyActivationAndRequiresUserRearm() throws {
    var controller = SleepController(restoringOwnedHold: true)
    var backend = TestBackend(observation: .disabled)
    var journal = TestJournal()
    let restored = controller.reconcile(
        wantsAwake: true, now: try instant(), backend: &backend, journal: &journal)
    #expect(restored.phase == .blocked && restored.fault == .interrupted)
    #expect(backend.writes == [false] && journal.claims == [false])
}

@Test func successfulRepairsDoNotResetRecoveryBudget() throws {
    var controller = SleepController(restoringOwnedHold: false)
    var backend = TestBackend()
    var journal = TestJournal()
    _ = controller.reconcile(
        wantsAwake: true, now: try instant(), backend: &backend, journal: &journal)
    for attempt in 1...SleepController.retryLimit {
        backend.observation = .allowed
        let recovered = controller.reconcile(
            wantsAwake: true, now: try instant(Double(attempt * 10 + 10)),
            backend: &backend, journal: &journal)
        #expect(recovered.phase == .active)
    }
    backend.observation = .allowed
    let exhausted = controller.reconcile(
        wantsAwake: true, now: try instant(100), backend: &backend, journal: &journal)
    #expect(exhausted.fault == .recoveryExhausted && exhausted.phase == .blocked)
    #expect(backend.writes.filter { $0 }.count == 4)
    #expect(!backend.hasIdleAssertion)
}

@Test func stopOutranksRecoveryBackoff() throws {
    var controller = SleepController(restoringOwnedHold: false)
    var backend = TestBackend()
    var journal = TestJournal()
    _ = controller.reconcile(
        wantsAwake: true, now: try instant(), backend: &backend, journal: &journal)
    backend.observation = .allowed
    let stopped = controller.reconcile(
        wantsAwake: false, now: try instant(10.1), backend: &backend, journal: &journal)
    #expect(stopped.phase == .inactive)
    #expect(backend.writes == [true, false])
}

@Test func lostCaffeinateAssertionIsRepairedWithinTheExistingBudgetAndStopWins() throws {
    var controller = SleepController(restoringOwnedHold: false)
    var backend = TestBackend()
    var journal = TestJournal()
    _ = controller.reconcile(
        wantsAwake: true, now: try instant(), backend: &backend, journal: &journal)
    for attempt in 1...SleepController.retryLimit {
        backend.hasIdleAssertion = false
        let repaired = controller.reconcile(
            wantsAwake: true, now: try instant(Double(attempt * 10 + 10)),
            backend: &backend, journal: &journal)
        #expect(repaired.phase == .active && backend.hasIdleAssertion)
        #expect(controller.recoveryAttempts == attempt)
    }
    backend.hasIdleAssertion = false
    let exhausted = controller.reconcile(
        wantsAwake: true, now: try instant(100), backend: &backend, journal: &journal)
    #expect(exhausted.fault == .recoveryExhausted && !exhausted.ownsGlobalHold)
    #expect(!backend.hasIdleAssertion && backend.observation == .allowed)
}

@Test func unknownOwnedStateTriggersCleanupInsteadOfEnablingAgain() throws {
    var controller = SleepController(restoringOwnedHold: false)
    var backend = TestBackend()
    var journal = TestJournal()
    _ = controller.reconcile(
        wantsAwake: true, now: try instant(), backend: &backend, journal: &journal)
    backend.observation = .unknown
    let result = controller.reconcile(
        wantsAwake: true, now: try instant(20), backend: &backend, journal: &journal)
    #expect(result.phase == .blocked && result.fault == .unreadableState)
    #expect(backend.writes == [true, false])
}

@Test func failedStopRetainsJournalAndBoundsAutomaticRetries() throws {
    var controller = SleepController(restoringOwnedHold: true)
    var backend = TestBackend(observation: .disabled, failsDisable: true)
    var journal = TestJournal()
    for second in [10.0, 11, 12, 16, 30, 100] {
        let result = controller.reconcile(
            wantsAwake: false, now: try instant(second), backend: &backend, journal: &journal)
        #expect(result.phase == (second >= 16 ? .blocked : .restoring) && result.ownsGlobalHold)
    }
    #expect(backend.writes == [false, false, false] && journal.claims.isEmpty)
    #expect(throws: SleepFault.restorationPending) { try controller.rearm() }
    backend.failsDisable = false
    controller.retryRestoration()
    let retried = controller.reconcile(
        wantsAwake: false, now: try instant(110), backend: &backend, journal: &journal)
    #expect(!retried.ownsGlobalHold && retried.phase == .blocked)
}

@Test func failedJournalReleaseCannotReportCompletedCleanup() throws {
    var controller = SleepController(restoringOwnedHold: true)
    var backend = TestBackend(observation: .disabled)
    var journal = TestJournal(failsRelease: true)
    let result = controller.reconcile(
        wantsAwake: false, now: try instant(), backend: &backend, journal: &journal)
    #expect(result.phase == .restoring && result.ownsGlobalHold)
    #expect(result.observed == .allowed)
}

@Test func assertionFailureDoesNotSkipGlobalCleanup() throws {
    var controller = SleepController(restoringOwnedHold: true)
    var backend = TestBackend(observation: .disabled, hasIdleAssertion: true, failsAssertion: true)
    var journal = TestJournal()
    let result = controller.reconcile(
        wantsAwake: false, now: try instant(), backend: &backend, journal: &journal)
    #expect(backend.writes == [false])
    #expect(result.ownsGlobalHold && result.phase == .restoring)
}

@Test func expiredDemandCannotBeRevivedByLostStateRecovery() throws {
    var registry = SessionRegistry(policy: try UserPolicy())
    try registry.start(
        .init(end: .after(seconds: 10)), owner: UUID(), kind: .manual, now: instant())
    let power = PowerSnapshot(source: .external, battery: .notPresent)
    var controller = SleepController(restoringOwnedHold: false)
    var backend = TestBackend()
    var journal = TestJournal()
    let first = registry.evaluate(power: power, now: try instant())
    _ = controller.reconcile(
        wantsAwake: first.wantsAwake, now: try instant(), backend: &backend, journal: &journal)
    backend.observation = .allowed
    let expired = registry.evaluate(power: power, now: try instant(20))
    let result = controller.reconcile(
        wantsAwake: expired.wantsAwake, now: try instant(20), backend: &backend, journal: &journal)
    #expect(result.phase == .inactive && registry.sessions.isEmpty)
    #expect(backend.writes == [true, false])
}

@Test func backwardsContinuousClockCleansUpRatherThanExtendingWork() throws {
    var controller = SleepController(restoringOwnedHold: false)
    var backend = TestBackend()
    var journal = TestJournal()
    _ = controller.reconcile(
        wantsAwake: true, now: try instant(), backend: &backend, journal: &journal)
    let invalidated = controller.reconcile(
        wantsAwake: true, now: try instant(1), backend: &backend, journal: &journal)
    #expect(invalidated.fault == .interrupted && !invalidated.ownsGlobalHold)
    #expect(backend.writes == [true, false])
}

import Foundation
import Testing

@testable import AwakeCore

@Test(arguments: [ThermalReading.serious, .critical, .unavailable])
func unsafeThermalStateStopsEverySessionAndNeverResumes(_ thermal: ThermalReading) throws {
    var registry = SessionRegistry(policy: try UserPolicy(allowsAutomation: true))
    let now = try ClockSnapshot(continuous: 1, wall: Date(timeIntervalSince1970: 1))
    let manual = try registry.start(.init(), owner: UUID(), kind: .manual, now: now)
    let task = try registry.start(.init(), owner: UUID(), kind: .task, now: now)
    let hot = PowerSnapshot(source: .external, battery: .notPresent, thermal: thermal)
    let result = registry.evaluate(power: hot, now: now)
    #expect(result.stopped == [manual: .thermalPressure, task: .thermalPressure])
    #expect(!result.wantsAwake && registry.sessions.isEmpty)
    #expect(registry.thermalCutoff == thermal)
    let cooled = PowerSnapshot(source: .external, battery: .notPresent, thermal: .nominal)
    #expect(!registry.evaluate(power: cooled, now: now).wantsAwake)
    #expect(registry.thermalCutoff == thermal)
    try registry.start(.init(), owner: UUID(), kind: .manual, now: now)
    #expect(registry.thermalCutoff == nil)
    #expect(registry.evaluate(power: cooled, now: now).wantsAwake)
}

@Test(arguments: [ThermalReading.nominal, .fair])
func normalThermalStatesPreserveAnAuthorizedHold(_ thermal: ThermalReading) throws {
    var registry = SessionRegistry(policy: try UserPolicy())
    let now = try ClockSnapshot(continuous: 1, wall: Date(timeIntervalSince1970: 1))
    let id = try registry.start(.init(), owner: UUID(), kind: .manual, now: now)
    let power = PowerSnapshot(
        source: .battery, battery: .available(percent: 80, isDischarging: true), thermal: thermal)
    #expect(registry.evaluate(power: power, now: now).eligible == [id])
    #expect(registry.thermalCutoff == nil)
}

@Test func thermalCutoffPreventsRecoveryOfAnOwnedSleepOverride() throws {
    var registry = SessionRegistry(policy: try UserPolicy())
    let now = try ClockSnapshot(continuous: 1, wall: Date(timeIntervalSince1970: 1))
    try registry.start(.init(), owner: UUID(), kind: .manual, now: now)
    let evaluation = registry.evaluate(
        power: .init(source: .external, battery: .notPresent, thermal: .critical), now: now)
    var backend = ThermalBackend()
    var journal = ThermalJournal()
    var controller = SleepController(restoringOwnedHold: false)
    let initial = controller.reconcile(
        wantsAwake: true, now: now, backend: &backend, journal: &journal)
    #expect(initial.phase == .active && initial.fault == nil)
    backend.state = .allowed
    let report = controller.reconcile(
        wantsAwake: evaluation.wantsAwake, now: now, backend: &backend, journal: &journal)
    #expect(backend.writes == [true, false])
    #expect(report.observed == .allowed && !report.ownsGlobalHold)
    #expect(journal.owned == false)
}

private struct ThermalBackend: SleepBackend {
    var hasIdleAssertion = false
    var state: SleepObservation = .allowed
    var writes: [Bool] = []
    mutating func observe() -> SleepObservation { state }
    mutating func setSleepDisabled(_ disabled: Bool) throws {
        writes.append(disabled)
        state = disabled ? .disabled : .allowed
    }
    mutating func setIdleAssertion(_ held: Bool) throws { hasIdleAssertion = held }
}

private struct ThermalJournal: OwnershipJournal {
    var owned = false
    mutating func storeOwned(_ owned: Bool) throws { self.owned = owned }
}

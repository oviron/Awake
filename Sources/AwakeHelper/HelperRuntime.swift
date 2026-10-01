import AwakeCore
import AwakeSystem
import Foundation

final class HelperRuntime {
    var sessions: ServiceSessions
    var controller: SleepController
    var backend = MacSleepBackend()
    var powerReader = PowerSourceReader()
    var journal: SecureOwnershipJournal
    private let identity: SignedIdentity
    private var installedFiles: InstalledHelperFiles?
    private var removalReady = false
    private(set) var expiredOwners: Set<UUID> = []

    init(identity: SignedIdentity) throws {
        self.identity = identity
        sessions = try ServiceSessions()
        journal = try SecureOwnershipJournal()
        controller = SleepController(restoringOwnedHold: try journal.loadOwned())
        _ = try reconcile(owner: UUID())
    }

    func reconcile(owner: UUID) throws -> ServiceStatus {
        let now = try SystemClock.now()
        expiredOwners.formUnion(
            try sessions.expire(now: now, consoleUser: ConsoleUser.identifier()))
        let power = powerReader.snapshot()
        var evaluation = sessions.evaluate(power: power, now: now)
        var report = controller.reconcile(
            wantsAwake: evaluation.wantsAwake, now: now,
            backend: &backend, journal: &journal)
        if report.fault != nil {
            try sessions.revokeAutomationAndStop()
            evaluation = sessions.evaluate(power: power, now: now)
            report = controller.reconcile(
                wantsAwake: false, now: now,
                backend: &backend, journal: &journal)
        }
        return ServiceStatus(
            policy: sessions.registry.policy, power: power, sleep: report,
            sessions: sessions.summaries(for: owner, evaluation: evaluation, now: now),
            sampledAt: now.wall,
            removal: sessions.isRemoving ? (removalReady ? .ready : .preparing) : .none,
            sudoTouchID: SudoTouchID.status(), batteryCutoff: sessions.registry.batteryCutoff,
            thermalCutoff: sessions.registry.thermalCutoff)
    }

    func takeExpiredOwners() -> Set<UUID> {
        defer { expiredOwners.removeAll() }
        return expiredOwners
    }

    func request(_ data: Data, owner: UUID) -> ServiceReply {
        do {
            let request = try ServiceWire.decodeRequest(data)
            if case .setSudoTouchID = request.operation { throw ServiceError.unauthorized }
            let current = try reconcile(owner: owner)
            switch request.operation {
            case .start, .startAgent:
                guard current.power.thermal.allowsAwake else { throw ServiceError.thermalPressure }
            default: break
            }
            if controller.fault != nil {
                switch request.operation {
                case .start, .startAgent: throw ServiceError.restorationRequired
                default: break
                }
            }
            let started = try sessions.apply(
                request.operation, owner: owner, now: SystemClock.now())
            switch request.operation {
            case .installCLI:
                guard let user = sessions.consoleUser else { throw ServiceError.unauthorized }
                try InstalledCLI.install(identity: identity, user: user)
            case .rearm: try controller.rearm()
            case .retryRestoration, .prepareRemoval, .prepareUpdate: controller.retryRestoration()
            default: break
            }
            if request.operation == .prepareRemoval || request.operation == .prepareUpdate {
                removalReady = false
                let status = try reconcile(owner: owner)
                guard status.canRemoveService, !backend.hasIdleAssertion
                else { throw ServiceError.restorationRequired }
                if request.operation == .prepareRemoval, let user = sessions.consoleUser {
                    try InstalledCLI.remove(user: user)
                }
                if installedFiles == nil {
                    installedFiles = try InstalledHelperFiles(identity: identity)
                }
                try journal.removeUnownedDirectory()
                removalReady = true
            }
            if request.operation == .finishRemoval {
                let status = try reconcile(owner: owner)
                guard removalReady, journal.isRemoved, status.canRemoveService,
                    !backend.hasIdleAssertion
                else { throw ServiceError.restorationRequired }
                try installedFiles?.remove()
            }
            return ServiceReply(status: try reconcile(owner: owner), startedSession: started)
        } catch {
            let failure: ServiceError
            switch error {
            case let value as ServiceError: failure = value
            case is PolicyError: failure = .sessionRejected
            case is SleepFault: failure = .restorationRequired
            default: failure = .unavailable
            }
            return ServiceReply(status: try? reconcile(owner: owner), error: failure)
        }
    }
}

import AppKit
import AwakeCore
import Carbon
import Foundation
import ServiceManagement
import SwiftUI
import Testing

@testable import AwakeApp
@testable import AwakeSystem

private final class MockUpdateHelper: @unchecked Sendable, HelperInstallation {
    var status: SMAppService.Status
    var registrations = 0
    var registrationFails = false

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() async throws {
        registrations += 1
        if registrationFails { throw CocoaError(.userCancelled) }
        status = .enabled
    }

    func unregister() async throws {
        status = .notRegistered
    }
}

@Test @MainActor func systemRestartAndShutdownAreDistinctFromOrdinaryQuit() {
    func quit(reason: OSType?) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEQuitApplication),
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        if let reason {
            event.setParam(
                NSAppleEventDescriptor(enumCode: reason), forKeyword: AEKeyword(kAEQuitReason))
        }
        return event
    }
    #expect(AppDelegate.isSystemRestart(quit(reason: OSType(kAERestart))))
    #expect(AppDelegate.isSystemRestart(quit(reason: OSType(kAEShutDown))))
    #expect(!AppDelegate.isSystemRestart(quit(reason: OSType(kAEReallyLogOut))))
    #expect(!AppDelegate.isSystemRestart(quit(reason: nil)))
    #expect(!AppDelegate.isSystemRestart(nil))
    #expect(!AppDelegate.isSystemRestart(NSAppleEventDescriptor(string: "restart")))
}

@Test @MainActor func restartDeferralEndsWithTheLastLiveProtectedSession() {
    #expect(AppDelegate.shouldDeferRestart(presentation: .active, remainingSessions: [120]))
    #expect(AppDelegate.shouldDeferRestart(presentation: .active, remainingSessions: [0, nil]))
    #expect(!AppDelegate.shouldDeferRestart(presentation: .active, remainingSessions: [0]))
    #expect(!AppDelegate.shouldDeferRestart(presentation: .active, remainingSessions: []))
    for state: PowerPresentation? in [
        nil, .inactive, .suspended, .recovering, .restoring, .attention, .unknown,
    ] {
        #expect(!AppDelegate.shouldDeferRestart(presentation: state, remainingSessions: [120]))
    }
}

@Test func durationPresetsMatchTheCompactMenu() {
    #expect(SessionEnd.presetMinutes == [15, 30, 45, 60, 120, 240, 480, 720, 1440])
}

@Test func multipleProcessIDsAreValidatedAndDeduplicated() throws {
    #expect(try ProcessSelection.parse("697;660;9931") == [697, 660, 9931])
    #expect(try ProcessSelection.parse(" 697 ; 660 ;697 ") == [697, 660])
    for invalid in ["", "0", "-2", "+12", "12;", ";12", "12;;34", "1,2", "12;word", "2147483648"] {
        #expect(throws: WorkError.invalidProcess) { try ProcessSelection.parse(invalid) }
    }
    #expect(throws: WorkError.invalidProcess) {
        try ProcessSelection.parse(Array(repeating: "12", count: 129).joined(separator: ";"))
    }
}

@Test @MainActor func processMonitoringWaitsUntilEverySelectedProcessHasEnded() throws {
    let first = Process()
    let second = Process()
    defer {
        for child in [first, second] where child.isRunning {
            child.terminate()
            child.waitUntilExit()
        }
    }
    for child in [first, second] {
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["60"]
        try child.run()
    }
    var followed = try [first, second].map { try ProcessIdentity(pid: $0.processIdentifier) }
    #if DEBUG
        let model = AppModel.preview("active", watchedProcesses: followed)
        #expect(model.taskCount == 2 && model.showsTaskCount)
        #expect(!model.pollWatchedProcesses())
        #expect(model.watchedProcesses?.map(\.pid) == followed.map(\.pid))
    #endif
    #expect(!ProcessSelection.allFinished(&followed))
    first.terminate()
    first.waitUntilExit()
    #expect(!ProcessSelection.allFinished(&followed) && followed.count == 1)
    #if DEBUG
        #expect(!model.pollWatchedProcesses())
        #expect(model.taskCount == 1)
        #expect(model.watchedProcesses?.map(\.pid) == [second.processIdentifier])
    #endif
    second.terminate()
    second.waitUntilExit()
    #expect(ProcessSelection.allFinished(&followed))
    #if DEBUG
        #expect(model.pollWatchedProcesses())
        #expect(model.taskCount == 0 && model.watchedProcesses?.isEmpty == true)
    #endif
}

@Test @MainActor func uninstallErasesAllPreferencesAndOnlyItsOwnCacheAndWindowState() throws {
    let domain = "Awake.test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: domain))
    let library = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: library)
    }
    defaults.set("saved", forKey: "userPolicy")
    defaults.set(true, forKey: "anotherPreference")
    for path in [
        "Caches/\(domain)", "Saved Application State/\(domain).savedState", "Caches/other-app",
    ] {
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent(path), withIntermediateDirectories: true)
    }
    try AppModel.erasePreferences(defaults, domain: domain, library: library)
    #expect(defaults.persistentDomain(forName: domain)?.isEmpty != false)
    #expect(
        !FileManager.default.fileExists(
            atPath: library.appendingPathComponent("Caches/\(domain)").path))
    #expect(
        !FileManager.default.fileExists(
            atPath: library.appendingPathComponent("Saved Application State/\(domain).savedState")
                .path))
    #expect(
        FileManager.default.fileExists(
            atPath: library.appendingPathComponent("Caches/other-app").path))
    try AppModel.erasePreferences(defaults, domain: domain, library: library)
}

private func status(
    _ phase: SleepPhase, observed: SleepObservation, owned: Bool,
    fault: SleepFault? = nil
) throws -> ServiceStatus {
    ServiceStatus(
        policy: try UserPolicy(), power: PowerSnapshot(source: .unknown, battery: .unavailable),
        sleep: SleepReport(phase: phase, observed: observed, ownsGlobalHold: owned, fault: fault),
        sessions: [], sampledAt: Date())
}

@Test func unverifiedOrForeignStateNeverLooksInactiveOrSuccessfullyActive() throws {
    #expect(PowerPresentation(try status(.inactive, observed: .unknown, owned: false)) == .unknown)
    #expect(
        PowerPresentation(try status(.inactive, observed: .disabled, owned: false)) == .attention)
    #expect(PowerPresentation(try status(.active, observed: .disabled, owned: false)) == .attention)
    #expect(
        PowerPresentation(
            try status(.restoring, observed: .disabled, owned: true, fault: .restorationFailed))
            == .restoring)
    #expect(PowerPresentation(try status(.active, observed: .disabled, owned: true)) == .active)
    #expect(PowerPresentation(try status(.inactive, observed: .allowed, owned: false)) == .inactive)
}

@Test func preferenceDraftNeverPersistsAutomationOrAcceptsInvalidLimits() throws {
    var draft = PolicyDraft(
        try UserPolicy(
            mode: .external, batteryFloor: 35,
            maximumDuration: 7_200, allowsAutomation: true))
    #expect(try draft.policy(allowsAutomation: false).allowsAutomation == false)
    #expect(try draft.policy(allowsAutomation: false).maximumDuration == 7_200)
    draft.maximumMinutes = .infinity
    #expect(throws: PolicyError.invalidDuration) { try draft.policy(allowsAutomation: false) }
    draft.limitsDuration = false
    draft.batteryFloor = 80
    #expect(try draft.policy(allowsAutomation: false).batteryFloor == 80)
    draft.batteryFloor = 81
    #expect(throws: PolicyError.invalidBatteryFloor) { try draft.policy(allowsAutomation: false) }
}

@Test @MainActor func batteryInputRejectsNonIntegersAndNonfiniteValues() {
    for value in 0...80 {
        #expect(SettingsView.batteryFloor(from: String(value)) == value)
    }
    for value in ["81", "100", String(repeating: "9", count: 500)] {
        #expect(SettingsView.batteryFloor(from: value) == 80)
    }
    #expect(SettingsView.batteryFloor(from: "٢٠") == 20)
    #expect(SettingsView.batteryFloor(from: "８１") == 80)
    for value in ["", "-1", "20.5", "20,5", "20x", "NaN", "∞", "-∞", "1e100", "²", " 20 "] {
        #expect(SettingsView.batteryFloor(from: value) == nil)
    }
}

@Test @MainActor func batteryCutoffExplainsFailedStartsAndStopsAfterLaterPolling() throws {
    let now = try ClockSnapshot(continuous: 100, wall: Date())
    var registry = SessionRegistry(policy: try UserPolicy(batteryFloor: 30))
    let id = try registry.start(.init(), owner: UUID(), kind: .manual, now: now)
    let low = PowerSnapshot(source: .battery, battery: .available(percent: 25, isDischarging: true))
    _ = registry.evaluate(power: low, now: now)
    let cutoff = try #require(registry.batteryCutoff)
    let report = ServiceStatus(
        policy: registry.policy, power: low,
        sleep: .init(phase: .inactive, observed: .allowed, ownsGlobalHold: false, fault: nil),
        sessions: [], sampledAt: now.wall, batteryCutoff: cutoff)
    let started = AppModel()
    try started.accept(
        ServiceWire.decodeReply(
            ServiceWire.encode(
                ServiceReply(status: report, startedSession: id))))
    #expect(started.batteryNotice == "Battery at 25%. Charge above 30% to start.")
    try started.accept(ServiceReply(status: report))
    #expect(started.batteryNotice == "Battery at 25%. Charge above 30% to start.")
    let running = AppModel()
    try running.accept(ServiceReply(status: report))
    #expect(running.batteryNotice == "Session ended at 25% battery (limit: 30%).")
    let clear = ServiceStatus(
        policy: report.policy, power: report.power, sleep: report.sleep,
        sessions: [], sampledAt: now.wall)
    try running.accept(ServiceReply(status: clear))
    #expect(running.batteryNotice == nil)
}

#if DEBUG
    @Test @MainActor func powerControlsMatchHardwareAndSelectedSource() {
        let desktop = AppModel.preview("desktop")
        #expect(!desktop.showsPowerSource && !desktop.showsBatteryLimit)
        #expect(!desktop.showsSudoTouchID)
        let external = AppModel.preview("external")
        #expect(external.showsPowerSource && !external.showsBatteryLimit)
        external.draft.mode = .all
        #expect(external.showsBatteryLimit)
        let unreadable = AppModel.preview("battery-unknown")
        #expect(unreadable.showsPowerSource && unreadable.showsBatteryLimit)
    }

    @Test @MainActor func setupHidesPowerControlsUntilTheHelperIsAvailable() {
        #expect(!AppModel().showsPowerControls)
        for state in ["setup", "removed"] {
            let model = AppModel.preview(state)
            #expect(!model.showsPowerControls && !model.canControl)
            #expect(!model.showsSudoTouchID)
            #expect(model.trustedBuild)
        }
        #expect(AppModel.preview("inactive").showsPowerControls)
        #expect(AppModel.preview("inactive").showsSudoTouchID)
    }

    @Test @MainActor func emptyTaskCountOnlyAppearsForProcessCompletion() {
        let model = AppModel.preview("inactive")
        #expect(model.taskCount == 0 && !model.showsTaskCount)
        model.stopChoice = .process
        #expect(model.showsTaskCount)
        model.stopChoice = .unlimited
        #expect(!model.showsTaskCount)
    }

    @Test @MainActor func lidPreferenceNeverStartsOrStopsASession() throws {
        let idle = AppModel.preview("inactive")
        let before = idle.status
        #expect(!idle.keepAwakeEnabled && !idle.draft.keepsAwakeWithLidClosed)
        idle.draft.keepsAwakeWithLidClosed = true
        #expect(!idle.keepAwakeEnabled && idle.status == before)
        #expect(idle.closedLidExplanation.contains("only while Awake is active"))
        let active = AppModel.preview("active")
        let sessions = active.status?.sessions
        active.draft.keepsAwakeWithLidClosed = false
        #expect(active.keepAwakeEnabled && active.status?.sessions == sessions)
        #expect(active.closedLidExplanation.contains("active for this session"))
        let draft = PolicyDraft(try UserPolicy(keepsAwakeWithLidClosed: true))
        #expect(try draft.policy(allowsAutomation: false).keepsAwakeWithLidClosed)
    }

    @Test @MainActor func startupNeverGrantsControlBeforeBuildVerification() async {
        let model = AppModel()
        #expect(model.buildTrust == .checking)
        #expect(!model.trustedBuild && !model.canControl)
        await model.prepareForLaunch()
        #expect(model.buildTrust == .untrusted)
        #expect(!model.trustedBuild && !model.canControl)
        #expect(model.status == nil && !model.removalComplete)
    }

    @Test @MainActor func helperApprovalEnablesLoginOnceWithoutOverridingLaterChoices() throws {
        let suite = "Awake-login-test-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(true, forKey: "enableLoginAfterHelperApproval")
        let model = AppModel(preferences: preferences)
        var registrations = 0
        for status: SMAppService.Status in [.notRegistered, .requiresApproval, .notFound] {
            try model.completeLoginSetup(helperStatus: status) { registrations += 1 }
        }
        #expect(registrations == 0)
        let reopened = AppModel(preferences: preferences)
        try reopened.completeLoginSetup(helperStatus: .enabled) { registrations += 1 }
        try reopened.completeLoginSetup(helperStatus: .enabled) { registrations += 1 }
        #expect(registrations == 1)
        #expect(reopened.status == nil)
        preferences.set(true, forKey: "enableLoginAfterHelperApproval")
        #expect(throws: CocoaError.self) {
            try reopened.completeLoginSetup(helperStatus: .enabled) {
                throw CocoaError(.userCancelled)
            }
        }
        try reopened.completeLoginSetup(helperStatus: .enabled) { registrations += 1 }
        #expect(registrations == 1)
    }

    @Test @MainActor func helperApprovalEnablesUpdatesOnlyWhenNoChoiceWasSaved() throws {
        let suite = "Awake-updates-test-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = AppModel(preferences: preferences)
        model.completeUpdateSetup(helperStatus: .requiresApproval)
        #expect(!model.automaticUpdates)
        model.completeUpdateSetup(helperStatus: .enabled)
        #expect(model.automaticUpdates)
        model.automaticUpdates = false
        let reopened = AppModel(preferences: preferences)
        reopened.completeUpdateSetup(helperStatus: .enabled)
        #expect(!reopened.automaticUpdates)
    }

    @Test @MainActor func updateHelperRecoveryRetriesFailuresAndAcceptsPendingApproval()
        async throws
    {
        let suite = "Awake-update-recovery-test-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let helper = MockUpdateHelper(status: .notRegistered)
        helper.registrationFails = true
        preferences.set(true, forKey: AppModel.updateHelperRecoveryKey)
        let model = AppModel(
            preferences: preferences, helper: helper, buildTrust: .trusted)
        await model.restoreUpdateHelperIfNeeded()
        #expect(helper.registrations == 1)
        #expect(preferences.bool(forKey: AppModel.updateHelperRecoveryKey))
        #expect(model.message != nil)
        helper.registrationFails = false
        await model.restoreUpdateHelperIfNeeded()
        #expect(helper.registrations == 2)
        #expect(helper.status == .enabled)
        #expect(preferences.object(forKey: AppModel.updateHelperRecoveryKey) == nil)

        let pending = MockUpdateHelper(status: .requiresApproval)
        preferences.set(true, forKey: AppModel.updateHelperRecoveryKey)
        let reopened = AppModel(
            preferences: preferences, helper: pending, buildTrust: .trusted)
        await reopened.restoreUpdateHelperIfNeeded()
        #expect(pending.registrations == 0)
        #expect(reopened.helperStatus == .requiresApproval)
        #expect(preferences.object(forKey: AppModel.updateHelperRecoveryKey) == nil)
    }

    @Test @MainActor func sudoTouchIDPermissionFeedbackPreservesSessionState() throws {
        let model = AppModel.preview("active")
        let before = model.status
        let reply = try ServiceWire.decodeReply(
            ServiceWire.encode(ServiceReply(error: .sudoTouchIDPermissionDenied)))
        model.reportOperationError(try #require(reply.error))
        #expect(model.sudoTouchIDNeedsPermission)
        #expect(
            model.sudoTouchIDMessage
                == "In Full Disk Access, enable the entry ending in “Awake.sudo.helper”, then try again."
        )
        #expect(model.message == nil)
        #expect(model.status == before && !model.busy && model.connectionError == nil)
        model.openPrivacySettings()
        model.reportOperationError(ServiceError.sudoTouchIDFailed)
        #expect(!model.sudoTouchIDNeedsPermission)
        #expect(model.sudoTouchIDMessage?.contains("sudo configuration") == true)
        #expect(model.message == nil)
        model.reportOperationError(ServiceError.unavailable)
        #expect(!model.sudoTouchIDNeedsPermission)
        #expect(model.message != nil && model.sudoTouchIDMessage != nil)
        #expect(model.status == before && model.connectionError == nil)
    }

    @Test @MainActor func previewCannotControlPowerOrAuthorizeAutomation() async {
        let model = AppModel.preview("active")
        let before = model.status
        #expect(model.isPreview && !model.canControl)
        await model.prepareForLaunch()
        #expect(model.buildTrust == .untrusted)
        await model.stopAll()
        await model.setKeepAwake(false)
        await model.setKeepAwake(true)
        await model.setAutomation(false)
        await model.setSudoTouchID(true)
        await model.setSudoTouchID(false)
        await model.registerHelper()
        await model.setLaunchAtLogin(true)
        model.draft.batteryFloor = 42
        model.policyEdited()
        _ = await model.checkForUpdates()
        await model.installUpdate()
        #expect(model.availableUpdate == nil && !model.updating)
        #expect(await model.removeIntegration() == false)
        #expect(!model.removalComplete)
        #expect(model.status == before)
        #expect(model.loginStatus == .notRegistered)
    }

    @Test @MainActor func detectedAutomaticUpdateStartsImmediatelyAndCooldownHidesButton() throws {
        let update = GitHubUpdate.Release(
            version: "1.0.3",
            url: URL(
                string:
                    "https://github.com/oviron/Awake/releases/download/v1.0.3/Awake-1.0.3-universal.zip"
            )!, digest: String(repeating: "a", count: 64),
            sourceRevision: String(repeating: "b", count: 40))
        let automatic = AppModel.preview("inactive")
        automatic.automaticUpdates = true
        #expect(automatic.recordDetectedUpdate(update, manual: false))
        #expect(automatic.availableUpdate == update)

        let suite = "Awake-update-presentation-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        var schedule = UpdateSchedule()
        let beganDownload = schedule.beginDownload()
        #expect(beganDownload)
        preferences.set(try JSONEncoder().encode(schedule), forKey: "updateSchedule")
        let manual = AppModel(preferences: preferences, helper: nil, buildTrust: .trusted)
        #expect(!manual.recordDetectedUpdate(update, manual: true))
        #expect(!manual.showsUpdateButton)
        #expect(!manual.canInstallAvailableUpdate(manual: true))
    }

    @Test @MainActor func settingsFitTheMenuBeforeAndAfterAutomaticUpdatesChange() {
        let model = AppModel.preview("inactive")
        model.automaticUpdates = false
        func width() -> CGFloat {
            NSHostingView(rootView: SettingsView(model: model)).fittingSize.width
        }
        #expect(width() <= 300)
        model.recordDetectedUpdate(
            GitHubUpdate.Release(
                version: "1.0.4", url: URL(string: "https://example.com/Awake.zip")!,
                digest: String(repeating: "a", count: 64),
                sourceRevision: String(repeating: "b", count: 40)), manual: true)
        #expect(model.showsUpdateButton)
        #expect(width() <= 300)
        model.automaticUpdates = true
        #expect(width() <= 300)
    }

    @Test @MainActor func manualUpdateCooldownExplainsWhenCheckingResumes() async throws {
        let suite = "Awake-update-cooldown-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        var schedule = UpdateSchedule()
        let beganCheck = schedule.beginCheck()
        #expect(beganCheck)
        preferences.set(try JSONEncoder().encode(schedule), forKey: "updateSchedule")
        let model = AppModel(preferences: preferences, helper: nil, buildTrust: .trusted)
        let update = await model.checkForUpdates(manual: true)
        #expect(update == nil)
        #expect(model.updateMessage?.hasPrefix("The next update check is available after ") == true)
    }
#endif

@Test @MainActor func defaultDurationIsRememberedWithoutAutoStarting() throws {
    let domain = "Awake.duration-test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    let first = AppModel(preferences: defaults)
    #expect(first.stopChoice == .unlimited)
    first.stopChoice = .preset(60)
    let reopened = AppModel(preferences: defaults)
    #expect(reopened.stopChoice == .preset(60) && !reopened.keepAwakeEnabled)
    reopened.stopChoice = .unlimited
    #expect(AppModel(preferences: defaults).stopChoice == .unlimited)
}

@Test @MainActor func idleAssertionAloneIsPresentedAsActiveWithNormalLidBehavior() throws {
    let model = AppModel()
    let report = SleepReport(
        phase: .active, observed: .allowed, ownsGlobalHold: false, fault: nil,
        holdsIdleAssertion: true)
    try model.accept(
        ServiceReply(
            status: ServiceStatus(
                policy: try UserPolicy(), power: .init(source: .external, battery: .notPresent),
                sleep: report, sessions: [], sampledAt: Date())))
    #expect(model.presentation == .active && model.keepAwakeEnabled)
    #expect(model.closedLidExplanation.contains("Closing the lid works normally"))
}

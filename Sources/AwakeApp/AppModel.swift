import AppKit
import AwakeCore
import AwakeSystem
import Foundation
import LocalAuthentication
import Observation
import ServiceManagement

@MainActor @Observable final class AppModel {
    enum BuildTrust { case checking, trusted, untrusted }
    static let updateHelperRecoveryKey = "restoreHelperAfterUpdate"

    private(set) var status: ServiceStatus?
    private(set) var busy = false
    private(set) var sudoTouchIDBusy = false
    private(set) var connectionError: String?
    private(set) var helperStatus: SMAppService.Status = .notRegistered
    private(set) var loginStatus: SMAppService.Status = .notRegistered
    private(set) var buildTrust = BuildTrust.checking
    var trustedBuild: Bool { buildTrust == .trusted }
    private(set) var removalComplete = false
    private(set) var removalStep: String?
    private(set) var availableUpdate: GitHubUpdate.Release?
    private(set) var updating = false
    private(set) var updateMessage: String?
    private(set) var hasTouchID = false
    var automaticUpdates: Bool {
        didSet {
            guard !isPreview else { return }
            preferences.set(automaticUpdates, forKey: "automaticUpdates")
            if automaticUpdates { requestAutomaticUpdateIfReady() }
        }
    }
    var message: String?
    private(set) var batteryNotice: String?
    private(set) var thermalNotice: String?
    private(set) var sudoTouchIDError: ServiceError?
    var pendingSudoTouchID: Bool?
    var draft = PolicyDraft()
    var stopChoice: StopChoice = .preset(60)
    var customDuration: Double = 90
    var durationUnit: DurationUnit = .minutes
    var stopDate = Date().addingTimeInterval(3_600)
    var processID = "" {
        didSet {
            let ids = Set(
                processID.split(separator: ";").compactMap {
                    Int32($0.trimmingCharacters(in: .whitespacesAndNewlines))
                })
            selectedProcesses = selectedProcesses.filter { ids.contains($0.key) }
        }
    }
    private(set) var processes: [RunningProcess] = []
    var processSearch = ""
    private(set) var processListError: String?
    private var selectedProcesses: [Int32: ProcessIdentity] = [:]
    private let preferences: UserDefaults
    private let helper: (any HelperInstallation)?
    private var client: ServiceClient?
    private var restoredAutomationPreference = false
    private var monitoring: Task<Void, Never>?
    private(set) var watchedProcesses: [ProcessIdentity]?
    private var policyApplication: Task<Void, Never>?
    private var updateMonitoring: Task<Void, Never>?
    private var updateInstallation: Task<Void, Never>?
    private var checkingUpdates = false
    private var updateSchedule: UpdateSchedule {
        didSet {
            guard !isPreview, let data = try? JSONEncoder().encode(updateSchedule) else { return }
            preferences.set(data, forKey: "updateSchedule")
        }
    }
    private var statusReceivedAt = ContinuousClock.now
    private var refreshing = false
    private var revision = 0
    private var quitting = false
    private var baseline = PolicyDraft()
    private(set) var isPreview = false

    init(
        preferences: UserDefaults = .standard,
        helper: (any HelperInstallation)? =
            (Bundle.main.object(
                forInfoDictionaryKey: "AwakeHelperInstallation") as? String)
            .flatMap(HelperInstallationKind.init(rawValue:))?.service,
        buildTrust: BuildTrust = .checking
    ) {
        self.preferences = preferences
        self.helper = helper
        self.buildTrust = buildTrust
        let authentication = LAContext()
        hasTouchID =
            authentication.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
            && authentication.biometryType == .touchID
        updateSchedule =
            preferences.data(forKey: "updateSchedule").flatMap {
                try? JSONDecoder().decode(UpdateSchedule.self, from: $0)
            } ?? UpdateSchedule()
        automaticUpdates = preferences.bool(forKey: "automaticUpdates")
        if let data = preferences.data(forKey: "userPolicy"),
            let policy = try? JSONDecoder().decode(UserPolicy.self, from: data)
        {
            draft = PolicyDraft(policy)
            baseline = draft
        }
    }

    func prepareForLaunch() async {
        guard !isPreview, buildTrust == .checking else { return }
        guard helper != nil else {
            buildTrust = .untrusted
            return
        }
        let identity = try? await SignedIdentity.current(
            expectedIdentifier: AwakeIdentity.application)
        buildTrust = identity == nil ? .untrusted : .trusted
    }

    func restoreUpdateHelperIfNeeded() async {
        guard preferences.bool(forKey: Self.updateHelperRecoveryKey), trustedBuild, !isPreview,
            let helper
        else { return }
        do {
            if [.notRegistered, .notFound].contains(helper.status) {
                try await helper.register()
            }
            helperStatus = helper.status
            guard helperStatus == .enabled || helperStatus == .requiresApproval else {
                throw ServiceError.unavailable
            }
            clearUpdateHelperRecovery()
        } catch {
            helperStatus = helper.status
            message =
                "The update finished, but the helper could not be restored. Enable it again to continue."
        }
    }

    private func clearUpdateHelperRecovery() {
        preferences.removeObject(forKey: Self.updateHelperRecoveryKey)
        _ = preferences.synchronize()
    }

    var canControl: Bool {
        trustedBuild && !isPreview && helperStatus == .enabled && client != nil
            && connectionError == nil && !removalInProgress && !removalComplete
    }
    var showsPowerControls: Bool {
        canControl || (isPreview && helperStatus == .enabled && !removalComplete)
    }
    var showsPowerSource: Bool { showsPowerControls && status?.power.battery != .notPresent }
    var showsBatteryLimit: Bool { showsPowerSource && draft.mode != .external }
    var showsSudoTouchID: Bool {
        showsPowerControls
            && (hasTouchID || status?.sudoTouchID == .enabled || status?.sudoTouchID == .external)
    }
    var removalInProgress: Bool { status.map { $0.removal != .none } ?? false }
    var ownSession: SessionSummary? {
        status?.sessions.first(where: { $0.belongsToClient && $0.kind == .manual })
    }
    var closedLidAwakeEnabled: Bool {
        status.map { !$0.sessions.isEmpty || $0.sleep.ownsGlobalHold } ?? false
    }
    var canToggleClosedLidAwake: Bool {
        canControl && !busy && !updating && !quitting
            && (closedLidAwakeEnabled
                || (status?.sleep.fault == nil && status?.sleep.observed == .allowed
                    && status?.power.thermal.allowsAwake == true))
    }
    var closedLidExplanation: String {
        guard connectionError == nil else {
            return "State unavailable. Reconnect before changing closed-lid sleep."
        }
        guard let status else {
            return "Enable Awake below to control closed-lid sleep."
        }
        if status.sleep.ownsGlobalHold && status.sleep.phase != .active {
            return "Protection is not confirmed. Turn off to restore normal sleep."
        }
        if status.sleep.observed == .unknown {
            return "State unavailable. Closed-lid protection has not been confirmed."
        }
        if status.sleep.fault != nil {
            return "Resolve the power issue above before enabling protection."
        }
        if !status.sessions.isEmpty {
            guard presentation == .active else {
                return
                    "Protection is waiting for power. Closing the lid can still put this Mac to sleep."
            }
            let hasStopCondition =
                status.policy.maximumDuration != nil
                || status.sessions.contains { $0.end != .unlimited }
                || watchedProcesses != nil
            return hasStopCondition
                ? "Active for the current session, until its stop condition or you turn this off."
                : "On until you turn it off. Battery and temperature limits still apply."
        }
        return "Turn on now, without a timer. Turning off ends all Awake sessions."
    }
    var taskCount: Int {
        (status?.sessions.filter { $0.kind != .manual }.count ?? 0)
            + (watchedProcesses?.count ?? 0)
    }
    var showsTaskCount: Bool { taskCount > 0 || stopChoice == .process }
    var presentation: PowerPresentation? {
        connectionError == nil ? status.map(PowerPresentation.init) : nil
    }
    var draftChanged: Bool { draft != baseline }
    private var readyToUpdate: Bool {
        guard connectionError == nil, !removalComplete else { return false }
        guard let status else { return helperStatus == .notRegistered }
        return status.sessions.isEmpty && !status.sleep.ownsGlobalHold
            && status.sleep.observed == .allowed
            && (status.sleep.phase == .inactive || status.sleep.phase == .blocked)
    }
    func canInstallAvailableUpdate(manual: Bool = false) -> Bool {
        !busy && !sudoTouchIDBusy && !updating && readyToUpdate
            && updateSchedule.canBeginDownload(manual: manual)
    }
    var showsUpdateButton: Bool {
        availableUpdate != nil && !automaticUpdates && updateSchedule.canBeginDownload()
    }
    func updateInstallBlockMessage(manual: Bool = false) -> String {
        !updateSchedule.canBeginDownload(manual: manual)
            ? "Update postponed. Please try again later."
            : "Stop current sessions to install the update."
    }

    func remainingSeconds(_ session: SessionSummary) -> Double? {
        guard let remaining = session.remainingSeconds else { return nil }
        let elapsed = statusReceivedAt.duration(to: .now).components
        return max(
            0, ceil(remaining - Double(elapsed.seconds) - Double(elapsed.attoseconds) / 1e18))
    }

    func refreshProcesses() {
        do {
            processes = try RunningProcess.snapshot()
            processListError = nil
        } catch {
            processes = []
            processListError = "Processes unavailable. Enter a PID or refresh."
        }
    }

    func selectProcess(_ process: RunningProcess) {
        var ids = (try? ProcessSelection.parse(processID)) ?? []
        if ids.contains(process.id) {
            ids.removeAll { $0 == process.id }
        } else {
            ids.append(process.id)
        }
        processID = ids.map(String.init).joined(separator: ";")
        if ids.contains(process.id) { selectedProcesses[process.id] = process.identity }
    }

    func isSelected(_ process: RunningProcess) -> Bool {
        ((try? ProcessSelection.parse(processID)) ?? []).contains(process.id)
    }

    func pollWatchedProcesses() -> Bool {
        guard var followed = watchedProcesses else { return false }
        let completed = ProcessSelection.allFinished(&followed)
        if followed != watchedProcesses { watchedProcesses = followed }
        return completed
    }

    func beginMonitoring() {
        guard monitoring == nil, !isPreview, !quitting else { return }
        if trustedBuild {
            updateMonitoring = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    _ = await self?.checkForUpdates()
                    let delay = max(
                        60,
                        self?.updateSchedule.nextCheck.timeIntervalSinceNow
                            ?? UpdateSchedule.interval)
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                }
            }
        }
        monitoring = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                if !quitting {
                    if pollWatchedProcesses(), ownSession != nil, !busy {
                        await stopManual()
                    }
                    if tick % 5 == 0 { await refresh() }
                    requestAutomaticUpdateIfReady()
                }
                tick &+= 1
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    func checkForUpdates(manual: Bool = false) async -> Bool? {
        if manual { updateMessage = nil }
        guard trustedBuild, !isPreview, !quitting, !updating else { return nil }
        guard !checkingUpdates else {
            if manual { updateMessage = "An update check is already in progress." }
            return nil
        }
        guard updateSchedule.beginCheck(manual: manual) else {
            if manual, let next = updateSchedule.nextManualCheck() {
                updateMessage =
                    "The next update check is available after \(next.formatted(date: .omitted, time: .shortened))."
            }
            return nil
        }
        checkingUpdates = true
        defer { checkingUpdates = false }
        do {
            let update = try await GitHubUpdate.latest(
                currentVersion: AwakeIdentity.version)
            recordDetectedUpdate(update, manual: manual)
            return update != nil
        } catch let error as UpdateError {
            if case .rateLimited(let until) = error {
                updateSchedule.failed(download: false, retryAfter: until)
            } else {
                updateSchedule.failed(download: false)
            }
            if manual { updateMessage = error.localizedDescription }
        } catch {
            updateSchedule.failed(download: false)
            if manual {
                updateMessage = "Could not reach GitHub. Check your connection and try again."
            }
        }
        return nil
    }

    @discardableResult
    func recordDetectedUpdate(_ update: GitHubUpdate.Release?, manual: Bool) -> Bool {
        availableUpdate = update
        updateSchedule.checked()
        return !manual && requestAutomaticUpdateIfReady()
    }

    @discardableResult
    func requestAutomaticUpdateIfReady() -> Bool {
        guard automaticUpdates, availableUpdate != nil, canInstallAvailableUpdate() else {
            return false
        }
        return requestUpdate()
    }

    func installUpdate(manual: Bool = false) async {
        guard trustedBuild, !isPreview, !quitting, !updating, !busy, !sudoTouchIDBusy,
            let availableUpdate
        else { return }
        guard readyToUpdate else {
            updateMessage = "Stop the current sessions before updating."
            return
        }
        guard updateSchedule.beginDownload(manual: manual) else {
            updateMessage = "Update postponed. Please try again later."
            return
        }
        updating = true
        updateMessage = "Downloading update…"
        var staged: GitHubUpdate.Staged?
        var launched = false
        defer {
            updating = false
            if !launched, let staged { try? FileManager.default.removeItem(at: staged.directory) }
        }
        do {
            let identity = try await SignedIdentity.current(
                expectedIdentifier: AwakeIdentity.application)
            let installedApp = try await GitHubUpdate.currentInstalledApplication(
                identity: identity)
            let candidate = try await GitHubUpdate.stage(
                availableUpdate, identity: identity, installedApp: installedApp)
            staged = candidate
            updateSchedule.downloaded()
            guard !quitting else { return }
            updateMessage = "Installing update…"
            if helper?.status == .enabled {
                preferences.set(true, forKey: Self.updateHelperRecoveryKey)
                guard preferences.synchronize() else { throw ServiceError.unavailable }
            }
            guard await removeIntegration(forUpdate: true) else {
                updateMessage = message
                await restoreUpdateHelperIfNeeded()
                return
            }
            try GitHubUpdate.launchInstaller(candidate)
            launched = true
            NSApp.terminate(nil)
        } catch {
            if case UpdateError.rateLimited(let until) = error {
                updateSchedule.failed(download: true, retryAfter: until)
                updateMessage = "Update postponed. Please try again later."
            } else {
                updateSchedule.failed(download: true)
                updateMessage = error.localizedDescription
            }
            if removalComplete {
                quitting = false
                removalComplete = false
                monitoring = nil
            }
            await restoreUpdateHelperIfNeeded()
            beginMonitoring()
        }
    }

    @discardableResult
    func requestUpdate(manual: Bool = false) -> Bool {
        guard updateInstallation == nil else { return false }
        updateInstallation = Task { [weak self] in
            await self?.installUpdate(manual: manual)
            self?.updateInstallation = nil
        }
        return true
    }

    func refresh() async {
        guard !isPreview, !busy, !refreshing, !quitting else { return }
        helperStatus = helper?.status ?? .notFound
        loginStatus = SMAppService.mainApp.status
        guard trustedBuild, helperStatus == .enabled else {
            if status != nil {
                connectionError =
                    "The helper is unavailable. The last power reading is no longer current."
            }
            await client?.close()
            client = nil
            watchedProcesses = nil
            return
        }
        completeUpdateSetup(helperStatus: helperStatus)
        do {
            try completeLoginSetup(helperStatus: helperStatus) {
                if loginStatus != .enabled && loginStatus != .requiresApproval {
                    try SMAppService.mainApp.register()
                }
            }
        } catch {
            message = "Launch at login could not be enabled. Check Login Items & Extensions."
        }
        loginStatus = SMAppService.mainApp.status
        refreshing = true
        defer { refreshing = false }
        let currentRevision = revision
        do {
            if client == nil {
                let connected = try await ServiceClient(role: .application)
                guard currentRevision == revision, !quitting else {
                    await connected.close()
                    return
                }
                client = connected
                restoredAutomationPreference = false
            }
            guard let client else { return }
            var reply = try await client.send(.status)
            guard currentRevision == revision, !busy, !quitting else { return }
            if let received = reply.status, received.sleep.fault != nil {
                preferences.set(false, forKey: "allowsAutomation")
            }
            if !restoredAutomationPreference {
                restoredAutomationPreference = true
                if let received = reply.status, preferences.bool(forKey: "allowsAutomation"),
                    let identity = try? await SignedIdentity.current(
                        expectedIdentifier: AwakeIdentity.application),
                    (try? await GitHubUpdate.currentInstalledApplication(identity: identity)) != nil
                {
                    let saved =
                        preferences.data(forKey: "userPolicy").flatMap {
                            try? JSONDecoder().decode(UserPolicy.self, from: $0)
                        } ?? received.policy
                    if let restored = try received.automationPolicyToRestore(saved) {
                        _ = try await client.send(.installCLI)
                        guard currentRevision == revision, !busy, !quitting else { return }
                        reply = try await client.send(.configure(restored))
                    }
                }
            }
            guard currentRevision == revision, !busy, !quitting else { return }
            if let received = reply.status, received.power.battery == .notPresent,
                received.policy.mode != .all, received.removal == .none
            {
                let policy = received.policy
                reply = try await client.send(
                    .configure(
                        try UserPolicy(
                            mode: .all,
                            batteryFloor: policy.batteryFloor,
                            maximumDuration: policy.maximumDuration,
                            allowsAutomation: policy.allowsAutomation)))
            }
            guard currentRevision == revision else { return }
            try accept(reply)
            connectionError = nil
        } catch {
            guard currentRevision == revision else { return }
            connectionError =
                "Connection unavailable. The last reading is no longer current. Reconnect to verify restoration."
            await client?.close()
            client = nil
            watchedProcesses = nil
        }
    }

    func accept(_ reply: ServiceReply) throws {
        guard let received = reply.status else { throw ServiceError.unavailable }
        if received.batteryCutoff != status?.batteryCutoff {
            batteryNotice = received.batteryCutoff.map { cutoff in
                reply.startedSession == cutoff.sessionID
                    ? "Battery at \(cutoff.percent)%. Charge above \(cutoff.limit)% to start."
                    : "Session ended at \(cutoff.percent)% battery (limit: \(cutoff.limit)%)."
            }
        }
        if !draftChanged { draft = PolicyDraft(received.policy) }
        if received.thermalCutoff != status?.thermalCutoff {
            thermalNotice = received.thermalCutoff.map { thermal in
                thermal == .unavailable
                    ? "Session ended because thermal monitoring is unavailable. Start a new session after monitoring returns."
                    : "Session ended to let your Mac cool down. It will not restart automatically."
            }
        }
        baseline = PolicyDraft(received.policy)
        status = received
        statusReceivedAt = .now
        if ownSession == nil { watchedProcesses = nil }
    }

    private func perform(_ operation: ServiceOperation) async -> Bool {
        guard canControl, !busy, let client else { return false }
        busy = true
        revision &+= 1
        message = nil
        defer { busy = false }
        do {
            try accept(await client.send(operation))
            return true
        } catch {
            reportOperationError(error)
            if let reply = try? await client.send(.status) {
                try? accept(reply)
            } else {
                connectionError = "Connection lost. Power restoration has not been confirmed."
                await client.close()
                self.client = nil
                watchedProcesses = nil
            }
            return false
        }
    }

    func reportOperationError(_ error: any Error) {
        switch error as? ServiceError {
        case .sudoTouchIDPermissionDenied, .sudoTouchIDFailed:
            sudoTouchIDError = error as? ServiceError
        case .thermalPressure:
            message = "Your Mac needs to cool down before a new session can start."
        default:
            message =
                "The request was not confirmed. Check the current state and your limits before retrying."
        }
    }

    var sudoTouchIDNeedsPermission: Bool { sudoTouchIDError == .sudoTouchIDPermissionDenied }

    var sudoTouchIDMessage: String? {
        switch sudoTouchIDError {
        case .sudoTouchIDPermissionDenied:
            "In Full Disk Access, enable the entry ending in “Awake.sudo.helper”, then try again."
        case .sudoTouchIDFailed:
            "Touch ID could not be changed. Check your sudo configuration before retrying."
        default: nil
        }
    }

    func startManual() async {
        do {
            let end: SessionEnd
            var followed: [ProcessIdentity] = []
            switch stopChoice {
            case .unlimited: end = .unlimited
            case .preset(let minutes): end = .after(seconds: Double(minutes) * 60)
            case .custom: end = .after(seconds: customDuration * durationUnit.seconds)
            case .date: end = .at(stopDate)
            case .process:
                followed = try ProcessSelection.parse(processID).map { pid in
                    let identity = try selectedProcesses[pid] ?? ProcessIdentity(pid: pid)
                    guard identity.isAlive else { throw WorkError.processUnavailable }
                    return identity
                }
                end = .unlimited
            }
            try end.validate(at: SystemClock.now())
            if await perform(.start(SessionRequest(end: end))), ownSession != nil {
                watchedProcesses = followed.isEmpty ? nil : followed
            }
        } catch {
            message =
                "Choose a valid duration, future date, or available PIDs separated by semicolons."
        }
    }

    func stopManual() async {
        guard let session = ownSession else { return }
        if await perform(.stop(session.id)) { watchedProcesses = nil }
    }

    func setClosedLidAwake(_ enabled: Bool) async {
        guard canToggleClosedLidAwake else { return }
        if enabled {
            guard !closedLidAwakeEnabled else { return }
            _ = await perform(.start(SessionRequest(end: .unlimited)))
        } else {
            guard closedLidAwakeEnabled else { return }
            guard await perform(.stopAll) else { return }
            if status?.sleep.ownsGlobalHold == true { await retryRestoration() }
        }
    }

    func stopAll() async { _ = await perform(.stopAll) }
    func rearm() async { _ = await perform(.rearm) }
    func retryRestoration() async { _ = await perform(.retryRestoration) }

    func applyPolicy() async {
        let submitted = draft
        do {
            let policy = try submitted.policy(
                allowsAutomation: status?.policy.allowsAutomation ?? false)
            if await perform(.configure(policy)) {
                let applied = PolicyDraft(status?.policy ?? policy)
                if draft == submitted { draft = applied }
                let saved = try applied.policy(allowsAutomation: false)
                preferences.set(try JSONEncoder().encode(saved), forKey: "userPolicy")
                message = nil
            }
        } catch { message = "Use a battery floor from 0 to 80% and a positive, finite duration." }
    }

    func policyEdited() {
        guard !isPreview, !quitting, draftChanged, policyApplication == nil else { return }
        policyApplication = Task { [weak self] in
            guard let self else { return }
            defer { policyApplication = nil }
            while draftChanged, !quitting {
                guard canControl else { return }
                if busy {
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                    continue
                }
                let submitted = draft
                await applyPolicy()
                if draft == submitted { return }
            }
        }
    }

    func setAutomation(_ enabled: Bool) async {
        guard let policy = status?.policy else { return }
        if enabled {
            guard
                let identity = try? await SignedIdentity.current(
                    expectedIdentifier: AwakeIdentity.application),
                (try? await GitHubUpdate.currentInstalledApplication(identity: identity)) != nil
            else {
                message = "Move Awake to Applications to enable the CLI."
                return
            }
            guard await perform(.installCLI) else {
                message =
                    "The awake command could not be installed. An existing command was left unchanged."
                return
            }
        }
        do {
            let updated = try UserPolicy(
                mode: policy.mode, batteryFloor: policy.batteryFloor,
                maximumDuration: policy.maximumDuration, allowsAutomation: enabled)
            if await perform(.configure(updated)) {
                preferences.set(enabled, forKey: "allowsAutomation")
            }
        } catch { message = "The automation limits could not be validated." }
    }

    func setSudoTouchID(_ enabled: Bool) async {
        guard canControl, !busy, !sudoTouchIDBusy, !updating, !quitting, !enabled || hasTouchID
        else { return }
        sudoTouchIDBusy = true
        sudoTouchIDError = nil
        var sudoClient: ServiceClient?
        do {
            try await SudoInstallation.ensureInstalled()
            guard !quitting else { throw CancellationError() }
            let client = try await ServiceClient(role: .application, sudo: true)
            sudoClient = client
            let reply = try await client.send(.setSudoTouchID(enabled))
            guard
                enabled
                    ? reply.sudoTouchID == .enabled || reply.sudoTouchID == .external
                    : reply.sudoTouchID == .disabled
            else { throw ServiceError.sudoTouchIDFailed }
        } catch {
            reportOperationError(
                error as? ServiceError == .sudoTouchIDPermissionDenied
                    ? ServiceError.sudoTouchIDPermissionDenied : ServiceError.sudoTouchIDFailed)
        }
        await sudoClient?.close()
        sudoTouchIDBusy = false
        await refresh()
    }

    func registerHelper() async {
        guard trustedBuild, !isPreview, !busy, !removalComplete, let helper else { return }
        busy = true
        do {
            try await helper.register()
            preferences.set(true, forKey: "enableLoginAfterHelperApproval")
        } catch {
            message =
                "The helper could not be enabled. Complete the macOS approval before retrying."
        }
        helperStatus = helper.status
        if helperStatus == .enabled || helperStatus == .requiresApproval {
            clearUpdateHelperRecovery()
        }
        busy = false
        await refresh()
    }

    func setLaunchAtLogin(_ enabled: Bool) async {
        guard trustedBuild, !isPreview, !busy, !removalComplete else { return }
        preferences.removeObject(forKey: "enableLoginAfterHelperApproval")
        busy = true
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try await SMAppService.mainApp.unregister()
            }
        } catch {
            message = "The login setting could not be changed. Check Login Items & Extensions."
        }
        loginStatus = SMAppService.mainApp.status
        busy = false
    }

    func completeLoginSetup(
        helperStatus: SMAppService.Status, register: () throws -> Void
    ) throws {
        guard helperStatus == .enabled,
            preferences.bool(forKey: "enableLoginAfterHelperApproval")
        else { return }
        preferences.removeObject(forKey: "enableLoginAfterHelperApproval")
        try register()
    }

    func completeUpdateSetup(helperStatus: SMAppService.Status) {
        guard helperStatus == .enabled,
            preferences.object(forKey: "automaticUpdates") == nil
        else { return }
        automaticUpdates = true
    }

    func openLoginSettings() {
        guard !isPreview else { return }
        SMAppService.openSystemSettingsLoginItems()
    }

    func openPrivacySettings() {
        guard !isPreview else { return }
        let workspace = NSWorkspace.shared
        if workspace.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        ) {
            return
        }
        if let settings = workspace.urlForApplication(
            withBundleIdentifier: "com.apple.systempreferences")
        {
            workspace.open(settings)
        }
    }

    func removeIntegration(forUpdate: Bool = false) async -> Bool {
        guard trustedBuild, !isPreview, !busy, !sudoTouchIDBusy, let helper else {
            message = "Removal requires a correctly signed Awake installation."
            return false
        }
        quitting = true
        busy = true
        removalStep = "Restoring normal sleep…"
        revision &+= 1
        defer {
            busy = false
            removalStep = nil
        }
        while refreshing { try? await Task.sleep(for: .milliseconds(50)) }
        do {
            helperStatus = helper.status
            let filesRemoved =
                try SecureOwnershipJournal.isStateDirectoryAbsent()
                && InstalledHelperFiles.areAbsent()
            if helperStatus == .enabled, !filesRemoved {
                if client == nil { client = try await ServiceClient(role: .application) }
                guard let client else { throw ServiceError.unavailable }
                try accept(await client.send(forUpdate ? .prepareUpdate : .prepareRemoval))
                guard let status, status.removal == .ready, status.canRemoveService,
                    try SecureOwnershipJournal.isStateDirectoryAbsent()
                else { throw ServiceError.restorationRequired }
            } else {
                guard try SecureOwnershipJournal.isStateDirectoryAbsent(),
                    try InstalledHelperFiles.areAbsent()
                else {
                    throw ServiceError.restorationRequired
                }
            }
            removalStep = "Removing the sudo component…"
            try await SudoInstallation.remove(forUpdate: forUpdate)
            if try !InstalledHelperFiles.areAbsent() {
                await client?.close()
                client = try await ServiceClient(role: .application)
                _ = try await client?.send(forUpdate ? .prepareUpdate : .prepareRemoval)
                _ = try await client?.send(.finishRemoval)
            }
            removalStep = "Removing the helper…"
            if !forUpdate, try InstalledCLI.isAppOwnedLinkPresent() {
                throw ServiceError.restorationRequired
            }
            if !helper.removalIsConfirmed { try await helper.unregister() }
            guard helper.removalIsConfirmed else { throw ServiceError.unavailable }
            await client?.close()
            client = nil
            removalStep = "Removing the login item…"
            let absentLoginStates: [SMAppService.Status] = [.notRegistered, .notFound]
            if !forUpdate, !absentLoginStates.contains(SMAppService.mainApp.status) {
                try await SMAppService.mainApp.unregister()
            }
            guard forUpdate || absentLoginStates.contains(SMAppService.mainApp.status),
                helper.removalIsConfirmed,
                try InstalledHelperFiles.areAbsent(kind: .sudo), !SudoInstallation.isRegistered
            else { throw ServiceError.restorationRequired }
            if !forUpdate {
                removalStep = "Removing preferences…"
                for provider in AgentSetup.providers {
                    try AgentSetup.configure(
                        provider, remove: true,
                        resources: Bundle.main.bundleURL.appendingPathComponent(
                            "Contents/Resources/awake-skill"))
                }
                let library = try FileManager.default.url(
                    for: .libraryDirectory, in: .userDomainMask,
                    appropriateFor: nil, create: false)
                try Self.erasePreferences(
                    preferences, domain: AwakeIdentity.application, library: library)
                guard
                    let sudoPreferences = UserDefaults(suiteName: AwakeIdentity.sudoApplication)
                else {
                    throw ServiceError.unavailable
                }
                try Self.erasePreferences(
                    sudoPreferences, domain: AwakeIdentity.sudoApplication, library: library)
            }
            helperStatus = helper.status
            loginStatus = SMAppService.mainApp.status
            status = nil
            watchedProcesses = nil
            connectionError = nil
            removalComplete = true
            monitoring?.cancel()
            updateMonitoring?.cancel()
            message =
                "Helper, login item and preferences removed."
            return true
        } catch {
            quitting = false
            if forUpdate, error as? ServiceError == .sessionRejected {
                if let reply = try? await client?.send(.status) {
                    try? accept(reply)
                } else {
                    connectionError = "Reconnect before retrying the update."
                }
                message = "Update postponed until current sessions end."
                return false
            }
            await client?.close()
            client = nil
            connectionError =
                "Removal was not confirmed. Reconnect before trusting the current state."
            helperStatus = helper.status
            loginStatus = SMAppService.mainApp.status
            message =
                "\(removalStep ?? "Uninstall") failed: \(error.localizedDescription) Keep Awake installed and retry."
            if error as? ServiceError == .sudoTouchIDPermissionDenied
                || error as? ServiceError == .sudoTouchIDFailed
            {
                reportOperationError(error)
            }
            return false
        }
    }

    static func erasePreferences(_ defaults: UserDefaults, domain: String, library: URL) throws {
        defaults.removePersistentDomain(forName: domain)
        guard defaults.synchronize() else { throw ServiceError.unavailable }
        for relative in ["Caches/\(domain)", "Saved Application State/\(domain).savedState"] {
            do {
                try FileManager.default.removeItem(at: library.appendingPathComponent(relative))
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
            }
        }
    }

    func prepareToQuit() async -> Bool {
        if isPreview { return true }
        quitting = true
        if !removalComplete { updateInstallation?.cancel() }
        while busy || refreshing || updating { try? await Task.sleep(for: .milliseconds(50)) }
        if ownSession != nil { await stopManual() }
        let unresolved =
            (status?.sleep.ownsGlobalHold == true)
            && (connectionError != nil || status?.sleep.fault != nil || ownSession != nil)
        if unresolved {
            quitting = false
            return false
        }
        monitoring?.cancel()
        updateMonitoring?.cancel()
        await client?.close()
        return true
    }
}

#if DEBUG
    extension AppModel {
        static func preview(_ state: String, watchedProcesses: [ProcessIdentity]? = nil) -> AppModel
        {
            let model = AppModel()
            model.isPreview = true
            model.buildTrust = .untrusted
            model.helperStatus = .enabled
            model.hasTouchID = state != "desktop"
            let active = state == "active" || state == "process"
            let waiting = state == "suspended"
            let failed = state == "restoration"
            let unknown = state == "unknown"
            let policy = try! UserPolicy(
                mode: waiting || state == "external" ? .external : .all,
                allowsAutomation: true)
            var registry = SessionRegistry(policy: policy)
            if state == "battery-low" {
                let now = try! SystemClock.now()
                try! registry.start(.init(), owner: UUID(), kind: .manual, now: now)
                _ = registry.evaluate(
                    power: .init(
                        source: .battery, battery: .available(percent: 18, isDischarging: true)),
                    now: now)
            }
            let session = SessionSummary(
                id: UUID(), kind: .manual, end: .after(seconds: 3_600),
                startedAt: Date().addingTimeInterval(-900), remainingSeconds: 2_700,
                suspension: waiting ? .powerSource : nil, belongsToClient: true)
            if state == "thermal" {
                let now = try! SystemClock.now()
                try! registry.start(.init(), owner: UUID(), kind: .manual, now: now)
                _ = registry.evaluate(
                    power: .init(source: .external, battery: .notPresent, thermal: .serious),
                    now: now)
            }
            let previewStatus = ServiceStatus(
                policy: policy,
                power: PowerSnapshot(
                    source: state == "desktop" ? .external : .battery,
                    battery: state == "desktop"
                        ? .notPresent
                        : (state == "battery-unknown"
                            ? .unavailable
                            : .available(
                                percent: state == "battery-low" ? 18 : 76, isDischarging: true)),
                    thermal: state == "thermal" ? .serious : .nominal),
                sleep: SleepReport(
                    phase: active ? .active : (failed ? .restoring : .inactive),
                    observed: unknown ? .unknown : (active || failed ? .disabled : .allowed),
                    ownsGlobalHold: active || failed, fault: failed ? .restorationFailed : nil),
                sessions: active || waiting ? [session] : [], sampledAt: Date(),
                sudoTouchID: state == "touch-id-external" ? .external : .disabled,
                batteryCutoff: registry.batteryCutoff,
                thermalCutoff: registry.thermalCutoff)
            try! model.accept(ServiceReply(status: previewStatus))
            if state == "touch-id-permission" {
                model.reportOperationError(ServiceError.sudoTouchIDPermissionDenied)
            }
            model.draft = PolicyDraft(policy)
            model.baseline = model.draft
            model.watchedProcesses = watchedProcesses
            if state == "process" {
                model.stopChoice = .process
                model.watchedProcesses =
                    watchedProcesses
                    ?? (try? RunningProcess.snapshot())?.prefix(3).map(\.identity) ?? []
            }
            if state == "setup" || state == "removed" {
                model.buildTrust = .trusted
                model.helperStatus = .notRegistered
                model.status = nil
                model.removalComplete = state == "removed"
            }
            return model
        }
    }
#endif

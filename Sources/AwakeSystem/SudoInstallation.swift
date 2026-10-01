import AppKit
import AwakeCore
import Foundation
import Security
import ServiceManagement

public enum SudoInstallation {
    private static let service: any HelperInstallation = SudoRegistration()
    public static var isRegistered: Bool { service.status == .enabled }

    @discardableResult
    public static func verifyBundle(_ bundle: URL, identity: SignedIdentity, build: String) throws
        -> [[String: Any]]
    {
        let app = try identity.verifyExecutable(
            at: bundle, identifier: AwakeIdentity.sudoApplication)
        let helper = try identity.verifyExecutable(
            at: bundle.appendingPathComponent(
                "Contents/Library/LaunchServices/" + AwakeIdentity.sudoHelper),
            identifier: AwakeIdentity.sudoHelper)
        guard let info = app[kSecCodeInfoPList as String] as? [String: Any],
            info["CFBundleIdentifier"] as? String == AwakeIdentity.sudoApplication,
            info["CFBundleExecutable"] as? String == "AwakeSudo",
            info["CFBundleVersion"] as? String == build,
            info["CFBundleIconFile"] as? String == "Awake",
            info["CFBundleDisplayName"] as? String == "Awake — Touch ID for sudo",
            info["AwakeHelperInstallation"] as? String == "blessed",
            info["LSMinimumSystemVersion"] as? String == "14.0",
            info["SMPrivilegedExecutables"] as? [String: String] == [
                AwakeIdentity.sudoHelper: try identity.requirement(
                    for: AwakeIdentity.sudoHelper)
            ],
            let embedded = helper[kSecCodeInfoPList as String] as? [String: Any],
            embedded["CFBundleIdentifier"] as? String == AwakeIdentity.sudoHelper,
            embedded["CFBundleVersion"] as? String == build,
            embedded["SMAuthorizedClients"] as? [String] == [
                try identity.requirement(for: AwakeIdentity.sudoApplication)
            ]
        else { throw HelperInstallationError.invalidBundle }
        return [app, helper]
    }

    public static func configure(register: Bool) async throws {
        if register { try await service.register() } else { try await service.unregister() }
    }

    @MainActor public static func openConfigurator(register: Bool) async throws {
        let identity = try await SignedIdentity.current(
            expectedIdentifier: AwakeIdentity.application)
        guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        else {
            throw HelperInstallationError.invalidBundle
        }
        let bundle = Bundle.main.bundleURL.appendingPathComponent(AwakeIdentity.sudoBundlePath)
        try verifyBundle(bundle, identity: identity, build: build)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = [register ? "--register" : "--unregister"]
        let app = try await NSWorkspace.shared.openApplication(
            at: bundle, configuration: configuration)
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while !app.isTerminated, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(250))
        }
        guard app.isTerminated, isRegistered == register,
            try register
                ? !installedHelperNeedsUpgrade(identity: identity, kind: .sudo, candidate: build)
                : InstalledHelperFiles.areAbsent(kind: .sudo)
        else { throw ServiceError.sudoTouchIDFailed }
    }

    @MainActor public static func ensureInstalled() async throws {
        if isRegistered {
            let identity = try await SignedIdentity.current(
                expectedIdentifier: AwakeIdentity.application)
            guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            else { throw HelperInstallationError.invalidBundle }
            if try !installedHelperNeedsUpgrade(identity: identity, kind: .sudo, candidate: build) {
                return
            }
        }
        try await openConfigurator(register: true)
    }

    @MainActor public static func remove(forUpdate: Bool) async throws {
        if !isRegistered {
            guard try InstalledHelperFiles.areAbsent(kind: .sudo) else {
                throw HelperInstallationError.unconfirmedRemoval
            }
            if try forUpdate || !SudoTouchID.requiresCleanup() { return }
            try await ensureInstalled()
        }
        if isRegistered { try await ensureInstalled() }
        if try !InstalledHelperFiles.areAbsent(kind: .sudo) {
            let client = try await ServiceClient(role: .application, sudo: true)
            do {
                _ = try await client.send(forUpdate ? .prepareUpdate : .prepareRemoval)
                _ = try await client.send(.finishRemoval)
                await client.close()
            } catch {
                await client.close()
                throw error
            }
        }
        guard try InstalledHelperFiles.areAbsent(kind: .sudo) else {
            throw HelperInstallationError.unconfirmedRemoval
        }
        try await openConfigurator(register: false)
    }
}

private struct SudoRegistration: HelperInstallation {
    @available(macOS, deprecated: 13.0, message: "Compatibility installation")
    var status: SMAppService.Status {
        SMJobCopyDictionary(kSMDomainSystemLaunchd, AwakeIdentity.sudoHelper as CFString)?
            .takeRetainedValue() != nil ? .enabled : .notRegistered
    }

    @available(macOS, deprecated: 13.0, message: "Compatibility installation")
    @concurrent func register() async throws { try configure(register: true) }

    @available(macOS, deprecated: 13.0, message: "Compatibility installation")
    @concurrent func unregister() async throws { try configure(register: false) }

    @available(macOS, deprecated: 13.0, message: "Compatibility installation")
    private func configure(register: Bool) throws {
        guard geteuid() != 0, ConsoleUser.identifier() == geteuid(),
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        else { throw ServiceError.unauthorized }
        let identity = try SignedIdentity(expectedIdentifier: AwakeIdentity.sudoApplication)
        try SudoInstallation.verifyBundle(Bundle.main.bundleURL, identity: identity, build: build)
        func requireFiles() throws {
            if register, status == .enabled {
                _ = try installedHelperNeedsUpgrade(
                    identity: identity, kind: .sudo, candidate: build)
                return
            }
            guard try InstalledHelperFiles.areAbsent(kind: .sudo) else {
                throw HelperInstallationError.conflictingInstallation
            }
            guard !register || status != .enabled else {
                throw HelperInstallationError.conflictingInstallation
            }
        }
        try requireFiles()
        if register, status == .enabled,
            try !installedHelperNeedsUpgrade(identity: identity, kind: .sudo, candidate: build)
        {
            return
        }
        try withAuthorization(
            right: register ? kSMRightBlessPrivilegedHelper : kSMRightModifySystemDaemons
        ) { authorization in
            try requireFiles()
            var error: Unmanaged<CFError>?
            let succeeded =
                register
                ? SMJobBless(
                    kSMDomainSystemLaunchd, AwakeIdentity.sudoHelper as CFString, authorization,
                    &error)
                : SMJobRemove(
                    kSMDomainSystemLaunchd, AwakeIdentity.sudoHelper as CFString, authorization,
                    true, &error)
            guard succeeded else {
                if let error { throw error.takeRetainedValue() }
                throw HelperInstallationError.invalidBundle
            }
        }
        guard (status == .enabled) == register,
            try register || InstalledHelperFiles.areAbsent(kind: .sudo)
        else { throw HelperInstallationError.unconfirmedRemoval }
    }
}

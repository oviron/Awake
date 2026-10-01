import AwakeCore
import Foundation
import Security
import ServiceManagement

public enum HelperInstallationKind: String, Sendable {
    case bundled, blessed

    public var service: any HelperInstallation {
        switch self {
        case .bundled: BundledHelperInstallation()
        case .blessed: BlessedHelperInstallation()
        }
    }

    func validateApplication() throws -> SignedIdentity {
        let identity = try SignedIdentity(expectedIdentifier: AwakeIdentity.application)
        guard geteuid() != 0, ConsoleUser.identifier() == geteuid(),
            Bundle.main.object(forInfoDictionaryKey: "AwakeHelperInstallation") as? String
                == rawValue
        else { throw HelperInstallationError.invalidBundle }
        return identity
    }
}

public enum HelperInstallationError: Error, Sendable {
    case invalidBundle, conflictingInstallation, unconfirmedRemoval
}

public protocol HelperInstallation: Sendable {
    var status: SMAppService.Status { get }
    func register() async throws
    func unregister() async throws
}

extension HelperInstallation {
    public var removalIsConfirmed: Bool {
        guard
            removalStatusesAreAbsent(
                service: status, systemJob: HelperInstallationKind.blessed.service.status)
        else { return false }
        return (try? requireRemovedFiles()) != nil
    }
}

func removalStatusesAreAbsent(
    service: SMAppService.Status, systemJob: SMAppService.Status
) -> Bool {
    [.notRegistered, .notFound].contains(service) && systemJob == .notRegistered
}

private func requireRemovedFiles() throws {
    var backend = MacSleepBackend()
    guard try SecureOwnershipJournal.isStateDirectoryAbsent(),
        try InstalledHelperFiles.areAbsent(), backend.observe() == .allowed
    else { throw HelperInstallationError.unconfirmedRemoval }
}

private struct BundledHelperInstallation: HelperInstallation {
    var status: SMAppService.Status {
        SMAppService.daemon(plistName: AwakeIdentity.daemonPlist).status
    }

    func register() async throws {
        try await Task.detached {
            let identity = try HelperInstallationKind.bundled.validateApplication()
            try identity.verifyExecutable(
                at: Bundle.main.bundleURL.appendingPathComponent(
                    "Contents/Library/HelperTools/AwakeHelper"),
                identifier: AwakeIdentity.helper)
            guard try InstalledHelperFiles.areAbsent() else {
                throw HelperInstallationError.conflictingInstallation
            }
            guard
                HelperInstallationKind.blessed.service.status != .enabled || self.status == .enabled
            else {
                throw HelperInstallationError.conflictingInstallation
            }
            try SMAppService.daemon(plistName: AwakeIdentity.daemonPlist).register()
        }.value
    }

    @concurrent func unregister() async throws {
        _ = try HelperInstallationKind.bundled.validateApplication()
        try requireRemovedFiles()
        let service = SMAppService.daemon(plistName: AwakeIdentity.daemonPlist)
        switch service.status {
        case .enabled, .requiresApproval: try await service.unregister()
        case .notRegistered, .notFound: break
        @unknown default: throw HelperInstallationError.unconfirmedRemoval
        }
        guard removalIsConfirmed else {
            throw HelperInstallationError.unconfirmedRemoval
        }
    }
}

private struct BlessedHelperInstallation: HelperInstallation {
    @available(macOS, deprecated: 13.0, message: "Compatibility channel without notarization")
    private func requireUnregisteredJob() throws {
        let modern = SMAppService.daemon(plistName: AwakeIdentity.daemonPlist).status
        guard modern != .enabled, modern != .requiresApproval, status != .enabled else {
            throw HelperInstallationError.conflictingInstallation
        }
    }

    @available(macOS, deprecated: 13.0, message: "Compatibility channel without notarization")
    var status: SMAppService.Status {
        if SMJobCopyDictionary(kSMDomainSystemLaunchd, AwakeIdentity.helper as CFString)?
            .takeRetainedValue() != nil
        {
            return .enabled
        }
        return (try? InstalledHelperFiles.areAbsent()) == true ? .notRegistered : .notFound
    }

    @available(macOS, deprecated: 13.0, message: "Compatibility channel without notarization")
    func register() async throws {
        try await Task.detached {
            let identity = try HelperInstallationKind.blessed.validateApplication()
            let helper = Bundle.main.bundleURL.appendingPathComponent(
                "Contents/Library/LaunchServices/" + AwakeIdentity.helper)
            let details = try identity.verifyExecutable(
                at: helper, identifier: AwakeIdentity.helper)
            let expected = try identity.requirement(for: AwakeIdentity.helper)
            guard
                Bundle.main.object(forInfoDictionaryKey: "SMPrivilegedExecutables")
                    as? [String: String] == [AwakeIdentity.helper: expected],
                let helperInfo = details[kSecCodeInfoPList as String] as? [String: Any],
                helperInfo["CFBundleIdentifier"] as? String == AwakeIdentity.helper,
                helperInfo["CFBundleVersion"] as? String
                    == Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                helperInfo["SMAuthorizedClients"] as? [String]
                    == [try identity.requirement(for: AwakeIdentity.application)]
            else { throw HelperInstallationError.invalidBundle }
            try requireUnregisteredJob()
            if try !SecureOwnershipJournal.directoryIsAbsent(
                at: InstalledHelperFiles.executablePath)
            {
                try identity.verifyExecutable(
                    at: URL(fileURLWithPath: InstalledHelperFiles.executablePath),
                    identifier: AwakeIdentity.helper)
            }
            try withAuthorization(right: kSMRightBlessPrivilegedHelper) { authorization in
                try requireUnregisteredJob()
                var error: Unmanaged<CFError>?
                guard
                    SMJobBless(
                        kSMDomainSystemLaunchd, AwakeIdentity.helper as CFString,
                        authorization, &error)
                else {
                    if let error { throw error.takeRetainedValue() }
                    throw CocoaError(.executableLoad)
                }
            }
            guard self.status == .enabled else { throw HelperInstallationError.invalidBundle }
        }.value
    }

    @available(macOS, deprecated: 13.0, message: "Compatibility channel without notarization")
    func unregister() async throws {
        try await Task.detached {
            _ = try HelperInstallationKind.blessed.validateApplication()
            try requireRemovedFiles()
            if removalIsConfirmed { return }
            try withAuthorization(right: kSMRightModifySystemDaemons) { authorization in
                try requireRemovedFiles()
                var error: Unmanaged<CFError>?
                guard
                    SMJobRemove(
                        kSMDomainSystemLaunchd, AwakeIdentity.helper as CFString,
                        authorization, true, &error)
                else {
                    if let error { throw error.takeRetainedValue() }
                    throw CocoaError(.executableLoad)
                }
            }
            guard removalIsConfirmed else { throw HelperInstallationError.unconfirmedRemoval }
        }.value
    }
}

func withAuthorization(right: String, operation: (AuthorizationRef) throws -> Void) throws {
    var reference: AuthorizationRef?
    let created = AuthorizationCreate(nil, nil, [], &reference)
    guard created == errAuthorizationSuccess, let reference else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(created))
    }
    defer { AuthorizationFree(reference, [.destroyRights]) }
    try right.withCString { name in
        var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
        try withUnsafeMutablePointer(to: &item) { itemPointer in
            var rights = AuthorizationRights(count: 1, items: itemPointer)
            let result = AuthorizationCopyRights(
                reference, &rights, nil, [.interactionAllowed, .extendRights, .preAuthorize], nil)
            guard result == errAuthorizationSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(result))
            }
        }
    }
    try operation(reference)
}

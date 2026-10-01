import CryptoKit
import Foundation
import Security
import SystemConfiguration

public enum AwakeIdentity {
    public static let version = "0.1.0"
    public static let application = "io.github.oviron.Awake"
    public static let commandLine = application + ".cli"
    public static let helper = application + ".helper"
    public static let controlService = application + ".control"
    public static let taskService = application + ".tasks"
    public static let daemonPlist = helper + ".plist"
    public static let sudoApplication = application + ".sudo"
    public static let sudoHelper = sudoApplication + ".helper"
    public static let sudoService = sudoApplication + ".control"
    public static let sudoBundlePath = "Contents/Helpers/Awake Sudo.app"
}

public enum InstalledHelperKind: Sendable {
    case power, sudo

    var identifier: String {
        self == .power ? AwakeIdentity.helper : AwakeIdentity.sudoHelper
    }
    var services: Set<String> {
        self == .power
            ? [AwakeIdentity.controlService, AwakeIdentity.taskService]
            : [AwakeIdentity.sudoService]
    }
    var executablePath: String { "/Library/PrivilegedHelperTools/" + identifier }
    var daemonPath: String { "/Library/LaunchDaemons/" + identifier + ".plist" }
}

public enum SignatureError: Error, Sendable {
    case untrustedIdentity, invalidRequirement
}

public struct SignedIdentity: Sendable {
    public let certificateFingerprint: String
    public let executableURL: URL

    @concurrent public static func current(expectedIdentifier: String) async throws -> Self {
        try Task.checkCancellation()
        let identity = try Self(expectedIdentifier: expectedIdentifier)
        try Task.checkCancellation()
        return identity
    }

    public init(expectedIdentifier: String) throws {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
            SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
            SecCodeCopySigningInformation(
                staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                &information) == errSecSuccess,
            let details = information as? [String: Any],
            let certificates = details[kSecCodeInfoCertificates as String] as? [SecCertificate],
            let leaf = certificates.first,
            let executable = details[kSecCodeInfoMainExecutable as String] as? URL,
            details[kSecCodeInfoIdentifier as String] as? String == expectedIdentifier
        else { throw SignatureError.untrustedIdentity }
        let fingerprint = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data)
            .map { String(format: "%02x", $0) }.joined()
        let requirement = try Self.requirement(
            identifier: expectedIdentifier, certificateFingerprint: fingerprint)
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess,
            let parsed, SecCodeCheckValidity(code, [], parsed) == errSecSuccess
        else { throw SignatureError.untrustedIdentity }
        certificateFingerprint = fingerprint
        executableURL = executable
    }

    public func requirement(for identifier: String) throws -> String {
        try Self.requirement(identifier: identifier, certificateFingerprint: certificateFingerprint)
    }

    @discardableResult
    func verifyExecutable(at url: URL, identifier: String) throws -> [String: Any] {
        let value = try requirement(for: identifier)
        var requirement: SecRequirement?
        var code: SecStaticCode?
        guard SecRequirementCreateWithString(value as CFString, [], &requirement) == errSecSuccess,
            let requirement,
            SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
            SecStaticCodeCheckValidity(
                code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
                requirement) == errSecSuccess
        else { throw SignatureError.untrustedIdentity }
        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
            let details = information as? [String: Any]
        else { throw SignatureError.untrustedIdentity }
        return details
    }

    static func requirement(identifier: String, certificateFingerprint: String) throws -> String {
        guard
            [
                AwakeIdentity.application, AwakeIdentity.commandLine,
                AwakeIdentity.helper, AwakeIdentity.sudoApplication,
                AwakeIdentity.sudoHelper,
            ]
            .contains(identifier), certificateFingerprint.utf8.count == 40,
            certificateFingerprint.utf8.allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            })
        else { throw SignatureError.invalidRequirement }
        let value =
            "identifier \"\(identifier)\" and certificate leaf = H\"\(certificateFingerprint)\""
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(value as CFString, [], &parsed) == errSecSuccess else {
            throw SignatureError.invalidRequirement
        }
        return value
    }
}

public enum ConsoleUser {
    public static func identifier() -> UInt32? {
        var user: uid_t = 0
        guard
            let name = SCDynamicStoreCopyConsoleUser(nil, &user, nil) as String?,
            name != "loginwindow", user != 0
        else { return nil }
        return user
    }
}

@objc public protocol AwakeXPC {
    func request(_ data: Data, reply: @escaping @Sendable (Data) -> Void)
}

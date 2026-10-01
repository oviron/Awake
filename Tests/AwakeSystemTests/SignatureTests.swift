import AwakeCore
import Foundation
import Security
import Testing

@testable import AwakeSystem

@Test func signingRequirementsPinIdentifierAndCertificateAndRejectInjection() throws {
    let fingerprint = "0123456789abcdef0123456789abcdef01234567"
    for identifier in [
        AwakeIdentity.application, AwakeIdentity.commandLine, AwakeIdentity.helper,
    ] {
        let requirement = try SignedIdentity.requirement(
            identifier: identifier, certificateFingerprint: fingerprint)
        var parsed: SecRequirement?
        #expect(
            SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess)
        #expect(requirement.contains("certificate leaf = H\"\(fingerprint)\""))
        #expect(requirement.contains(identifier))
        let connection = NSXPCConnection(
            machServiceName: "io.github.oviron.Awake.test-unregistered")
        connection.setCodeSigningRequirement(requirement)
        connection.invalidate()
    }
    _ = try SignedIdentity.requirement(
        identifier: AwakeIdentity.application,
        certificateFingerprint: fingerprint.uppercased())
    for invalid in [
        "", String(fingerprint.dropLast()), fingerprint + "0",
        fingerprint + "\n", "g" + String(fingerprint.dropFirst()),
        fingerprint + "\" or true",
    ] {
        #expect(throws: SignatureError.invalidRequirement) {
            try SignedIdentity.requirement(
                identifier: AwakeIdentity.application, certificateFingerprint: invalid)
        }
    }
    #expect(throws: SignatureError.invalidRequirement) {
        try SignedIdentity.requirement(
            identifier: "arbitrary.identifier", certificateFingerprint: fingerprint)
    }
}

@Test func testHostCannotImpersonateTheSignedProductionHelper() {
    #expect(throws: SignatureError.untrustedIdentity) {
        try SignedIdentity(expectedIdentifier: AwakeIdentity.helper)
    }
}

@Test(arguments: [ClientRole.application, .task]) @MainActor
func asynchronousClientSetupRejectsTheTestHost(role: ClientRole) async {
    await #expect(throws: SignatureError.untrustedIdentity) {
        try await ServiceClient(role: role)
    }
}

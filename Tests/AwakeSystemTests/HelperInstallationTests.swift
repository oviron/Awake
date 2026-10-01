import ServiceManagement
import Testing

@testable import AwakeSystem

@Test(arguments: [
    (SMAppService.Status.notRegistered, SMAppService.Status.notRegistered, true),
    (.notFound, .notRegistered, true),
    (.notFound, .enabled, false),
    (.notFound, .requiresApproval, false),
    (.notFound, .notFound, false),
    (.notRegistered, .enabled, false),
    (.notRegistered, .notFound, false),
    (.enabled, .notRegistered, false),
    (.requiresApproval, .notRegistered, false),
])
func missingServiceStatusCannotHideAnInstalledOrUnknownJob(
    service: SMAppService.Status, systemJob: SMAppService.Status, expected: Bool
) {
    #expect(removalStatusesAreAbsent(service: service, systemJob: systemJob) == expected)
}

@Test(arguments: [HelperInstallationKind.bundled, .blessed])
func anAdHocTestHostCannotRequestNativeInstallationOrRemoval(_ kind: HelperInstallationKind) async {
    let service = kind.service
    await #expect(throws: SignatureError.untrustedIdentity) { try await service.register() }
    await #expect(throws: SignatureError.untrustedIdentity) { try await service.unregister() }
}

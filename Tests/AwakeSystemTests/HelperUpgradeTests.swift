import Testing

@testable import AwakeSystem

@Test func helperUpgradeRefusesDowngradesAndInvalidBuildNumbers() throws {
    #expect(try helperNeedsUpgrade(installed: "1", candidate: "2"))
    #expect(try !helperNeedsUpgrade(installed: "2", candidate: "2"))
    #expect(throws: HelperInstallationError.self) {
        try helperNeedsUpgrade(installed: "2", candidate: "1")
    }
    for invalid in ["", "0", "-1", "+2", "2.0", "2\n", "18446744073709551616"] {
        #expect(throws: HelperInstallationError.self) {
            try helperNeedsUpgrade(installed: "1", candidate: invalid)
        }
        #expect(throws: HelperInstallationError.self) {
            try helperNeedsUpgrade(installed: invalid, candidate: "2")
        }
    }
}

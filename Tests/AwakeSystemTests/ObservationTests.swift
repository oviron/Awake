import AwakeCore
import CoreFoundation
import Foundation
import IOKit.pwr_mgt
import Testing

@testable import AwakeSystem

@Test func caffeinateRequiresAnActiveIdleAssertionNotJustAProcessOrOtherAssertion() {
    let active: [String: Any] = [
        kIOPMAssertionTypeKey: kIOPMAssertionTypePreventUserIdleSystemSleep,
        kIOPMAssertionLevelKey: NSNumber(value: kIOPMAssertionLevelOn),
    ]
    #expect(CaffeinateAssertion.containsIdleAssertion([active]))
    #expect(!CaffeinateAssertion.containsIdleAssertion(nil))
    #expect(!CaffeinateAssertion.containsIdleAssertion([]))
    var inactive = active
    inactive[kIOPMAssertionLevelKey] = NSNumber(value: kIOPMAssertionLevelOff)
    #expect(!CaffeinateAssertion.containsIdleAssertion([inactive]))
    var displayOnly = active
    displayOnly[kIOPMAssertionTypeKey] = kIOPMAssertionTypePreventUserIdleDisplaySleep
    #expect(!CaffeinateAssertion.containsIdleAssertion([displayOnly]))
}

@Test func assertionChildCleanupConfirmsExitWithoutChangingPowerSettings() throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["30"]
    try child.run()
    defer { if child.isRunning { child.terminate() } }
    var assertion = CaffeinateAssertion(process: child)
    #expect(!assertion.isEffective)
    try assertion.stop()
    #expect(!child.isRunning && assertion.process == nil)
    try assertion.stop()
}

@Test func onlyRealBooleanSleepPropertiesAreTrusted() {
    #expect(MacSleepBackend.decodeSleepProperty(kCFBooleanTrue) == .disabled)
    #expect(MacSleepBackend.decodeSleepProperty(kCFBooleanFalse) == .allowed)
    #expect(MacSleepBackend.decodeSleepProperty(nil) == .unknown)
    #expect(MacSleepBackend.decodeSleepProperty("0" as CFString) == .unknown)
    #expect(MacSleepBackend.decodeSleepProperty(NSNumber(value: 0)) == .unknown)
    #expect(MacSleepBackend.decodeSleepProperty(NSNumber(value: 2)) == .unknown)
}

@Test func nativeClockAdvancesAndHasRealWallTime() throws {
    let before = try SystemClock.now()
    let after = try SystemClock.now()
    #expect(after.continuous >= before.continuous)
    #expect(abs(after.wall.timeIntervalSinceNow) < 5)
}

@Test func boundedCommandsCheckExitStatusAndStartupFailure() throws {
    var command = BoundedSystemCommand()
    try command.run(executable: "/usr/bin/true", arguments: [])
    #expect(!command.isRunning)
    #expect(throws: MacSleepError.commandFailed(1)) {
        try command.run(executable: "/usr/bin/false", arguments: [])
    }
    #expect(throws: (any Error).self) {
        try command.run(executable: "/nonexistent/awake-test", arguments: [])
    }
}

@Test func timedOutCommandIsTerminatedAndNeverReportedSuccessful() throws {
    var command = BoundedSystemCommand()
    let clock = ContinuousClock()
    let started = clock.now
    #expect(throws: MacSleepError.commandTimedOut) {
        try command.run(executable: "/bin/sleep", arguments: ["10"], timeout: 0.05)
    }
    #expect(started.duration(to: clock.now) < .seconds(2))
    #expect(!command.isRunning)
    try command.run(executable: "/usr/bin/true", arguments: [])
}

@Test(arguments: [0.0, -1, .infinity, .nan, 3])
func commandTimeoutCannotBypassItsBound(_ timeout: Double) {
    var command = BoundedSystemCommand()
    #expect(throws: MacSleepError.invalidTimeout) {
        try command.run(executable: "/usr/bin/true", arguments: [], timeout: timeout)
    }
}

import AwakeCore
import Foundation
import Testing

@testable import AwakeCLI

@Test func setupParsesOnlySupportedProvidersAndRemoval() throws {
    for provider in ["codex", "claude", "cursor", "gemini"] {
        #expect(
            try CommandOptions.parse(["setup", provider])
                == .setup(provider: provider, remove: false))
        #expect(
            try CommandOptions.parse(["setup", provider, "--remove"])
                == .setup(provider: provider, remove: true))
    }
    for arguments in [["setup"], ["setup", "unknown"], ["setup", "codex", "--force"]] {
        #expect(throws: CLIError.self) { try CommandOptions.parse(arguments) }
    }
}

@Test func parsingPreservesCommandArgumentsAndExclusivePowerModes() throws {
    #expect(
        try CommandOptions.parse([
            "run", "-b", "--for", "1.5h", "--battery-floor", "25", "--", "printf", "%s",
            "a; echo not-a-shell",
        ])
            == .run(
                command: ["printf", "%s", "a; echo not-a-shell"],
                request: SessionRequest(
                    mode: .battery, batteryFloor: 25, end: .after(seconds: 5_400))))
    #expect(
        try CommandOptions.parse(["watch", "-c", "--pid", "123", "--unlimited"])
            == .watch(pid: 123, request: SessionRequest(mode: .external)))
    #expect(try CommandOptions.parse(["status", "--json"]) == .status(json: true))
    #expect(try CommandOptions.parse([]) == .help)
}

@Test(arguments: [
    ["run", "-b", "-c", "--", "true"], ["run", "-a", "-a", "--", "true"],
    ["run", "--for", "1h", "--unlimited", "--", "true"], ["watch", "--pid", "1"],
    ["watch", "--pid", "2147483648"], ["watch", "--pid", "12", "--pid", "13"],
    ["run", "--battery-floor", "81", "--", "true"],
    ["run", "--battery-floor", "-1", "--", "true"],
    ["run", "--battery-floor", "2.5", "--", "true"],
    ["run", "--"], ["run", "true"], ["watch", "--", "true"],
    ["run", "--until", "2026-10-01", "--", "true"], ["run", "--for"], ["status", "--for", "1h"],
    ["run", "--until", "2026-10-01T18:00:00", "--", "true"],
])
func invalidCLIOptionsFailBeforeWorkIsLaunched(_ arguments: [String]) {
    #expect(throws: CLIError.self) { try CommandOptions.parse(arguments) }
}

@Test(arguments: [0, 50, 51, 79, 80])
func cliAcceptsBatteryLimitsThroughEighty(_ floor: Int) throws {
    #expect(
        try CommandOptions.parse(["run", "--battery-floor", String(floor), "--", "true"])
            == .run(command: ["true"], request: SessionRequest(batteryFloor: floor)))
}

@Test func durationsHaveNoArbitraryMaximumAndDatesRequireTimezones() throws {
    #expect(try CommandOptions.duration("1000000d") == 86_400_000_000)
    for invalid in ["0s", "-2h", "nans", "infs", "1e309d", "30", "hours"] {
        #expect(throws: CLIError.self) { try CommandOptions.duration(invalid) }
    }
    guard
        case .run(_, let request) = try CommandOptions.parse([
            "run", "--until", "2026-10-01T18:00:00+02:00", "--", "true",
        ]),
        case .at(let date) = request.end
    else {
        Issue.record("Expected date stop")
        return
    }
    #expect(date == ISO8601DateFormatter().date(from: "2026-10-01T16:00:00Z"))
}

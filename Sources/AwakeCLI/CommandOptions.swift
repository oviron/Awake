import AwakeCore
import AwakeSystem
import Foundation

enum CLIError: Error, Equatable {
    case usage(String)
}

enum CommandOptions: Equatable {
    case help, version
    case status(json: Bool)
    case run(command: [String], request: SessionRequest)
    case watch(pid: Int32, request: SessionRequest)
    case hook(provider: String)
    case setup(provider: String, remove: Bool)

    static func parse(_ arguments: [String]) throws -> Self {
        if arguments.isEmpty || arguments == ["--help"] || arguments == ["help"] { return .help }
        if arguments == ["--version"] { return .version }
        if arguments == ["status"] { return .status(json: false) }
        if arguments == ["status", "--json"] { return .status(json: true) }
        if arguments.count == 2 || arguments.count == 3, arguments[0] == "setup",
            AgentSetup.providers.contains(arguments[1]),
            arguments.count == 2 || arguments[2] == "--remove"
        {
            return .setup(provider: arguments[1], remove: arguments.count == 3)
        }
        if arguments.count == 2, arguments[0] == "hook",
            ["codex", "claude", "cursor", "gemini", "other"].contains(arguments[1])
        {
            return .hook(provider: arguments[1])
        }
        guard let verb = arguments.first, verb == "run" || verb == "watch" else {
            throw CLIError.usage("Expected run, watch, status or setup. Use --help for syntax.")
        }
        var mode: PowerMode?
        var floor: Int?
        var end: SessionEnd?
        var pid: Int32?
        var index = 1
        func nextValue() throws -> String {
            index += 1
            guard index < arguments.count else { throw CLIError.usage("Missing option value.") }
            return arguments[index]
        }
        while index < arguments.count {
            let flag = arguments[index]
            switch flag {
            case "-a", "-b", "-c":
                guard mode == nil else { throw CLIError.usage("Choose exactly one of -a, -b, -c.") }
                mode = flag == "-a" ? .all : (flag == "-b" ? .battery : .external)
            case "--battery-floor":
                guard floor == nil, let value = Int(try nextValue()),
                    UserPolicy.batteryFloorRange.contains(value)
                else {
                    throw CLIError.usage("Battery floor must be one integer from 0 through 80.")
                }
                floor = value
            case "--for":
                guard end == nil else { throw CLIError.usage("Choose one stop condition.") }
                end = .after(seconds: try duration(nextValue()))
            case "--until":
                guard end == nil else { throw CLIError.usage("Choose one stop condition.") }
                let value = try nextValue()
                let formatter = ISO8601DateFormatter()
                var date = formatter.date(from: value)
                if date == nil {
                    formatter.formatOptions.insert(.withFractionalSeconds)
                    date = formatter.date(from: value)
                }
                guard let date else {
                    throw CLIError.usage(
                        "Use an ISO 8601 date with a timezone, for example 2026-10-01T18:00:00+02:00."
                    )
                }
                end = .at(date)
            case "--unlimited":
                guard end == nil else { throw CLIError.usage("Choose one stop condition.") }
                end = .unlimited
            case "--pid":
                guard verb == "watch", pid == nil, let value = Int32(try nextValue()), value > 1
                else {
                    throw CLIError.usage("watch requires one positive process ID greater than 1.")
                }
                pid = value
            case "--":
                guard verb == "run", index + 1 < arguments.count else {
                    throw CLIError.usage("run requires -- followed by a command.")
                }
                let command = Array(arguments.dropFirst(index + 1))
                guard !command[0].isEmpty else {
                    throw CLIError.usage("The command cannot be empty.")
                }
                return .run(
                    command: command,
                    request: SessionRequest(mode: mode, batteryFloor: floor, end: end ?? .unlimited)
                )
            default: throw CLIError.usage("Unknown option: \(flag). Use -- before the command.")
            }
            index += 1
        }
        guard verb == "watch", let pid else {
            throw CLIError.usage("run requires -- command; watch requires --pid ID.")
        }
        return .watch(
            pid: pid,
            request: SessionRequest(mode: mode, batteryFloor: floor, end: end ?? .unlimited))
    }

    static func duration(_ text: String) throws -> TimeInterval {
        let units: [Character: Double] = ["s": 1, "m": 60, "h": 3_600, "d": 86_400]
        guard let suffix = text.last, let multiplier = units[suffix],
            let number = Double(text.dropLast())
        else {
            throw CLIError.usage(
                "Duration needs a positive number and s, m, h or d, for example 90m.")
        }
        let seconds = number * multiplier
        do { try UserPolicy.validateDuration(seconds) } catch {
            throw CLIError.usage("Duration must be positive, finite and representable.")
        }
        return seconds
    }
}

import Foundation
import IOKit

struct ObservationFailure: Error { let message: String }

func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw ObservationFailure(message: message) }
}

func say(_ message: String) {
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
}

func command(_ executable: String, _ arguments: [String]) throws -> (Int32, Data) {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, data)
}

func status() throws -> [String: Any] {
    let (code, data) = try command(
        "/Applications/Awake.app/Contents/MacOS/awake", ["status", "--json"])
    guard code == 0, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw ObservationFailure(message: "Authenticated status unavailable.") }
    return value
}

func helperPID() throws -> Int32? {
    let (code, data) = try command(
        "/bin/launchctl", ["print", "system/io.github.oviron.Awake.helper"])
    if code == 113 { return nil }
    try require(code == 0, "Cannot inspect the fixed helper job.")
    let text = String(decoding: data, as: UTF8.self)
    let expression = try NSRegularExpression(pattern: #"(?m)^\s*pid = ([0-9]+)\s*$"#)
    let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
    if matches.isEmpty { return nil }
    guard matches.count == 1, let range = Range(matches[0].range(at: 1), in: text),
        let pid = Int32(text[range]), pid > 1
    else { throw ObservationFailure(message: "Ambiguous helper PID.") }
    return pid
}

func sleepDisabled() throws -> Bool {
    let service = IOServiceGetMatchingService(
        kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    try require(service != IO_OBJECT_NULL, "Root power domain unavailable.")
    defer { IOObjectRelease(service) }
    guard
        let property = IORegistryEntryCreateCFProperty(
            service, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
        CFGetTypeID(property) == CFBooleanGetTypeID(), let disabled = property as? Bool
    else { throw ObservationFailure(message: "Power observation is unknown.") }
    return disabled
}

func main() throws {
    try require(
        geteuid() != 0 && Array(CommandLine.arguments.dropFirst()) == ["--observe-armed-restart"],
        "Usage: swift Tests/NativeMac/ObserveHelperRestart.swift --observe-armed-restart (non-root)"
    )
    let baseline = try status()
    guard let sleep = baseline["sleep"] as? [String: Any],
        let sessions = baseline["sessions"] as? [[String: Any]], !sessions.isEmpty,
        sessions.allSatisfy({ ($0["remainingSeconds"] as? Double ?? 0) >= 120 }),
        sleep["phase"] as? String == "active", sleep["observed"] as? String == "disabled",
        sleep["ownsGlobalHold"] as? Bool == true, sleep["fault"] == nil,
        let originalPID = try helperPID(), try sleepDisabled()
    else {
        throw ObservationFailure(
            message: "Requires a verified active owned hold with at least two minutes remaining.")
    }
    let start = ProcessInfo.processInfo.systemUptime
    let output = FileManager.default.temporaryDirectory.appendingPathComponent(
        "Awake-helper-restart-\(UUID().uuidString).jsonl")
    let descriptor = open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    try require(descriptor >= 0, "Cannot create a private observation trace.")
    let trace = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? trace.close() }
    say("READY: helper PID \(originalPID); trace: \(output.path)")
    say("An operator may now perform the separately authorized SIGKILL test within 60 seconds.")
    var replacementPID: Int32?
    var restoredAt: TimeInterval?
    var previous = ""
    repeat {
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let pid = try helperPID()
        let disabled = try sleepDisabled()
        let entry: [String: Any] = [
            "elapsed": elapsed, "helperPID": pid.map { $0 as Any } ?? NSNull(),
            "sleepDisabled": disabled,
        ]
        try trace.write(
            contentsOf: JSONSerialization.data(withJSONObject: entry, options: .sortedKeys))
        try trace.write(contentsOf: Data("\n".utf8))
        let line = "pid=\(pid.map(String.init) ?? "absent") sleepDisabled=\(disabled)"
        if line != previous {
            say(String(format: "%.2fs ", elapsed) + line)
            previous = line
        }
        if let pid, pid != originalPID {
            if let replacementPID {
                try require(pid == replacementPID, "The replacement helper restarted again.")
            } else {
                replacementPID = pid
            }
        }
        if let restoredAt {
            try require(!disabled, "Protection reactivated without an explicit new session.")
            if elapsed - restoredAt >= 10 { break }
        } else if replacementPID != nil, !disabled {
            restoredAt = elapsed
        }
        try require(elapsed < 90, "No confirmed restart/restoration within the observation window.")
        if elapsed >= 60, replacementPID == nil {
            throw ObservationFailure(
                message: "No helper replacement observed; no crash result claimed.")
        }
        Thread.sleep(forTimeInterval: 0.25)
    } while true
    let final = try status()
    guard let sleep = final["sleep"] as? [String: Any],
        (final["sessions"] as? [Any])?.isEmpty == true,
        (final["policy"] as? [String: Any])?["allowsAutomation"] as? Bool == false,
        sleep["observed"] as? String == "allowed", sleep["ownsGlobalHold"] as? Bool == false,
        sleep["phase"] as? String == "blocked", sleep["fault"] as? String == "interrupted",
        try helperPID() == replacementPID, try !sleepDisabled()
    else {
        throw ObservationFailure(
            message: "Restart did not confirm journal recovery and revocation.")
    }
    try trace.write(contentsOf: JSONSerialization.data(withJSONObject: final, options: .sortedKeys))
    try trace.write(contentsOf: Data("\n".utf8))
    say(
        "PASS: replacement helper restored its journaled hold without reviving sessions or automation."
    )
}

do { try main() } catch {
    FileHandle.standardError.write(Data("Restart observation stopped: \(error)\n".utf8))
    exit(1)
}

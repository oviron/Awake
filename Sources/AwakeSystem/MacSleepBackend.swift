import AwakeCore
import Darwin
import Foundation
import IOKit
import IOKit.pwr_mgt

public enum MacSleepError: Error, Equatable, Sendable {
    case administratorRequired
    case commandFailed(Int32)
    case commandTimedOut, verificationFailed
    case commandStillRunning, invalidTimeout
}

public struct MacSleepBackend: SleepBackend, Sendable {
    private var caffeinate = CaffeinateAssertion()
    private var command = BoundedSystemCommand()

    public init() {}

    public var hasIdleAssertion: Bool { caffeinate.isEffective }

    public mutating func observe() -> SleepObservation {
        guard !command.isRunning else { return .unknown }
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return .unknown }
        defer { IOObjectRelease(service) }
        let property = IORegistryEntryCreateCFProperty(
            service, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return Self.decodeSleepProperty(property)
    }

    static func decodeSleepProperty(_ property: CFTypeRef?) -> SleepObservation {
        guard let property, CFGetTypeID(property) == CFBooleanGetTypeID(),
            let disabled = property as? Bool
        else { return .unknown }
        return disabled ? .disabled : .allowed
    }

    public mutating func setIdleAssertion(_ held: Bool) throws {
        if held { try caffeinate.start() } else { try caffeinate.stop() }
    }

    public mutating func setSleepDisabled(_ disabled: Bool) throws {
        guard geteuid() == 0 else { throw MacSleepError.administratorRequired }
        try command.run(
            executable: "/usr/bin/pmset", arguments: ["disablesleep", disabled ? "1" : "0"])
        let expected: SleepObservation = disabled ? .disabled : .allowed
        for _ in 0..<20 {
            if observe() == expected { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard observe() == expected else { throw MacSleepError.verificationFailed }
    }
}

struct CaffeinateAssertion: Sendable {
    var process: Process?

    var isEffective: Bool {
        guard let process, process.isRunning else { return false }
        var assertions: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&assertions) == kIOReturnSuccess,
            let snapshot = assertions?.takeRetainedValue() as? [NSNumber: Any]
        else { return false }
        return Self.containsIdleAssertion(snapshot[NSNumber(value: process.processIdentifier)])
            && process.isRunning
    }

    static func containsIdleAssertion(_ value: Any?) -> Bool {
        guard let assertions = value as? [[String: Any]] else { return false }
        return assertions.contains { assertion in
            assertion[kIOPMAssertionTypeKey] as? String
                == kIOPMAssertionTypePreventUserIdleSystemSleep
                && (assertion[kIOPMAssertionLevelKey] as? NSNumber)?.intValue
                    == kIOPMAssertionLevelOn
        }
    }

    mutating func start() throws {
        if isEffective { return }
        try stop()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        child.arguments = ["-i", "-w", String(getpid())]
        child.currentDirectoryURL = URL(fileURLWithPath: "/")
        child.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child
        for _ in 0..<20 {
            if isEffective { return }
            if !child.isRunning { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw MacSleepError.verificationFailed
    }

    mutating func stop() throws {
        guard let child = process else { return }
        if child.isRunning { child.terminate() }
        for _ in 0..<20 {
            if !child.isRunning {
                process = nil
                return
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
        throw MacSleepError.commandStillRunning
    }
}

struct BoundedSystemCommand: Sendable {
    private var process: Process?
    var isRunning: Bool { process?.isRunning == true }

    mutating func run(executable: String, arguments: [String], timeout: TimeInterval = 2) throws {
        guard timeout.isFinite, timeout > 0, timeout <= 2 else {
            throw MacSleepError.invalidTimeout
        }
        guard !isRunning else { throw MacSleepError.commandStillRunning }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        child.currentDirectoryURL = URL(fileURLWithPath: "/")
        child.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        child.terminationHandler = { _ in finished.signal() }
        try child.run()
        process = child
        guard finished.wait(timeout: .now() + timeout) == .success else {
            if child.isRunning { child.terminate() }
            if finished.wait(timeout: .now() + 0.25) != .success, child.isRunning {
                kill(child.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 0.25)
            }
            throw MacSleepError.commandTimedOut
        }
        process = nil
        guard child.terminationReason == .exit, child.terminationStatus == 0 else {
            throw MacSleepError.commandFailed(child.terminationStatus)
        }
    }
}

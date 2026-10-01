import Darwin
import Foundation

public enum WorkError: Error, Equatable, Sendable {
    case invalidProcess, processUnavailable, differentUser, administratorNotAllowed, alreadyStarted
}

public struct ProcessIdentity: Codable, Equatable, Sendable {
    public let pid: Int32
    private let user: UInt32
    private let startedSeconds: UInt64
    private let startedMicroseconds: UInt64

    public init(pid: Int32) throws {
        guard geteuid() != 0, geteuid() == getuid() else { throw WorkError.administratorNotAllowed }
        guard pid > 1, pid != getpid() else { throw WorkError.invalidProcess }
        guard let info = Self.read(pid), info.pbi_status != SZOMB else {
            throw WorkError.processUnavailable
        }
        guard info.pbi_uid == geteuid(), info.pbi_ruid == getuid() else {
            throw WorkError.differentUser
        }
        self.pid = pid
        user = info.pbi_uid
        startedSeconds = info.pbi_start_tvsec
        startedMicroseconds = info.pbi_start_tvusec
    }

    public var isAlive: Bool {
        user == geteuid() && getuid() == geteuid() && geteuid() != 0
            && pid > 1 && pid != getpid() && (Self.read(pid).map(matches) ?? false)
    }

    public static func hookHost() throws -> Self {
        var pid = getppid()
        for _ in 0..<8 {
            let identity = try Self(pid: pid)
            guard var info = read(pid) else { throw WorkError.processUnavailable }
            let name = withUnsafeBytes(of: &info.pbi_comm) {
                String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            if !["sh", "bash", "zsh", "fish", "env"].contains(name) { return identity }
            pid = Int32(info.pbi_ppid)
        }
        throw WorkError.processUnavailable
    }

    func matches(_ info: proc_bsdinfo) -> Bool {
        info.pbi_pid == UInt32(pid) && info.pbi_uid == user && info.pbi_ruid == user
            && info.pbi_start_tvsec == startedSeconds
            && info.pbi_start_tvusec == startedMicroseconds && info.pbi_status != SZOMB
    }

    static func read(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }
}

public struct RunningProcess: Identifiable, Sendable {
    public let identity: ProcessIdentity
    public let name: String
    public var id: Int32 { identity.pid }

    public static func snapshot() throws -> [Self] {
        guard geteuid() != 0, geteuid() == getuid() else { throw WorkError.administratorNotAllowed }
        let needed = proc_listpids(UInt32(PROC_UID_ONLY), geteuid(), nil, 0)
        guard needed > 0 else { throw WorkError.processUnavailable }
        var pids = [Int32](repeating: 0, count: Int(needed) / MemoryLayout<Int32>.stride + 256)
        let bytes = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_UID_ONLY), geteuid(), $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0 else { throw WorkError.processUnavailable }
        return pids.prefix(Int(bytes) / MemoryLayout<Int32>.stride).compactMap { pid in
            guard let identity = try? ProcessIdentity(pid: pid),
                var info = ProcessIdentity.read(pid), identity.matches(info)
            else { return nil }
            let name = withUnsafeBytes(of: &info.pbi_name) { bytes in
                String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            return Self(identity: identity, name: name.isEmpty ? "Process \(pid)" : name)
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}

@MainActor public final class TrackedCommand {
    private let process = Process()
    private let results: AsyncStream<Int32>
    private let completion: AsyncStream<Int32>.Continuation
    private var started = false

    public init(arguments: [String]) throws {
        guard geteuid() != 0, geteuid() == getuid() else { throw WorkError.administratorNotAllowed }
        guard let executable = arguments.first, !executable.isEmpty else {
            throw WorkError.invalidProcess
        }
        let stream = AsyncStream<Int32>.makeStream(bufferingPolicy: .bufferingNewest(1))
        results = stream.stream
        completion = stream.continuation
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["--"] + arguments
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        process.terminationHandler = { child in
            let code =
                child.terminationReason == .exit
                ? child.terminationStatus : 128 + child.terminationStatus
            stream.continuation.yield(code)
            stream.continuation.finish()
        }
    }

    public var isRunning: Bool { process.isRunning }
    public var processIdentifier: Int32 { process.processIdentifier }

    public func start() throws {
        guard !started else { throw WorkError.alreadyStarted }
        started = true
        do { try process.run() } catch {
            completion.finish()
            throw error
        }
    }

    public func result() async -> Int32 {
        for await code in results { return code }
        return 125
    }

    public func interrupt(terminate: Bool = false) {
        guard process.isRunning else { return }
        if terminate { process.terminate() } else { process.interrupt() }
    }
}

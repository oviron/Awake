import AwakeSystem
import CryptoKit
import Darwin
import Foundation

struct AgentEvent: Equatable {
    enum Action: String { case begin, end, endSession }
    let action: Action
    let session: String
    let task: String

    struct Input: Decodable {
        let hookEventName: String
        let sessionId: String?
        let conversationId: String?
        let turnId: String?
        let generationId: String?
    }

    static func decode(_ data: Data, provider: String) throws -> Self {
        guard data.count <= 1_048_576 else { throw CLIError.usage("Hook input is too large.") }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let input = try decoder.decode(Input.self, from: data)
        let event = input.hookEventName
        let action: Action
        switch (provider, event) {
        case ("codex", "UserPromptSubmit"), ("claude", "UserPromptSubmit"),
            ("cursor", "beforeSubmitPrompt"), ("gemini", "BeforeAgent"), ("other", "Begin"):
            action = .begin
        case ("codex", "Stop"), ("codex", "Interrupt"),
            ("claude", "Stop"), ("claude", "StopFailure"),
            ("cursor", "stop"), ("gemini", "AfterAgent"), ("other", "End"):
            action = .end
        case ("codex", "SessionEnd"), ("claude", "SessionEnd"),
            ("cursor", "sessionEnd"), ("gemini", "SessionEnd"), ("other", "SessionEnd"):
            action = .endSession
        default: throw CLIError.usage("Unsupported agent lifecycle event.")
        }
        guard let session = provider == "cursor" ? input.conversationId : input.sessionId else {
            throw CLIError.usage("Missing agent session identifier.")
        }
        let task: String
        if action == .endSession {
            task = "session"
        } else if provider == "codex" || provider == "cursor" || provider == "other" {
            guard let id = provider == "cursor" ? input.generationId : input.turnId else {
                throw CLIError.usage("Missing turn identifier.")
            }
            task = "turn:" + id
        } else {
            task = "turn"
        }
        return try Self(action: action, provider: provider, session: session, task: task)
    }

    init(action: Action, provider: String, session: String, task: String) throws {
        guard [provider, session, task].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }) else {
            throw CLIError.usage("Invalid task identifier.")
        }
        self.action = action
        self.session = Self.digest(provider + "\0" + session)
        self.task = Self.digest(task)
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

final class AgentActivity {
    struct Context: Codable {
        let name: String
        let host: ProcessIdentity
        let device: dev_t
        let inode: ino_t
    }
    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AwakeIdentity.application).appendingPathComponent("Agents")
    }
    let context: Context
    private let directoryFD: Int32
    private let markerFD: Int32

    private static func openDirectory(_ url: URL) throws -> Int32 {
        guard geteuid() != 0, getuid() == geteuid() else { throw WorkError.administratorNotAllowed }
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw WorkError.processUnavailable }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            close(fd)
            throw WorkError.differentUser
        }
        do { try SecureOwnershipJournal.rejectExtendedAccess(fd) } catch {
            close(fd)
            throw error
        }
        return fd
    }

    static func begin(_ event: AgentEvent, host: ProcessIdentity, directory: URL = directory) throws
        -> Context?
    {
        let fd = try openDirectory(directory)
        defer { close(fd) }
        guard host.isAlive else { throw WorkError.processUnavailable }
        guard try FileManager.default.contentsOfDirectory(atPath: directory.path).count < 256 else {
            throw CLIError.usage(
                "Too many unfinished agent tasks. End the previous sessions first.")
        }
        let name = event.session + "." + event.task
        let marker = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if marker < 0, errno == EEXIST { return nil }
        guard marker >= 0 else { throw WorkError.processUnavailable }
        var info = stat()
        let sampled = fstat(marker, &info) == 0
        close(marker)
        guard sampled else { throw WorkError.processUnavailable }
        return Context(name: name, host: host, device: info.st_dev, inode: info.st_ino)
    }

    static func end(_ event: AgentEvent, directory: URL = directory) throws {
        let fd = try openDirectory(directory)
        defer { close(fd) }
        let names =
            event.action == .endSession
            ? try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
                $0.hasPrefix(event.session + ".")
            }
            : [event.session + "." + event.task]
        for name in names where validName(name) {
            if unlinkat(fd, name, 0) != 0, errno != ENOENT { throw WorkError.processUnavailable }
        }
    }

    init(_ context: Context, directory: URL = directory) throws {
        guard Self.validName(context.name), context.host.isAlive else {
            throw WorkError.invalidProcess
        }
        let directoryFD = try Self.openDirectory(directory)
        let markerFD = openat(
            directoryFD, context.name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        do {
            var info = stat()
            guard markerFD >= 0, fstat(markerFD, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                info.st_uid == geteuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1,
                info.st_dev == context.device, info.st_ino == context.inode,
                flock(markerFD, LOCK_EX | LOCK_NB) == 0
            else { throw WorkError.processUnavailable }
            try SecureOwnershipJournal.rejectExtendedAccess(markerFD)
        } catch {
            if markerFD >= 0 { close(markerFD) }
            close(directoryFD)
            throw error
        }
        self.context = context
        self.directoryFD = directoryFD
        self.markerFD = markerFD
    }

    var isAlive: Bool { context.host.isAlive && sameMarker }

    private var sameMarker: Bool {
        var original = stat()
        var current = stat()
        return fstat(markerFD, &original) == 0
            && fstatat(directoryFD, context.name, &current, AT_SYMLINK_NOFOLLOW) == 0
            && original.st_dev == current.st_dev && original.st_ino == current.st_ino
    }

    func finish() { if sameMarker { _ = unlinkat(directoryFD, context.name, 0) } }

    deinit {
        close(markerFD)
        close(directoryFD)
    }

    private static func validName(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2
            && parts.allSatisfy {
                $0.utf8.count == 64
                    && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            }
    }
}

@MainActor enum AgentHook {
    static func run(provider: String) async {
        do {
            let data = try readInput(maximum: 1_048_576)
            let event = try AgentEvent.decode(data, provider: provider)
            if event.action == .begin {
                let identity = try await SignedIdentity.current(
                    expectedIdentifier: AwakeIdentity.commandLine)
                if let context = try AgentActivity.begin(event, host: ProcessIdentity.hookHost()) {
                    try launch(context, executable: identity.executableURL)
                }
            } else {
                try AgentActivity.end(event)
            }
        } catch {
            FileHandle.standardError.write(
                Data("Awake could not follow this agent event; check the app.\n".utf8))
        }
        print("{}")
    }

    static func readInput(maximum: Int) throws -> Data {
        var result = Data()
        while let part = try FileHandle.standardInput.read(
            upToCount: min(65_536, maximum + 1 - result.count)), !part.isEmpty
        {
            result.append(part)
            guard result.count <= maximum else { throw CLIError.usage("Hook input is too large.") }
        }
        return result
    }

    static func launch(_ context: AgentActivity.Context, executable: URL) throws {
        let child = Process()
        let input = Pipe()
        let ready = Pipe()
        child.executableURL = executable
        child.arguments = ["_agent-hold"]
        child.environment = [:]
        child.currentDirectoryURL = URL(fileURLWithPath: "/")
        child.standardInput = input
        child.standardOutput = ready
        child.standardError = FileHandle.nullDevice
        try child.run()
        ready.fileHandleForWriting.closeFile()
        input.fileHandleForReading.closeFile()
        try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(context))
        try input.fileHandleForWriting.close()
        var descriptor = pollfd(
            fd: ready.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        defer { ready.fileHandleForReading.closeFile() }
        guard poll(&descriptor, 1, 2_000) > 0,
            try ready.fileHandleForReading.read(upToCount: 1) == Data([1])
        else {
            throw WorkError.processUnavailable
        }
    }
}

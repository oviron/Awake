import Darwin
import Foundation
import Testing

@testable import AwakeSystem

@Test @MainActor func trackedCommandReportsRealExitAndCannotBeStartedTwice() async throws {
    let command = try TrackedCommand(arguments: ["/usr/bin/false"])
    try command.start()
    #expect(throws: WorkError.alreadyStarted) { try command.start() }
    let code = await command.result()
    #expect(code == 1)
    #expect(!command.isRunning)
}

@Test @MainActor func processIdentityDetectsExitAndRejectsPidReuseOrAnotherOwner() async throws {
    let command = try TrackedCommand(arguments: ["/bin/sleep", "10"])
    try command.start()
    defer { command.interrupt(terminate: true) }
    let identity = try ProcessIdentity(pid: command.processIdentifier)
    #expect(identity.isAlive)
    let listed = try #require(RunningProcess.snapshot().first { $0.id == identity.pid })
    #expect(listed.identity == identity && !listed.name.isEmpty)
    #expect(try RunningProcess.snapshot().allSatisfy { $0.id != getpid() && $0.id > 1 })
    var info = try #require(ProcessIdentity.read(identity.pid))
    info.pbi_start_tvusec &+= 1
    #expect(!identity.matches(info))
    info = try #require(ProcessIdentity.read(identity.pid))
    info.pbi_uid &+= 1
    #expect(!identity.matches(info))
    command.interrupt(terminate: true)
    let code = await command.result()
    #expect(code == 128 + SIGTERM)
    #expect(!identity.isAlive)
}

@Test func watcherRejectsInvalidSystemAndSelfPids() {
    for pid in [Int32(-1), 0, 1, getpid()] {
        #expect(throws: WorkError.invalidProcess) { try ProcessIdentity(pid: pid) }
    }
}

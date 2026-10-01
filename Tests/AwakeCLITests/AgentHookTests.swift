import AwakeSystem
import Darwin
import Foundation
import Testing

@testable import AwakeCLI

@Test func hookEventsPairOnlyTheirOwnTaskWithoutUsingPromptData() throws {
    for (provider, start, end, session, turn) in [
        ("codex", "UserPromptSubmit", "Stop", "session_id", "turn_id"),
        ("claude", "UserPromptSubmit", "Stop", "session_id", "unused"),
        ("cursor", "beforeSubmitPrompt", "stop", "conversation_id", "generation_id"),
        ("gemini", "BeforeAgent", "AfterAgent", "session_id", "unused"),
        ("other", "Begin", "End", "session_id", "turn_id"),
    ] {
        func decode(_ event: String, task: String = "1") throws -> AgentEvent {
            let data = try JSONSerialization.data(withJSONObject: [
                "hook_event_name": event, session: "same", turn: task,
                "prompt": "must never become a filename", "transcript_path": "/never/read",
            ])
            return try AgentEvent.decode(data, provider: provider)
        }
        let begin = try decode(start)
        let finish = try decode(end)
        #expect(begin.action == .begin && finish.action == .end)
        #expect(begin.session == finish.session && begin.task == finish.task)
        #expect(begin.session.count == 64 && begin.task.count == 64)
        if turn != "unused" { #expect(try decode(start, task: "2").task != begin.task) }
    }
    #expect(throws: (any Error).self) {
        try AgentEvent.decode(
            Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"s"}"#.utf8),
            provider: "codex")
    }
    let interrupted = try AgentEvent.decode(
        Data(#"{"hook_event_name":"Interrupt","session_id":"s","turn_id":"t"}"#.utf8),
        provider: "codex")
    #expect(interrupted.action == .end)
    #expect(throws: (any Error).self) {
        try AgentEvent.decode(
            Data(#"{"hook_event_name":"SubagentStart","session_id":"s"}"#.utf8), provider: "codex")
    }
}

@Test func agentMarkersAreIndependentIdempotentAndBoundToTheirOriginalInode() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["60"]
    try child.run()
    defer {
        if child.isRunning {
            child.terminate()
            child.waitUntilExit()
        }
    }
    let host = try ProcessIdentity(pid: child.processIdentifier)
    let begin = try AgentEvent(action: .begin, provider: "other", session: "s", task: "a")
    let end = try AgentEvent(action: .end, provider: "other", session: "s", task: "a")
    let created = try AgentActivity.begin(begin, host: host, directory: root)
    let context = try #require(created)
    let activity = try AgentActivity(context, directory: root)
    #expect(activity.isAlive)
    #expect(try AgentActivity.begin(begin, host: host, directory: root) == nil)
    #expect(throws: (any Error).self) { try AgentActivity(context, directory: root) }
    try AgentActivity.end(end, directory: root)
    #expect(!activity.isAlive)
    let replaced = try AgentActivity.begin(begin, host: host, directory: root)
    let replacement = try #require(replaced)
    #expect(throws: (any Error).self) { try AgentActivity(context, directory: root) }
    let newer = try AgentActivity(replacement, directory: root)
    activity.finish()
    #expect(newer.isAlive)
    let other = try AgentEvent(action: .begin, provider: "other", session: "another", task: "a")
    let otherCreated = try AgentActivity.begin(other, host: host, directory: root)
    let otherContext = try #require(otherCreated)
    let otherActivity = try AgentActivity(otherContext, directory: root)
    try AgentActivity.end(
        AgentEvent(action: .endSession, provider: "other", session: "s", task: "all"),
        directory: root)
    #expect(!newer.isAlive && otherActivity.isAlive)
    let damaged = try AgentActivity.begin(begin, host: host, directory: root)
    let damagedContext = try #require(damaged)
    let marker = root.appendingPathComponent(damagedContext.name)
    try FileManager.default.removeItem(at: marker)
    #expect(mkfifo(marker.path, 0o600) == 0)
    #expect(throws: (any Error).self) { try AgentActivity(damagedContext, directory: root) }
    try FileManager.default.removeItem(at: marker)
    child.terminate()
    child.waitUntilExit()
    #expect(!otherActivity.isAlive)
    otherActivity.finish()
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
}

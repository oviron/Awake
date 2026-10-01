import AwakeCore
import AwakeSystem
import Darwin
import Foundation

@main
struct AwakeCLI {
    @MainActor static func main() async {
        if Array(CommandLine.arguments.dropFirst()) == ["_agent-hold"] {
            await holdAgent()
            return
        }
        do {
            let options = try CommandOptions.parse(Array(CommandLine.arguments.dropFirst()))
            switch options {
            case .help: print(help)
            case .version: print("Awake \(AwakeIdentity.version)")
            case .hook(let provider): await AgentHook.run(provider: provider)
            case .setup(let provider, let remove):
                try AgentSetup.configure(provider, remove: remove)
                print(
                    remove
                        ? "Awake integration removed from \(provider)."
                        : "Awake is ready for \(provider). Restart your agent and approve its hooks if asked."
                )
            case .status(let json):
                let client = try await ServiceClient(role: .task)
                do {
                    guard let status = try await client.send(.status).status else {
                        throw ServiceError.unavailable
                    }
                    if json {
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        print(String(decoding: try encoder.encode(status), as: UTF8.self))
                    } else {
                        print(
                            "Awake: \(status.sleep.phase.rawValue); observed sleep flag: \(status.sleep.observed.rawValue)"
                        )
                        print(
                            "Power: \(status.power.source.rawValue); mode: \(status.policy.mode.flag); battery floor: \(status.policy.batteryFloor)%"
                        )
                        print(
                            "Sessions: \(status.sessions.count); automation: \(status.policy.allowsAutomation ? "allowed" : "disabled")"
                        )
                        if let fault = status.sleep.fault {
                            print("Action required: \(fault.rawValue)")
                        }
                    }
                    await client.close()
                } catch {
                    await client.close()
                    throw error
                }
            case .run(let command, let request):
                let work = try TrackedCommand(arguments: command)
                exit(try await follow(command: work, process: nil, request: request))
            case .watch(let pid, let request):
                let process = try ProcessIdentity(pid: pid)
                exit(try await follow(command: nil, process: process, request: request))
            }
        } catch {
            report(message(for: error))
            exit(error is CLIError ? 64 : 69)
        }
    }

    @MainActor private static func follow(
        command: TrackedCommand?, process: ProcessIdentity?, request: SessionRequest,
        agent: AgentActivity? = nil
    ) async throws -> Int32 {
        let client = try await ServiceClient(role: .task)
        do {
            let reply = try await client.send(agent == nil ? .start(request) : .startAgent)
            guard let id = reply.startedSession, let status = reply.status,
                let session = status.sessions.first(where: { $0.id == id && $0.belongsToClient }),
                status.sleep.fault == nil
            else { throw ServiceError.sessionRejected }
            if agent != nil {
                FileHandle.standardOutput.write(Data([1]))
                try FileHandle.standardOutput.close()
            }
            if max(request.batteryFloor ?? 0, status.policy.batteryFloor) == 0 {
                report("Warning: custom battery protection is disabled (0%).")
            }
            if let reason = session.suspension {
                report(
                    "Keep-awake is suspended: \(reason.rawValue). The task still runs under your limits."
                )
            }
            if let process, !process.isAlive {
                await release(id, client: client)
                return 0
            }
            try command?.start()
            var protectionEnded = false
            let heartbeat = Task {
                do {
                    while !Task.isCancelled && !protectionEnded {
                        try await Task.sleep(for: .seconds(ServiceSessions.heartbeatSeconds))
                        if let command, !command.isRunning { return }
                        if let process, !process.isAlive { return }
                        if let agent, !agent.isAlive { return }
                        let current = try await client.send(.heartbeat)
                        guard !protectionEnded else { return }
                        guard let status = current.status,
                            status.sessions.contains(where: { $0.id == id })
                        else {
                            protectionEnded = true
                            report(
                                "The keep-awake session ended. The task may continue; protection will not restart."
                            )
                            if let fault = current.status?.sleep.fault {
                                report(
                                    "Restoration needs attention: \(fault.rawValue). Check the app's observed state."
                                )
                            }
                            await client.close()
                            return
                        }
                    }
                } catch {
                    guard !Task.isCancelled && !protectionEnded else { return }
                    protectionEnded = true
                    report(
                        "Keep-awake connection lost. The task continues without reacquiring protection."
                    )
                    await client.close()
                }
            }
            var interrupted: Int32 = 0
            let signals = [SIGINT, SIGTERM].map { number in
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler {
                    Task { @MainActor in
                        interrupted = number
                        protectionEnded = true
                        command?.interrupt(terminate: number == SIGTERM)
                        await client.close()
                    }
                }
                source.resume()
                return source
            }
            defer {
                for source in signals { source.cancel() }
                heartbeat.cancel()
            }
            let result: Int32
            if let command {
                result = await command.result()
            } else {
                while interrupted == 0, process?.isAlive ?? agent?.isAlive ?? false {
                    try await Task.sleep(for: .seconds(1))
                }
                result = interrupted == 0 ? 0 : 128 + interrupted
            }
            if !protectionEnded {
                protectionEnded = true
                await release(id, client: client)
            }
            heartbeat.cancel()
            await heartbeat.value
            return result
        } catch {
            await client.close()
            throw error
        }
    }

    @MainActor private static func holdAgent() async {
        _ = setsid()
        signal(SIGPIPE, SIG_IGN)
        do {
            let data = try AgentHook.readInput(maximum: 8_192)
            let context = try JSONDecoder().decode(AgentActivity.Context.self, from: data)
            let activity = try AgentActivity(context)
            defer { activity.finish() }
            do {
                _ = try await follow(command: nil, process: nil, request: .init(), agent: activity)
            } catch {
                try? FileHandle.standardOutput.close()
                while activity.isAlive { try await Task.sleep(for: .seconds(1)) }
            }
        } catch { return }
    }

    private static func release(_ id: UUID, client: ServiceClient) async {
        do {
            let reply: ServiceReply
            do { reply = try await client.send(.stop(id)) } catch ServiceError.unauthorized {
                reply = try await client.send(.status)
            }
            guard let status = reply.status,
                !status.sessions.contains(where: { $0.id == id })
            else { throw ServiceError.unavailable }
            if status.sleep.fault != nil || (status.sessions.isEmpty && status.sleep.ownsGlobalHold)
            {
                report(
                    "The task ended, but power restoration needs attention. Check Awake's observed state."
                )
            }
        } catch {
            report(
                "The task ended; restoration could not be confirmed. Check Awake's observed state."
            )
        }
        await client.close()
    }

    private static func report(_ text: String) {
        FileHandle.standardError.write(Data("awake: \(text)\n".utf8))
    }

    private static func message(for error: any Error) -> String {
        if case CLIError.usage(let reason) = error { return reason }
        if error is SignatureError {
            return
                "A correctly signed Awake installation is required. The command was not launched."
        }
        if let error = error as? ServiceError {
            return
                "Service refused the request (\(error.rawValue)). Check Awake and its automation limits."
        }
        if let error = error as? WorkError { return "Cannot follow this work: \(error)." }
        return "Operation failed: \(error.localizedDescription)"
    }

    private static let help = """
        Awake — keep awake for explicitly tracked work.

        Usage:
          awake status [--json]
          awake run [options] -- command [arguments...]
          awake watch [options] --pid ID
          awake setup codex|claude|cursor|gemini [--remove]
          awake hook codex|claude|cursor|gemini|other   (lifecycle JSON on stdin)
          awake --version

        Options:
          -b | -c | -a          Battery only, AC only, or both (mutually exclusive).
          --battery-floor N    Integer 0–80; 0 disables custom protection with warning.
          --for DURATION       Positive duration: 30s, 90m, 2h, 1.5d.
          --until ISO8601      Stop at a date/time with an explicit timezone.
          --unlimited          No task duration limit (the default).

        The app must authorize automation first. Requests can only narrow its limits.
        Protection ends when the command/process exits, a limit is reached, or the
        connection is lost. The command itself is not killed when protection expires.
        run preserves the command's exit code and standard streams. Ctrl-C forwards
        an interrupt and releases this session. watch never signals the observed PID.
        No command is sent to the administrator helper. No automatic reacquisition.
        """
}

import Foundation
import os

final class ProbeServer: NSObject, NSXPCListenerDelegate, AwakeXPC {
    let requirement: String
    private let lock = NSLock()
    private var connections: [NSXPCConnection] = []
    var admissionCount: Int { lock.withLock { connections.count } }

    init(requirement: String) { self.requirement = requirement }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection)
        -> Bool
    {
        guard connection.effectiveUserIdentifier == geteuid(), geteuid() != 0 else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: AwakeXPC.self)
        connection.exportedObject = self
        lock.withLock { connections.append(connection) }
        connection.activate()
        return true
    }

    func request(_ data: Data, reply: @escaping @Sendable (Data) -> Void) {
        guard data == Data("signed-xpc-probe".utf8) else { return }
        reply(Data("probe:\(getpid()):\(geteuid())".utf8))
    }
}

enum ProbeResult: Sendable {
    case reply(Data)
    case refused(String, Int)
    case timeout
}

@main struct Probe {
    @MainActor static func exchange(_ connection: NSXPCConnection) async -> ProbeResult {
        await withCheckedContinuation { continuation in
            let pending = OSAllocatedUnfairLock(initialState: Optional(continuation))
            let finish: @Sendable (ProbeResult) -> Void = { result in
                let current = pending.withLock { value in
                    defer { value = nil }
                    return value
                }
                current?.resume(returning: result)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { finish(.timeout) }
            guard
                let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable error in
                    let error = error as NSError
                    finish(.refused(error.domain, error.code))
                }) as? any AwakeXPC
            else {
                finish(.refused("Probe", -1))
                return
            }
            proxy.request(Data("signed-xpc-probe".utf8)) { finish(.reply($0)) }
        }
    }

    @MainActor static func verifyAdmission(identity: SignedIdentity, wrongPin: String) async throws
    {
        let correct = try identity.requirement(for: AwakeIdentity.commandLine)
        for (name, requirement, expectedCount) in [
            ("matching", correct, 1),
            (
                "wrong-pin",
                correct.replacingOccurrences(of: identity.certificateFingerprint, with: wrongPin), 0
            ),
            ("wrong-id", try identity.requirement(for: AwakeIdentity.application), 0),
        ] {
            let server = ProbeServer(requirement: requirement)
            let listener = NSXPCListener.anonymous()
            listener.setConnectionCodeSigningRequirement(requirement)
            listener.delegate = server
            listener.activate()
            let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
            connection.setCodeSigningRequirement(correct)
            connection.remoteObjectInterface = NSXPCInterface(with: AwakeXPC.self)
            connection.activate()
            let result = await exchange(connection)
            connection.invalidate()
            listener.invalidate()
            guard server.admissionCount == expectedCount else {
                print(
                    "FAIL admission \(name): delegate ran \(server.admissionCount) times, expected \(expectedCount)"
                )
                exit(1)
            }
            switch result {
            case .reply(let data):
                guard expectedCount == 1, data == Data("probe:\(getpid()):\(geteuid())".utf8) else {
                    exit(1)
                }
            case .refused(let domain, let code):
                guard expectedCount == 0, domain == NSCocoaErrorDomain,
                    [NSXPCConnectionInterrupted, NSXPCConnectionInvalid].contains(code)
                else { exit(1) }
            case .timeout:
                print("FAIL admission \(name): timeout")
                exit(1)
            }
            print("PASS admission \(name): delegate ran \(expectedCount) times")
        }
    }

    static func main() async {
        do {
            guard geteuid() != 0, let identifier = Bundle.main.bundleIdentifier else {
                throw CocoaError(.coderValueNotFound)
            }
            let identity: SignedIdentity
            if identifier == AwakeIdentity.helper {
                identity = try SignedIdentity(expectedIdentifier: identifier)
            } else {
                identity = try await SignedIdentity.current(expectedIdentifier: identifier)
            }
            let mode =
                Bundle.main.object(forInfoDictionaryKey: "AwakeProbeCase") as? String ?? "valid"
            let wrongPin =
                (identity.certificateFingerprint.first == "0" ? "1" : "0")
                + identity.certificateFingerprint.dropFirst()
            if identifier == AwakeIdentity.helper {
                var requirement = try identity.requirement(for: AwakeIdentity.commandLine)
                if mode == "reject-client-pin" {
                    requirement = requirement.replacingOccurrences(
                        of: identity.certificateFingerprint, with: wrongPin)
                } else if mode == "reject-client-id" {
                    requirement = try identity.requirement(for: AwakeIdentity.application)
                }
                let server = ProbeServer(requirement: requirement)
                let listener = NSXPCListener.service()
                listener.delegate = server
                DispatchQueue.global().asyncAfter(deadline: .now() + 8) { exit(0) }
                withExtendedLifetime(server) { listener.resume() }
                return
            }
            if mode == "valid" { try await verifyAdmission(identity: identity, wrongPin: wrongPin) }
            let connection = NSXPCConnection(serviceName: AwakeIdentity.helper)
            var requirement = try identity.requirement(for: AwakeIdentity.helper)
            if mode == "reject-server-pin" {
                requirement = requirement.replacingOccurrences(
                    of: identity.certificateFingerprint, with: wrongPin)
            } else if mode == "reject-server-id" {
                requirement = try identity.requirement(for: AwakeIdentity.application)
            }
            connection.setCodeSigningRequirement(requirement)
            connection.remoteObjectInterface = NSXPCInterface(with: AwakeXPC.self)
            connection.activate()
            let result = await exchange(connection)
            connection.invalidate()
            switch result {
            case .reply(let data):
                let parts = String(decoding: data, as: UTF8.self).split(separator: ":")
                guard mode == "valid", parts.count == 3, parts[0] == "probe",
                    let peerPID = Int32(parts[1]), peerPID > 0, peerPID != getpid(),
                    UInt32(parts[2]) == geteuid()
                else { exit(1) }
                print("PASS valid: authenticated reply from distinct non-root PID \(peerPID)")
            case .refused(let domain, let code):
                let expectedCodes =
                    mode.hasPrefix("reject-server")
                    ? [NSXPCConnectionCodeSigningRequirementFailure]
                    : [NSXPCConnectionInterrupted, NSXPCConnectionInvalid]
                guard mode != "valid", domain == NSCocoaErrorDomain,
                    expectedCodes.contains(code)
                else {
                    print("FAIL \(mode): XPC error \(code)")
                    exit(1)
                }
                print("PASS \(mode): XPC invalidated the mismatched connection (\(code))")
            case .timeout:
                print("FAIL \(mode): timeout is not evidence of authentication refusal")
                exit(1)
            }
        } catch {
            print("FAIL probe: \(error)")
            exit(1)
        }
    }
}

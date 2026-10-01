import AwakeCore
import Foundation
import os

public actor ServiceClient {
    private let lifetime: ConnectionLifetime
    private var connection: NSXPCConnection { lifetime.connection }
    private var closed = false

    public init(role: ClientRole, sudo: Bool = false) async throws {
        guard !sudo || role == .application else { throw ServiceError.unauthorized }
        let isApp = role == .application
        let identity = try await SignedIdentity.current(
            expectedIdentifier:
                isApp ? AwakeIdentity.application : AwakeIdentity.commandLine)
        let connection = NSXPCConnection(
            machServiceName:
                sudo
                ? AwakeIdentity.sudoService
                : (isApp ? AwakeIdentity.controlService : AwakeIdentity.taskService),
            options: .privileged)
        connection.setCodeSigningRequirement(
            try identity.requirement(
                for: sudo ? AwakeIdentity.sudoHelper : AwakeIdentity.helper))
        connection.remoteObjectInterface = NSXPCInterface(with: AwakeXPC.self)
        connection.interruptionHandler = { [weak connection] in connection?.invalidate() }
        lifetime = ConnectionLifetime(connection)
        connection.activate()
    }

    public func close() {
        closed = true
        connection.invalidate()
    }

    public func send(_ operation: ServiceOperation) async throws -> ServiceReply {
        try Task.checkCancellation()
        guard !closed else { throw ServiceError.unavailable }
        let payload = try ServiceWire.encode(ServiceRequest(operation))
        do {
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                let pending = OSAllocatedUnfairLock(
                    initialState:
                        CheckedContinuation<Data, any Error>?(continuation))
                let finish: @Sendable (Result<Data, any Error>) -> Void = { result in
                    let continuation = pending.withLock { value in
                        defer { value = nil }
                        return value
                    }
                    continuation?.resume(with: result)
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                    finish(.failure(ServiceError.unavailable))
                }
                guard
                    let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                        finish(.failure(ServiceError.unavailable))
                    }) as? any AwakeXPC
                else {
                    finish(.failure(ServiceError.unavailable))
                    return
                }
                proxy.request(payload) { finish(.success($0)) }
            }
            try Task.checkCancellation()
            let reply = try ServiceWire.decodeReply(data)
            if let error = reply.error { throw error }
            return reply
        } catch {
            if error as? ServiceError == .unavailable || !(error is ServiceError) {
                close()
            }
            throw error
        }
    }
}

final class ConnectionLifetime {
    let connection: NSXPCConnection

    init(_ connection: NSXPCConnection) { self.connection = connection }

    deinit { connection.invalidate() }
}

import AwakeCore
import AwakeSystem
import Darwin
import Foundation
import os

@main
struct AwakeSudoHelper {
    static func main() {
        do {
            guard geteuid() == 0 else { throw ServiceError.unauthorized }
            let identity = try SignedIdentity(expectedIdentifier: AwakeIdentity.sudoHelper)
            let server = SudoServer(identity: identity)
            try server.start()
            withExtendedLifetime(server) { dispatchMain() }
        } catch { exit(1) }
    }
}

private final class SudoServer: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let identity: SignedIdentity
    private let listener = NSXPCListener(machServiceName: AwakeIdentity.sudoService)
    private let queue = DispatchQueue(label: AwakeIdentity.sudoHelper)
    private let pending = OSAllocatedUnfairLock(initialState: 0)
    private var connections: [UUID: NSXPCConnection] = [:]
    private var files: InstalledHelperFiles?
    private var closing = false

    init(identity: SignedIdentity) { self.identity = identity }

    func start() throws {
        listener.setConnectionCodeSigningRequirement(
            try identity.requirement(for: AwakeIdentity.application))
        listener.delegate = self
        listener.activate()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection)
        -> Bool
    {
        guard connection.effectiveUserIdentifier != 0,
            connection.effectiveUserIdentifier == ConsoleUser.identifier(),
            let requirement = try? identity.requirement(for: AwakeIdentity.application)
        else { return false }
        connection.setCodeSigningRequirement(requirement)
        let owner = UUID()
        guard
            queue.sync(execute: {
                guard connections.count < 8 else { return false }
                connections[owner] = connection
                return true
            })
        else { return false }
        connection.exportedInterface = NSXPCInterface(with: AwakeXPC.self)
        connection.exportedObject = SudoEndpoint(server: self, owner: owner)
        connection.invalidationHandler = { [weak self] in self?.disconnect(owner) }
        connection.interruptionHandler = { [weak connection] in connection?.invalidate() }
        connection.activate()
        return true
    }

    func submit(_ data: Data, owner: UUID, reply: @escaping @Sendable (Data) -> Void) {
        guard
            pending.withLock({ value in
                guard value < 8, data.count <= 1_024 else { return false }
                value += 1
                return true
            })
        else {
            reply(Self.encode(ServiceReply(error: .capacityReached)))
            return
        }
        queue.async { [self] in
            defer { pending.withLock { $0 -= 1 } }
            do {
                guard let connection = connections[owner],
                    connection.effectiveUserIdentifier == ConsoleUser.identifier()
                else { throw ServiceError.unauthorized }
                let operation = try ServiceWire.decodeRequest(data).operation
                try SudoTouchID.validateOperation(operation)
                switch operation {
                case .status: break
                case .setSudoTouchID(let enabled):
                    guard !closing else { throw ServiceError.removalInProgress }
                    try SudoTouchID.setEnabled(enabled)
                case .prepareRemoval, .prepareUpdate:
                    closing = true
                    if operation == .prepareRemoval { try SudoTouchID.removeOwnedSetting() }
                    if files == nil {
                        files = try InstalledHelperFiles(identity: identity, kind: .sudo)
                    }
                    guard files != nil else { throw ServiceError.sudoTouchIDFailed }
                case .finishRemoval:
                    guard closing, let files else { throw ServiceError.removalInProgress }
                    try files.remove()
                default: throw ServiceError.unauthorized
                }
                reply(Self.encode(ServiceReply(sudoTouchID: SudoTouchID.status())))
            } catch {
                reply(
                    Self.encode(ServiceReply(error: (error as? ServiceError) ?? .sudoTouchIDFailed))
                )
            }
        }
    }

    private func disconnect(_ owner: UUID) {
        queue.async { [self] in
            connections.removeValue(forKey: owner)
            queue.asyncAfter(deadline: .now() + 1) { [self] in
                if connections.isEmpty { exit(0) }
            }
        }
    }

    private static func encode(_ reply: ServiceReply) -> Data {
        (try? ServiceWire.encode(reply)) ?? Data()
    }
}

private final class SudoEndpoint: NSObject, AwakeXPC {
    let server: SudoServer
    let owner: UUID
    init(server: SudoServer, owner: UUID) {
        self.server = server
        self.owner = owner
    }
    func request(_ data: Data, reply: @escaping @Sendable (Data) -> Void) {
        server.submit(data, owner: owner, reply: reply)
    }
}

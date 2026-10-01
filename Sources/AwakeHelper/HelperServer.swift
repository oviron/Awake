import AwakeCore
import AwakeSystem
import Darwin
import Foundation
import IOKit.ps
import notify
import os

final class HelperServer: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.oviron.Awake.helper")
    private let pending = OSAllocatedUnfairLock(initialState: 0)
    private let logger = Logger(subsystem: AwakeIdentity.helper, category: "service")
    private let identity: SignedIdentity
    private let control = NSXPCListener(machServiceName: AwakeIdentity.controlService)
    private let tasks = NSXPCListener(machServiceName: AwakeIdentity.taskService)
    private var runtime: HelperRuntime?
    private var connections: [UUID: NSXPCConnection] = [:]
    private var watchdog: (any DispatchSourceTimer)?
    private var signals: [any DispatchSourceSignal] = []
    private var notificationTokens: [Int32] = []
    private var stoppingAt: TimeInterval?

    init(identity: SignedIdentity) {
        self.identity = identity
        super.init()
    }

    func start() throws {
        control.setConnectionCodeSigningRequirement(
            try identity.requirement(for: AwakeIdentity.application))
        tasks.setConnectionCodeSigningRequirement(
            try identity.requirement(for: AwakeIdentity.commandLine))
        try queue.sync { runtime = try HelperRuntime(identity: identity) }
        control.delegate = self
        tasks.delegate = self
        queue.sync {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .seconds(2), leeway: .milliseconds(250))
            timer.setEventHandler { [weak self] in self?.tick() }
            watchdog = timer
            timer.resume()
            for name in [kIOPSNotifyPowerSource, kIOPSTimeRemainingNotificationKey] {
                var token: Int32 = 0
                if notify_register_dispatch(name, &token, queue, { [weak self] _ in self?.tick() })
                    == 0
                {
                    notificationTokens.append(token)
                } else {
                    logger.error("Power notification unavailable; watchdog remains active.")
                }
            }
            for number in [SIGTERM, SIGINT] {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
                source.setEventHandler { [weak self] in self?.beginShutdown() }
                signals.append(source)
                source.resume()
            }
        }
        control.activate()
        tasks.activate()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection)
        -> Bool
    {
        let role: ClientRole = listener === control ? .application : .task
        let identifier =
            role == .application ? AwakeIdentity.application : AwakeIdentity.commandLine
        guard let requirement = try? identity.requirement(for: identifier),
            connection.effectiveUserIdentifier != 0,
            connection.effectiveUserIdentifier == ConsoleUser.identifier()
        else { return false }
        connection.setCodeSigningRequirement(requirement)
        let owner = UUID()
        let accepted = queue.sync {
            guard stoppingAt == nil, let runtime,
                connections.count < ServiceSessions.clientCapacity
            else { return false }
            do {
                _ = try runtime.reconcile(owner: owner)
                try runtime.sessions.connect(
                    owner: owner, user: connection.effectiveUserIdentifier,
                    role: role, now: SystemClock.now())
                connections[owner] = connection
                return true
            } catch { return false }
        }
        guard accepted else { return false }
        connection.exportedInterface = NSXPCInterface(with: AwakeXPC.self)
        connection.exportedObject = Endpoint(server: self, owner: owner)
        connection.invalidationHandler = { [weak self] in self?.disconnect(owner) }
        connection.interruptionHandler = { [weak connection] in connection?.invalidate() }
        connection.activate()
        return true
    }

    func submit(_ data: Data, owner: UUID, reply: @escaping @Sendable (Data) -> Void) {
        let admitted = pending.withLock { count in
            guard count < ServiceSessions.clientCapacity,
                data.count <= ServiceWire.maximumMessageBytes
            else { return false }
            count += 1
            return true
        }
        guard admitted else {
            reply(Self.encode(ServiceReply(error: .capacityReached)))
            return
        }
        queue.async { [self] in
            defer { pending.withLock { $0 -= 1 } }
            guard stoppingAt == nil, let runtime, connections[owner] != nil else {
                reply(Self.encode(ServiceReply(error: .ownerExpired)))
                return
            }
            reply(Self.encode(runtime.request(data, owner: owner)))
            pruneExpired()
        }
    }

    private func disconnect(_ owner: UUID) {
        queue.async { [self] in
            connections.removeValue(forKey: owner)
            runtime?.sessions.disconnect(owner)
            tick()
        }
    }

    private func pruneExpired() {
        guard let runtime else { return }
        for owner in runtime.takeExpiredOwners() {
            connections.removeValue(forKey: owner)?.invalidate()
        }
    }

    private func tick() {
        guard let runtime else { return }
        do {
            _ = try runtime.reconcile(owner: UUID())
            pruneExpired()
            if let stoppingAt {
                if !runtime.controller.ownsGlobalHold { exit(0) }
                if ProcessInfo.processInfo.systemUptime - stoppingAt >= 12 {
                    logger.fault(
                        "Shutdown could not confirm restoration; ownership journal retained.")
                    exit(1)
                }
            }
        } catch { logger.fault("Cannot reconcile power state; no successful state is reported.") }
    }

    private func beginShutdown() {
        guard stoppingAt == nil else { return }
        stoppingAt = ProcessInfo.processInfo.systemUptime
        control.invalidate()
        tasks.invalidate()
        try? runtime?.sessions.revokeAutomationAndStop()
        runtime?.controller.retryRestoration()
        for connection in connections.values { connection.invalidate() }
        connections.removeAll()
        tick()
    }

    private static func encode(_ reply: ServiceReply) -> Data {
        (try? ServiceWire.encode(reply))
            ?? Data("{\"version\":\(ServiceWire.version),\"error\":\"unavailable\"}".utf8)
    }
}

private final class Endpoint: NSObject, AwakeXPC {
    let server: HelperServer
    let owner: UUID
    init(server: HelperServer, owner: UUID) {
        self.server = server
        self.owner = owner
    }
    func request(_ data: Data, reply: @escaping @Sendable (Data) -> Void) {
        server.submit(data, owner: owner, reply: reply)
    }
}

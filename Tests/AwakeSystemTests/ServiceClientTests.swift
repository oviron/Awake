import Foundation
import Testing

@testable import AwakeSystem

private final class InvalidationProbe: NSXPCConnection {
    var invalidated = false

    override func invalidate() {
        invalidated = true
        super.invalidate()
    }
}

@Test func droppingConnectionOwnerInvalidatesWithoutExplicitClose() {
    let connection = InvalidationProbe(
        machServiceName: "io.github.oviron.Awake.test-unregistered")
    var lifetime: ConnectionLifetime? = ConnectionLifetime(connection)
    #expect(lifetime?.connection === connection)
    #expect(!connection.invalidated)
    lifetime = nil
    #expect(connection.invalidated)
}

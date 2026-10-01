import AwakeSystem
import Darwin
import Foundation
import os

@main
struct AwakeHelper {
    static func main() {
        do {
            guard geteuid() == 0 else { throw JournalError.administratorRequired }
            let identity = try SignedIdentity(expectedIdentifier: AwakeIdentity.helper)
            let server = HelperServer(identity: identity)
            try server.start()
            withExtendedLifetime(server) { dispatchMain() }
        } catch {
            Logger(subsystem: AwakeIdentity.helper, category: "startup")
                .fault(
                    "Helper startup refused: identity or protected state could not be validated.")
            exit(1)
        }
    }
}

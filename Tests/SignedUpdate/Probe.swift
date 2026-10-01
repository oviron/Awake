import AwakeSystem
import Foundation

@main enum UpdateProbe {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 2, geteuid() != 0 else { exit(64) }
        let candidate = URL(fileURLWithPath: arguments[1])
        let current = Bundle.main.bundleURL
        let identity = try SignedIdentity(expectedIdentifier: AwakeIdentity.application)
        if arguments[0] == "reject-installed-build" {
            let finishedParent = Process()
            finishedParent.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            try finishedParent.run()
            finishedParent.waitUntilExit()
            do {
                _ = try await GitHubUpdate.finish(
                    app: candidate, parentPID: finishedParent.processIdentifier)
                exit(1)
            } catch UpdateError.unsafeLocation {}
            print("PASS signed update \(arguments[0])")
            return
        }
        if arguments[0] == "replace" {
            let finishedParent = Process()
            finishedParent.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            try finishedParent.run()
            finishedParent.waitUntilExit()
            let installed = try await GitHubUpdate.finish(
                app: candidate, parentPID: finishedParent.processIdentifier)
            let expected = candidate.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Awake.app", isDirectory: true)
            guard installed.app == expected, installed.app != current else { exit(1) }
            let info =
                try PropertyListSerialization.propertyList(
                    from: Data(
                        contentsOf: installed.app.appendingPathComponent("Contents/Info.plist")),
                    format: nil) as? [String: Any]
            guard info?["CFBundleShortVersionString"] as? String == "0.2.0" else { exit(1) }
            _ = try FileManager.default.replaceItemAt(
                installed.app, withItemAt: installed.backup, options: .usingNewMetadataOnly)
            let restored =
                try PropertyListSerialization.propertyList(
                    from: Data(
                        contentsOf: installed.app.appendingPathComponent("Contents/Info.plist")),
                    format: nil) as? [String: Any]
            guard restored?["CFBundleShortVersionString"] as? String == "0.1.0" else { exit(1) }
            try FileManager.default.removeItem(at: installed.staging)
        } else {
            var accepted = false
            do {
                try GitHubUpdate.verify(
                    candidate, identity: identity, newerThan: current,
                    expectedSourceRevision: String(
                        repeating: arguments[0] == "reject-revision" ? "1" : "0", count: 40))
                accepted = true
            } catch {}
            guard accepted == (arguments[0] == "accept") else { exit(1) }
        }
        print("PASS signed update \(arguments[0])")
    }
}

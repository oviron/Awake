import Foundation

struct ProbeFailure: Error { let message: String }

func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        throw ProbeFailure(message: "Failed: " + executable)
    }
}

func main() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard geteuid() != 0, arguments.count == 2,
        arguments[0].utf8.count == 40,
        arguments[0].utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        })
    else {
        throw ProbeFailure(
            message:
                "Usage: swift Tests/SignedXPC/Run.swift CERT_SHA1 NEW_OUTPUT_DIRECTORY (non-root)")
    }
    let files = FileManager.default
    let certificate = arguments[0]
    let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
    guard mkdir(root.path, 0o700) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let binary = root.appendingPathComponent("Probe")
    try run(
        "/usr/bin/xcrun",
        [
            "swiftc", "-parse-as-library", "-swift-version", "6", "-warnings-as-errors",
            "Sources/AwakeSystem/SignedConnection.swift", "Tests/SignedXPC/Probe.swift",
            "-o", binary.path,
        ])
    for mode in [
        "valid", "reject-client-pin", "reject-server-pin", "reject-client-id", "reject-server-id",
    ] {
        let app = root.appendingPathComponent(mode + ".app")
        let service = app.appendingPathComponent(
            "Contents/XPCServices/io.github.oviron.Awake.helper.xpc")
        for (bundle, identifier, package) in [
            (app, "io.github.oviron.Awake.cli", "APPL"),
            (service, "io.github.oviron.Awake.helper", "XPC!"),
        ] {
            let contents = bundle.appendingPathComponent("Contents")
            try files.createDirectory(
                at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            try files.copyItem(at: binary, to: contents.appendingPathComponent("MacOS/Probe"))
            var info: [String: Any] = [
                "CFBundleIdentifier": identifier, "CFBundleExecutable": "Probe",
                "CFBundlePackageType": package,
                "CFBundleVersion": "1", "CFBundleShortVersionString": "0.1.0",
                "LSMinimumSystemVersion": "14.0",
                "AwakeProbeCase": mode,
            ]
            if package == "XPC!" {
                info["XPCService"] = ["ServiceType": "Application", "RunLoopType": "NSRunLoop"]
            } else {
                info["LSUIElement"] = true
            }
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(
                    to: contents.appendingPathComponent("Info.plist"), options: .withoutOverwriting)
        }
        for (bundle, identifier) in [
            (service, "io.github.oviron.Awake.helper"),
            (app, "io.github.oviron.Awake.cli"),
        ] {
            try run(
                "/usr/bin/codesign",
                [
                    "--force", "--sign", certificate, "--options", "runtime", "--timestamp=none",
                    "--requirements",
                    "=designated => identifier \"\(identifier)\" and anchor = H\"\(certificate)\"",
                    bundle.path,
                ])
        }
        try run("/usr/bin/codesign", ["--verify", "--strict", "--deep", app.path])
        try run(app.appendingPathComponent("Contents/MacOS/Probe").path, [])
    }
    print(
        "Five signed cross-process cases and three listener admission cases passed. No privileged service was installed."
    )
}

do { try main() } catch {
    FileHandle.standardError.write(Data("Signed XPC test stopped: \(error)\n".utf8))
    exit(1)
}

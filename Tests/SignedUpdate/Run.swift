import Foundation

func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        throw CocoaError(.executableRuntimeMismatch)
    }
}

func main() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count == 4, geteuid() != 0, args[0].count == 40,
        args[0].utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        })
    else {
        print(
            "Usage: swift Tests/SignedUpdate/Run.swift CERT_SHA1 DEBUG_PRODUCTS_DIR TEMPLATE_APP NEW_OUTPUT_DIRECTORY"
        )
        exit(64)
    }
    let files = FileManager.default
    let root = URL(fileURLWithPath: args[3]).resolvingSymlinksInPath()
    guard mkdir(root.path, 0o700) == 0 else { throw CocoaError(.fileWriteFileExists) }
    let probe = root.appendingPathComponent("probe")
    try run(
        "/usr/bin/xcrun",
        [
            "swiftc", "-parse-as-library", "-swift-version", "6", "-warnings-as-errors",
            "-profile-generate", "-I",
            args[1], "-L", args[1], "-lAwakeSystem", "-lAwakeCore",
            "Tests/SignedUpdate/Probe.swift", "-o", probe.path,
        ])
    let current = root.appendingPathComponent("Awake.app")
    let staging = root.appendingPathComponent(".Awake-update-\(UUID().uuidString)")
    try files.createDirectory(
        at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let candidate = staging.appendingPathComponent("Awake.app")
    let certificate = args[0]
    func sign(_ app: URL, certificate: String) throws {
        func requirements(for identifier: String) -> [String] {
            certificate == "-"
                ? []
                : [
                    "--requirements",
                    "=designated => identifier \"\(identifier)\" and anchor = H\"\(certificate)\"",
                ]
        }
        let plist =
            try PropertyListSerialization.propertyList(
                from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
                format: nil) as! [String: Any]
        let helper =
            plist["AwakeHelperInstallation"] as? String == "blessed"
            ? "Contents/Library/LaunchServices/io.github.oviron.Awake.helper"
            : "Contents/Library/HelperTools/AwakeHelper"
        for (path, identifier) in [
            ("Contents/MacOS/awake", "io.github.oviron.Awake.cli"),
            (
                helper,
                "io.github.oviron.Awake.helper"
            ),
            (
                "Contents/Helpers/Awake Sudo.app/Contents/Library/LaunchServices/io.github.oviron.Awake.sudo.helper",
                "io.github.oviron.Awake.sudo.helper"
            ),
            ("Contents/Helpers/Awake Sudo.app", "io.github.oviron.Awake.sudo"),
        ] {
            try run(
                "/usr/bin/codesign",
                [
                    "--force", "--sign", certificate, "--options", "runtime", "--timestamp=none",
                    "--identifier", identifier,
                ] + requirements(for: identifier) + [app.appendingPathComponent(path).path])
        }
        try run(
            "/usr/bin/codesign",
            [
                "--force", "--sign", certificate, "--options", "runtime", "--timestamp=none",
            ] + requirements(for: "io.github.oviron.Awake") + [app.path])
    }
    func setVersion(_ app: URL, _ version: String) throws {
        let path = app.appendingPathComponent("Contents/Info.plist")
        var info =
            try PropertyListSerialization.propertyList(from: Data(contentsOf: path), format: nil)
            as! [String: Any]
        guard let kind = info["AwakeHelperInstallation"] as? String,
            ["bundled", "blessed"].contains(kind)
        else {
            throw CocoaError(.executableLoad)
        }
        info["CFBundleShortVersionString"] = version
        info.removeValue(forKey: "AwakePreviewState")
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(
            to: path)
    }
    try files.copyItem(at: URL(fileURLWithPath: args[2]), to: current)
    try files.copyItem(at: URL(fileURLWithPath: args[2]), to: candidate)
    try files.removeItem(at: current.appendingPathComponent("Contents/MacOS/AwakeApp"))
    try files.copyItem(at: probe, to: current.appendingPathComponent("Contents/MacOS/AwakeApp"))
    try setVersion(current, "0.1.0")
    try setVersion(candidate, "0.2.0")
    let record: [String: Any] = [
        "configuration": "release", "sourceClean": true,
        "sourceRevision": String(repeating: "0", count: 40),
    ]
    let recordURL = candidate.appendingPathComponent("Contents/Resources/Build.json")
    try JSONSerialization.data(withJSONObject: record).write(to: recordURL)
    try sign(current, certificate: certificate)
    try sign(candidate, certificate: certificate)
    let launched = root.appendingPathComponent("LaunchedElsewhere.app")
    try files.copyItem(at: current, to: launched)
    let executable = launched.appendingPathComponent("Contents/MacOS/AwakeApp").path
    try run(executable, ["accept", candidate.path])
    try run(executable, ["reject-revision", candidate.path])
    try Data("tampered".utf8).write(to: recordURL)
    try run(executable, ["reject", candidate.path])
    try JSONSerialization.data(withJSONObject: record).write(to: recordURL)
    try sign(candidate, certificate: "-")
    try run(executable, ["reject", candidate.path])
    try setVersion(candidate, "0.1.0")
    try sign(candidate, certificate: certificate)
    try run(executable, ["reject", candidate.path])
    try setVersion(candidate, "0.2.0")
    try sign(candidate, certificate: certificate)
    let currentRecordURL = current.appendingPathComponent("Contents/Resources/Build.json")
    let currentRecord = try Data(contentsOf: currentRecordURL)
    let changedRecord = try Data(contentsOf: recordURL)
    guard currentRecord != changedRecord else { throw CocoaError(.fileReadCorruptFile) }
    try changedRecord.write(to: currentRecordURL)
    try sign(current, certificate: certificate)
    try run(executable, ["reject-installed-build", candidate.path])
    try currentRecord.write(to: currentRecordURL)
    try sign(current, certificate: certificate)
    try run(executable, ["replace", candidate.path])
    print(
        "Signed upgrade acceptance, revision mismatch/tampering/ad-hoc/downgrade refusal and atomic replacement passed. No installed app was changed."
    )
}

do { try main() } catch {
    FileHandle.standardError.write(Data("Signed update fixture failed: \(error)\n".utf8))
    exit(1)
}

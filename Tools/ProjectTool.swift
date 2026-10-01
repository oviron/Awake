import CryptoKit
import Foundation
import MachO
import Security

func run(
    _ executable: String, _ arguments: [String], capture: Bool = false, saveOutput: URL? = nil,
    environment: [String: String]? = nil
)
    throws -> String
{
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = environment ?? ProcessInfo.processInfo.environment
    let pipe = capture ? Pipe() : nil
    if let pipe { process.standardOutput = pipe }
    if !capture { print("\(executable) \(arguments.joined(separator: " "))") }
    try process.run()
    let data = pipe?.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    if let saveOutput, let data { try data.write(to: saveOutput, options: .withoutOverwriting) }
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        throw NSError(
            domain: "Awake.ProjectTool", code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "Check failed: \(executable)"])
    }
    return data.map {
        String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
        ?? ""
}

func require(_ condition: Bool, _ message: String) throws {
    guard condition else {
        throw NSError(
            domain: "Awake.ProjectTool", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
    }
}

func matches(_ value: String, _ pattern: String) -> Bool {
    value.range(of: "\\A(?:" + pattern + ")\\z", options: .regularExpression) != nil
}

func propertyList(_ path: URL) throws -> [String: Any] {
    let value = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: path), format: nil)
    guard let dictionary = value as? [String: Any] else {
        throw CocoaError(.propertyListReadCorrupt)
    }
    return dictionary
}

func writeHelperMetadata(
    helper: [String: Any], daemon: [String: Any], to directory: URL
) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    for (name, value) in [
        ("HelperInfo.plist", helper), ("HelperLaunchd.plist", daemon),
    ] {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
            .write(to: directory.appendingPathComponent(name), options: .withoutOverwriting)
    }
}

func cleanRevision() throws -> String {
    try require(
        try run("/usr/bin/git", ["status", "--porcelain", "--untracked-files=all"], capture: true)
            .isEmpty,
        "Release signing requires a clean, committed worktree.")
    let revision = try run("/usr/bin/git", ["rev-parse", "--verify", "HEAD"], capture: true)
    try require(matches(revision, "[0-9a-f]{40}"), "Expected a full Git source revision.")
    return revision
}

struct BuildRecord: Codable, Equatable {
    let sourceRevision: String
    let configuration: String
    let sourceClean: Bool
}

enum ReleaseIdentity {
    case developerID(team: String)
    case community(certificate: String)

    var helperPath: String {
        switch self {
        case .developerID: "Library/HelperTools/AwakeHelper"
        case .community: "Library/LaunchServices/io.github.oviron.Awake.helper"
        }
    }

    var installationKind: String {
        switch self {
        case .developerID: "bundled"
        case .community: "blessed"
        }
    }

    func requirement(identifier: String) throws -> SecRequirement {
        switch self {
        case .developerID(let team):
            return try developerRequirement(identifier: identifier, team: team)
        case .community(let certificate):
            let value = try certificateRequirement(identifier: identifier, certificate: certificate)
            var requirement: SecRequirement?
            try require(
                SecRequirementCreateWithString(value as CFString, [], &requirement)
                    == errSecSuccess,
                "Could not parse the certificate requirement.")
            guard let requirement else { throw CocoaError(.coderValueNotFound) }
            return requirement
        }
    }
}

func certificateRequirement(identifier: String, certificate: String) throws -> String {
    try require(
        [
            "io.github.oviron.Awake", "io.github.oviron.Awake.cli",
            "io.github.oviron.Awake.helper",
            "io.github.oviron.Awake.sudo", "io.github.oviron.Awake.sudo.helper",
        ].contains(identifier)
            && matches(certificate, "[A-Fa-f0-9]{40}"), "Invalid certificate identity.")
    return "identifier \"\(identifier)\" and certificate leaf = H\"\(certificate.lowercased())\""
}

func communityDesignatedRequirement(identifier: String, certificate: String) throws -> String {
    _ = try certificateRequirement(identifier: identifier, certificate: certificate)
    return "identifier \"\(identifier)\" and anchor = H\"\(certificate.lowercased())\""
}

func communityMetadata(info: [String: Any], certificate: String?, sudo: Bool = false) throws
    -> (app: [String: Any], helper: [String: Any], daemon: [String: Any])
{
    let identifier = "io.github.oviron.Awake" + (sudo ? ".sudo" : "")
    guard let version = info["CFBundleShortVersionString"] as? String,
        let build = info["CFBundleVersion"] as? String
    else { throw CocoaError(.coderValueNotFound) }
    try require(
        matches(version, "(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)")
            && matches(build, "[1-9][0-9]*")
            && info["CFBundleIdentifier"] as? String == identifier,
        "Invalid helper metadata version or identity.")
    let appRequirement =
        try certificate.map { try certificateRequirement(identifier: identifier, certificate: $0) }
        ?? "false"
    let helperRequirement =
        try certificate.map {
            try certificateRequirement(identifier: identifier + ".helper", certificate: $0)
        } ?? "false"
    var app = info
    app["AwakeHelperInstallation"] = "blessed"
    app["SMPrivilegedExecutables"] = [identifier + ".helper": helperRequirement]
    let helper: [String: Any] = [
        "CFBundleIdentifier": identifier + ".helper",
        "CFBundleName": sudo ? "Awake — Touch ID for sudo" : "Awake Helper",
        "CFBundleVersion": build, "CFBundleShortVersionString": version,
        "SMAuthorizedClients": [appRequirement],
    ]
    var daemon =
        sudo
        ? [
            "Label": identifier + ".helper", "UserName": "root",
            "MachServices": [identifier + ".control": true],
        ]
        : try propertyList(URL(fileURLWithPath: "Packaging/" + identifier + ".helper.plist"))
    daemon.removeValue(forKey: "BundleProgram")
    daemon.removeValue(forKey: "ProgramArguments")
    try require(
        daemon["Program"] == nil && daemon["Label"] as? String == identifier + ".helper",
        "SMJobBless must assign the installed program itself.")
    if !sudo {
        try require(
            daemon["ProcessType"] as? String == "Adaptive",
            "The power helper must become responsive while serving XPC requests.")
    }
    return (app, helper, daemon)
}

func embeddedPropertyList(_ data: Data, section name: String) throws -> [String: Any] {
    func read<T>(_ offset: Int, as type: T.Type) throws -> T {
        try require(
            offset >= 0 && offset <= data.count && MemoryLayout<T>.size <= data.count - offset,
            "Truncated Mach-O metadata.")
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: type) }
    }
    func field<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
    let header = try read(0, as: mach_header_64.self)
    var offset = MemoryLayout<mach_header_64>.size
    try require(
        header.magic == MH_MAGIC_64
            && [CPU_TYPE_ARM64, CPU_TYPE_X86_64].contains(header.cputype)
            && Int(header.sizeofcmds) <= data.count - offset
            && header.ncmds <= header.sizeofcmds / UInt32(MemoryLayout<load_command>.size),
        "Expected bounded load commands in an ARM64 Mach-O executable.")
    let end = offset + Int(header.sizeofcmds)
    for _ in 0..<header.ncmds {
        let command = try read(offset, as: load_command.self)
        try require(
            command.cmdsize >= MemoryLayout<load_command>.size
                && Int(command.cmdsize) <= end - offset, "Invalid Mach-O load command.")
        if command.cmd == LC_SEGMENT_64 {
            try require(
                command.cmdsize >= MemoryLayout<segment_command_64>.size, "Truncated segment.")
            let segment = try read(offset, as: segment_command_64.self)
            try require(
                Int(segment.nsects)
                    <= (Int(command.cmdsize) - MemoryLayout<segment_command_64>.size)
                        / MemoryLayout<section_64>.size,
                "Truncated section table.")
            for index in 0..<Int(segment.nsects) {
                let section = try read(
                    offset + MemoryLayout<segment_command_64>.size + index
                        * MemoryLayout<section_64>.size, as: section_64.self)
                if field(segment.segname) == "__TEXT" && field(section.segname) == "__TEXT"
                    && field(section.sectname) == name
                {
                    let start = Int(section.offset)
                    try require(
                        start <= data.count && section.size <= UInt64(data.count - start)
                            && section.size <= 65_536, "Invalid embedded plist extent.")
                    let value = try PropertyListSerialization.propertyList(
                        from: data.subdata(in: start..<(start + Int(section.size))), format: nil)
                    guard let dictionary = value as? [String: Any] else {
                        throw CocoaError(.propertyListReadCorrupt)
                    }
                    return dictionary
                }
            }
        }
        offset += Int(command.cmdsize)
    }
    throw NSError(
        domain: "Awake.ProjectTool", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Missing embedded \(name)."])
}

func verifyCommunityMetadata(_ app: URL, certificate: String?, sudo: Bool = false) throws {
    let contents = app.appendingPathComponent("Contents")
    let info = try propertyList(contents.appendingPathComponent("Info.plist"))
    let expected = try communityMetadata(info: info, certificate: certificate, sudo: sudo)
    let helper = contents.appendingPathComponent(
        "Library/LaunchServices/io.github.oviron.Awake"
            + (sudo ? ".sudo.helper" : ".helper"))
    try require(
        NSDictionary(dictionary: info).isEqual(to: expected.app),
        "App and embedded helper metadata disagree with the signing identity.")
    let architectures = try run("/usr/bin/lipo", ["-archs", helper.path], capture: true)
        .split(separator: " ").map(String.init)
    try require(
        !architectures.isEmpty && Set(architectures).isSubset(of: ["arm64", "x86_64"]),
        "Unsupported helper architecture.")
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: temporary) }
    for architecture in architectures {
        var executable = helper
        if architectures.count > 1 {
            executable = temporary.appendingPathComponent(architecture)
            _ = try run(
                "/usr/bin/lipo", [helper.path, "-thin", architecture, "-output", executable.path])
        }
        let data = try Data(contentsOf: executable, options: .mappedIfSafe)
        try require(
            NSDictionary(dictionary: try embeddedPropertyList(data, section: "__info_plist"))
                .isEqual(to: expected.helper)
                && NSDictionary(
                    dictionary: try embeddedPropertyList(data, section: "__launchd_plist")
                )
                .isEqual(to: expected.daemon),
            "Embedded helper metadata disagrees for \(architecture).")
    }
    var code: SecStaticCode?
    var information: CFDictionary?
    try require(
        SecStaticCodeCreateWithPath(helper as CFURL, [], &code) == errSecSuccess,
        "Cannot inspect the embedded helper's signature.")
    guard let code else { throw CocoaError(.coderValueNotFound) }
    try require(
        SecCodeCopySigningInformation(
            code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
        "Cannot inspect the helper's signed metadata.")
    let details = information as? [String: Any]
    guard let securedInfo = details?[kSecCodeInfoPList as String] as? [String: Any] else {
        throw CocoaError(.coderValueNotFound)
    }
    try require(
        NSDictionary(dictionary: securedInfo).isEqual(to: expected.helper),
        "Security's embedded Info.plist differs from the release metadata.")
}

func developerRequirement(identifier: String, team: String) throws -> SecRequirement {
    try require(matches(team, "[A-Z0-9]{10}"), "Expected a ten-character Apple Team ID.")
    let value =
        "anchor apple generic and identifier \"\(identifier)\" "
        + "and certificate 1[field.1.2.840.113635.100.6.2.6] exists "
        + "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists "
        + "and certificate leaf[subject.OU] = \"\(team)\""
    var requirement: SecRequirement?
    try require(
        SecRequirementCreateWithString(value as CFString, [], &requirement) == errSecSuccess,
        "Could not parse the Developer ID requirement.")
    guard let requirement else { throw CocoaError(.coderValueNotFound) }
    return requirement
}

func verifyCode(_ path: URL, identifier: String, identity: ReleaseIdentity) throws -> Data {
    let requirement = try identity.requirement(identifier: identifier)
    var code: SecStaticCode?
    try require(
        SecStaticCodeCreateWithPath(path as CFURL, [], &code) == errSecSuccess,
        "Cannot read code signature: \(path.path)")
    guard let code else { throw CocoaError(.coderValueNotFound) }
    try require(
        SecStaticCodeCheckValidity(
            code,
            SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
            requirement) == errSecSuccess,
        "Signing identity or code integrity check failed: \(path.path)")
    var information: CFDictionary?
    try require(
        SecCodeCopySigningInformation(
            code, SecCSFlags(rawValue: kSecCSSigningInformation),
            &information) == errSecSuccess,
        "Cannot inspect signing information: \(path.path)")
    let details = information as? [String: Any] ?? [:]
    try verifySigningInformation(details, requiresTimestamp: identity.installationKind == "bundled")
    guard let certificates = details[kSecCodeInfoCertificates as String] as? [SecCertificate],
        let leaf = certificates.first
    else { throw CocoaError(.coderValueNotFound) }
    return SecCertificateCopyData(leaf) as Data
}

func verifySigningInformation(_ details: [String: Any], requiresTimestamp: Bool = true) throws {
    let flags = (details[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
    try require(
        SecCodeSignatureFlags(rawValue: flags).contains(.runtime)
            && (details[kSecCodeInfoTimestamp as String] is Date
                || (!requiresTimestamp && details[kSecCodeInfoTimestamp as String] == nil))
            && details[kSecCodeInfoEntitlements as String] == nil
            && details[kSecCodeInfoEntitlementsDict as String] == nil,
        "Release code needs hardened runtime and no entitlements; Developer ID also needs a secure timestamp."
    )
}

func verifyRelease(_ app: URL, identity: ReleaseIdentity, notarized: Bool) throws -> (
    String, BuildRecord
) {
    try require(app.lastPathComponent == "Awake.app", "Expected a Awake.app bundle.")
    let identifier = "io.github.oviron.Awake"
    let certificate = try verifyCode(app, identifier: identifier, identity: identity)
    for (relative, suffix) in [
        ("MacOS/awake", ".cli"),
        (identity.helperPath, ".helper"),
        ("Helpers/Awake Sudo.app", ".sudo"),
        (
            "Helpers/Awake Sudo.app/Contents/Library/LaunchServices/io.github.oviron.Awake.sudo.helper",
            ".sudo.helper"
        ),
    ] {
        let peerCertificate = try verifyCode(
            app.appendingPathComponent("Contents/" + relative),
            identifier: identifier + suffix, identity: identity)
        try require(
            peerCertificate == certificate,
            "App, CLI and helper must use the same signing certificate.")
    }
    _ = try run("/usr/bin/codesign", ["--verify", "--strict", "--deep", app.path])
    let contents = app.appendingPathComponent("Contents")
    let info = try propertyList(contents.appendingPathComponent("Info.plist"))
    let version = info["CFBundleShortVersionString"] as? String ?? ""
    try require(
        matches(version, "(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)")
            && info["CFBundleIdentifier"] as? String == identifier
            && info["CFBundleExecutable"] as? String == "AwakeApp"
            && info["LSMinimumSystemVersion"] as? String == "14.0",
        "Unexpected release bundle identity, version or macOS minimum.")
    try verifyCompatibility(contents, helperPath: identity.helperPath)
    try require(
        info["AwakeHelperInstallation"] as? String == identity.installationKind,
        "Release channel and installation metadata disagree.")
    if case .community(let certificate) = identity {
        try require(!notarized, "Community artifacts do not claim notarization.")
        try verifyCommunityMetadata(app, certificate: certificate)
    }
    try verifyCommunityMetadata(
        contents.appendingPathComponent("Helpers/Awake Sudo.app"),
        certificate: Insecure.SHA1.hash(data: certificate).map { String(format: "%02x", $0) }
            .joined(), sudo: true)
    let record = try JSONDecoder().decode(
        BuildRecord.self,
        from: Data(contentsOf: contents.appendingPathComponent("Resources/Build.json")))
    try require(
        record.configuration == "release" && record.sourceClean
            && matches(record.sourceRevision, "[0-9a-f]{40}"),
        "Release requires recorded, clean, committed Release sources.")
    if notarized {
        _ = try run("/usr/bin/xcrun", ["stapler", "validate", app.path])
        _ = try run("/usr/sbin/spctl", ["--assess", "--type", "execute", "--verbose=2", app.path])
    }
    return (version, record)
}

func verifyCompatibility(_ contents: URL, helperPath: String) throws {
    for relative in [
        "MacOS/AwakeApp", "MacOS/awake", helperPath,
        "Helpers/Awake Sudo.app/Contents/MacOS/AwakeSudo",
        "Helpers/Awake Sudo.app/Contents/Library/LaunchServices/io.github.oviron.Awake.sudo.helper",
    ] {
        let executable = contents.appendingPathComponent(relative)
        let architectures = try run(
            "/usr/bin/lipo", ["-archs", executable.path],
            capture: true)
        try require(
            Set(architectures.split(separator: " ")) == ["arm64", "x86_64"],
            "Releases require both Apple Silicon and Intel binaries.")
        let build = try run(
            "/usr/bin/xcrun", ["vtool", "-show-build", executable.path], capture: true)
        let minimumVersions = build.split(separator: "\n").map {
            $0.split(whereSeparator: \.isWhitespace)
        }.filter { $0.first == "minos" }
        try require(
            minimumVersions.count == 2 && minimumVersions.allSatisfy { $0 == ["minos", "14.0"] },
            "Both architectures must target macOS 14.0.")
        let sdkVersions = build.split(separator: "\n").map {
            $0.split(whereSeparator: \.isWhitespace)
        }.filter { $0.first == "sdk" }
        try require(
            sdkVersions.count == 2
                && sdkVersions.allSatisfy {
                    $0.count == 2 && (Int($0[1].split(separator: ".").first ?? "") ?? 0) >= 26
                },
            "Both architectures must identify the modern SDK used to build the app.")
    }
}

func archive(_ app: URL, to destination: URL) throws {
    try require(
        !FileManager.default.fileExists(atPath: destination.path), "Archive already exists.")
    _ = try run(
        "/usr/bin/ditto",
        ["-c", "-k", "--sequesterRsrc", "--keepParent", app.path, destination.path])
}

func selfTest(developmentApp: URL? = nil) throws {
    func rejects(_ operation: () throws -> Void) throws {
        var accepted = false
        do {
            try operation()
            accepted = true
        } catch {}
        try require(!accepted, "Self-test accepted an invalid release input.")
    }
    let digest = SHA256.hash(data: Data("abc".utf8)).map { String(format: "%02x", $0) }.joined()
    try require(
        digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        "SHA-256 self-test failed.")
    _ = try developerRequirement(identifier: "io.github.oviron.Awake", team: "0123456789")
    let signingInformation: [String: Any] = [
        kSecCodeInfoFlags as String: NSNumber(value: SecCodeSignatureFlags.runtime.rawValue),
        kSecCodeInfoTimestamp as String: Date(timeIntervalSince1970: 0),
    ]
    try verifySigningInformation(signingInformation)
    for key in [kSecCodeInfoFlags, kSecCodeInfoTimestamp] {
        var incomplete = signingInformation
        incomplete.removeValue(forKey: key as String)
        try rejects { try verifySigningInformation(incomplete) }
    }
    for (key, value) in [
        (kSecCodeInfoFlags, NSNumber(value: 0) as Any),
        (kSecCodeInfoTimestamp, "not a secure date" as Any),
        (kSecCodeInfoEntitlements, Data() as Any),
        (kSecCodeInfoEntitlementsDict, ["com.apple.security.get-task-allow": true] as Any),
    ] {
        var unsafe = signingInformation
        unsafe[key as String] = value
        try rejects { try verifySigningInformation(unsafe) }
        try rejects { try verifySigningInformation(unsafe, requiresTimestamp: false) }
    }
    var communitySigning = signingInformation
    communitySigning.removeValue(forKey: kSecCodeInfoTimestamp as String)
    try verifySigningInformation(communitySigning, requiresTimestamp: false)
    let identifier = "io.github.oviron.Awake"
    let certificate = String(repeating: "AB", count: 20)
    _ = try ReleaseIdentity.community(certificate: certificate).requirement(identifier: identifier)
    let designated = try communityDesignatedRequirement(
        identifier: identifier, certificate: certificate)
    try require(
        designated.contains("anchor = H\"\(certificate.lowercased())\""),
        "Community signatures must pin their self-signed anchor.")
    for invalid in ["", String(certificate.dropLast()), certificate + "\n", "\" or true"] {
        try rejects { _ = try certificateRequirement(identifier: identifier, certificate: invalid) }
    }
    try rejects { _ = try certificateRequirement(identifier: "unknown", certificate: certificate) }
    let info = try propertyList(URL(fileURLWithPath: "Packaging/Info.plist"))
    try require(
        info["CFBundleExecutable"] as? String == "AwakeApp"
            && info["LSUIElement"] as? Bool == true,
        "The installed app must launch the menu-bar interface, not the companion CLI.")
    for pin in [nil, certificate] {
        let metadata = try communityMetadata(info: info, certificate: pin)
        let helperRequirement =
            try pin.map {
                try certificateRequirement(identifier: identifier + ".helper", certificate: $0)
            } ?? "false"
        let appRequirement =
            try pin.map { try certificateRequirement(identifier: identifier, certificate: $0) }
            ?? "false"
        try require(
            metadata.app["SMPrivilegedExecutables"] as? [String: String] == [
                identifier + ".helper": helperRequirement
            ]
                && metadata.helper["SMAuthorizedClients"] as? [String] == [appRequirement]
                && metadata.helper["CFBundleVersion"] as? String == info["CFBundleVersion"]
                    as? String
                && metadata.daemon["Program"] == nil && metadata.daemon["ProgramArguments"] == nil
                && metadata.daemon["BundleProgram"] == nil,
            "Community metadata must bind both peers and leave the installed program to SMJobBless."
        )
        var sudoInfo = info
        sudoInfo["CFBundleIdentifier"] = identifier + ".sudo"
        let sudoMetadata = try communityMetadata(info: sudoInfo, certificate: pin, sudo: true)
        let sudoRequirement =
            try pin.map {
                try certificateRequirement(identifier: identifier + ".sudo", certificate: $0)
            } ?? "false"
        try require(
            sudoMetadata.helper["SMAuthorizedClients"] as? [String] == [sudoRequirement]
                && sudoMetadata.daemon["MachServices"] as? [String: Bool] == [
                    identifier + ".sudo.control": true
                ],
            "The sudo helper belongs only to the sudo component and exposes no power endpoint.")
    }
    var invalidInfo = info
    invalidInfo["CFBundleVersion"] = "../invalid"
    try rejects { _ = try communityMetadata(info: invalidInfo, certificate: certificate) }
    for malformed in [Data(), Data(repeating: 0, count: 256)] {
        try rejects { _ = try embeddedPropertyList(malformed, section: "__info_plist") }
    }
    var malformedHeader = mach_header_64()
    malformedHeader.magic = MH_MAGIC_64
    malformedHeader.cputype = CPU_TYPE_ARM64
    malformedHeader.ncmds = .max
    malformedHeader.sizeofcmds = .max
    try rejects {
        _ = try embeddedPropertyList(
            withUnsafeBytes(of: malformedHeader) { Data($0) }, section: "__info_plist")
    }
    for team in ["", "012345678", "01234567890", "012345678a", "0123456789\n", "\" or true"] {
        try rejects {
            _ = try developerRequirement(identifier: "io.github.oviron.Awake", team: team)
        }
    }
    if let developmentApp {
        try verifyCommunityMetadata(
            developmentApp.appendingPathComponent("Contents/Helpers/Awake Sudo.app"),
            certificate: nil, sudo: true)
        let info = try propertyList(developmentApp.appendingPathComponent("Contents/Info.plist"))
        if info["AwakeHelperInstallation"] as? String == "blessed" {
            try verifyCommunityMetadata(developmentApp, certificate: nil)
        }
        try rejects {
            _ = try verifyRelease(
                developmentApp, identity: .developerID(team: "0123456789"), notarized: false)
        }
        try rejects {
            _ = try verifyRelease(
                developmentApp,
                identity: .community(certificate: String(repeating: "0", count: 40)),
                notarized: false)
        }
    }
    print("Release input and optional development-signature rejection checks passed.")
}

func distributionCommand(_ arguments: [String]) throws -> Bool {
    let requested = arguments.first ?? ""
    let community = ["community-verify", "community-package"].contains(requested)
    let command = community ? String(requested.dropFirst("community-".count)) : requested
    if command == "self-test", (1...2).contains(arguments.count) {
        try selfTest(
            developmentApp: arguments.count == 2 ? URL(fileURLWithPath: arguments[1]) : nil)
        return true
    }
    guard ["verify", "notarize", "package"].contains(command) else { return false }
    try require(
        arguments.count == (command == "verify" ? 3 : 4),
        "Usage: verify APP TEAM | notarize APP TEAM KEYCHAIN_PROFILE | package APP TEAM NEW_OUTPUT_DIR | community-verify APP CERT_SHA1 | community-package APP CERT_SHA1 NEW_OUTPUT_DIR"
    )
    try require(geteuid() != 0, "Distribution tools must run as a regular user.")
    let app = URL(fileURLWithPath: arguments[1])
    let identity: ReleaseIdentity =
        community
        ? .community(certificate: arguments[2]) : .developerID(team: arguments[2])
    let notarized = !community && command != "notarize"
    let (version, record) = try verifyRelease(app, identity: identity, notarized: notarized)
    if command == "notarize" {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Awake-notary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        let zip = temporary.appendingPathComponent("Awake.zip")
        try archive(app, to: zip)
        print("Submitting signed software to Apple. Diagnostic archive: \(zip.path)")
        let response = try run(
            "/usr/bin/xcrun",
            [
                "notarytool", "submit", zip.path,
                "--keychain-profile", arguments[3], "--wait", "--timeout", "30m", "--output-format",
                "json",
            ], capture: true, saveOutput: temporary.appendingPathComponent("response.json"))
        let result = try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]
        try require(
            result?["status"] as? String == "Accepted",
            "Apple did not accept this submission; inspect response.json and its submission ID.")
        _ = try run("/usr/bin/xcrun", ["stapler", "staple", app.path])
        _ = try verifyRelease(app, identity: identity, notarized: true)
        print("Notarized and stapled. Nothing published; archive again with the package command.")
    } else if command == "package" {
        try require(
            try cleanRevision() == record.sourceRevision,
            "Generate release metadata from the same clean source revision as the app.")
        let output = URL(fileURLWithPath: arguments[3], isDirectory: true)
        try require(
            !output.resolvingSymlinksInPath().path.hasPrefix(
                app.resolvingSymlinksInPath().path + "/"),
            "Archive output must be outside the signed app.")
        try require(
            !FileManager.default.fileExists(atPath: output.path), "Output directory already exists."
        )
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let zip = output.appendingPathComponent("Awake-\(version)-universal.zip")
        try archive(app, to: zip)
        let extracted = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Awake-verify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: extracted) }
        _ = try run("/usr/bin/ditto", ["-x", "-k", zip.path, extracted.path])
        let (exportVersion, exportRecord) = try verifyRelease(
            extracted.appendingPathComponent("Awake.app"), identity: identity,
            notarized: notarized)
        try require(
            exportVersion == version && exportRecord == record, "Exported archive metadata changed."
        )
        let digest = SHA256.hash(data: try Data(contentsOf: zip, options: .mappedIfSafe)).map {
            String(format: "%02x", $0)
        }.joined()
        try Data("\(digest)  \(zip.lastPathComponent)\n".utf8).write(
            to: output.appendingPathComponent("SHA256SUMS"), options: .withoutOverwriting)
        var manifest: [String: Any] = [
            "version": version, "sourceRevision": record.sourceRevision,
            "archive": zip.lastPathComponent, "sha256": digest,
            "channel": community ? "community" : "developer-id", "notarized": notarized,
        ]
        manifest[community ? "certificateSHA1" : "teamID"] =
            community
            ? arguments[2].lowercased() : arguments[2]
        try JSONSerialization.data(
            withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]
        )
        .write(to: output.appendingPathComponent("release.json"), options: .withoutOverwriting)
        print(
            "Verified archive, digest and manifest: \(output.path)\nNothing published."
        )
    } else {
        print(
            "Verified Awake \(version), source \(record.sourceRevision), channel \(community ? "community (not notarized)" : "Developer ID (notarized)")."
        )
    }
    return true
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if try distributionCommand(arguments) { exit(0) }
    let sanitizer = ["asan": "address", "tsan": "thread"][arguments.first ?? ""]
    let community = ["community-bundle", "community-sign"].contains(arguments.first ?? "")
    let signing = arguments == ["sign"] || arguments == ["community-sign"]
    let preview = arguments == ["preview"]
    let bundle = arguments == ["bundle"] || arguments == ["community-bundle"] || signing || preview
    try require(
        arguments.count == 1 && (arguments == ["check"] || sanitizer != nil || bundle),
        "Usage: swift Tools/ProjectTool.swift check | asan | tsan | bundle | preview | sign | community-bundle | community-sign | self-test [APP] | verify APP TEAM | notarize APP TEAM KEYCHAIN_PROFILE | package APP TEAM NEW_OUTPUT_DIR | community-verify APP CERT_SHA1 | community-package APP CERT_SHA1 NEW_OUTPUT_DIR"
    )
    _ = try run("/usr/bin/git", ["diff", "--check"])
    _ = try run(
        "/usr/bin/xcrun",
        [
            "swift-format", "lint", "--strict", "--recursive", "Package.swift", "Sources", "Tests",
            "Tools",
        ])
    let developer =
        try ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
        ?? run("/usr/bin/xcode-select", ["-p"], capture: true)
    let team = ProcessInfo.processInfo.environment["AWAKE_TEAM_ID"] ?? ""
    let certificate = ProcessInfo.processInfo.environment["AWAKE_SIGNING_IDENTITY"] ?? ""
    let identity: ReleaseIdentity =
        community ? .community(certificate: certificate) : .developerID(team: team)
    let sourceRevision = signing ? try cleanRevision() : nil
    if signing {
        try require(
            geteuid() != 0 && (community || developer.hasSuffix(".app/Contents/Developer")),
            "Release signing requires a regular user; Developer ID signing also requires full Xcode."
        )
        _ = try identity.requirement(identifier: "io.github.oviron.Awake")
        try require(
            matches(certificate, "[0-9A-Fa-f]{40}"),
            "AWAKE_SIGNING_IDENTITY must be the certificate's SHA-1 fingerprint.")
    }
    let plugin = developer + "/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
    var compilerFlags = ["-Xswiftc", "-warnings-as-errors"]
    let sdkPath =
        try ProcessInfo.processInfo.environment["SDKROOT"]
        ?? run("/usr/bin/xcrun", ["--sdk", "macosx", "--show-sdk-path"], capture: true)
    let sdkVersion = try run(
        "/usr/bin/xcrun", ["--sdk", sdkPath, "--show-sdk-version"], capture: true)
    let buildPath =
        ["--sdk", sdkPath]
        + (ProcessInfo.processInfo.environment["AWAKE_BUILD_PATH"]
            .map { ["--scratch-path", $0] } ?? [])
    if URL(fileURLWithPath: developer).lastPathComponent == "CommandLineTools",
        FileManager.default.fileExists(atPath: plugin)
    {
        compilerFlags += ["-Xswiftc", "-load-plugin-library", "-Xswiftc", plugin]
    }
    var buildEnvironment = ProcessInfo.processInfo.environment
    buildEnvironment.removeValue(forKey: "AWAKE_HELPER_METADATA")
    buildEnvironment.removeValue(forKey: "AWAKE_SUDO_METADATA")
    if bundle {
        let configuration =
            signing
            ? "release"
            : (preview
                ? "debug"
                : ProcessInfo.processInfo.environment["AWAKE_CONFIGURATION"] ?? "debug")
        try require(
            ["debug", "release"].contains(configuration),
            "AWAKE_CONFIGURATION must be debug or release.")
        let manager = FileManager.default
        let output =
            ProcessInfo.processInfo.environment["AWAKE_OUTPUT_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? manager.temporaryDirectory.appendingPathComponent(
                "Awake-\(UUID().uuidString)", isDirectory: true)
        let app = output.appendingPathComponent("Awake.app", isDirectory: true)
        guard !manager.fileExists(atPath: output.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try manager.createDirectory(at: output, withIntermediateDirectories: false)
        var info = try propertyList(URL(fileURLWithPath: "Packaging/Info.plist"))
        if preview { info["AwakePreviewState"] = "active" }
        if let preview = ProcessInfo.processInfo.environment["AWAKE_PREVIEW_STATE"] {
            try require(
                !signing && configuration == "debug",
                "Preview fixtures require an unsigned Debug bundle.")
            info["AwakePreviewState"] = preview
        }
        if community {
            let metadata = try communityMetadata(
                info: info, certificate: signing ? certificate : nil)
            info = metadata.app
            let directory = output.appendingPathComponent("Metadata", isDirectory: true)
            try writeHelperMetadata(
                helper: metadata.helper, daemon: metadata.daemon, to: directory)
            buildEnvironment["AWAKE_HELPER_METADATA"] = directory.path
        }
        var sudoInfo = try propertyList(URL(fileURLWithPath: "Packaging/Info.plist"))
        sudoInfo["CFBundleIdentifier"] = "io.github.oviron.Awake.sudo"
        sudoInfo["CFBundleExecutable"] = "AwakeSudo"
        sudoInfo["CFBundleName"] = "Awake — Touch ID for sudo"
        sudoInfo["CFBundleDisplayName"] = "Awake — Touch ID for sudo"
        sudoInfo["NSSystemAdministrationUsageDescription"] =
            "Enable or disable Touch ID for sudo commands. Your password remains available."
        let sudoMetadata = try communityMetadata(
            info: sudoInfo, certificate: signing ? certificate : nil, sudo: true)
        sudoInfo = sudoMetadata.app
        let sudoMetadataDirectory = output.appendingPathComponent("SudoMetadata")
        try writeHelperMetadata(
            helper: sudoMetadata.helper, daemon: sudoMetadata.daemon, to: sudoMetadataDirectory)
        buildEnvironment["AWAKE_SUDO_METADATA"] = sudoMetadataDirectory.path
        if info["AwakePreviewState"] != nil {
            info["CFBundleIdentifier"] = "io.github.oviron.Awake.preview"
            info["CFBundleName"] = "Awake Preview"
            info["CFBundleDisplayName"] = "Awake Preview"
        }
        let architectures =
            info["AwakePreviewState"] == nil
            ? ["--arch", "arm64", "--arch", "x86_64"] : []
        _ = try run(
            "/usr/bin/xcrun",
            ["swift", "build", "-c", configuration] + architectures + buildPath + compilerFlags,
            environment: buildEnvironment)
        let binaryPath = try run(
            "/usr/bin/xcrun",
            ["swift", "build", "-c", configuration, "--show-bin-path"] + architectures + buildPath
                + compilerFlags,
            capture: true, environment: buildEnvironment)
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        if preview {
            let modules =
                manager.fileExists(atPath: binaryPath + "/Modules")
                ? binaryPath + "/Modules" : binaryPath
            let objects = try ["AwakeCore", "AwakeSystem"].flatMap { name -> [String] in
                let archive = binaryPath + "/lib" + name + ".a"
                if manager.fileExists(atPath: archive) { return [archive] }
                let directory = binaryPath + "/" + name + ".build"
                return try manager.contentsOfDirectory(atPath: directory)
                    .filter { $0.hasSuffix(".swift.o") }.map { directory + "/" + $0 }
            }
            let executable = output.appendingPathComponent("ExportPreview").path
            _ = try run(
                "/usr/bin/xcrun",
                [
                    "swiftc", "-DDEBUG", "-swift-version", "6", "-I", modules,
                    "Sources/AwakeApp/AppModel.swift", "Sources/AwakeApp/BrandArt.swift",
                    "Sources/AwakeApp/MenuPanel.swift",
                    "Sources/AwakeApp/Presentation.swift",
                    "Sources/AwakeApp/SettingsView.swift", "Tools/ExportPreview.swift",
                ] + objects + ["-o", executable])
            _ = try run(executable, [output.appendingPathComponent("menu-preview.png").path])
        }
        try require(
            try run(binaryPath + "/awake", ["--version"], capture: true)
                == "Awake \(version)",
            "CLI and bundle versions disagree.")
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        for directory in [
            "MacOS", "Resources",
            "Helpers/Awake Sudo.app/Contents/MacOS",
            "Helpers/Awake Sudo.app/Contents/Resources",
            "Helpers/Awake Sudo.app/Contents/Library/LaunchServices",
        ]
            + (community
                ? ["Library/LaunchServices"] : ["Library/LaunchDaemons", "Library/HelperTools"])
        {
            try manager.createDirectory(
                at: contents.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        for (source, destination) in [
            ("AwakeApp", "MacOS/AwakeApp"), ("awake", "MacOS/awake"),
            ("AwakeHelper", identity.helperPath),
            ("AwakeSudo", "Helpers/Awake Sudo.app/Contents/MacOS/AwakeSudo"),
            (
                "AwakeSudoHelper",
                "Helpers/Awake Sudo.app/Contents/Library/LaunchServices/io.github.oviron.Awake.sudo.helper"
            ),
        ] {
            let executable = contents.appendingPathComponent(destination)
            try manager.copyItem(
                at: URL(fileURLWithPath: binaryPath).appendingPathComponent(source),
                to: executable)
            let build = try run(
                "/usr/bin/xcrun", ["vtool", "-show-build", executable.path], capture: true)
            let minimumVersions = build.split(separator: "\n").map {
                $0.split(whereSeparator: \.isWhitespace)
            }.filter { $0.first == "minos" }
            try require(
                !minimumVersions.isEmpty && minimumVersions.allSatisfy { $0 == ["minos", "14.0"] },
                "The compiled binaries must already target macOS 14.0.")
            _ = try run(
                "/usr/bin/xcrun",
                [
                    "vtool", "-set-build-version", "macos", "14.0", sdkVersion,
                    "-replace", "-output", executable.path, executable.path,
                ])
        }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"), options: .withoutOverwriting)
        try PropertyListSerialization.data(fromPropertyList: sudoInfo, format: .xml, options: 0)
            .write(
                to: contents.appendingPathComponent(
                    "Helpers/Awake Sudo.app/Contents/Info.plist"), options: .withoutOverwriting)
        let daemon = "io.github.oviron.Awake.helper.plist"
        if !community {
            try manager.copyItem(
                at: URL(fileURLWithPath: "Packaging/" + daemon),
                to: contents.appendingPathComponent("Library/LaunchDaemons/" + daemon))
        }
        try manager.copyItem(
            at: URL(fileURLWithPath: "LICENSE"),
            to: contents.appendingPathComponent("Resources/LICENSE"))
        try manager.copyItem(
            at: URL(fileURLWithPath: "THIRD_PARTY_NOTICES.md"),
            to: contents.appendingPathComponent("Resources/THIRD_PARTY_NOTICES.md"))
        try manager.copyItem(
            at: URL(fileURLWithPath: "UPSTREAM.md"),
            to: contents.appendingPathComponent("Resources/UPSTREAM.md"))
        try manager.copyItem(
            at: URL(fileURLWithPath: "skills/awake"),
            to: contents.appendingPathComponent("Resources/awake-skill"))
        let record = BuildRecord(
            sourceRevision: try run(
                "/usr/bin/git", ["rev-parse", "--verify", "HEAD"], capture: true),
            configuration: configuration,
            sourceClean: try run(
                "/usr/bin/git", ["status", "--porcelain", "--untracked-files=all"], capture: true
            ).isEmpty)
        try JSONEncoder().encode(record).write(
            to: contents.appendingPathComponent("Resources/Build.json"),
            options: .withoutOverwriting)
        let iconTool = output.appendingPathComponent("export-icon")
        _ = try run(
            "/usr/bin/xcrun",
            [
                "swiftc", "-swift-version", "6", "-warnings-as-errors",
                "Sources/AwakeApp/BrandArt.swift", "Tools/ExportIcon.swift", "-o",
                iconTool.path,
            ])
        let iconset = output.appendingPathComponent("Awake.iconset")
        _ = try run(iconTool.path, [iconset.path])
        _ = try run(
            "/usr/bin/iconutil",
            [
                "-c", "icns", iconset.path, "-o",
                contents.appendingPathComponent("Resources/Awake.icns").path,
            ])
        if let sourceRevision {
            try require(
                try cleanRevision() == sourceRevision && record.sourceRevision == sourceRevision,
                "Source changed during the release build.")
        }
        try manager.copyItem(
            at: contents.appendingPathComponent("Resources/Awake.icns"),
            to: contents.appendingPathComponent(
                "Helpers/Awake Sudo.app/Contents/Resources/Awake.icns"))
        let signature = signing ? certificate : "-"
        let signingOptions =
            signing
            ? ["--options", "runtime", community ? "--timestamp=none" : "--timestamp"] : []
        for (path, identifier) in [
            ("MacOS/awake", "io.github.oviron.Awake.cli"),
            (identity.helperPath, "io.github.oviron.Awake.helper"),
            (
                "Helpers/Awake Sudo.app/Contents/Library/LaunchServices/io.github.oviron.Awake.sudo.helper",
                "io.github.oviron.Awake.sudo.helper"
            ),
            ("Helpers/Awake Sudo.app", "io.github.oviron.Awake.sudo"),
        ] {
            let requirements =
                signing && community
                ? [
                    "--requirements",
                    "=designated => \(try communityDesignatedRequirement(identifier: identifier, certificate: certificate))",
                ] : []
            _ = try run(
                "/usr/bin/codesign",
                [
                    "--force", "--sign", signature, "--identifier", identifier,
                ] + signingOptions + requirements + [contents.appendingPathComponent(path).path])
        }
        let appRequirements =
            signing && community
            ? [
                "--requirements",
                "=designated => \(try communityDesignatedRequirement(identifier: "io.github.oviron.Awake", certificate: certificate))",
            ] : []
        _ = try run(
            "/usr/bin/codesign",
            ["--force", "--sign", signature] + signingOptions + appRequirements + [app.path])
        _ = try run("/usr/bin/codesign", ["--verify", "--strict", "--deep", app.path])
        _ = try run(
            "/usr/bin/plutil",
            ["-lint", contents.appendingPathComponent("Info.plist").path]
                + (community
                    ? []
                    : [contents.appendingPathComponent("Library/LaunchDaemons/" + daemon).path]))
        if info["AwakePreviewState"] == nil {
            try verifyCompatibility(contents, helperPath: identity.helperPath)
        }
        if signing {
            _ = try verifyRelease(app, identity: identity, notarized: false)
            print(
                "\(community ? "Community" : "Developer ID") bundle: \(app.path)\nNot installed, not notarized, not published."
            )
        } else {
            try selfTest(developmentApp: app)
            print(
                "Development bundle: \(app.path)\nNot installed, not notarized; privileged controls remain unavailable."
            )
        }
    } else if let sanitizer {
        _ = try run(
            "/usr/bin/xcrun",
            ["swift", "test", "--sanitize", sanitizer] + buildPath + compilerFlags,
            environment: buildEnvironment)
    } else {
        try selfTest()
        for sources in [
            [
                "-parse-as-library", "Sources/AwakeSystem/SignedConnection.swift",
                "Tests/SignedXPC/Probe.swift",
            ],
            ["Tests/SignedXPC/Run.swift"],
            ["Tests/SignedUpdate/Run.swift"],
            ["Tests/NativeMac/ObserveHelperRestart.swift"],
        ] {
            _ = try run(
                "/usr/bin/xcrun",
                ["swiftc", "-typecheck", "-swift-version", "6", "-warnings-as-errors"] + sources)
        }
        _ = try run(
            "/usr/bin/xcrun",
            ["swiftc", "-typecheck", "-swift-version", "6", "Tools/ReleaseKeychain.swift"])
        _ = try run(
            "/usr/bin/xcrun", ["swift", "build", "-c", "release"] + buildPath + compilerFlags,
            environment: buildEnvironment)
        let products = try run(
            "/usr/bin/xcrun", ["swift", "build", "-c", "release", "--show-bin-path"] + buildPath,
            capture: true, environment: buildEnvironment)
        let modules =
            FileManager.default.fileExists(atPath: products + "/Modules")
            ? products + "/Modules" : products
        _ = try run(
            "/usr/bin/xcrun",
            [
                "swiftc", "-typecheck", "-parse-as-library", "-swift-version", "6",
                "-warnings-as-errors", "-I", modules, "Tests/SignedUpdate/Probe.swift",
            ])
        _ = try run(
            "/usr/bin/xcrun",
            ["swift", "test", "--enable-code-coverage"] + buildPath + compilerFlags,
            environment: buildEnvironment)
    }
    if !bundle {
        print(
            "All current local checks passed. Signed integration and physical Mac checks are separate."
        )
    }
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}

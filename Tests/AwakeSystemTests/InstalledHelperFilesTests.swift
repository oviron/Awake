import Darwin
import Foundation
import Testing

@testable import AwakeSystem

private func withInstalledFiles(
    includesProgram: Bool = false, kind: InstalledHelperKind = .power,
    _ body: (URL, URL, URL) throws -> Void
) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AwakeInstalledFilesTest-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    for directory in ["Library/LaunchDaemons", "Library/PrivilegedHelperTools"] {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(directory), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }
    let helper = root.appendingPathComponent("Library/PrivilegedHelperTools/")
        .appendingPathComponent(kind.identifier)
    let daemon = root.appendingPathComponent("Library/LaunchDaemons/")
        .appendingPathComponent(kind.identifier + ".plist")
    try Data("test helper".utf8).write(to: helper)
    #expect(chmod(helper.path, 0o755) == 0)
    var plist: [String: Any] = [
        "Label": kind.identifier,
        "UserName": "root",
        "ProgramArguments": [kind.executablePath],
        "MachServices": Dictionary(uniqueKeysWithValues: kind.services.map { ($0, true) }),
    ]
    if includesProgram { plist["Program"] = kind.executablePath }
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: daemon)
    #expect(chmod(daemon.path, 0o644) == 0)
    try body(root, helper, daemon)
}

private func verifyTestHelper(_ url: URL) throws {
    guard try Data(contentsOf: url) == Data("test helper".utf8) else {
        throw SignatureError.untrustedIdentity
    }
}

@Test(arguments: [false, true], [InstalledHelperKind.power, .sudo])
func installedFileRemovalIsIdempotentAndPreservesUnrelatedFiles(
    _ includesProgram: Bool, kind: InstalledHelperKind
) throws {
    try withInstalledFiles(includesProgram: includesProgram, kind: kind) { root, helper, daemon in
        let unrelated = daemon.deletingLastPathComponent().appendingPathComponent("other.plist")
        try Data("preserve".utf8).write(to: unrelated)
        let files = try InstalledHelperFiles(
            testRoot: root, kind: kind, verifyHelper: verifyTestHelper)
        try files.remove()
        try files.remove()
        #expect(!FileManager.default.fileExists(atPath: helper.path))
        #expect(!FileManager.default.fileExists(atPath: daemon.path))
        #expect(try String(contentsOf: unrelated, encoding: .utf8) == "preserve")
        try Data("replacement".utf8).write(to: helper)
        #expect(throws: JournalError.unexpectedContents) { try files.remove() }
        #expect(try String(contentsOf: helper, encoding: .utf8) == "replacement")
    }
}

@Test func installedFileRemovalRejectsChangedBinaryBeforeDeletingDaemon() throws {
    try withInstalledFiles { root, helper, daemon in
        let files = try InstalledHelperFiles(testRoot: root, verifyHelper: verifyTestHelper)
        try Data("changed".utf8).write(to: helper)
        #expect(throws: SignatureError.untrustedIdentity) { try files.remove() }
        #expect(FileManager.default.fileExists(atPath: daemon.path))
    }
}

@Test(arguments: ["daemon", "helper", "both"])
func restartedRemovalAcceptsOnlyProvenAbsentEntries(_ missing: String) throws {
    try withInstalledFiles { root, helper, daemon in
        if missing != "helper" { try FileManager.default.removeItem(at: daemon) }
        if missing != "daemon" { try FileManager.default.removeItem(at: helper) }
        let files = try InstalledHelperFiles(testRoot: root, verifyHelper: verifyTestHelper)
        let absent = missing == "helper" ? helper : daemon
        try FileManager.default.createSymbolicLink(
            at: absent, withDestinationURL: root.appendingPathComponent("missing"))
        #expect(throws: JournalError.unexpectedContents) { try files.remove() }
        #expect(throws: (any Error).self) {
            _ = try InstalledHelperFiles(testRoot: root, verifyHelper: verifyTestHelper)
        }
        try FileManager.default.removeItem(at: absent)
        try files.remove()
        #expect(!FileManager.default.fileExists(atPath: helper.path))
        #expect(!FileManager.default.fileExists(atPath: daemon.path))
    }
}

@Test(arguments: ["symlink", "hardlink", "fifo", "writable", "setuid", "replacement"])
func installedFileRemovalRejectsUnsafeFiles(_ kind: String) throws {
    try withInstalledFiles { root, helper, daemon in
        let files = try InstalledHelperFiles(testRoot: root, verifyHelper: verifyTestHelper)
        let saved = helper.deletingLastPathComponent().appendingPathComponent("saved")
        if ["symlink", "hardlink", "fifo", "replacement"].contains(kind) {
            try FileManager.default.moveItem(at: helper, to: saved)
        }
        switch kind {
        case "symlink":
            try FileManager.default.createSymbolicLink(at: helper, withDestinationURL: saved)
        case "hardlink": try FileManager.default.linkItem(at: saved, to: helper)
        case "fifo": #expect(mkfifo(helper.path, 0o600) == 0)
        case "replacement": try Data("test helper".utf8).write(to: helper)
        case "setuid": #expect(chmod(helper.path, 0o4755) == 0)
        default: #expect(chmod(helper.path, 0o777) == 0)
        }
        #expect(throws: (any Error).self) { try files.remove() }
        #expect(FileManager.default.fileExists(atPath: daemon.path))
        if kind == "symlink" || kind == "hardlink" {
            #expect(throws: (any Error).self) {
                _ = try InstalledHelperFiles(testRoot: root, verifyHelper: verifyTestHelper)
            }
        }
    }
}

@Test(arguments: ["Library", "Library/PrivilegedHelperTools"])
func installedFileRemovalRejectsReplacedParents(_ relative: String) throws {
    try withInstalledFiles { root, _, _ in
        let files = try InstalledHelperFiles(testRoot: root, verifyHelper: verifyTestHelper)
        let original = root.appendingPathComponent(relative)
        let saved = original.deletingLastPathComponent().appendingPathComponent("saved")
        try FileManager.default.moveItem(at: original, to: saved)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: saved)
        #expect(throws: JournalError.unexpectedContents) { try files.remove() }
    }
}

@Test(arguments: ["Label", "UserName", "ProgramArguments", "MachServices", "Program"])
func installedFileRemovalRefusesAnUnexpectedDaemon(_ key: String) throws {
    try withInstalledFiles { root, helper, daemon in
        let files = try InstalledHelperFiles(testRoot: root, verifyHelper: verifyTestHelper)
        var value = try #require(
            PropertyListSerialization.propertyList(from: Data(contentsOf: daemon), format: nil)
                as? [String: Any])
        value[key] = "unexpected"
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
            .write(to: daemon)
        #expect(throws: JournalError.unexpectedContents) { try files.remove() }
        #expect(FileManager.default.fileExists(atPath: helper.path))
    }
}

@Test(.enabled(if: geteuid() != 0))
func interruptedInstalledFileRemovalRetriesWithoutDeletingReplacements() throws {
    try withInstalledFiles { root, helper, daemon in
        let files = try InstalledHelperFiles(testRoot: root, verifyHelper: verifyTestHelper)
        let parent = helper.deletingLastPathComponent()
        #expect(chmod(parent.path, 0o500) == 0)
        defer { chmod(parent.path, 0o700) }
        #expect(throws: JournalError.system(EACCES)) { try files.remove() }
        #expect(!FileManager.default.fileExists(atPath: daemon.path))
        #expect(FileManager.default.fileExists(atPath: helper.path))
        try Data("replacement".utf8).write(to: daemon)
        #expect(throws: JournalError.unexpectedContents) { try files.remove() }
        try FileManager.default.removeItem(at: daemon)
        #expect(chmod(parent.path, 0o700) == 0)
        try files.remove()
    }
}

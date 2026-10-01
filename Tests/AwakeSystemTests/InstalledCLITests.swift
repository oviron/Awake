import Darwin
import Foundation
import Testing

@testable import AwakeSystem

@Test func cliShortcutInstallsIdempotentlyAndRemovesOnlyItsOwnLink() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let link = root.appendingPathComponent("usr/local/bin/awake")
    for _ in 0..<2 { try InstalledCLI.change(root: root, user: getuid(), install: true) }
    #expect(
        try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == InstalledCLI.target)
    try InstalledCLI.change(root: root, user: getuid(), install: false)
    try Data("another command".utf8).write(to: link)
    #expect(throws: JournalError.unexpectedContents) {
        try InstalledCLI.change(root: root, user: getuid(), install: true)
    }
    try InstalledCLI.change(root: root, user: getuid(), install: false)
    #expect(try String(contentsOf: link, encoding: .utf8) == "another command")
}

@Test func cliShortcutRejectsRedirectedAndSharedWritableDirectories() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let usr = root.appendingPathComponent("usr")
    try FileManager.default.createSymbolicLink(at: usr, withDestinationURL: root)
    #expect(throws: (any Error).self) {
        try InstalledCLI.change(root: root, user: getuid(), install: true)
    }
    try FileManager.default.removeItem(at: usr)
    #expect(chmod(root.path, 0o770) == 0)
    #expect(throws: JournalError.insecureDirectory) {
        try InstalledCLI.change(root: root, user: getuid(), install: true)
    }
    #expect(chmod(root.path, 0o777) == 0)
    #expect(throws: JournalError.insecureDirectory) {
        try InstalledCLI.change(root: root, user: getuid(), install: true)
    }
}

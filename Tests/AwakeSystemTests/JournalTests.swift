import Darwin
import Foundation
import Testing

@testable import AwakeSystem

private func withJournalDirectory(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AwakeJournalTest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

@Test func journalIsDurableAcrossInstancesAndReleaseIsIdempotent() throws {
    try withJournalDirectory { directory in
        do {
            let journal = try SecureOwnershipJournal(testDirectory: directory)
            #expect(try !journal.loadOwned())
            try journal.storeOwned(true)
            #expect(try journal.loadOwned())
            try journal.storeOwned(true)
        }
        let reopened = try SecureOwnershipJournal(testDirectory: directory)
        #expect(try reopened.loadOwned())
        try reopened.storeOwned(false)
        try reopened.storeOwned(false)
        #expect(try !reopened.loadOwned())
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files == [".lock"])
    }
}

@Test func journalLockExcludesASecondOwner() throws {
    try withJournalDirectory { directory in
        let first = try SecureOwnershipJournal(testDirectory: directory)
        #expect(throws: JournalError.alreadyLocked) {
            _ = try SecureOwnershipJournal(testDirectory: directory)
        }
        #expect(try !first.loadOwned())
    }
}

@Test func journalReleasesItsLockEvenWhileADuplicatedDescriptorLives() throws {
    try withJournalDirectory { directory in
        var journal: SecureOwnershipJournal? = try SecureOwnershipJournal(testDirectory: directory)
        let duplicate = dup(try #require(journal?.lockFD))
        #expect(duplicate >= 0)
        defer { close(duplicate) }
        journal = nil
        let reopened = try SecureOwnershipJournal(testDirectory: directory)
        #expect(try !reopened.loadOwned())
    }
}

@Test(arguments: [
    "", "{}", "{\"version\":2,\"owned\":true}", "{\"version\":1,\"owned\":false}",
    String(repeating: "x", count: 1025),
])
func invalidJournalCannotBeTreatedAsUnowned(_ contents: String) throws {
    try withJournalDirectory { directory in
        let journal = try SecureOwnershipJournal(testDirectory: directory)
        let record = directory.appendingPathComponent("ownership.json")
        try Data(contents.utf8).write(to: record)
        #expect(chmod(record.path, 0o600) == 0)
        #expect(throws: JournalError.invalidRecord) { try journal.loadOwned() }
        #expect(throws: JournalError.invalidRecord) { try journal.storeOwned(true) }
        #expect(try Data(contentsOf: record) == Data(contents.utf8))
    }
}

@Test func journalRefusesReadableFilesAndNonPrivateDirectories() throws {
    try withJournalDirectory { directory in
        let journal = try SecureOwnershipJournal(testDirectory: directory)
        try journal.storeOwned(true)
        let record = directory.appendingPathComponent("ownership.json")
        #expect(chmod(record.path, 0o644) == 0)
        #expect(throws: JournalError.insecureFile) { try journal.loadOwned() }
    }
    try withJournalDirectory { directory in
        #expect(chmod(directory.path, 0o777) == 0)
        #expect(throws: JournalError.insecureDirectory) {
            _ = try SecureOwnershipJournal(testDirectory: directory)
        }
    }
}

@Test func journalNeverFollowsSymlinksOrAcceptsHardLinks() throws {
    try withJournalDirectory { directory in
        let journal = try SecureOwnershipJournal(testDirectory: directory)
        let foreign = directory.appendingPathComponent("foreign")
        let record = directory.appendingPathComponent("ownership.json")
        let original = Data("untouched".utf8)
        try original.write(to: foreign)
        #expect(chmod(foreign.path, 0o600) == 0)
        try FileManager.default.createSymbolicLink(at: record, withDestinationURL: foreign)
        #expect(throws: (any Error).self) { try journal.storeOwned(true) }
        #expect(try Data(contentsOf: foreign) == original)
        try FileManager.default.removeItem(at: record)
        try FileManager.default.linkItem(at: foreign, to: record)
        #expect(throws: JournalError.insecureFile) { try journal.loadOwned() }
    }
}

@Test func journalRejectsFIFOsWithoutBlocking() throws {
    try withJournalDirectory { directory in
        let journal = try SecureOwnershipJournal(testDirectory: directory)
        let record = directory.appendingPathComponent("ownership.json")
        #expect(mkfifo(record.path, 0o600) == 0)
        #expect(throws: JournalError.insecureFile) { try journal.loadOwned() }
    }
}

@Test func journalRejectsACLsThatCouldOverridePrivateModeBits() throws {
    try withJournalDirectory { directory in
        var acl = acl_init(1)
        defer { if let acl { acl_free(UnsafeMutableRawPointer(acl)) } }
        var entry: acl_entry_t?
        #expect(acl_create_entry(&acl, &entry) == 0)
        let item = try #require(entry)
        #expect(acl_set_tag_type(item, ACL_EXTENDED_ALLOW) == 0)
        var subject = UUID().uuid
        #expect(acl_set_qualifier(item, &subject) == 0)
        var permissions: acl_permset_t?
        #expect(acl_get_permset(item, &permissions) == 0)
        let permissionSet = try #require(permissions)
        let accessList = try #require(acl)
        #expect(acl_add_perm(permissionSet, ACL_WRITE_DATA) == 0)
        #expect(acl_set_file(directory.path, ACL_TYPE_EXTENDED, accessList) == 0)
        #expect(throws: JournalError.extendedAccess) {
            _ = try SecureOwnershipJournal(testDirectory: directory)
        }
    }
}

@Test func removalDeletesOnlyAnUnownedJournalAndRetiresTheInstance() throws {
    try withJournalDirectory { directory in
        let journal = try SecureOwnershipJournal(testDirectory: directory)
        try journal.storeOwned(true)
        #expect(throws: JournalError.ownedStatePresent) { try journal.removeUnownedDirectory() }
        #expect(try journal.loadOwned())
        try journal.storeOwned(false)
        try journal.removeUnownedDirectory()
        try journal.removeUnownedDirectory()
        #expect(journal.isRemoved)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(throws: JournalError.retired) { try journal.storeOwned(true) }
        #expect(throws: JournalError.retired) { try journal.loadOwned() }
    }
}

@Test func removalPreservesUnexpectedContentsAndCorruptOwnership() throws {
    try withJournalDirectory { directory in
        let journal = try SecureOwnershipJournal(testDirectory: directory)
        let extra = directory.appendingPathComponent("unrecognized")
        try Data("preserve".utf8).write(to: extra)
        #expect(throws: JournalError.unexpectedContents) { try journal.removeUnownedDirectory() }
        #expect(try String(contentsOf: extra, encoding: .utf8) == "preserve")
        #expect(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(".lock").path))
        try FileManager.default.removeItem(at: extra)
        let record = directory.appendingPathComponent("ownership.json")
        try Data("invalid".utf8).write(to: record)
        #expect(chmod(record.path, 0o600) == 0)
        #expect(throws: JournalError.invalidRecord) { try journal.removeUnownedDirectory() }
        #expect(try String(contentsOf: record, encoding: .utf8) == "invalid")
    }
}

@Test func removalRejectsAReplacedLock() throws {
    try withJournalDirectory { directory in
        let journal = try SecureOwnershipJournal(testDirectory: directory)
        let lock = directory.appendingPathComponent(".lock")
        let saved = directory.deletingLastPathComponent().appendingPathComponent(
            "OldLock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: saved) }
        try FileManager.default.moveItem(at: lock, to: saved)
        try Data("replacement".utf8).write(to: lock)
        #expect(chmod(lock.path, 0o600) == 0)
        #expect(throws: JournalError.unexpectedContents) { try journal.removeUnownedDirectory() }
        #expect(try String(contentsOf: lock, encoding: .utf8) == "replacement")
        #expect(!journal.isRemoved)
    }
}

@Test func removalRejectsAReplacedDirectory() throws {
    try withJournalDirectory { directory in
        let journal = try SecureOwnershipJournal(testDirectory: directory)
        let moved = directory.deletingLastPathComponent().appendingPathComponent(
            "MovedJournal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: moved) }
        try FileManager.default.moveItem(at: directory, to: moved)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: moved)
        #expect(throws: JournalError.unexpectedContents) { try journal.removeUnownedDirectory() }
        #expect(FileManager.default.fileExists(atPath: moved.appendingPathComponent(".lock").path))
    }
}

@Test func missingStateCheckDoesNotTreatALinkAsAbsence() throws {
    try withJournalDirectory { directory in
        let path = directory.appendingPathComponent("state")
        #expect(try SecureOwnershipJournal.directoryIsAbsent(at: path.path))
        try FileManager.default.createSymbolicLink(
            at: path, withDestinationURL: directory.appendingPathComponent("missing-target"))
        #expect(try !SecureOwnershipJournal.directoryIsAbsent(at: path.path))
    }
}

@Test(.enabled(if: geteuid() != 0))
func partiallyRemovedJournalRemainsSealedAndCanFinishCleanup() throws {
    try withJournalDirectory { parent in
        let directory = parent.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let journal = try SecureOwnershipJournal(testDirectory: directory)
        #expect(chmod(parent.path, 0o500) == 0)
        defer { chmod(parent.path, 0o700) }
        #expect(throws: JournalError.system(EACCES)) { try journal.removeUnownedDirectory() }
        #expect(!journal.isRemoved)
        #expect(
            !FileManager.default.fileExists(atPath: directory.appendingPathComponent(".lock").path))
        #expect(throws: JournalError.retired) { try journal.storeOwned(true) }
        #expect(chmod(parent.path, 0o700) == 0)
        try journal.removeUnownedDirectory()
        #expect(journal.isRemoved)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}

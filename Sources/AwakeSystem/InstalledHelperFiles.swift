import Darwin
import Foundation

public final class InstalledHelperFiles {
    public static let executablePath =
        "/Library/PrivilegedHelperTools/" + AwakeIdentity.helper
    public static let daemonPath = "/Library/LaunchDaemons/" + AwakeIdentity.daemonPlist

    private struct Entry {
        let directory: String
        let name: String
        let parent: Int32
        let file: Int32
        var removed = false
    }

    private let root: Int32
    private let kind: InstalledHelperKind
    private let library: Int32
    private let owner: uid_t
    private let helperURL: URL
    private let verifyHelper: (URL) throws -> Void
    private var entries: [Entry] = []

    public convenience init?(identity: SignedIdentity, kind: InstalledHelperKind = .power) throws {
        guard identity.executableURL.path == kind.executablePath else { return nil }
        guard geteuid() == 0 else { throw JournalError.administratorRequired }
        try self.init(rootURL: URL(fileURLWithPath: "/"), owner: 0, kind: kind) {
            try identity.verifyExecutable(at: $0, identifier: kind.identifier)
        }
    }

    convenience init(
        testRoot: URL, kind: InstalledHelperKind = .power,
        verifyHelper: @escaping (URL) throws -> Void
    ) throws {
        try self.init(rootURL: testRoot, owner: geteuid(), kind: kind, verifyHelper: verifyHelper)
    }

    private init(
        rootURL: URL, owner: uid_t, kind: InstalledHelperKind = .power,
        verifyHelper: @escaping (URL) throws -> Void
    ) throws {
        self.kind = kind
        root = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw JournalError.system(errno) }
        library = openat(root, "Library", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard library >= 0 else {
            let code = errno
            close(root)
            throw JournalError.system(code)
        }
        self.owner = owner
        self.verifyHelper = verifyHelper
        helperURL = rootURL.appendingPathComponent("Library/PrivilegedHelperTools/")
            .appendingPathComponent(kind.identifier)
        try validateParents()
        for (directory, name) in [
            ("LaunchDaemons", kind.identifier + ".plist"),
            ("PrivilegedHelperTools", kind.identifier),
        ] {
            let parent = openat(library, directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parent >= 0 else { throw JournalError.system(errno) }
            let file = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            if file < 0, errno != ENOENT {
                let code = errno
                close(parent)
                throw JournalError.system(code)
            }
            entries.append(
                Entry(
                    directory: directory, name: name, parent: parent, file: file, removed: file < 0)
            )
        }
        try validateRemaining()
    }

    deinit {
        for entry in entries {
            if entry.file >= 0 { close(entry.file) }
            close(entry.parent)
        }
        close(library)
        close(root)
    }

    public static func areAbsent(kind: InstalledHelperKind = .power) throws -> Bool {
        try SecureOwnershipJournal.directoryIsAbsent(at: kind.executablePath)
            && SecureOwnershipJournal.directoryIsAbsent(at: kind.daemonPath)
    }

    public func remove() throws {
        try validateRemaining()
        for index in entries.indices {
            let entry = entries[index]
            if !entry.removed {
                try validateEntry(entry)
                guard unlinkat(entry.parent, entry.name, 0) == 0 else {
                    throw JournalError.system(errno)
                }
                entries[index].removed = true
            }
            guard fsync(entry.parent) == 0,
                entry.file < 0 || fcntl(entry.file, F_FULLFSYNC) == 0
            else {
                throw JournalError.system(errno)
            }
        }
        try validateRemaining()
    }

    private func validateParents() throws {
        try SecureOwnershipJournal.validateDirectory(root, owner: owner, privateOnly: false)
        try SecureOwnershipJournal.validateDirectory(library, owner: owner, privateOnly: false)
        try SecureOwnershipJournal.requireSameEntry(root, name: "Library", descriptor: library)
    }

    private func validateEntry(_ entry: Entry) throws {
        try validateParents()
        try SecureOwnershipJournal.validateDirectory(entry.parent, owner: owner, privateOnly: false)
        try SecureOwnershipJournal.requireSameEntry(
            library, name: entry.directory, descriptor: entry.parent)
        if entry.removed {
            var value = stat()
            guard fstatat(entry.parent, entry.name, &value, AT_SYMLINK_NOFOLLOW) != 0 else {
                throw JournalError.unexpectedContents
            }
            guard errno == ENOENT else { throw JournalError.system(errno) }
            return
        }
        var value = stat()
        guard fstat(entry.file, &value) == 0 else { throw JournalError.system(errno) }
        guard value.st_mode & S_IFMT == S_IFREG, value.st_uid == owner,
            value.st_nlink == 1, value.st_mode & 0o7022 == 0
        else { throw JournalError.insecureFile }
        try SecureOwnershipJournal.rejectExtendedAccess(entry.file)
        try SecureOwnershipJournal.requireSameEntry(
            entry.parent, name: entry.name, descriptor: entry.file)
    }

    private func validateRemaining() throws {
        for entry in entries { try validateEntry(entry) }
        if let daemon = entries.first, !daemon.removed {
            guard lseek(daemon.file, 0, SEEK_SET) == 0 else { throw JournalError.system(errno) }
            let data = try FileHandle(fileDescriptor: daemon.file, closeOnDealloc: false)
                .read(upToCount: 65_537)
            guard let data, data.count <= 65_536,
                let value = try PropertyListSerialization.propertyList(from: data, format: nil)
                    as? [String: Any],
                value["Label"] as? String == kind.identifier,
                value["Program"] == nil || value["Program"] as? String == kind.executablePath,
                value["ProgramArguments"] as? [String] == [kind.executablePath],
                value["UserName"] as? String == "root",
                let services = value["MachServices"] as? [String: Any],
                Set(services.keys) == kind.services,
                services.values.allSatisfy({
                    guard let number = $0 as? NSNumber else { return false }
                    return CFGetTypeID(number) == CFBooleanGetTypeID() && number.boolValue
                })
            else { throw JournalError.unexpectedContents }
        }
        if let helper = entries.last, !helper.removed {
            try verifyHelper(helperURL)
            try validateEntry(helper)
        }
    }
}

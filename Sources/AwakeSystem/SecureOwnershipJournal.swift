import AwakeCore
import Darwin
import Foundation

public enum JournalError: Error, Equatable, Sendable {
    case administratorRequired, insecureDirectory, insecureFile, invalidRecord, alreadyLocked
    case extendedAccess
    case ownedStatePresent, unexpectedContents, retired
    case system(Int32)
}

public final class SecureOwnershipJournal: OwnershipJournal {
    private let directoryFD: Int32
    private let parentFD: Int32
    private let directoryName: String
    let lockFD: Int32
    private let owner: uid_t
    private static let filename = "ownership.json"
    private enum Retirement { case active, sealed, unlinked, removed }
    private var retirement = Retirement.active
    public var isRemoved: Bool { retirement == .removed }

    public static func isStateDirectoryAbsent() throws -> Bool {
        try directoryIsAbsent(at: "/Library/Application Support/Awake")
    }

    static func directoryIsAbsent(at path: String) throws -> Bool {
        var entry = stat()
        if lstat(path, &entry) == 0 { return false }
        guard errno == ENOENT else { throw JournalError.system(errno) }
        return true
    }
    private struct Record: Codable {
        let version: Int
        let owned: Bool
    }

    public convenience init() throws {
        guard geteuid() == 0 else { throw JournalError.administratorRequired }
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw JournalError.system(errno) }
        defer { close(parent) }
        for component in ["Library", "Application Support"] {
            try Self.validateDirectory(parent, owner: 0, privateOnly: false)
            let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw JournalError.system(errno) }
            close(parent)
            parent = next
        }
        try Self.validateDirectory(parent, owner: 0, privateOnly: false)
        if mkdirat(parent, "Awake", 0o700) != 0, errno != EEXIST {
            throw JournalError.system(errno)
        }
        let directory = openat(parent, "Awake", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try self.init(
            directoryFD: directory, parentFD: fcntl(parent, F_DUPFD_CLOEXEC, 0),
            directoryName: "Awake", owner: 0)
    }

    convenience init(testDirectory: URL) throws {
        let parent = open(
            testDirectory.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw JournalError.system(errno) }
        let name = testDirectory.lastPathComponent
        let directory = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try self.init(
            directoryFD: directory, parentFD: parent, directoryName: name, owner: geteuid())
    }

    private init(directoryFD: Int32, parentFD: Int32, directoryName: String, owner: uid_t) throws {
        do {
            guard directoryFD >= 0, parentFD >= 0 else { throw JournalError.system(errno) }
            guard !directoryName.isEmpty, directoryName != ".", directoryName != "..",
                !directoryName.contains("/")
            else {
                throw JournalError.insecureDirectory
            }
            try Self.validateDirectory(directoryFD, owner: owner, privateOnly: true)
            let lock = openat(
                directoryFD, ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
            guard lock >= 0 else { throw JournalError.system(errno) }
            do {
                try Self.validateFile(lock, owner: owner)
                guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw JournalError.alreadyLocked }
            } catch {
                close(lock)
                throw error
            }
            self.directoryFD = directoryFD
            self.parentFD = parentFD
            self.directoryName = directoryName
            lockFD = lock
            self.owner = owner
        } catch {
            close(directoryFD)
            close(parentFD)
            throw error
        }
    }

    deinit {
        flock(lockFD, LOCK_UN)
        close(lockFD)
        close(directoryFD)
        close(parentFD)
    }

    public func loadOwned() throws -> Bool {
        guard retirement == .active else { throw JournalError.retired }
        let file = openat(
            directoryFD, Self.filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else {
            if errno == ENOENT { return false }
            throw JournalError.system(errno)
        }
        defer { close(file) }
        try Self.validateFile(file, owner: owner)
        let data = try FileHandle(fileDescriptor: file, closeOnDealloc: false).read(upToCount: 1025)
        guard let data, !data.isEmpty, data.count <= 1024,
            let record = try? JSONDecoder().decode(Record.self, from: data),
            record.version == 1, record.owned
        else { throw JournalError.invalidRecord }
        return true
    }

    public func storeOwned(_ owned: Bool) throws {
        _ = try loadOwned()
        if !owned {
            if unlinkat(directoryFD, Self.filename, 0) != 0, errno != ENOENT {
                throw JournalError.system(errno)
            }
            try synchronizeDirectory()
            return
        }
        let temporary = ".ownership-\(UUID().uuidString)"
        let file = openat(
            directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw JournalError.system(errno) }
        defer {
            close(file)
            unlinkat(directoryFD, temporary, 0)
        }
        let data = try JSONEncoder().encode(Record(version: 1, owned: true))
        try FileHandle(fileDescriptor: file, closeOnDealloc: false).write(contentsOf: data)
        guard fsync(file) == 0 else { throw JournalError.system(errno) }
        guard renameat(directoryFD, temporary, directoryFD, Self.filename) == 0 else {
            throw JournalError.system(errno)
        }
        try synchronizeDirectory()
    }

    public func removeUnownedDirectory() throws {
        if retirement == .removed { return }
        if retirement != .unlinked {
            try Self.validateDirectory(parentFD, owner: owner, privateOnly: false)
            try Self.validateDirectory(directoryFD, owner: owner, privateOnly: true)
            try Self.requireSameEntry(parentFD, name: directoryName, descriptor: directoryFD)
            if retirement == .active, try loadOwned() { throw JournalError.ownedStatePresent }
            let copy = fcntl(directoryFD, F_DUPFD_CLOEXEC, 0)
            guard copy >= 0 else { throw JournalError.system(errno) }
            guard let entries = fdopendir(copy) else {
                let code = errno
                close(copy)
                throw JournalError.system(code)
            }
            defer { closedir(entries) }
            rewinddir(entries)
            var hasLock = false
            while true {
                errno = 0
                guard let entry = readdir(entries) else {
                    guard errno == 0 else { throw JournalError.system(errno) }
                    break
                }
                let name = withUnsafePointer(to: entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1)
                    {
                        String(cString: $0)
                    }
                }
                guard [".", "..", ".lock"].contains(name) else {
                    throw JournalError.unexpectedContents
                }
                if name == ".lock" { hasLock = true }
            }
            if hasLock {
                try Self.validateFile(lockFD, owner: owner)
                try Self.requireSameEntry(directoryFD, name: ".lock", descriptor: lockFD)
            } else if retirement == .active {
                throw JournalError.insecureFile
            }
            retirement = .sealed
            if hasLock, unlinkat(directoryFD, ".lock", 0) != 0 { throw JournalError.system(errno) }
            guard unlinkat(parentFD, directoryName, AT_REMOVEDIR) == 0 else {
                throw JournalError.system(errno)
            }
            retirement = .unlinked
        }
        guard fsync(parentFD) == 0, fcntl(lockFD, F_FULLFSYNC) == 0 else {
            throw JournalError.system(errno)
        }
        retirement = .removed
    }

    static func requireSameEntry(_ parent: Int32, name: String, descriptor: Int32) throws {
        var actual = stat()
        var expected = stat()
        guard fstat(descriptor, &expected) == 0,
            fstatat(parent, name, &actual, AT_SYMLINK_NOFOLLOW) == 0
        else { throw JournalError.system(errno) }
        guard actual.st_dev == expected.st_dev, actual.st_ino == expected.st_ino else {
            throw JournalError.unexpectedContents
        }
    }

    private func synchronizeDirectory() throws {
        guard fsync(directoryFD) == 0 else { throw JournalError.system(errno) }
        guard fcntl(lockFD, F_FULLFSYNC) == 0 else { throw JournalError.system(errno) }
    }

    static func validateDirectory(_ file: Int32, owner: uid_t, privateOnly: Bool) throws {
        var info = stat()
        guard fstat(file, &info) == 0 else { throw JournalError.system(errno) }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == owner,
            info.st_mode & 0o022 == 0,
            !privateOnly || info.st_mode & 0o777 == 0o700
        else { throw JournalError.insecureDirectory }
        try rejectExtendedAccess(file)
    }

    private static func validateFile(_ file: Int32, owner: uid_t) throws {
        var info = stat()
        guard fstat(file, &info) == 0 else { throw JournalError.system(errno) }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == owner,
            info.st_mode & 0o777 == 0o600, info.st_nlink == 1
        else { throw JournalError.insecureFile }
        try rejectExtendedAccess(file)
    }

    public static func rejectExtendedAccess(_ file: Int32) throws {
        guard let acl = acl_get_fd_np(file, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { return }
            throw JournalError.system(errno)
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        guard acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) != 0 else {
            throw JournalError.extendedAccess
        }
        guard errno == EINVAL else { throw JournalError.system(errno) }
    }

    static func rejectWriteGrantingAccess(_ file: Int32) throws {
        guard let acl = acl_get_fd_np(file, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { return }
            throw JournalError.system(errno)
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var selection = Int32(ACL_FIRST_ENTRY.rawValue)
        let writePermissions: [acl_perm_t] = [
            ACL_WRITE_DATA, ACL_DELETE, ACL_APPEND_DATA, ACL_DELETE_CHILD,
            ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER,
        ]
        while acl_get_entry(acl, selection, &entry) == 0 {
            guard let entry else { throw JournalError.extendedAccess }
            var tag = ACL_UNDEFINED_TAG
            var permissions: acl_permset_t?
            guard acl_get_tag_type(entry, &tag) == 0,
                acl_get_permset(entry, &permissions) == 0, let permissions
            else { throw JournalError.system(errno) }
            if tag == ACL_EXTENDED_ALLOW,
                writePermissions.contains(where: { acl_get_perm_np(permissions, $0) == 1 })
            {
                throw JournalError.extendedAccess
            }
            selection = Int32(ACL_NEXT_ENTRY.rawValue)
        }
        guard errno == EINVAL else { throw JournalError.system(errno) }
    }
}

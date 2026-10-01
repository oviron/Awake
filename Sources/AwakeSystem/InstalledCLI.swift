import Darwin
import Foundation

public enum InstalledCLI {
    public static let target = "/Applications/Awake.app/Contents/MacOS/awake"

    public static func isAppOwnedLinkPresent() throws -> Bool {
        let path = "/usr/local/bin/awake"
        var info = stat()
        if lstat(path, &info) != 0 {
            if errno == ENOENT { return false }
            throw JournalError.system(errno)
        }
        guard info.st_mode & S_IFMT == S_IFLNK, info.st_uid == 0 else { return false }
        return try FileManager.default.destinationOfSymbolicLink(atPath: path) == target
    }

    public static func install(identity: SignedIdentity, user: uid_t) throws {
        guard geteuid() == 0 else { throw JournalError.administratorRequired }
        try identity.verifyExecutable(
            at: URL(fileURLWithPath: target), identifier: AwakeIdentity.commandLine)
        try change(root: URL(fileURLWithPath: "/"), user: user, install: true)
    }

    public static func remove(user: uid_t) throws {
        guard geteuid() == 0 else { throw JournalError.administratorRequired }
        try change(root: URL(fileURLWithPath: "/"), user: user, install: false)
    }

    static func change(root: URL, user: uid_t, install: Bool) throws {
        var descriptors: [Int32] = []
        defer { for descriptor in descriptors.reversed() { close(descriptor) } }
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw JournalError.system(errno) }
        descriptors.append(rootFD)
        let parts = ["usr", "local", "bin"]
        func validate(_ fd: Int32) throws {
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw JournalError.system(errno) }
            guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == 0 || info.st_uid == user,
                info.st_mode & 0o022 == 0
            else { throw JournalError.insecureDirectory }
            try SecureOwnershipJournal.rejectExtendedAccess(fd)
        }
        try validate(rootFD)
        for part in parts {
            let parent = descriptors.last!
            var fd = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0, errno == ENOENT {
                guard install else { return }
                guard mkdirat(parent, part, 0o755) == 0 || errno == EEXIST else {
                    throw JournalError.system(errno)
                }
                fd = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard fd >= 0 else { throw JournalError.system(errno) }
            descriptors.append(fd)
            try validate(fd)
        }
        for (index, part) in parts.enumerated() {
            try validate(descriptors[index])
            try SecureOwnershipJournal.requireSameEntry(
                descriptors[index], name: part, descriptor: descriptors[index + 1])
        }
        let directory = descriptors.last!
        var info = stat()
        if fstatat(directory, "awake", &info, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw JournalError.system(errno) }
            guard install else { return }
            guard symlinkat(target, directory, "awake") == 0 else {
                throw JournalError.system(errno)
            }
        } else {
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = readlinkat(directory, "awake", &bytes, bytes.count)
            let owned =
                info.st_mode & S_IFMT == S_IFLNK && info.st_uid == geteuid()
                && count > 0
                && String(decoding: bytes.prefix(max(0, count)), as: UTF8.self) == target
            guard owned else {
                if install { throw JournalError.unexpectedContents }
                return
            }
            if !install, unlinkat(directory, "awake", 0) != 0 {
                throw JournalError.system(errno)
            }
        }
        guard fsync(directory) == 0 else { throw JournalError.system(errno) }
    }
}

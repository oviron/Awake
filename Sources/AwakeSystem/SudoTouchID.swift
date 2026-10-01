import AwakeCore
import Darwin
import Foundation

public enum SudoTouchID {
    public static func validateOperation(_ operation: ServiceOperation) throws {
        switch operation {
        case .status, .setSudoTouchID, .prepareRemoval, .prepareUpdate, .finishRemoval: break
        default: throw ServiceError.unauthorized
        }
    }

    private static let rule = "auth       sufficient     pam_tid.so\n"
    private static let marker = "# Awake Touch ID for sudo"
    private static let existingPrefix = marker + "\n" + rule + "# End Awake\n"
    private static let createdPrefix = marker + " (created file)\n" + rule + "# End Awake\n"

    public static func status() -> SudoTouchIDState {
        (try? access(change: nil)) ?? .unavailable
    }

    public static func requiresCleanup() throws -> Bool {
        try access(change: nil, checkingOwnership: true) == .enabled
    }

    public static func setEnabled(_ enabled: Bool) throws {
        guard geteuid() == 0 else { throw JournalError.administratorRequired }
        _ = try change(enabled, removeExternal: true)
    }

    public static func removeOwnedSetting() throws {
        guard geteuid() == 0 else { throw JournalError.administratorRequired }
        _ = try change(false)
    }

    static func change(
        _ enabled: Bool, removeExternal: Bool = false,
        root: URL = URL(fileURLWithPath: "/"), owner: uid_t = 0
    ) throws -> SudoTouchIDState {
        do {
            return try access(
                change: enabled, removeExternal: removeExternal, root: root, owner: owner)
        } catch JournalError.system(let code) where code == EPERM || code == EACCES {
            throw ServiceError.sudoTouchIDPermissionDenied
        } catch {
            throw ServiceError.sudoTouchIDFailed
        }
    }

    static func transform(
        sudo: String, local: String?, enabled: Bool?, removeExternal: Bool = false
    ) throws
        -> (state: SudoTouchIDState, contents: String?)
    {
        let text = local ?? ""
        let prefix = [createdPrefix, existingPrefix].first { text.hasPrefix($0) }
        if let prefix {
            let remaining = String(text.dropFirst(prefix.count))
            guard !remaining.contains(marker) else { throw JournalError.unexpectedContents }
            if enabled == false {
                return (.disabled, prefix == createdPrefix && remaining.isEmpty ? nil : remaining)
            }
        }
        guard prefix != nil || !text.contains(marker) else { throw JournalError.unexpectedContents }
        if enabled == false && !removeExternal { return (.disabled, local) }
        func entries(_ value: String) -> [[String]] {
            value.split(separator: "\n").compactMap { line in
                let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(
                    String.init)
                return fields.isEmpty || fields[0].hasPrefix("#") ? nil : fields
            }
        }
        let expected = [
            ["auth", "include", "sudo_local"],
            ["auth", "sufficient", "pam_smartcard.so"],
            ["auth", "required", "pam_opendirectory.so"],
            ["account", "required", "pam_permit.so"],
            ["password", "required", "pam_deny.so"],
            ["session", "required", "pam_permit.so"],
        ]
        guard entries(sudo) == expected else { throw JournalError.unexpectedContents }
        let localEntries = entries(text)
        if prefix != nil {
            guard localEntries == [["auth", "sufficient", "pam_tid.so"]] else {
                throw JournalError.unexpectedContents
            }
            return (.enabled, local)
        }
        if localEntries == [["auth", "sufficient", "pam_tid.so"]] {
            if enabled == false {
                let remaining = text.split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { entries(String($0)).isEmpty }.joined(separator: "\n")
                return (.disabled, remaining)
            }
            return (.external, local)
        }
        guard localEntries.isEmpty else { throw JournalError.unexpectedContents }
        guard enabled == true else { return (.disabled, local) }
        return (.enabled, (local == nil ? createdPrefix : existingPrefix) + text)
    }

    static func access(
        change: Bool?, removeExternal: Bool = false, checkingOwnership: Bool = false,
        root: URL = URL(fileURLWithPath: "/"), owner: uid_t = 0
    )
        throws -> SudoTouchIDState
    {
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw JournalError.system(errno) }
        var descriptors = [rootFD]
        defer { for fd in descriptors.reversed() { close(fd) } }
        let parts = ["private", "etc", "pam.d"]
        try SecureOwnershipJournal.validateDirectory(rootFD, owner: owner, privateOnly: false)
        for part in parts {
            let fd = openat(
                descriptors.last!, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw JournalError.system(errno) }
            descriptors.append(fd)
            try SecureOwnershipJournal.validateDirectory(fd, owner: owner, privateOnly: false)
        }
        let directory = descriptors.last!
        struct Snapshot: Equatable {
            let text: String
            let inode: ino_t
            let device: dev_t
            let mode: mode_t
            let group: gid_t
        }
        func read(_ name: String) throws -> Snapshot? {
            let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard file >= 0 else {
                if errno == ENOENT { return nil }
                throw JournalError.system(errno)
            }
            defer { close(file) }
            var info = stat()
            guard fstat(file, &info) == 0 else { throw JournalError.system(errno) }
            guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == owner,
                info.st_mode & 0o7022 == 0, info.st_nlink == 1,
                info.st_size <= 16_384
            else { throw JournalError.insecureFile }
            try SecureOwnershipJournal.rejectExtendedAccess(file)
            let data =
                try FileHandle(fileDescriptor: file, closeOnDealloc: false)
                .read(upToCount: 16_385) ?? Data()
            guard data.count <= 16_384, let text = String(data: data, encoding: .utf8),
                !text.contains("\0"), !text.contains("\r")
            else { throw JournalError.unexpectedContents }
            try SecureOwnershipJournal.requireSameEntry(directory, name: name, descriptor: file)
            return Snapshot(
                text: text, inode: info.st_ino, device: info.st_dev,
                mode: info.st_mode & 0o777, group: info.st_gid)
        }
        let sudo = try read("sudo")
        let local = try read("sudo_local")
        if checkingOwnership {
            let cleaned = try transform(sudo: sudo?.text ?? "", local: local?.text, enabled: false)
            return cleaned.contents == local?.text ? .disabled : .enabled
        }
        let result = try transform(
            sudo: sudo?.text ?? "", local: local?.text, enabled: change,
            removeExternal: removeExternal)
        guard change != nil, result.contents != local?.text else { return result.state }
        guard (result.contents?.utf8.count ?? 0) <= 16_384 else {
            throw JournalError.unexpectedContents
        }
        for (index, part) in parts.enumerated() {
            try SecureOwnershipJournal.validateDirectory(
                descriptors[index], owner: owner, privateOnly: false)
            try SecureOwnershipJournal.requireSameEntry(
                descriptors[index], name: part, descriptor: descriptors[index + 1])
        }
        guard try read("sudo") == sudo, try read("sudo_local") == local else {
            throw JournalError.unexpectedContents
        }
        if let contents = result.contents {
            let temporary = ".awake-\(UUID().uuidString)"
            let file = openat(
                directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard file >= 0 else { throw JournalError.system(errno) }
            defer {
                close(file)
                unlinkat(directory, temporary, 0)
            }
            try FileHandle(fileDescriptor: file, closeOnDealloc: false).write(
                contentsOf: Data(contents.utf8))
            if let local, fchown(file, owner, local.group) != 0 { throw JournalError.system(errno) }
            guard fchmod(file, local?.mode ?? 0o444) == 0,
                fsync(file) == 0, fcntl(file, F_FULLFSYNC) == 0
            else { throw JournalError.system(errno) }
            guard try read("sudo_local") == local, try read("sudo") == sudo else {
                throw JournalError.unexpectedContents
            }
            guard renameat(directory, temporary, directory, "sudo_local") == 0 else {
                throw JournalError.system(errno)
            }
        } else if unlinkat(directory, "sudo_local", 0) != 0 {
            throw JournalError.system(errno)
        }
        guard fsync(directory) == 0 else { throw JournalError.system(errno) }
        guard try read("sudo_local")?.text == result.contents else {
            throw JournalError.unexpectedContents
        }
        return result.state
    }
}

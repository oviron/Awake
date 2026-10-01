import Darwin
import Foundation

public enum AgentSetup {
    public static let providers = ["codex", "claude", "cursor", "gemini"]
    private static let maximumFileSize = 1_024 * 1_024

    private struct ManagedFile: Equatable {
        let data: Data
        let device: dev_t
        let inode: ino_t
        let mode: mode_t
    }

    private final class ManagedDirectory {
        private let descriptors: [Int32]
        private let components: [String]
        private let owner: uid_t
        private var descriptor: Int32 { descriptors.last! }

        private init(descriptors: [Int32], components: [String], owner: uid_t) {
            self.descriptors = descriptors
            self.components = components
            self.owner = owner
        }

        deinit {
            for descriptor in descriptors.reversed() { close(descriptor) }
        }

        static func open(
            home: URL, components: [String], create: Bool, owner: uid_t
        ) throws -> ManagedDirectory? {
            if create, mkdir(home.path, 0o700) != 0, errno != EEXIST {
                throw JournalError.system(errno)
            }
            let root = Darwin.open(
                home.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard root >= 0 else {
                if !create, errno == ENOENT { return nil }
                throw JournalError.system(errno)
            }
            var descriptors = [root]
            do {
                try validateDirectory(root, owner: owner)
                for component in components {
                    try validateName(component)
                    let parent = descriptors.last!
                    var child = openat(
                        parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    if child < 0, errno == ENOENT {
                        guard create else {
                            for descriptor in descriptors.reversed() { close(descriptor) }
                            return nil
                        }
                        guard mkdirat(parent, component, 0o700) == 0 || errno == EEXIST else {
                            throw JournalError.system(errno)
                        }
                        child = openat(
                            parent, component,
                            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    }
                    guard child >= 0 else { throw JournalError.system(errno) }
                    descriptors.append(child)
                    try validateDirectory(child, owner: owner)
                    try SecureOwnershipJournal.requireSameEntry(
                        parent, name: component, descriptor: child)
                }
                return ManagedDirectory(
                    descriptors: descriptors, components: components, owner: owner)
            } catch {
                for descriptor in descriptors.reversed() { close(descriptor) }
                throw error
            }
        }

        func read(_ name: String) throws -> ManagedFile? {
            try Self.validateName(name)
            try validate()
            let file = openat(
                descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard file >= 0 else {
                if errno == ENOENT { return nil }
                throw JournalError.system(errno)
            }
            defer { close(file) }
            let initial = try validateFile(file)
            let data =
                try FileHandle(fileDescriptor: file, closeOnDealloc: false)
                .read(upToCount: maximumFileSize + 1) ?? Data()
            let final = try validateFile(file)
            guard data.count <= maximumFileSize, initial.st_dev == final.st_dev,
                initial.st_ino == final.st_ino, initial.st_size == final.st_size,
                final.st_size == off_t(data.count)
            else { throw CocoaError(.fileReadCorruptFile) }
            try SecureOwnershipJournal.requireSameEntry(
                descriptor, name: name, descriptor: file)
            try validate()
            return ManagedFile(
                data: data, device: final.st_dev, inode: final.st_ino,
                mode: final.st_mode & 0o777)
        }

        func names() throws -> Set<String> {
            try validate()
            let copy = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
            guard copy >= 0 else { throw JournalError.system(errno) }
            guard let directory = fdopendir(copy) else {
                let code = errno
                close(copy)
                throw JournalError.system(code)
            }
            defer { closedir(directory) }
            var names: Set<String> = []
            while true {
                errno = 0
                guard let entry = readdir(directory) else {
                    guard errno == 0 else { throw JournalError.system(errno) }
                    break
                }
                let name = withUnsafePointer(to: entry.pointee.d_name) {
                    $0.withMemoryRebound(
                        to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1
                    ) { String(cString: $0) }
                }
                if name != ".", name != ".." { names.insert(name) }
            }
            try validate()
            return names
        }

        func create(_ name: String, data: Data, mode: mode_t) throws -> ManagedFile {
            try Self.validateName(name)
            guard data.count <= maximumFileSize else {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try validate()
            let file = openat(
                descriptor, name,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, mode)
            guard file >= 0 else { throw JournalError.system(errno) }
            defer { close(file) }
            try FileHandle(fileDescriptor: file, closeOnDealloc: false).write(contentsOf: data)
            guard fchmod(file, mode) == 0, fsync(file) == 0 else {
                throw JournalError.system(errno)
            }
            let info = try validateFile(file)
            guard info.st_size == off_t(data.count) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try SecureOwnershipJournal.requireSameEntry(
                descriptor, name: name, descriptor: file)
            guard fsync(descriptor) == 0 else { throw JournalError.system(errno) }
            try validate()
            return ManagedFile(
                data: data, device: info.st_dev, inode: info.st_ino,
                mode: info.st_mode & 0o777)
        }

        func replace(
            _ name: String, data: Data, expected: ManagedFile?, replacement: inout ManagedFile?
        ) throws {
            try Self.validateName(name)
            guard data.count <= maximumFileSize else {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            guard try read(name) == expected else { throw CocoaError(.fileWriteUnknown) }
            let temporary = ".awake-\(UUID().uuidString)"
            let file = openat(
                descriptor, temporary,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
            guard file >= 0 else { throw JournalError.system(errno) }
            defer {
                close(file)
                unlinkat(descriptor, temporary, 0)
            }
            try FileHandle(fileDescriptor: file, closeOnDealloc: false).write(contentsOf: data)
            guard fchmod(file, expected?.mode ?? 0o600) == 0, fsync(file) == 0 else {
                throw JournalError.system(errno)
            }
            let info = try validateFile(file)
            guard info.st_size == off_t(data.count) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let candidate = ManagedFile(
                data: data, device: info.st_dev, inode: info.st_ino,
                mode: info.st_mode & 0o777)
            try validate()
            guard try read(name) == expected else { throw CocoaError(.fileWriteUnknown) }
            replacement = candidate
            guard renameat(descriptor, temporary, descriptor, name) == 0,
                fsync(descriptor) == 0
            else { throw JournalError.system(errno) }
            guard try read(name) == candidate else { throw CocoaError(.fileWriteUnknown) }
        }

        func remove(_ name: String, expected: ManagedFile?) throws {
            try Self.validateName(name)
            let current = try read(name)
            guard current == expected else { throw CocoaError(.fileWriteUnknown) }
            guard current != nil else { return }
            try validate()
            guard try read(name) == expected else { throw CocoaError(.fileWriteUnknown) }
            guard unlinkat(descriptor, name, 0) == 0, fsync(descriptor) == 0 else {
                throw JournalError.system(errno)
            }
            guard try read(name) == nil else { throw CocoaError(.fileWriteUnknown) }
        }

        func removeIfEmpty() throws {
            guard descriptors.count > 1, let name = components.last else {
                throw CocoaError(.fileWriteNoPermission)
            }
            guard try names().isEmpty else { return }
            let parent = descriptors[descriptors.count - 2]
            try SecureOwnershipJournal.requireSameEntry(
                parent, name: name, descriptor: descriptor)
            guard unlinkat(parent, name, AT_REMOVEDIR) == 0, fsync(parent) == 0 else {
                throw JournalError.system(errno)
            }
        }

        private func validate() throws {
            for descriptor in descriptors {
                try Self.validateDirectory(descriptor, owner: owner)
            }
            for (index, component) in components.enumerated() {
                try SecureOwnershipJournal.requireSameEntry(
                    descriptors[index], name: component, descriptor: descriptors[index + 1])
            }
        }

        private func validateFile(_ file: Int32) throws -> stat {
            var info = stat()
            guard fstat(file, &info) == 0 else { throw JournalError.system(errno) }
            guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == owner,
                info.st_mode & 0o022 == 0, info.st_nlink == 1, info.st_size >= 0,
                info.st_size <= off_t(maximumFileSize)
            else { throw CocoaError(.fileReadCorruptFile) }
            try SecureOwnershipJournal.rejectWriteGrantingAccess(file)
            return info
        }

        private static func validateDirectory(_ descriptor: Int32, owner: uid_t) throws {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw JournalError.system(errno) }
            guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == owner,
                info.st_mode & 0o022 == 0
            else {
                throw CocoaError(.fileWriteNoPermission)
            }
            try SecureOwnershipJournal.rejectWriteGrantingAccess(descriptor)
        }

        private static func validateName(_ name: String) throws {
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
                throw CocoaError(.fileReadInvalidFileName)
            }
        }
    }

    private static func locations(_ provider: String) throws -> (config: String, skill: String) {
        switch provider {
        case "codex": (".codex/hooks.json", ".agents/skills/awake")
        case "claude": (".claude/settings.json", ".claude/skills/awake")
        case "cursor": (".cursor/hooks.json", ".cursor/skills/awake")
        case "gemini": (".gemini/settings.json", ".gemini/skills/awake")
        default: throw CocoaError(.fileReadInvalidFileName)
        }
    }

    private static func restore(
        _ directory: ManagedDirectory, name: String, previous: ManagedFile?,
        attempted: ManagedFile?,
        allowMissing: Bool = false
    ) throws {
        let current = try directory.read(name)
        guard current == previous || current == attempted || (allowMissing && current == nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard current != previous else { return }
        if let previous {
            var replacement: ManagedFile?
            try directory.replace(
                name, data: previous.data, expected: current, replacement: &replacement)
        } else {
            try directory.remove(name, expected: current)
        }
    }

    static func merged(_ data: Data?, template: Data, provider: String, remove: Bool) throws -> Data
    {
        let source = try JSONSerialization.jsonObject(with: template) as? [String: Any]
        guard let additions = source?["hooks"] as? [String: [[String: Any]]] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var config: [String: Any] = [:]
        if let data {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            config = parsed
        }
        if provider == "cursor", let version = config["version"], (version as? Int) != 1 {
            throw CocoaError(.fileReadCorruptFile)
        }
        if config["hooks"] != nil, !(config["hooks"] is [String: Any]) {
            throw CocoaError(.fileReadCorruptFile)
        }
        var hooks = config["hooks"] as? [String: Any] ?? [:]
        let command = "/Applications/Awake.app/Contents/MacOS/awake hook " + provider
        for (event, entries) in additions {
            if hooks[event] != nil, !(hooks[event] is [[String: Any]]) {
                throw CocoaError(.fileReadCorruptFile)
            }
            let existing = hooks[event] as? [[String: Any]] ?? []
            var retained: [[String: Any]] = []
            for var entry in existing {
                if provider == "cursor" {
                    if entry["command"] as? String != command { retained.append(entry) }
                } else if let commands = entry["hooks"] as? [[String: Any]] {
                    let remaining = commands.filter { $0["command"] as? String != command }
                    if remaining.count == commands.count {
                        retained.append(entry)
                    } else if !remaining.isEmpty {
                        entry["hooks"] = remaining
                        retained.append(entry)
                    }
                } else {
                    retained.append(entry)
                }
            }
            if !remove { retained += entries }
            hooks[event] = retained.isEmpty ? nil : retained
        }
        config["hooks"] = hooks.isEmpty ? nil : hooks
        if provider == "cursor", !remove { config["version"] = 1 }
        return try JSONSerialization.data(
            withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
    }

    public static func configure(
        _ provider: String, remove: Bool = false,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        resources: URL = URL(
            fileURLWithPath: "/Applications/Awake.app/Contents/Resources/awake-skill")
    ) throws {
        try configure(
            provider, remove: remove, home: home, resources: resources, beforeMutation: {})
    }

    static func configure(
        _ provider: String, remove: Bool,
        home: URL,
        resources: URL,
        beforeMutation: () throws -> Void
    ) throws {
        guard geteuid() != 0 else { throw CocoaError(.fileWriteNoPermission) }
        let home = home.standardizedFileURL.resolvingSymlinksInPath()
        let paths = try locations(provider)
        let configParts = paths.config.split(separator: "/").map(String.init)
        let skillParts = paths.skill.split(separator: "/").map(String.init)
        guard let configName = configParts.last else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let owner = geteuid()
        var skillDirectory = try ManagedDirectory.open(
            home: home, components: skillParts, create: false, owner: owner)
        var configDirectory = try ManagedDirectory.open(
            home: home, components: Array(configParts.dropLast()), create: false, owner: owner)
        let skillExisted = skillDirectory != nil
        let old = try configDirectory?.read(configName)
        let existingMarker = try skillDirectory?.read(".awake-managed")
        if remove, existingMarker == nil { return }
        let newConfigMarker = Data("Awake:new-config\n".utf8)
        let savedMarker =
            existingMarker?.data ?? (old == nil ? newConfigMarker : Data("Awake\n".utf8))
        let template = try Data(
            contentsOf: resources.appendingPathComponent("hooks/\(provider).json"))
        let updated = try merged(
            old?.data, template: template, provider: provider, remove: remove)
        let skillText = try Data(contentsOf: resources.appendingPathComponent("SKILL.md"))
        if skillExisted {
            let names = try skillDirectory!.names()
            guard names.isSubset(of: ["SKILL.md", ".awake-managed"]),
                existingMarker?.data == Data("Awake\n".utf8)
                    || existingMarker?.data == newConfigMarker
            else { throw CocoaError(.fileWriteFileExists) }
        }
        let oldSkill = try skillDirectory?.read("SKILL.md")
        let unchanged =
            old.flatMap { try? JSONSerialization.jsonObject(with: $0.data) as? NSDictionary }
            == (try JSONSerialization.jsonObject(with: updated) as? NSDictionary)
        if unchanged, !remove, oldSkill?.data == skillText { return }
        if configDirectory == nil {
            configDirectory = try ManagedDirectory.open(
                home: home, components: Array(configParts.dropLast()), create: true, owner: owner)
        }
        if skillDirectory == nil {
            skillDirectory = try ManagedDirectory.open(
                home: home, components: skillParts, create: true, owner: owner)
        }
        let activeConfigDirectory = configDirectory!
        let activeSkillDirectory = skillDirectory!
        var backupName: String?
        var backup: ManagedFile?
        var writtenConfig: ManagedFile?
        var writtenSkill: ManagedFile?
        var writtenMarker: ManagedFile?
        let removeConfig: Bool
        if remove {
            let remaining = try JSONSerialization.jsonObject(with: updated) as? [String: Any] ?? [:]
            removeConfig =
                existingMarker?.data == newConfigMarker
                && (remaining.isEmpty
                    || (provider == "cursor" && Set(remaining.keys) == ["version"]))
        } else {
            removeConfig = false
        }
        do {
            try beforeMutation()
            if !unchanged, let old {
                let name = configName + ".awake-backup-" + UUID().uuidString
                backupName = name
                backup = try activeConfigDirectory.create(name, data: old.data, mode: 0o600)
            }
            if !remove {
                try activeSkillDirectory.replace(
                    "SKILL.md", data: skillText, expected: oldSkill,
                    replacement: &writtenSkill)
                try activeSkillDirectory.replace(
                    ".awake-managed", data: savedMarker, expected: existingMarker,
                    replacement: &writtenMarker
                )
            }
            if !unchanged {
                try activeConfigDirectory.replace(
                    configName, data: updated, expected: old, replacement: &writtenConfig)
            }
            if remove {
                if removeConfig {
                    try activeConfigDirectory.remove(configName, expected: writtenConfig ?? old)
                }
                try activeSkillDirectory.remove("SKILL.md", expected: oldSkill)
                try activeSkillDirectory.remove(".awake-managed", expected: existingMarker)
                try activeSkillDirectory.removeIfEmpty()
            }
        } catch {
            let setupError = error
            var rollbackError: (any Error)?
            func attempt(_ action: () throws -> Void) {
                do {
                    try action()
                } catch {
                    if rollbackError == nil { rollbackError = error }
                }
            }
            attempt {
                try restore(
                    activeSkillDirectory, name: "SKILL.md", previous: oldSkill,
                    attempted: writtenSkill, allowMissing: remove)
            }
            attempt {
                try restore(
                    activeSkillDirectory, name: ".awake-managed", previous: existingMarker,
                    attempted: writtenMarker, allowMissing: remove)
            }
            if !remove, !skillExisted { attempt { try activeSkillDirectory.removeIfEmpty() } }
            attempt {
                try restore(
                    activeConfigDirectory, name: configName, previous: old,
                    attempted: writtenConfig, allowMissing: remove && removeConfig)
            }
            if let backupName, let backup {
                attempt { try activeConfigDirectory.remove(backupName, expected: backup) }
            }
            if let rollbackError { throw rollbackError }
            throw setupError
        }
    }
}

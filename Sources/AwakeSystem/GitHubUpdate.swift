import CryptoKit
import Darwin
import Foundation
import Security

public struct UpdateSchedule: Codable, Sendable {
    public static let interval: TimeInterval = 8 * 3_600
    public private(set) var nextCheck = Date.distantPast
    public private(set) var nextDownload = Date.distantPast
    private var checkFailures = 0
    private var downloadFailures = 0
    private var manualCheckAfter = Date.distantPast
    private var manualDownloadAfter = Date.distantPast
    private var rateLimitUntil = Date.distantPast
    private let scheduledInterval = Self.interval

    private enum CodingKeys: String, CodingKey {
        case nextCheck, nextDownload, checkFailures, downloadFailures, scheduledInterval
        case manualCheckAfter, manualDownloadAfter, rateLimitUntil
    }

    public init() {}

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let previousInterval =
            try values.decodeIfPresent(
                TimeInterval.self, forKey: .scheduledInterval) ?? 8 * 3_600
        checkFailures = try values.decode(Int.self, forKey: .checkFailures)
        downloadFailures = try values.decode(Int.self, forKey: .downloadFailures)
        guard
            [Self.interval, TimeInterval(12 * 3_600), TimeInterval(24 * 3_600)]
                .contains(previousInterval),
            (0...6).contains(checkFailures), (0...6).contains(downloadFailures)
        else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: values.codingPath, debugDescription: "Invalid update schedule"))
        }
        let checkShift =
            checkFailures == 0
            ? Self.interval - previousInterval : max(0, Self.interval - previousInterval)
        let downloadShift =
            downloadFailures == 0
            ? Self.interval - previousInterval : max(0, Self.interval - previousInterval)
        nextCheck = try values.decode(Date.self, forKey: .nextCheck)
            .addingTimeInterval(checkShift)
        nextDownload = try values.decode(Date.self, forKey: .nextDownload)
            .addingTimeInterval(downloadShift)
        manualCheckAfter =
            try values.decodeIfPresent(Date.self, forKey: .manualCheckAfter)
            ?? .distantPast
        manualDownloadAfter =
            try values.decodeIfPresent(Date.self, forKey: .manualDownloadAfter)
            ?? .distantPast
        rateLimitUntil =
            try values.decodeIfPresent(Date.self, forKey: .rateLimitUntil)
            ?? .distantPast
    }

    public mutating func beginCheck(manual: Bool = false, at now: Date = Date()) -> Bool {
        let due = manual || now >= nextCheck
        guard now >= manualCheckAfter, now >= rateLimitUntil, due
        else { return false }
        nextCheck = now.addingTimeInterval(Self.interval)
        manualCheckAfter = now.addingTimeInterval(5 * 60)
        return true
    }

    public func nextManualCheck(at now: Date = Date()) -> Date? {
        let next = max(manualCheckAfter, rateLimitUntil)
        return next > now ? next : nil
    }

    public func canBeginDownload(manual: Bool = false, at now: Date = Date()) -> Bool {
        now >= rateLimitUntil && (manual ? now >= manualDownloadAfter : now >= nextDownload)
    }

    public mutating func beginDownload(manual: Bool = false, at now: Date = Date()) -> Bool {
        guard canBeginDownload(manual: manual, at: now) else { return false }
        nextDownload = now.addingTimeInterval(Self.interval)
        manualDownloadAfter = now.addingTimeInterval(5 * 60)
        return true
    }

    public mutating func checked() { checkFailures = 0 }

    public mutating func downloaded() { downloadFailures = 0 }

    public mutating func failed(download: Bool, retryAfter: Date? = nil, at now: Date = Date()) {
        if download {
            downloadFailures = min(downloadFailures, 5) + 1
        } else {
            checkFailures = min(checkFailures, 5) + 1
        }
        let failures = download ? downloadFailures : checkFailures
        let delay = min(Self.interval * pow(2, Double(failures - 1)), 7 * 86_400)
        let next = max(now.addingTimeInterval(delay), retryAfter ?? .distantPast)
        if download {
            nextDownload = max(nextDownload, next)
        } else {
            nextCheck = max(nextCheck, next)
        }
        if let retryAfter {
            rateLimitUntil = max(rateLimitUntil, retryAfter)
            nextCheck = max(nextCheck, retryAfter)
            nextDownload = max(nextDownload, retryAfter)
        }
    }
}

public enum UpdateError: Error, LocalizedError, Equatable, Sendable {
    case invalidRelease, invalidArchive, untrustedBuild, unsafeLocation, busy, failed
    case rateLimited(until: Date)
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidRelease: "GitHub did not provide a valid Awake release."
        case .invalidArchive: "The update archive failed verification."
        case .untrustedBuild: "The update must be signed by the same certificate as this app."
        case .unsafeLocation: "Move Awake to a writable Applications folder before updating."
        case .busy: "Close the running Awake app before replacing it."
        case .failed: "The update could not be completed. Reopen Awake or retry."
        case .rateLimited(let until):
            "GitHub's request limit was reached. Try again after \(until.formatted(date: .omitted, time: .shortened))."
        case .httpStatus(let status): "GitHub returned HTTP \(status)."
        }
    }
}

public enum GitHubUpdate {
    public static let repository = URL(string: "https://github.com/oviron/Awake")!
    private static let installedApplication = URL(
        fileURLWithPath: "/Applications/Awake.app", isDirectory: true)
    static let latestURL = repository.appendingPathComponent(
        "releases/latest/download/release.json")
    static let maximumArchiveSize = 64 * 1_024 * 1_024

    public struct Release: Equatable, Sendable {
        public let version: String
        let url: URL
        let digest: String
        let sourceRevision: String
    }

    public struct Staged: Sendable {
        public let app: URL
        public let directory: URL
    }

    private struct Manifest: Decodable {
        let version: String
        let sourceRevision: String
        let archive: String
        let sha256: String
        let channel: String
        let notarized: Bool
    }

    static func version(_ text: String) throws -> [Int] {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw UpdateError.invalidRelease }
        return try parts.map {
            guard !$0.isEmpty, $0.count <= 9,
                $0.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int($0),
                String(number) == $0
            else { throw UpdateError.invalidRelease }
            return number
        }
    }

    static func release(from data: Data, currentVersion: String) throws -> Release? {
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            throw UpdateError.invalidRelease
        }
        let candidate = manifest.version
        guard try version(currentVersion).lexicographicallyPrecedes(version(candidate)) else {
            return nil
        }
        let archive = "Awake-\(candidate)-universal.zip"
        guard manifest.archive == archive,
            manifest.sourceRevision.utf8.count == 40,
            manifest.sourceRevision.utf8.allSatisfy({
                (48...57).contains($0) || (97...102).contains($0)
            }),
            manifest.sha256.utf8.count == 64,
            manifest.sha256.utf8.allSatisfy({
                (48...57).contains($0) || (97...102).contains($0)
            }),
            (manifest.channel == "community" && !manifest.notarized)
                || (manifest.channel == "developer-id" && manifest.notarized),
            let url = URL(
                string: repository.absoluteString
                    + "/releases/download/v\(candidate)/\(archive)")
        else { throw UpdateError.invalidRelease }
        return Release(
            version: candidate, url: url, digest: manifest.sha256,
            sourceRevision: manifest.sourceRevision)
    }

    @concurrent public static func latest(currentVersion: String) async throws -> Release? {
        guard let data = try await download(latestURL, limit: 1_024 * 1_024, allowsMissing: true)
        else { return nil }
        return try release(from: data, currentVersion: currentVersion)
    }

    private static func download(_ url: URL, limit: Int, allowsMissing: Bool = false) async throws
        -> Data?
    {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        let session = URLSession(
            configuration: configuration, delegate: GitHubRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("Awake", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw UpdateError.invalidRelease }
        guard try validateResponse(response, limit: limit, allowsMissing: allowsMissing) else {
            return nil
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw UpdateError.invalidArchive }
            data.append(byte)
        }
        return data
    }

    static func validateResponse(
        _ response: HTTPURLResponse, limit: Int, allowsMissing: Bool = false, now: Date = Date()
    ) throws -> Bool {
        guard let url = response.url, GitHubRedirects.allows(url) else {
            throw UpdateError.invalidRelease
        }
        if allowsMissing, response.statusCode == 404 { return false }
        if response.statusCode == 429
            || (response.statusCode == 403
                && (response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
                    || response.value(forHTTPHeaderField: "Retry-After") != nil))
        {
            let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset")
                .flatMap(TimeInterval.init).map { $0 - now.timeIntervalSince1970 }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap {
                TimeInterval($0) ?? formatter.date(from: $0)?.timeIntervalSince(now)
            }
            let delay =
                [reset, retry].compactMap { $0 }.filter {
                    $0.isFinite && $0 > 0 && $0 <= Date.distantFuture.timeIntervalSince(now)
                }.max() ?? UpdateSchedule.interval
            throw UpdateError.rateLimited(until: now.addingTimeInterval(max(60, delay)))
        }
        guard response.statusCode == 200 else { throw UpdateError.httpStatus(response.statusCode) }
        guard response.expectedContentLength <= limit else { throw UpdateError.invalidRelease }
        return true
    }

    @concurrent public static func stage(
        _ release: Release, identity: SignedIdentity, installedApp: URL
    ) async throws -> Staged {
        let target = try canonical(installedApp)
        try requireWritableApp(target)
        let directory = target.deletingLastPathComponent().appendingPathComponent(
            ".Awake-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        var staged = false
        defer { if !staged { try? FileManager.default.removeItem(at: directory) } }
        guard let data = try await download(release.url, limit: maximumArchiveSize),
            SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == release.digest
        else { throw UpdateError.invalidArchive }
        let archive = directory.appendingPathComponent("update.zip")
        try data.write(to: archive, options: .withoutOverwriting)
        try await extract(archive, to: directory)
        let app = directory.appendingPathComponent("Awake.app")
        try verify(
            app, identity: identity, newerThan: target, expectedVersion: release.version,
            expectedSourceRevision: release.sourceRevision)
        try quarantine(app, downloadedFrom: release.url)
        staged = true
        return Staged(app: app, directory: directory)
    }

    static func quarantine(_ app: URL, downloadedFrom url: URL) throws {
        try (app as NSURL).setResourceValue(
            [
                "LSQuarantineAgentName": "Awake",
                "LSQuarantineType": "LSQuarantineTypeOtherDownload",
                "LSQuarantineTimeStamp": Date(),
                "LSQuarantineOriginURL": repository,
                "LSQuarantineDataURL": url,
            ], forKey: .quarantinePropertiesKey)
        let properties =
            try app.resourceValues(forKeys: [.quarantinePropertiesKey]).allValues[
                .quarantinePropertiesKey] as? [String: Any]
        guard properties?["LSQuarantineAgentName"] as? String == "Awake" else {
            throw UpdateError.invalidArchive
        }
    }

    static func validateListing(_ listing: String) throws {
        let lines = listing.split(separator: "\n")
        guard !lines.isEmpty, lines.count <= 512 else { throw UpdateError.invalidArchive }
        var total = 0
        var names: Set<String> = []
        for line in lines {
            let fields = line.split(
                maxSplits: 8, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 9, let mode = fields.first,
                mode.first == "-" || mode.first == "d",
                !mode.contains("s"), !mode.contains("S"), !mode.contains("t"), !mode.contains("T"),
                let size = Int(fields[4]), (0...maximumArchiveSize * 4).contains(size)
            else { throw UpdateError.invalidArchive }
            let path = String(fields[8])
            guard path.hasPrefix("Awake.app/"),
                path.utf8.allSatisfy({
                    (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                        || [32, 45, 46, 47, 95].contains($0)
                }),
                !path.split(separator: "/").contains(".."), !path.contains("//"),
                names.insert(path).inserted
            else { throw UpdateError.invalidArchive }
            total += size
            guard total <= maximumArchiveSize * 4 else { throw UpdateError.invalidArchive }
        }
        guard names.contains("Awake.app/Contents/Info.plist"),
            names.contains("Awake.app/Contents/MacOS/AwakeApp")
        else { throw UpdateError.invalidArchive }
    }

    static func extract(_ archive: URL, to directory: URL) async throws {
        let listing = try await tar(["-tvf", archive.path], directory: directory)
        try validateListing(listing)
        _ = try await tar(
            [
                "-xkf", archive.path, "--no-same-owner", "--no-same-permissions", "--no-acls",
                "--no-fflags", "-C", directory.path,
            ], directory: directory)
    }

    private static func tar(_ arguments: [String], directory: URL) async throws -> String {
        let output = directory.appendingPathComponent(UUID().uuidString + ".log")
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else {
            throw UpdateError.invalidArchive
        }
        let handle = try FileHandle(forWritingTo: output)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: output)
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        child.arguments = arguments
        child.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "TZ": "UTC"]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = handle
        child.standardError = FileHandle.nullDevice
        try child.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while child.isRunning {
            let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            if Task.isCancelled || ContinuousClock.now >= deadline || size > 1_024 * 1_024 {
                child.terminate()
                try? await Task.sleep(for: .milliseconds(250))
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                child.waitUntilExit()
                throw UpdateError.invalidArchive
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard child.terminationReason == .exit, child.terminationStatus == 0 else {
            throw UpdateError.invalidArchive
        }
        let data = try Data(contentsOf: output)
        guard data.count <= 1_024 * 1_024, let text = String(data: data, encoding: .utf8) else {
            throw UpdateError.invalidArchive
        }
        return text
    }

    private static func requireWritableApp(_ app: URL) throws {
        let values = try app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard app.lastPathComponent == "Awake.app", values.isDirectory == true,
            values.isSymbolicLink == false,
            FileManager.default.isWritableFile(atPath: app.path),
            FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path),
            geteuid() != 0, geteuid() == getuid()
        else { throw UpdateError.unsafeLocation }
    }

    private static func canonical(_ url: URL) throws -> URL {
        guard url.isFileURL, let path = realpath(url.path, nil) else {
            throw UpdateError.unsafeLocation
        }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    @concurrent public static func currentInstalledApplication(identity: SignedIdentity)
        async throws
        -> URL
    {
        guard try canonical(installedApplication) == installedApplication else {
            throw UpdateError.unsafeLocation
        }
        try requireCurrentApplication(installedApplication, identity: identity)
        return installedApplication
    }

    private static func requireCurrentApplication(_ app: URL, identity: SignedIdentity) throws {
        let details = try identity.verifyExecutable(
            at: app, identifier: AwakeIdentity.application)
        let runningRecord = try? Data(
            contentsOf: Bundle.main.bundleURL.appendingPathComponent(
                "Contents/Resources/Build.json"))
        let installedRecord = try? Data(
            contentsOf: app.appendingPathComponent("Contents/Resources/Build.json"))
        guard let info = details[kSecCodeInfoPList as String] as? [String: Any],
            info["CFBundleVersion"] as? String
                == Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            info["CFBundleShortVersionString"] as? String
                == Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String,
            let runningRecord, runningRecord.count <= 4_096,
            let installedRecord, installedRecord == runningRecord
        else { throw UpdateError.unsafeLocation }
    }

    public static func verify(
        _ app: URL, identity: SignedIdentity, newerThan current: URL,
        expectedVersion: String? = nil, expectedSourceRevision: String? = nil
    ) throws {
        let info = try identity.verifyExecutable(at: app, identifier: AwakeIdentity.application)
        guard let plist = info[kSecCodeInfoPList as String] as? [String: Any],
            plist["CFBundleIdentifier"] as? String == AwakeIdentity.application,
            plist["CFBundleExecutable"] as? String == "AwakeApp",
            let build = plist["CFBundleVersion"] as? String,
            let buildNumber = Int(build), buildNumber > 0,
            let versionName = plist["CFBundleShortVersionString"] as? String,
            let oldVersion = Bundle(url: current)?.object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            try version(oldVersion).lexicographicallyPrecedes(version(versionName)),
            expectedVersion == nil || expectedVersion == versionName,
            let kindName = plist["AwakeHelperInstallation"] as? String,
            let kind = HelperInstallationKind(rawValue: kindName),
            kindName == Bundle(url: current)?.object(
                forInfoDictionaryKey: "AwakeHelperInstallation") as? String,
            let flags = info[kSecCodeInfoFlags as String] as? UInt32, flags & 0x10000 != 0
        else { throw UpdateError.untrustedBuild }
        let cliInfo = try identity.verifyExecutable(
            at: app.appendingPathComponent("Contents/MacOS/awake"),
            identifier: AwakeIdentity.commandLine)
        let helperPath =
            kind == .blessed
            ? "Library/LaunchServices/" + AwakeIdentity.helper
            : "Library/HelperTools/AwakeHelper"
        let helperInfo = try identity.verifyExecutable(
            at: app.appendingPathComponent("Contents/" + helperPath),
            identifier: AwakeIdentity.helper)
        let sudoInfo = try SudoInstallation.verifyBundle(
            app.appendingPathComponent(AwakeIdentity.sudoBundlePath), identity: identity,
            build: build)
        for details in [info, cliInfo, helperInfo] + sudoInfo {
            guard let flags = details[kSecCodeInfoFlags as String] as? UInt32,
                flags & 0x10000 != 0,
                (details[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]).isEmpty
            else { throw UpdateError.untrustedBuild }
        }
        struct Record: Decodable {
            let configuration: String
            let sourceClean: Bool
            let sourceRevision: String
        }
        let recordData = try Data(
            contentsOf: app.appendingPathComponent("Contents/Resources/Build.json"))
        guard recordData.count <= 4_096 else { throw UpdateError.untrustedBuild }
        let record = try JSONDecoder().decode(Record.self, from: recordData)
        guard record.configuration == "release", record.sourceClean,
            record.sourceRevision.count == 40,
            record.sourceRevision.utf8.allSatisfy({
                (48...57).contains($0) || (97...102).contains($0)
            }), expectedSourceRevision == nil || record.sourceRevision == expectedSourceRevision
        else { throw UpdateError.untrustedBuild }
        if kind == .blessed {
            guard let embedded = helperInfo[kSecCodeInfoPList as String] as? [String: Any],
                embedded["CFBundleVersion"] as? String == plist["CFBundleVersion"] as? String,
                embedded["SMAuthorizedClients"] as? [String] == [
                    try identity.requirement(for: AwakeIdentity.application)
                ],
                plist["SMPrivilegedExecutables"] as? [String: String] == [
                    AwakeIdentity.helper: try identity.requirement(
                        for: AwakeIdentity.helper)
                ]
            else { throw UpdateError.untrustedBuild }
        }
    }

    public static func launchInstaller(_ staged: Staged) throws {
        guard let executable = Bundle.main.executableURL else { throw UpdateError.failed }
        let child = Process()
        child.executableURL = executable
        child.arguments = ["--finish-update", staged.app.path, String(getpid())]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
    }

    @concurrent public static func finish(app: URL, parentPID: Int32) async throws -> (
        app: URL, backup: URL, staging: URL
    ) {
        let identity = try SignedIdentity(expectedIdentifier: AwakeIdentity.application)
        guard try app.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false,
            try app.deletingLastPathComponent().resourceValues(forKeys: [.isSymbolicLinkKey])
                .isSymbolicLink == false
        else { throw UpdateError.unsafeLocation }
        let app = try canonical(app)
        let directory = app.deletingLastPathComponent()
        let current = directory.deletingLastPathComponent().appendingPathComponent(
            "Awake.app", isDirectory: true)
        guard try canonical(current) == current else { throw UpdateError.unsafeLocation }
        try requireCurrentApplication(current, identity: identity)
        try requireWritableApp(current)
        guard app.lastPathComponent == "Awake.app",
            directory.deletingLastPathComponent() == current.deletingLastPathComponent(),
            directory.lastPathComponent.hasPrefix(".Awake-update-"),
            let uuid = UUID(
                uuidString: String(
                    directory.lastPathComponent.dropFirst(".Awake-update-".count))),
            directory.lastPathComponent == ".Awake-update-" + uuid.uuidString
        else { throw UpdateError.unsafeLocation }
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.ownerAccountID] as? UInt32 == geteuid(),
            attributes[.posixPermissions] as? Int == 0o700,
            parentPID > 1, parentPID != getpid()
        else { throw UpdateError.unsafeLocation }
        let parent = try? ProcessIdentity(pid: parentPID)
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while parent?.isAlive == true {
            guard ContinuousClock.now < deadline else { throw UpdateError.busy }
            try await Task.sleep(for: .milliseconds(100))
        }
        try verify(app, identity: identity, newerThan: current)
        guard try SecureOwnershipJournal.isStateDirectoryAbsent(),
            try InstalledHelperFiles.areAbsent(),
            try InstalledHelperFiles.areAbsent(kind: .sudo), !SudoInstallation.isRegistered,
            HelperInstallationKind.blessed.service.status == .notRegistered
        else { throw UpdateError.busy }
        let backupName = ".Awake-previous-\(UUID().uuidString).app"
        let backup = current.deletingLastPathComponent().appendingPathComponent(backupName)
        do {
            _ = try FileManager.default.replaceItemAt(
                current, withItemAt: app, backupItemName: backupName,
                options: [.withoutDeletingBackupItem, .usingNewMetadataOnly])
            try identity.verifyExecutable(at: current, identifier: AwakeIdentity.application)
        } catch {
            if FileManager.default.fileExists(atPath: backup.path) {
                _ = try? FileManager.default.replaceItemAt(
                    current, withItemAt: backup, options: .usingNewMetadataOnly)
            }
            throw UpdateError.failed
        }
        return (current, backup, directory)
    }
}

private final class GitHubRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    static func allows(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443)
            && [
                "github.com", "release-assets.githubusercontent.com",
                "objects.githubusercontent.com",
            ].contains(url.host ?? "")
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(request.url.map(Self.allows) == true ? request : nil)
    }
}

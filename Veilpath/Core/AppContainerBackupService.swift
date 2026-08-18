import CryptoKit
import Foundation

struct AppContainerBackupManifest: Codable, Sendable {
    struct Entry: Codable, Sendable {
        let path: String
        let size: Int64
        let sha256: String
        let modifiedAt: Date?
        let permissions: Int?
    }

    let schemaVersion: Int
    let createdAt: Date
    let bundleIdentifier: String
    let containerKind: ContainerKind
    let sourceContainerUUID: String
    let systemVersion: String
    let appVersion: String
    let includedRoots: [String]
    let entries: [Entry]
}

struct AppContainerBackupResult: Sendable {
    let url: URL
    let manifest: AppContainerBackupManifest
    let skippedSymbolicLinks: Int
}

struct AppContainerRestoreResult: Sendable {
    let restoredFileCount: Int
    let safetyBackupURL: URL
    let manifest: AppContainerBackupManifest
}

enum AppContainerBackupError: LocalizedError {
    case applicationContainerRequired, missingIdentifier, missingDataDirectories, malformedManifest
    case identifierMismatch(expected: String, actual: String), hashMismatch(String), unexpectedPayload(String), invalidSourcePath(String)
    case duplicatePath(String), selfRestoreUnsupported, insufficientStorage, inconsistentSource(String)

    var errorDescription: String? {
        switch self {
        case .applicationContainerRequired: "Complete backup and restore currently require an Application data container."
        case .missingIdentifier: "The selected application container has no resolved bundle identifier."
        case .missingDataDirectories: "The container has no Documents, Library, or tmp directory to back up."
        case .malformedManifest: "The backup manifest is missing or malformed."
        case .identifierMismatch(let expected, let actual): "This backup belongs to \(actual), not \(expected)."
        case .hashMismatch(let path): "SHA-256 verification failed for \(path)."
        case .unexpectedPayload(let path): "The backup contains an undeclared payload entry: \(path)."
        case .invalidSourcePath(let path): "A source item is outside the selected container: \(path)."
        case .duplicatePath(let path): "The backup contains a duplicate path: \(path)."
        case .selfRestoreUnsupported: "Veilpath cannot restore its own active data container."
        case .insufficientStorage: "There is not enough free storage to create the safety backup and stage this restore."
        case .inconsistentSource(let path): "The source changed while it was being backed up: \(path). Close the target app and try again."
        }
    }
}

enum AppContainerBackupService {
    typealias Progress = StoredZIPArchive.Progress
    private static let roots = ["Documents", "Library", "tmp"]

    nonisolated static func create(
        container: ContainerDescriptor,
        destination: URL,
        progress: Progress
    ) async throws -> AppContainerBackupResult {
        guard container.kind == .application else { throw AppContainerBackupError.applicationContainerRequired }
        guard let identifier = container.identifier else { throw AppContainerBackupError.missingIdentifier }
        let root = URL(fileURLWithPath: container.path, isDirectory: true).standardizedFileURL
        let grant = try acquireGrant(root)
        defer { release(grant) }
        let collected = try collect(root: root)
        guard !collected.entries.isEmpty else { throw AppContainerBackupError.missingDataDirectories }
        let (verificationBytes, overflow) = collected.totalBytes.multipliedReportingOverflow(by: 2)
        guard !overflow else { throw AppContainerBackupError.insufficientStorage }
        try requireStorage(for: verificationBytes + 64 * 1024 * 1024, near: destination)
        try requireStorage(for: collected.totalBytes + 64 * 1024 * 1024,
                           near: FileManager.default.temporaryDirectory.appending(path: "backup-verification"))
        let manifest = AppContainerBackupManifest(
            schemaVersion: 1, createdAt: .now, bundleIdentifier: identifier, containerKind: container.kind,
            sourceContainerUUID: container.uuid, systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            includedRoots: collected.includedRoots,
            entries: collected.manifestEntries
        )
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        var zipEntries = collected.entries
        zipEntries.append(.data(try encoder.encode(manifest), path: "manifest.json"))
        do {
            try await StoredZIPArchive.write(entries: zipEntries, to: destination, progress: progress)
            let (verified, extraction) = try await inspect(destination)
            defer { try? FileManager.default.removeItem(at: extraction) }
            guard verified.entries.map(\.path) == manifest.entries.map(\.path),
                  verified.entries.map(\.sha256) == manifest.entries.map(\.sha256) else {
                throw AppContainerBackupError.malformedManifest
            }
            return .init(url: destination, manifest: manifest, skippedSymbolicLinks: collected.skippedLinks)
        } catch AppContainerBackupError.hashMismatch(let path) {
            try? FileManager.default.removeItem(at: destination)
            throw AppContainerBackupError.inconsistentSource(path)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    nonisolated static func inspect(_ archive: URL) async throws -> (AppContainerBackupManifest, URL) {
        let extraction = FileManager.default.temporaryDirectory
            .appending(path: "Veilpath Backup Inspection", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        do {
            let entries = try await StoredZIPArchive.extract(archive, to: extraction) { _, _, _, _ in }
            guard let manifestURL = entries.first(where: { $0.archivePath == "manifest.json" && !$0.isDirectory })?.destinationURL else {
                throw AppContainerBackupError.malformedManifest
            }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(AppContainerBackupManifest.self, from: Data(contentsOf: manifestURL))
            guard manifest.schemaVersion == 1 else { throw AppContainerBackupError.malformedManifest }
            try verify(manifest, extraction: extraction, extracted: entries)
            return (manifest, extraction)
        } catch {
            try? FileManager.default.removeItem(at: extraction)
            throw error
        }
    }

    nonisolated static func restore(
        archive: URL,
        to container: ContainerDescriptor,
        progress: Progress
    ) async throws -> AppContainerRestoreResult {
        guard container.kind == .application else { throw AppContainerBackupError.applicationContainerRequired }
        guard let identifier = container.identifier else { throw AppContainerBackupError.missingIdentifier }
        let root = URL(fileURLWithPath: container.path, isDirectory: true).standardizedFileURL
        guard canonicalPath(root) != canonicalPath(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) else {
            throw AppContainerBackupError.selfRestoreUnsupported
        }
        let (manifest, extraction) = try await inspect(archive)
        defer { try? FileManager.default.removeItem(at: extraction) }
        guard manifest.bundleIdentifier == identifier else {
            throw AppContainerBackupError.identifierMismatch(expected: identifier, actual: manifest.bundleIdentifier)
        }
        let grant = try acquireGrant(root)
        defer { release(grant) }

        let restoreBytes = manifest.entries.reduce(Int64(0)) { $0 + max(0, $1.size) }
        let currentBytes = try dataRootSize(root)
        try requireStorage(for: restoreBytes + currentBytes + 128 * 1024 * 1024, near: root)

        let safetyURL = try OperationSafetyStore.makeArchiveURL(category: .containerRestore, stem: safeName(identifier) + " before restore")
        _ = try await create(container: container, destination: safetyURL) { _, _, _, _ in }

        let operationID = UUID().uuidString
        let staged = root.appending(path: ".veilpath-restore-stage-\(operationID)", directoryHint: .isDirectory)
        let rollback = root.appending(path: ".veilpath-restore-rollback-\(operationID)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: rollback, withIntermediateDirectories: false)
        var swapped: [String] = []
        do {
            for name in manifest.includedRoots {
                let source = extraction.appending(path: name, directoryHint: .isDirectory)
                let target = staged.appending(path: name, directoryHint: .isDirectory)
                if FileManager.default.fileExists(atPath: source.path) {
                    try FileManager.default.copyItem(at: source, to: target)
                } else {
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                }
            }
            try restoreAttributes(manifest, staged: staged)
            for name in roots {
                try Task.checkCancellation()
                let current = root.appending(path: name, directoryHint: .isDirectory)
                let old = rollback.appending(path: name, directoryHint: .isDirectory)
                let replacement = staged.appending(path: name, directoryHint: .isDirectory)
                if FileManager.default.fileExists(atPath: current.path) { try FileManager.default.moveItem(at: current, to: old) }
                swapped.append(name)
                if manifest.includedRoots.contains(name) { try FileManager.default.moveItem(at: replacement, to: current) }
            }
            try FileManager.default.removeItem(at: rollback)
            try? FileManager.default.removeItem(at: staged)
            await progress(Int64(manifest.entries.reduce(0) { $0 + $1.size }),
                           Int64(manifest.entries.reduce(0) { $0 + $1.size }),
                           manifest.entries.count, manifest.entries.count)
            return .init(restoredFileCount: manifest.entries.count, safetyBackupURL: safetyURL, manifest: manifest)
        } catch {
            for name in swapped.reversed() {
                let current = root.appending(path: name, directoryHint: .isDirectory)
                let old = rollback.appending(path: name, directoryHint: .isDirectory)
                if FileManager.default.fileExists(atPath: current.path) { try? FileManager.default.removeItem(at: current) }
                if FileManager.default.fileExists(atPath: old.path) { try? FileManager.default.moveItem(at: old, to: current) }
            }
            try? FileManager.default.removeItem(at: staged)
            try? FileManager.default.removeItem(at: rollback)
            throw error
        }
    }

    private struct Collected {
        var entries: [StoredZIPEntry] = []
        var manifestEntries: [AppContainerBackupManifest.Entry] = []
        var includedRoots: [String] = []
        var skippedLinks = 0
        var totalBytes: Int64 = 0
    }

    private static func collect(root: URL) throws -> Collected {
        var result = Collected()
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        for name in roots {
            let directory = root.appending(path: name, directoryHint: .isDirectory)
            result.includedRoots.append(name)
            result.entries.append(.directory(name, modifiedAt: try? directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate))
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys), options: []) else { continue }
            while let url = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                let values = try url.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true {
                    result.skippedLinks += 1
                    if values.isDirectory == true { enumerator.skipDescendants() }
                    continue
                }
                let relative = name + "/" + (try relativePath(of: url, under: directory))
                if values.isDirectory == true {
                    result.entries.append(.directory(relative, modifiedAt: values.contentModificationDate))
                } else {
                    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                    let size = (attributes[.size] as? NSNumber)?.int64Value ?? Int64(values.fileSize ?? 0)
                    let digest = try sha256(url)
                    result.entries.append(.file(url, path: relative, modifiedAt: values.contentModificationDate))
                    result.manifestEntries.append(.init(path: relative, size: size, sha256: digest,
                                                        modifiedAt: values.contentModificationDate,
                                                        permissions: (attributes[.posixPermissions] as? NSNumber)?.intValue))
                    let (next, overflow) = result.totalBytes.addingReportingOverflow(max(0, size))
                    guard !overflow else { throw AppContainerBackupError.insufficientStorage }
                    result.totalBytes = next
                }
            }
        }
        result.manifestEntries.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        result.entries.sort { $0.archivePath.localizedStandardCompare($1.archivePath) == .orderedAscending }
        return result
    }

    /// Physical devices commonly expose the same container through `/var` and
    /// `/private/var`. Resolve both sides before deriving an archive path so a
    /// legitimate child never turns into an accidental absolute ZIP member.
    private static func relativePath(of child: URL, under root: URL) throws -> String {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let childPath = child.resolvingSymlinksInPath().standardizedFileURL.path
        guard childPath.hasPrefix(rootPath + "/") else { throw AppContainerBackupError.invalidSourcePath(child.path) }
        return String(childPath.dropFirst(rootPath.count + 1))
    }

    private static func verify(
        _ manifest: AppContainerBackupManifest,
        extraction: URL,
        extracted: [StoredZIPExtractedEntry]
    ) throws {
        guard !manifest.includedRoots.isEmpty,
              manifest.includedRoots.count == Set(manifest.includedRoots).count,
              manifest.includedRoots.allSatisfy({ roots.contains($0) }) else {
            throw AppContainerBackupError.malformedManifest
        }
        let extractedDirectories = Set(extracted.filter(\.isDirectory).map { $0.archivePath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) })
        guard Set(manifest.includedRoots).isSubset(of: extractedDirectories) else {
            throw AppContainerBackupError.malformedManifest
        }
        guard manifest.entries.count == Set(manifest.entries.map(\.path)).count else {
            let duplicate = Dictionary(grouping: manifest.entries, by: \.path).first { $0.value.count > 1 }?.key ?? "unknown"
            throw AppContainerBackupError.duplicatePath(duplicate)
        }
        guard extracted.count == Set(extracted.map(\.archivePath)).count else {
            let duplicate = Dictionary(grouping: extracted, by: \.archivePath).first { $0.value.count > 1 }?.key ?? "unknown"
            throw AppContainerBackupError.duplicatePath(duplicate)
        }
        let declared = Set(manifest.entries.map(\.path))
        let payload = extracted.filter { $0.archivePath != "manifest.json" }
        for entry in payload {
            guard roots.contains(where: { entry.archivePath == $0 + "/" || entry.archivePath.hasPrefix($0 + "/") }) else {
                throw AppContainerBackupError.unexpectedPayload(entry.archivePath)
            }
            if !entry.isDirectory, !declared.contains(entry.archivePath) {
                throw AppContainerBackupError.unexpectedPayload(entry.archivePath)
            }
        }
        guard Set(payload.filter { !$0.isDirectory }.map(\.archivePath)) == declared else { throw AppContainerBackupError.malformedManifest }
        for entry in manifest.entries {
            guard entry.size >= 0,
                  roots.contains(where: { entry.path.hasPrefix($0 + "/") }) else {
                throw AppContainerBackupError.unexpectedPayload(entry.path)
            }
            let url = extraction.appending(path: entry.path)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.size] as? NSNumber)?.int64Value == entry.size,
                  try sha256(url) == entry.sha256 else { throw AppContainerBackupError.hashMismatch(entry.path) }
        }
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func restoreAttributes(_ manifest: AppContainerBackupManifest, staged: URL) throws {
        for entry in manifest.entries {
            let target = staged.appending(path: entry.path)
            var attributes: [FileAttributeKey: Any] = [:]
            if let permissions = entry.permissions { attributes[.posixPermissions] = permissions }
            if let modifiedAt = entry.modifiedAt { attributes[.modificationDate] = modifiedAt }
            if !attributes.isEmpty { try FileManager.default.setAttributes(attributes, ofItemAtPath: target.path) }
        }
    }

    private static func dataRootSize(_ root: URL) throws -> Int64 {
        var total: Int64 = 0
        for name in roots {
            let directory = root.appending(path: name, directoryHint: .isDirectory)
            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey],
                options: []
            ) else { continue }
            while let url = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true { continue }
                if values.isRegularFile == true {
                    let (next, overflow) = total.addingReportingOverflow(Int64(values.fileSize ?? 0))
                    guard !overflow else { throw AppContainerBackupError.insufficientStorage }
                    total = next
                }
            }
        }
        return total
    }

    private static func requireStorage(for bytes: Int64, near url: URL) throws {
        var probe = url.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" { probe.deleteLastPathComponent() }
        let values = try probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage, available < bytes {
            throw AppContainerBackupError.insufficientStorage
        }
    }

    private static func canonicalPath(_ url: URL) -> String {
        var path = url.resolvingSymlinksInPath().standardizedFileURL.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path == "/var" || path.hasPrefix("/var/") { path = "/private" + path }
        return path
    }

    private static func acquireGrant(_ root: URL) throws -> BadQueryGrant? {
        #if targetEnvironment(simulator)
        nil
        #else
        try BadQueryClient.acquire(.forPath(root.path))
        #endif
    }

    private static func release(_ grant: BadQueryGrant?) { if let grant { BadQueryClient.release(grant) } }

    private static func safeName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:\0").union(.controlCharacters)
        let cleaned = value.components(separatedBy: invalid).filter { !$0.isEmpty }.joined(separator: "-")
        return cleaned.isEmpty ? "Application" : String(cleaned.prefix(120))
    }
}

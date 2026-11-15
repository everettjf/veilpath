import Foundation
import Darwin

struct AppLibraryBackup: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case application, cacheRecovery }
    enum Reason: String, Codable, Sendable { case manual, cleanup, beforeRestore, imported }
    let id: UUID
    let kind: Kind
    let container: ContainerDescriptor
    let createdAt: Date
    let payloadBytes: Int64
    let archiveSHA256: String
    var reason: Reason? = nil
    var skippedSymbolicLinks: Int? = nil
    var folder: URL { AppBackupLibrary.directory.appendingPathComponent(id.uuidString) }
    var archive: URL { folder.appendingPathComponent("backup.zip") }
    var exportName: String {
        let date = ISO8601DateFormatter().string(from: createdAt).replacingOccurrences(of: ":", with: "-")
        return ExportCache.safeName(container.identifier ?? container.uuid) + "-" + kind.rawValue + "-" + date + ".zip"
    }
    var archiveBytes: Int64 { ((try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)) ?? 0 }
}

enum AppBackupLibrary {
    static let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("App Backups", isDirectory: true)

    static func records() throws -> [AppLibraryBackup] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .compactMap { folder in
                guard UUID(uuidString: folder.lastPathComponent) != nil,
                      (try? ManagedAppFiles.kind(folder)) == S_IFDIR,
                      let data = try? Data(contentsOf: folder.appendingPathComponent("record.json")),
                      let record = try? JSONDecoder().decode(AppLibraryBackup.self, from: data),
                      record.id.uuidString == folder.lastPathComponent,
                      (try? ManagedAppFiles.kind(record.archive)) == S_IFREG else { return nil }
                return record
            }.sorted { $0.createdAt > $1.createdAt }
    }

    static func publish(id: UUID, kind: AppLibraryBackup.Kind, container: ContainerDescriptor,
                        bytes: Int64, staging: URL, reason: AppLibraryBackup.Reason? = nil,
                        skippedSymbolicLinks: Int? = nil) throws -> AppLibraryBackup {
        let archive = staging.appendingPathComponent("backup.zip")
        var record = AppLibraryBackup(id: id, kind: kind, container: container, createdAt: .now,
                                      payloadBytes: bytes, archiveSHA256: try ManagedAppFiles.hash(archive))
        record.reason = reason
        record.skippedSymbolicLinks = skippedSymbolicLinks
        try JSONEncoder().encode(record).write(to: staging.appendingPathComponent("record.json"), options: .atomic)
        try FileManager.default.moveItem(at: staging, to: record.folder)
        return record
    }

    static func stage(_ id: UUID) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".partial-" + id.uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        return staging
    }

    static func verifyArchive(_ record: AppLibraryBackup, checkCancellation: Bool = true) throws {
        guard try ManagedAppFiles.hash(record.archive, checkCancellation: checkCancellation) == record.archiveSHA256 else { throw AppManagementError.invalidBackup }
    }

    static func canDelete(_ record: AppLibraryBackup) -> Bool {
        (try? validateDeletion(record, folder: record.folder)) != nil
    }

    private static func validateDeletion(_ record: AppLibraryBackup, folder: URL) throws {
        guard ManagedAppFiles.canonical(directory.resolvingSymlinksInPath()) == ManagedAppFiles.canonical(directory),
              ManagedAppFiles.canonical(folder.deletingLastPathComponent()) == ManagedAppFiles.canonical(directory),
              ManagedAppFiles.canonical(folder.resolvingSymlinksInPath()) == ManagedAppFiles.canonical(folder),
              try ManagedAppFiles.kind(folder) == S_IFDIR else { throw AppManagementError.invalidBackup }
        let children = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        guard Set(children.map(\.lastPathComponent)) == ["record.json", "backup.zip"] else { throw AppManagementError.backupInUse }
        for file in children where try ManagedAppFiles.kind(file) != S_IFREG { throw AppManagementError.invalidBackup }
        let metadata = folder.appendingPathComponent("record.json")
        guard let size = try metadata.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1024 * 1024,
              try JSONDecoder().decode(AppLibraryBackup.self, from: Data(contentsOf: metadata)) == record else {
            throw AppManagementError.invalidBackup
        }
    }

    /// A user-confirmed purge of one retained backup, never the live app data.
    /// No backup-of-a-backup is made; active journals and preserved staging block it.
    static func delete(_ record: AppLibraryBackup) throws {
        try Task.checkCancellation()
        try validateDeletion(record, folder: record.folder)
        let staging = directory.appendingPathComponent(".deleting-" + record.id.uuidString)
        guard try ManagedAppFiles.kind(staging) == nil else { throw AppManagementError.backupInUse }
        try FileManager.default.moveItem(at: record.folder, to: staging)
        // Once removal starts, cancellation must not strand an intentionally
        // deleted record. If removal fails, return the remaining files to view.
        do { try FileManager.default.removeItem(at: staging) }
        catch {
            if (try? ManagedAppFiles.kind(record.folder)) == nil { try? FileManager.default.moveItem(at: staging, to: record.folder) }
            throw error
        }
        guard try ManagedAppFiles.kind(staging) == nil, try ManagedAppFiles.kind(record.folder) == nil else {
            throw AppManagementError.invalidBackup
        }
    }

    static func recoverInterruptedDeletions() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for folder in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where folder.lastPathComponent.hasPrefix(".deleting-") {
            let suffix = String(folder.lastPathComponent.dropFirst(".deleting-".count))
            guard let id = UUID(uuidString: suffix), try ManagedAppFiles.kind(folder) == S_IFDIR else { throw AppManagementError.backupInUse }
            let metadata = folder.appendingPathComponent("record.json")
            guard try ManagedAppFiles.kind(metadata) == S_IFREG,
                  let size = try metadata.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1024 * 1024,
                  let record = try? JSONDecoder().decode(AppLibraryBackup.self, from: Data(contentsOf: metadata)), record.id == id else {
                throw AppManagementError.backupInUse
            }
            // A complete interrupted deletion can be offered for confirmation
            // again. Partial or unexpected contents are retained, never purged.
            try validateDeletion(record, folder: folder)
            guard try ManagedAppFiles.kind(record.folder) == nil else { throw AppManagementError.backupInUse }
            try FileManager.default.moveItem(at: folder, to: record.folder)
        }
    }
}

struct CacheBackupManifest: Codable, Sendable {
    let schemaVersion: Int
    let bundleIdentifier: String
    let locations: [CacheLocation]
    let entries: [ManagedTreeEntry]
}

struct CacheCleaningResult: Sendable {
    let backup: AppLibraryBackup
    let processedBytes: Int64
    let netFreedBytes: Int64?
}

actor AppDataOperations {
    static let shared = AppDataOperations()
    private var busy = false

    func recoverInterruptedOperations() throws {
        guard !busy else { throw AppManagementError.busy }; busy = true; defer { busy = false }
        try AppBackupLibrary.recoverInterruptedDeletions()
        for record in try AppBackupLibrary.records() where FileManager.default.fileExists(atPath: record.folder.appendingPathComponent("transaction.json").path) {
            try ManagedAppFiles.validate(record.container)
            let grant = try ManagedAppFiles.acquire(URL(fileURLWithPath: record.container.path))
            defer { ManagedAppFiles.release(grant) }
            try CacheTransaction.recoverAll(for: record.container)
        }
    }

    func createBackup(_ container: ContainerDescriptor, progress: StoredZIPArchive.Progress) async throws -> AppLibraryBackup {
        guard !busy else { throw AppManagementError.busy }; busy = true; defer { busy = false }
        return try await createAppSnapshot(container, progress: progress)
    }

    func deleteBackup(_ record: AppLibraryBackup) throws {
        guard !busy else { throw AppManagementError.busy }; busy = true; defer { busy = false }
        try AppBackupLibrary.delete(record)
    }

    private func createAppSnapshot(_ container: ContainerDescriptor, reason: AppLibraryBackup.Reason = .manual,
                                   progress: StoredZIPArchive.Progress) async throws -> AppLibraryBackup {
        try ManagedAppFiles.validate(container)
        let grant = try ManagedAppFiles.acquire(URL(fileURLWithPath: container.path))
        defer { ManagedAppFiles.release(grant) }
        try CacheTransaction.recoverAll(for: container)
        let id = UUID(), staging = try AppBackupLibrary.stage(UUID())
        do {
            let result = try await AppContainerBackupService.create(container: container,
                destination: staging.appendingPathComponent("backup.zip"), progress: progress)
            return try AppBackupLibrary.publish(id: id, kind: .application, container: container,
                bytes: result.manifest.entries.reduce(0) { $0 + $1.size }, staging: staging, reason: reason,
                skippedSymbolicLinks: result.skippedSymbolicLinks)
        } catch { try? FileManager.default.removeItem(at: staging); throw error }
    }

    func importBackup(_ source: URL, applications: [ContainerDescriptor]) async throws -> AppLibraryBackup {
        guard !busy else { throw AppManagementError.busy }; busy = true; defer { busy = false }
        guard try ManagedAppFiles.kind(source) == S_IFREG,
              let sourceSize = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              sourceSize > 0, Int64(sourceSize) <= 8 * 1024 * 1024 * 1024,
              let free = ManagedAppFiles.freeSpace(), free > Int64(sourceSize) * 2 + 64 * 1024 * 1024 else {
            throw AppManagementError.invalidBackup
        }
        let staging = try AppBackupLibrary.stage(UUID())
        do {
            let archive = staging.appendingPathComponent("backup.zip")
            guard FileManager.default.createFile(atPath: archive.path, contents: nil) else { throw AppManagementError.invalidBackup }
            let input = try FileHandle(forReadingFrom: source), output = try FileHandle(forWritingTo: archive)
            do {
                var copied: Int64 = 0
                while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
                    try Task.checkCancellation()
                    copied += Int64(data.count)
                    guard copied <= sourceSize else { throw AppManagementError.sourceChanged }
                    try output.write(contentsOf: data)
                }
                guard copied == sourceSize else { throw AppManagementError.sourceChanged }
                try output.synchronize(); try input.close(); try output.close()
            } catch { try? input.close(); try? output.close(); throw error }
            let identifier: String, bytes: Int64, kind: AppLibraryBackup.Kind
            if let (manifest, extracted) = try? await AppContainerBackupService.inspect(archive) {
                try? FileManager.default.removeItem(at: extracted)
                identifier = manifest.bundleIdentifier
                bytes = manifest.entries.reduce(0) { $0 + $1.size }; kind = .application
            } else {
                let (manifest, extracted) = try await inspectCache(archive)
                try? FileManager.default.removeItem(at: extracted)
                identifier = manifest.bundleIdentifier
                bytes = manifest.entries.reduce(0) { $0 + $1.size }; kind = .cacheRecovery
            }
            guard !identifier.isEmpty, identifier.utf8.count <= 255,
                  identifier.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0) }) else {
                throw AppManagementError.invalidBackup
            }
            let uuid = UUID().uuidString
            let container = applications.first { $0.identifier == identifier } ?? ContainerDescriptor(
                path: ContainerKind.application.rootPath + "/" + uuid, identifier: identifier,
                uuid: uuid, kind: .application, metadataDiagnostic: nil)
            return try AppBackupLibrary.publish(id: UUID(), kind: kind, container: container, bytes: bytes, staging: staging, reason: .imported)
        } catch { try? FileManager.default.removeItem(at: staging); throw error }
    }

    func clean(_ container: ContainerDescriptor, locations: [CacheLocation], progress: StoredZIPArchive.Progress) async throws -> CacheCleaningResult {
        guard !busy else { throw AppManagementError.busy }; busy = true; defer { busy = false }
        try ManagedAppFiles.validate(container)
        let root = URL(fileURLWithPath: container.path)
        let grant = try ManagedAppFiles.acquire(root); defer { ManagedAppFiles.release(grant) }
        try CacheTransaction.recoverAll(for: container)
        let freeBefore = ManagedAppFiles.freeSpace()
        let (backup, manifest) = try await snapshotCache(container, locations: locations, progress: progress)
        try CacheTransaction.apply(container: container, manifest: manifest, replacement: nil, journalFolder: backup.folder)
        let freeAfter = ManagedAppFiles.freeSpace()
        return .init(backup: backup, processedBytes: backup.payloadBytes,
                     netFreedBytes: freeBefore.flatMap { before in freeAfter.map { $0 - before } })
    }

    func restore(_ record: AppLibraryBackup, to container: ContainerDescriptor, progress: @escaping StoredZIPArchive.Progress) async throws {
        guard !busy else { throw AppManagementError.busy }; busy = true; defer { busy = false }
        try ManagedAppFiles.validate(container)
        guard container.identifier == record.container.identifier else { throw AppManagementError.wrongApplication }
        try AppBackupLibrary.verifyArchive(record)
        let root = URL(fileURLWithPath: container.path)
        let grant = try ManagedAppFiles.acquire(root); defer { ManagedAppFiles.release(grant) }
        try CacheTransaction.recoverAll(for: container)
        if record.kind == .application {
            _ = try await AppContainerBackupService.restore(archive: record.archive, to: container,
                safetyBackupProvider: { selected in
                    try await self.createAppSnapshot(selected, reason: .beforeRestore, progress: progress).archive
                }, progress: progress)
        } else {
            let (wanted, extraction) = try await inspectCache(record.archive)
            defer { try? FileManager.default.removeItem(at: extraction) }
            guard wanted.bundleIdentifier == container.identifier else { throw AppManagementError.wrongApplication }
            let (safety, current) = try await snapshotCache(container, locations: wanted.locations, reason: .beforeRestore, progress: progress)
            try CacheTransaction.apply(container: container, manifest: current, replacement: (wanted, extraction), journalFolder: safety.folder)
        }
    }

    private func snapshotCache(_ container: ContainerDescriptor, locations: [CacheLocation], reason: AppLibraryBackup.Reason = .cleanup,
                               progress: StoredZIPArchive.Progress) async throws -> (AppLibraryBackup, CacheBackupManifest) {
        let root = URL(fileURLWithPath: container.path)
        let selected = CacheLocation.allCases.filter { locations.contains($0) }
        guard !selected.isEmpty else { throw AppManagementError.invalidBackup }
        var entries: [ManagedTreeEntry] = [], archiveEntries: [StoredZIPEntry] = []
        var existing: [CacheLocation] = []
        for location in selected {
            let folder = root.appendingPathComponent(location.rawValue)
            existing.append(location)
            guard try ManagedAppFiles.kind(folder) != nil else { continue }
            let tree = try ManagedAppFiles.tree(folder, prefix: location.rawValue)
            entries += tree
            archiveEntries += tree.map { entry in
                entry.directory ? .directory(entry.path, modifiedAt: entry.modifiedAt)
                    : .file(root.appendingPathComponent(entry.path), path: entry.path, modifiedAt: entry.modifiedAt)
            }
        }
        guard !existing.isEmpty, let identifier = container.identifier else { throw AppManagementError.invalidBackup }
        let bytes = try entries.reduce(Int64(0)) { partial, entry in
            let (sum, overflow) = partial.addingReportingOverflow(entry.size)
            guard entry.size >= 0, !overflow, sum <= Int64(UInt32.max) else { throw StoredZIPError.archiveTooLarge }
            return sum
        }
        guard let free = ManagedAppFiles.freeSpace(), free > bytes * 2 + 64 * 1024 * 1024 else { throw StoredZIPError.insufficientStorage }
        let manifest = CacheBackupManifest(schemaVersion: 1, bundleIdentifier: identifier, locations: existing, entries: entries)
        archiveEntries.append(.data(try JSONEncoder().encode(manifest), path: "cache-manifest.json"))
        let id = UUID(), staging = try AppBackupLibrary.stage(UUID())
        do {
            let archive = staging.appendingPathComponent("backup.zip")
            try await StoredZIPArchive.write(entries: archiveEntries, to: archive, compressFiles: true, progress: progress)
            let (verified, extracted) = try await inspectCache(archive)
            defer { try? FileManager.default.removeItem(at: extracted) }
            guard ManagedAppFiles.sameContents(verified.entries, entries) else { throw AppManagementError.invalidBackup }
            // Source stability is checked again after archiving and before staging.
            var current: [ManagedTreeEntry] = []
            for location in existing {
                let folder = root.appendingPathComponent(location.rawValue)
                if try ManagedAppFiles.kind(folder) != nil { current += try ManagedAppFiles.tree(folder, prefix: location.rawValue) }
            }
            guard ManagedAppFiles.sameContents(current, entries) else { throw AppManagementError.sourceChanged }
            let record = try AppBackupLibrary.publish(id: id, kind: .cacheRecovery, container: container, bytes: bytes, staging: staging, reason: reason)
            return (record, manifest)
        } catch { try? FileManager.default.removeItem(at: staging); throw error }
    }

    private func inspectCache(_ archive: URL) async throws -> (CacheBackupManifest, URL) {
        let extraction = FileManager.default.temporaryDirectory.appendingPathComponent("Cache Backup-" + UUID().uuidString)
        do {
            let extracted = try await StoredZIPArchive.extract(archive, to: extraction) { _, _, _, _ in }
            let manifest = try JSONDecoder().decode(CacheBackupManifest.self,
                from: Data(contentsOf: extraction.appendingPathComponent("cache-manifest.json")))
            guard manifest.schemaVersion == 1, !manifest.locations.isEmpty,
                  Set(manifest.locations).count == manifest.locations.count,
                  Set(manifest.entries.map(\.path)).count == manifest.entries.count else { throw AppManagementError.invalidBackup }
            let expected = Set(manifest.entries.map { $0.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }).union(["cache-manifest.json"])
            let actual = Set(extracted.map { $0.archivePath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) })
            guard actual == expected else { throw AppManagementError.invalidBackup }
            var inventory: [ManagedTreeEntry] = []
            for location in manifest.locations {
                let folder = extraction.appendingPathComponent(location.rawValue)
                if try ManagedAppFiles.kind(folder) != nil { inventory += try ManagedAppFiles.tree(folder, prefix: location.rawValue) }
            }
            guard ManagedAppFiles.sameContents(inventory, manifest.entries) else { throw AppManagementError.invalidBackup }
            // Restore original modes/dates only inside the private extraction tree.
            for entry in manifest.entries.reversed() {
                var attributes: [FileAttributeKey: Any] = [.posixPermissions: entry.permissions & 0o777]
                if let date = entry.modifiedAt { attributes[.modificationDate] = date }
                try FileManager.default.setAttributes(attributes, ofItemAtPath: extraction.appendingPathComponent(entry.path).path)
            }
            return (manifest, extraction)
        } catch { try? FileManager.default.removeItem(at: extraction); throw error }
    }
}

/// Journaled replacement of only the two allowlisted cache roots. Original
/// directories are retained until both the archive and staged tree are verified.
enum CacheTransaction {
    struct Journal: Codable {
        let id: UUID
        let container: ContainerDescriptor
        let locations: [CacheLocation]
        let original: [ManagedTreeEntry]
        let replacement: [ManagedTreeEntry]
        var committed: Bool
    }

    static func recoverAll(for container: ContainerDescriptor) throws {
        try ManagedAppFiles.verifyIdentity(container)
        for record in try AppBackupLibrary.records() {
            let journalURL = record.folder.appendingPathComponent("transaction.json")
            guard FileManager.default.fileExists(atPath: journalURL.path) else { continue }
            let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
            if ManagedAppFiles.canonical(URL(fileURLWithPath: journal.container.path)) == ManagedAppFiles.canonical(URL(fileURLWithPath: container.path)) {
                guard journal.container.identifier == container.identifier else { throw AppManagementError.recoveryRequired }
                try AppBackupLibrary.verifyArchive(record, checkCancellation: false)
                try finish(journal, at: journalURL)
            }
        }
    }

    static func apply(container: ContainerDescriptor, manifest: CacheBackupManifest,
                      replacement: (CacheBackupManifest, URL)?, journalFolder: URL) throws {
        try ManagedAppFiles.validate(container)
        let root = URL(fileURLWithPath: container.path)
        let desired = replacement?.0.entries ?? manifest.locations.map {
            ManagedTreeEntry(path: $0.rawValue, directory: true, size: 0, sha256: nil, permissions: 0o700, modifiedAt: nil)
        }
        let replacementBytes = desired.reduce(Int64(0)) { $0 + $1.size }
        guard let free = ManagedAppFiles.freeSpace(), free > replacementBytes + 64 * 1024 * 1024 else {
            throw StoredZIPError.insufficientStorage
        }
        var journal = Journal(id: UUID(), container: container, locations: manifest.locations,
                              original: manifest.entries, replacement: desired, committed: false)
        let journalURL = journalFolder.appendingPathComponent("transaction.json")
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
        do {
            for location in journal.locations {
                try Task.checkCancellation()
                let target = root.appendingPathComponent(location.rawValue)
                let (old, fresh) = staging(target, id: journal.id)
                let original = journal.original.filter { $0.path == location.rawValue || $0.path.hasPrefix(location.rawValue + "/") }
                let wanted = desired.filter { $0.path == location.rawValue || $0.path.hasPrefix(location.rawValue + "/") }
                let current = try ManagedAppFiles.kind(target) == nil ? [] : ManagedAppFiles.tree(target, prefix: location.rawValue)
                guard ManagedAppFiles.sameContents(current, original),
                      try ManagedAppFiles.kind(old) == nil, try ManagedAppFiles.kind(fresh) == nil else { throw AppManagementError.sourceChanged }
                _ = try ManagedAppFiles.relative(target, root: root)
                if let replacement, !wanted.isEmpty {
                    try FileManager.default.copyItem(at: replacement.1.appendingPathComponent(location.rawValue), to: fresh)
                } else if replacement == nil {
                    let attributes = (try? FileManager.default.attributesOfItem(atPath: target.path)) ?? [:]
                    try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: false,
                        attributes: [.posixPermissions: attributes[.posixPermissions] ?? 0o700])
                }
                if !original.isEmpty { try FileManager.default.moveItem(at: target, to: old) }
                // Inspect the moved directory, not the previous pathname.
                let staged = try ManagedAppFiles.kind(old) == nil ? [] : ManagedAppFiles.tree(old, prefix: location.rawValue)
                guard ManagedAppFiles.sameContents(staged, original) else {
                    throw AppManagementError.sourceChanged
                }
                if !wanted.isEmpty { try FileManager.default.moveItem(at: fresh, to: target) }
            }
            for location in journal.locations {
                let expected = desired.filter { $0.path == location.rawValue || $0.path.hasPrefix(location.rawValue + "/") }
                let folder = root.appendingPathComponent(location.rawValue)
                let actual = try ManagedAppFiles.kind(folder) == nil ? [] : ManagedAppFiles.tree(folder, prefix: location.rawValue)
                guard ManagedAppFiles.sameContents(actual, expected) else {
                    throw AppManagementError.sourceChanged
                }
            }
            journal.committed = true
            try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
            try finish(journal, at: journalURL)
        } catch {
            do { try finish(journal, at: journalURL) }
            catch { throw AppManagementError.recoveryRequired }
            throw error
        }
    }

    private static func staging(_ target: URL, id: UUID) -> (URL, URL) {
        let stem = ".veilpath-cache-" + id.uuidString + "-" + target.lastPathComponent
        return (target.deletingLastPathComponent().appendingPathComponent(stem + "-old"),
                target.deletingLastPathComponent().appendingPathComponent(stem + "-new"))
    }

    private static func finish(_ journal: Journal, at url: URL) throws {
        try ManagedAppFiles.validate(journal.container)
        let root = URL(fileURLWithPath: journal.container.path)
        guard !journal.locations.isEmpty, Set(journal.locations).count == journal.locations.count else { throw AppManagementError.recoveryRequired }
        for location in journal.locations.reversed() {
            let target = root.appendingPathComponent(location.rawValue)
            let (old, fresh) = staging(target, id: journal.id)
            _ = try ManagedAppFiles.relative(target, root: root)
            let original = journal.original.filter { $0.path == location.rawValue || $0.path.hasPrefix(location.rawValue + "/") }
            let desired = journal.replacement.filter { $0.path == location.rawValue || $0.path.hasPrefix(location.rawValue + "/") }
            if try ManagedAppFiles.kind(old) != nil {
                let staged = try ManagedAppFiles.tree(old, prefix: location.rawValue, checkCancellation: false)
                let originalKeys = Set(original.map(\.contentKey))
                guard journal.committed ? staged.allSatisfy({ originalKeys.contains($0.contentKey) })
                    : ManagedAppFiles.sameContents(staged, original) else { throw AppManagementError.recoveryRequired }
                if journal.committed { try FileManager.default.removeItem(at: old) }
                else {
                    if try ManagedAppFiles.kind(target) != nil {
                        guard ManagedAppFiles.sameContents(try ManagedAppFiles.tree(target, prefix: location.rawValue, checkCancellation: false), desired) else { throw AppManagementError.recoveryRequired }
                        try FileManager.default.removeItem(at: target)
                    }
                    try FileManager.default.moveItem(at: old, to: target)
                }
            } else if !journal.committed, original.isEmpty, try ManagedAppFiles.kind(target) != nil {
                guard ManagedAppFiles.sameContents(try ManagedAppFiles.tree(target, prefix: location.rawValue, checkCancellation: false), desired) else { throw AppManagementError.recoveryRequired }
                try FileManager.default.removeItem(at: target)
            }
            if try ManagedAppFiles.kind(fresh) != nil {
                // An interrupted copy may be partial; retain it rather than
                // deleting an unexpected tree during automatic recovery.
                let actual = try ManagedAppFiles.tree(fresh, prefix: location.rawValue, checkCancellation: false)
                if ManagedAppFiles.sameContents(actual, desired) { try FileManager.default.removeItem(at: fresh) }
                else {
                    let preserved = url.deletingLastPathComponent().appendingPathComponent("Interrupted Staging-" + journal.id.uuidString + "-" + target.lastPathComponent)
                    guard try ManagedAppFiles.kind(preserved) == nil else { throw AppManagementError.recoveryRequired }
                    try FileManager.default.moveItem(at: fresh, to: preserved)
                }
            }
        }
        try FileManager.default.removeItem(at: url)
    }
}

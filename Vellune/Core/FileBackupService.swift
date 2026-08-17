import CryptoKit
import Foundation

enum FileVersionRole: String, Codable, Sendable { case original, revision }

struct FileBackupManifest: Codable, Identifiable, Sendable {
    let id: UUID
    let targetPath: String
    let createdAt: Date
    let originalSHA256: String
    let originalSize: Int64
    let originalPermissions: Int?
    let originalModificationDate: Date?
    var replacementSHA256: String?
    var completed: Bool
    var role: FileVersionRole?
    var blobName: String?

    var effectiveRole: FileVersionRole { role ?? .revision }
}

struct FileBackupRecord: Identifiable, Sendable {
    let id: UUID
    let folderURL: URL
    let manifest: FileBackupManifest
}

enum FileBackupError: LocalizedError {
    case directoryUnsupported, symbolicLinkUnsupported, verificationFailed, targetMismatch, malformedBackup

    var errorDescription: String? {
        switch self {
        case .directoryUnsupported: "Directories cannot be replaced."
        case .symbolicLinkUnsupported: "Symbolic links cannot be replaced."
        case .verificationFailed: "The written file did not pass SHA-256 verification. The previous version was restored."
        case .targetMismatch: "The backup belongs to a different target path."
        case .malformedBackup: "The backup is incomplete or corrupted."
        }
    }
}

enum FileBackupService {
    private static let encoder: JSONEncoder = {
        let value = JSONEncoder()
        value.outputFormatting = [.prettyPrinted, .sortedKeys]
        value.dateEncodingStrategy = .iso8601
        return value
    }()
    private static let decoder: JSONDecoder = {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        return value
    }()

    nonisolated static func replace(target: URL, replacementData: Data) throws -> FileBackupRecord {
        let target = target.standardizedFileURL
        try validate(target)
        let grants = try acquireGrants(for: target)
        defer { grants.forEach(BadQueryClient.release) }
        let record = try createSnapshot(of: target)
        do {
            try replacementData.write(to: target, options: .atomic)
            try restoreAttributes(record.manifest, target: target)
            let replacementHash = try hash(target)
            guard replacementHash == hash(replacementData) else { throw FileBackupError.verificationFailed }
            return try update(record, replacementSHA256: replacementHash, completed: true)
        } catch {
            try? restoreSnapshot(record, to: target)
            throw error
        }
    }

    nonisolated static func restore(_ record: FileBackupRecord) throws -> FileBackupRecord {
        let target = URL(fileURLWithPath: record.manifest.targetPath).standardizedFileURL
        guard target.path == record.manifest.targetPath else { throw FileBackupError.targetMismatch }
        let source = try contentURL(for: record)
        guard try hash(source) == record.manifest.originalSHA256 else { throw FileBackupError.malformedBackup }
        let grants = try acquireGrants(for: target)
        defer { grants.forEach(BadQueryClient.release) }
        let safetySnapshot = try createSnapshot(of: target)
        do {
            try Data(contentsOf: source, options: .mappedIfSafe).write(to: target, options: .atomic)
            try restoreAttributes(record.manifest, target: target)
            guard try hash(target) == record.manifest.originalSHA256 else { throw FileBackupError.verificationFailed }
            return try update(safetySnapshot, replacementSHA256: record.manifest.originalSHA256, completed: true)
        } catch {
            try? restoreSnapshot(safetySnapshot, to: target)
            throw error
        }
    }

    nonisolated static func records() throws -> [FileBackupRecord] {
        let root = try backupRoot()
        let modern = try FileManager.default.contentsOfDirectory(at: manifestsRoot(), includingPropertiesForKeys: nil)
            .compactMap { folder -> FileBackupRecord? in
                let url = folder.appending(path: "manifest.json")
                guard let data = try? Data(contentsOf: url),
                      let manifest = try? decoder.decode(FileBackupManifest.self, from: data) else { return nil }
                return .init(id: manifest.id, folderURL: folder, manifest: manifest)
            }
        let legacy = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .compactMap { folder -> FileBackupRecord? in
                guard folder.lastPathComponent != "Blobs", folder.lastPathComponent != "Manifests" else { return nil }
                let manifestURL = folder.appending(path: "manifest.json")
                guard let data = try? Data(contentsOf: manifestURL),
                      let manifest = try? decoder.decode(FileBackupManifest.self, from: data) else { return nil }
                return .init(id: manifest.id, folderURL: folder, manifest: manifest)
            }
        return (modern + legacy).sorted { $0.manifest.createdAt > $1.manifest.createdAt }
    }

    nonisolated static func records(for target: URL) throws -> [FileBackupRecord] {
        try records().filter { $0.manifest.targetPath == target.standardizedFileURL.path }
    }

    nonisolated static func contentURL(for record: FileBackupRecord) throws -> URL {
        if let blobName = record.manifest.blobName {
            let url = try blobsRoot().appending(path: blobName)
            guard FileManager.default.fileExists(atPath: url.path) else { throw FileBackupError.malformedBackup }
            return url
        }
        let legacy = record.folderURL.appending(path: "original")
        guard FileManager.default.fileExists(atPath: legacy.path) else { throw FileBackupError.malformedBackup }
        return legacy
    }

    private nonisolated static func validate(_ target: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw FileBackupError.directoryUnsupported
        }
        if try target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw FileBackupError.symbolicLinkUnsupported
        }
    }

    private nonisolated static func acquireGrants(for target: URL) throws -> [BadQueryGrant] {
        #if targetEnvironment(simulator)
        return []
        #else
        let parent = try BadQueryClient.acquire(.forPath(target.deletingLastPathComponent().path))
        do { return [parent, try BadQueryClient.acquire(.forPath(target.path))] }
        catch { BadQueryClient.release(parent); throw error }
        #endif
    }

    private nonisolated static func createSnapshot(of target: URL) throws -> FileBackupRecord {
        try validate(target)
        let data = try Data(contentsOf: target, options: .mappedIfSafe)
        let contentHash = hash(data)
        let blob = try blobsRoot().appending(path: contentHash)
        if !FileManager.default.fileExists(atPath: blob.path) { try data.write(to: blob, options: .atomic) }
        guard try hash(blob) == contentHash else { throw FileBackupError.verificationFailed }
        let existingOriginal = try records().contains {
            $0.manifest.targetPath == target.path && $0.manifest.effectiveRole == .original
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        let manifest = FileBackupManifest(
            id: UUID(), targetPath: target.path, createdAt: .now, originalSHA256: contentHash,
            originalSize: (attributes[.size] as? NSNumber)?.int64Value ?? Int64(data.count),
            originalPermissions: (attributes[.posixPermissions] as? NSNumber)?.intValue,
            originalModificationDate: attributes[.modificationDate] as? Date,
            replacementSHA256: nil, completed: false,
            role: existingOriginal ? .revision : .original, blobName: contentHash
        )
        let folder = try manifestsRoot().appending(path: manifest.id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return try update(.init(id: manifest.id, folderURL: folder, manifest: manifest),
                          replacementSHA256: nil, completed: false)
    }

    private nonisolated static func update(_ record: FileBackupRecord, replacementSHA256: String?, completed: Bool) throws -> FileBackupRecord {
        var manifest = record.manifest
        manifest.replacementSHA256 = replacementSHA256
        manifest.completed = completed
        let url = record.folderURL.appending(path: "manifest.json")
        try encoder.encode(manifest).write(to: url, options: .atomic)
        return .init(id: record.id, folderURL: record.folderURL, manifest: manifest)
    }

    private nonisolated static func restoreSnapshot(_ record: FileBackupRecord, to target: URL) throws {
        try Data(contentsOf: contentURL(for: record), options: .mappedIfSafe).write(to: target, options: .atomic)
        try restoreAttributes(record.manifest, target: target)
    }

    private nonisolated static func backupRoot() throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
            .appending(path: "File Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private nonisolated static func manifestsRoot() throws -> URL {
        let url = try backupRoot().appending(path: "Manifests", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private nonisolated static func blobsRoot() throws -> URL {
        let url = try backupRoot().appending(path: "Blobs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private nonisolated static func hash(_ url: URL) throws -> String { hash(try Data(contentsOf: url, options: .mappedIfSafe)) }
    private nonisolated static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func restoreAttributes(_ manifest: FileBackupManifest, target: URL) throws {
        var attributes: [FileAttributeKey: Any] = [:]
        if let permissions = manifest.originalPermissions { attributes[.posixPermissions] = permissions }
        if let modified = manifest.originalModificationDate { attributes[.modificationDate] = modified }
        if !attributes.isEmpty { try FileManager.default.setAttributes(attributes, ofItemAtPath: target.path) }
    }
}

import CryptoKit
import Foundation

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
}

struct FileBackupRecord: Identifiable, Sendable {
    let id: UUID
    let folderURL: URL
    let manifest: FileBackupManifest
}

enum FileBackupError: LocalizedError {
    case directoryUnsupported
    case symbolicLinkUnsupported
    case verificationFailed
    case targetMismatch
    case malformedBackup

    var errorDescription: String? {
        switch self {
        case .directoryUnsupported: "Directories cannot be replaced."
        case .symbolicLinkUnsupported: "Symbolic links cannot be replaced."
        case .verificationFailed: "The written file did not pass SHA-256 verification."
        case .targetMismatch: "The backup belongs to a different target path."
        case .malformedBackup: "The backup is incomplete or corrupted."
        }
    }
}

enum FileBackupService {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    nonisolated static func replace(target: URL, replacementData: Data) throws -> FileBackupRecord {
        let target = target.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw FileBackupError.directoryUnsupported
        }
        if try target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw FileBackupError.symbolicLinkUnsupported
        }
        let grants = try acquireGrants(for: target)
        defer { grants.forEach(BadQueryClient.release) }
        let record = try createBackup(of: target)
        try replacementData.write(to: target, options: .atomic)
        try restoreAttributes(record.manifest, target: target)
        let replacementHash = try hash(target)
        guard replacementHash == hash(replacementData) else { throw FileBackupError.verificationFailed }
        return try update(record, replacementSHA256: replacementHash, completed: true)
    }

    nonisolated static func restore(_ record: FileBackupRecord) throws -> FileBackupRecord {
        let target = URL(fileURLWithPath: record.manifest.targetPath).standardizedFileURL
        guard target.path == record.manifest.targetPath else { throw FileBackupError.targetMismatch }
        let original = record.folderURL.appending(path: "original")
        guard FileManager.default.fileExists(atPath: original.path), try hash(original) == record.manifest.originalSHA256 else {
            throw FileBackupError.malformedBackup
        }
        let grants = try acquireGrants(for: target)
        defer { grants.forEach(BadQueryClient.release) }
        let safetyBackup = try createBackup(of: target)
        try Data(contentsOf: original, options: .mappedIfSafe).write(to: target, options: .atomic)
        try restoreAttributes(record.manifest, target: target)
        guard try hash(target) == record.manifest.originalSHA256 else { throw FileBackupError.verificationFailed }
        return try update(safetyBackup, replacementSHA256: record.manifest.originalSHA256, completed: true)
    }

    nonisolated static func records() throws -> [FileBackupRecord] {
        let root = try backupRoot()
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .compactMap { folder in
                let manifestURL = folder.appending(path: "manifest.json")
                guard let data = try? Data(contentsOf: manifestURL),
                      let manifest = try? decoder.decode(FileBackupManifest.self, from: data) else { return nil }
                return .init(id: manifest.id, folderURL: folder, manifest: manifest)
            }
            .sorted { $0.manifest.createdAt > $1.manifest.createdAt }
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

    private nonisolated static func createBackup(of target: URL) throws -> FileBackupRecord {
        let id = UUID()
        let folder = try backupRoot().appending(path: id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let original = folder.appending(path: "original")
        try Data(contentsOf: target, options: .mappedIfSafe).write(to: original, options: .atomic)
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        let manifest = FileBackupManifest(
            id: id,
            targetPath: target.path,
            createdAt: .now,
            originalSHA256: try hash(original),
            originalSize: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            originalPermissions: (attributes[.posixPermissions] as? NSNumber)?.intValue,
            originalModificationDate: attributes[.modificationDate] as? Date,
            replacementSHA256: nil,
            completed: false
        )
        return try update(.init(id: id, folderURL: folder, manifest: manifest), replacementSHA256: nil, completed: false)
    }

    private nonisolated static func update(
        _ record: FileBackupRecord,
        replacementSHA256: String?,
        completed: Bool
    ) throws -> FileBackupRecord {
        var manifest = record.manifest
        manifest.replacementSHA256 = replacementSHA256
        manifest.completed = completed
        try encoder.encode(manifest).write(to: record.folderURL.appending(path: "manifest.json"), options: .atomic)
        return .init(id: record.id, folderURL: record.folderURL, manifest: manifest)
    }

    private nonisolated static func backupRoot() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "File Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
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

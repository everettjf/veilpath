import CryptoKit
import Foundation

enum StructuredEditorKind: Equatable, Sendable {
    case json
    case propertyList(PropertyListSerialization.PropertyListFormat)

    var title: String {
        switch self {
        case .json: "JSON"
        case .propertyList(.binary): "Binary Plist"
        case .propertyList: "XML Plist"
        }
    }
}

struct StructuredEditSession: Sendable {
    let targetURL: URL
    let draftURL: URL
    let originalSHA256: String
    let kind: StructuredEditorKind
    let text: String
}

enum StructuredEditorError: LocalizedError {
    case unsupportedFormat
    case tooLarge(Int64)
    case invalidJSON(String)
    case invalidPropertyList(String)
    case externalModification

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "Only valid JSON and property list files can be edited safely."
        case .tooLarge(let size): "This structured file is too large to edit safely (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))."
        case .invalidJSON(let detail): "Invalid JSON: \(detail)"
        case .invalidPropertyList(let detail): "Invalid property list: \(detail)"
        case .externalModification: "The original file changed after editing began. Reopen it before saving so external changes are not overwritten."
        }
    }
}

enum SafeStructuredEditor {
    static let maximumEditableBytes: Int64 = 8 * 1024 * 1024

    nonisolated static func open(target: URL) throws -> StructuredEditSession {
        let target = target.standardizedFileURL
        let grants = try acquireGrants(for: target)
        defer { grants.forEach(BadQueryClient.release) }
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= maximumEditableBytes else { throw StructuredEditorError.tooLarge(size) }
        let data = try Data(contentsOf: target, options: .mappedIfSafe)
        let kind: StructuredEditorKind
        let text: String
        if let json = try? JSONSerialization.jsonObject(with: data), JSONSerialization.isValidJSONObject(json) {
            kind = .json
            text = String(decoding: try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        } else {
            var format = PropertyListSerialization.PropertyListFormat.xml
            guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format) else {
                throw StructuredEditorError.unsupportedFormat
            }
            kind = .propertyList(format)
            text = String(decoding: try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), as: UTF8.self)
        }
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "Vellune Edit Drafts", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let draft = folder.appending(path: target.lastPathComponent)
        try Data(text.utf8).write(to: draft, options: .atomic)
        return .init(targetURL: target, draftURL: draft, originalSHA256: hash(data), kind: kind, text: text)
    }

    nonisolated static func updateDraft(_ session: StructuredEditSession, text: String) throws {
        try Data(text.utf8).write(to: session.draftURL, options: .atomic)
    }

    nonisolated static func validate(_ session: StructuredEditSession, text: String) throws -> Data {
        let source = Data(text.utf8)
        switch session.kind {
        case .json:
            do {
                let object = try JSONSerialization.jsonObject(with: source)
                guard JSONSerialization.isValidJSONObject(object) else { throw StructuredEditorError.invalidJSON("The root value cannot be written as JSON.") }
                return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            } catch let error as StructuredEditorError { throw error }
            catch { throw StructuredEditorError.invalidJSON(error.localizedDescription) }
        case .propertyList(let originalFormat):
            do {
                let object = try PropertyListSerialization.propertyList(from: source, options: [], format: nil)
                let outputFormat: PropertyListSerialization.PropertyListFormat = originalFormat == .binary ? .binary : .xml
                return try PropertyListSerialization.data(fromPropertyList: object, format: outputFormat, options: 0)
            } catch { throw StructuredEditorError.invalidPropertyList(error.localizedDescription) }
        }
    }

    @discardableResult
    nonisolated static func save(_ session: StructuredEditSession, text: String) throws -> FileBackupRecord {
        let grants = try acquireGrants(for: session.targetURL)
        defer { grants.forEach(BadQueryClient.release) }
        let current = try Data(contentsOf: session.targetURL, options: .mappedIfSafe)
        guard hash(current) == session.originalSHA256 else { throw StructuredEditorError.externalModification }
        let validated = try validate(session, text: text)
        try updateDraft(session, text: text)
        let record = try FileBackupService.replace(target: session.targetURL, replacementData: validated)
        discard(session)
        return record
    }

    nonisolated static func discard(_ session: StructuredEditSession) {
        try? FileManager.default.removeItem(at: session.draftURL.deletingLastPathComponent())
    }

    private nonisolated static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
}

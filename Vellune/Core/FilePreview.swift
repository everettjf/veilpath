import Foundation

enum FilePreview: Equatable, Sendable {
    case structured(root: StructuredNode, source: String, format: String)
    case text(String, format: String)
    case image(Data, ImageDetails)
    case machO(MachOInfo)
    case binary
    case tooLarge(Int64)

    static let maximumInlineBytes: Int64 = 32 * 1024 * 1024
}

enum ExportCache {
    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Exports", directoryHint: .isDirectory)
    }

    static func stage(_ source: URL, named name: String) throws -> URL {
        try stage(Data(contentsOf: source), named: name)
    }

    static func stage(_ data: Data, named name: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = uniqueDestination(named: name)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    static func removeExpired(olderThan age: TimeInterval = 24 * 60 * 60) {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for entry in entries where (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture < cutoff {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    static func removeAll() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    private static func uniqueDestination(named name: String) -> URL {
        let base = directory.appending(path: name)
        guard FileManager.default.fileExists(atPath: base.path) else { return base }
        let stem = base.deletingPathExtension().lastPathComponent
        let ext = base.pathExtension
        let unique = "\(stem)-\(UUID().uuidString.prefix(8))" + (ext.isEmpty ? "" : ".\(ext)")
        return directory.appending(path: unique)
    }
}

enum FilePreviewLoader {
    struct Result: Sendable {
        let preview: FilePreview
        let properties: FileProperties
        let exportURL: URL
        let hexDump: String
    }

    nonisolated static func load(_ item: FileItem) throws -> Result {
        #if targetEnvironment(simulator)
        let data = try Data(contentsOf: item.url, options: .mappedIfSafe)
        let exportURL = try ExportCache.stage(data, named: item.name)
        return .init(preview: try makePreview(item: item, data: data), properties: try FileAnalyzer.properties(for: item.url, data: data), exportURL: exportURL, hexDump: FileAnalyzer.hexDump(data: data))
        #else
        let parentGrant = try BadQueryClient.acquire(.init(
            path: item.url.deletingLastPathComponent().path,
            createIfMissing: true
        ))
        defer { BadQueryClient.release(parentGrant) }
        let fileGrant = try BadQueryClient.acquire(.init(path: item.url.path, createIfMissing: true))
        defer { BadQueryClient.release(fileGrant) }
        ExportCache.removeExpired()
        let data = try Data(contentsOf: item.url, options: .mappedIfSafe)
        let exportURL = try ExportCache.stage(data, named: item.name)
        return .init(preview: try makePreview(item: item, data: data), properties: try FileAnalyzer.properties(for: item.url, data: data), exportURL: exportURL, hexDump: FileAnalyzer.hexDump(data: data))
        #endif
    }

    private static func makePreview(item: FileItem, data: Data) throws -> FilePreview {
        let ext = item.url.pathExtension.lowercased()
        if let machO = MachOParser.parse(data) { return .machO(machO) }
        if ["png", "jpg", "jpeg", "heic", "gif", "webp", "tif", "tiff"].contains(ext), let details = FileAnalyzer.imageDetails(data: data) { return .image(data, details) }
        if ext == "plist" {
            var format = PropertyListSerialization.PropertyListFormat.binary
            let object = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
            let xml = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
            return .structured(root: .make(key: "Root", value: object), source: String(decoding: xml, as: UTF8.self), format: format == .binary ? "Binary Plist" : "XML Plist")
        }
        if ext == "json" {
            let object = try JSONSerialization.jsonObject(with: data)
            let formatted = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            return .structured(root: .make(key: "Root", value: object), source: String(decoding: formatted, as: UTF8.self), format: "JSON")
        }
        if let text = decodeText(data) { return .text(text, format: ext == "xml" ? "XML" : (ext.isEmpty ? "Text" : ext.uppercased())) }
        if Int64(data.count) > FilePreview.maximumInlineBytes { return .tooLarge(Int64(data.count)) }
        return .binary
    }

    private static func decodeText(_ data: Data) -> String? {
        for encoding in [String.Encoding.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .ascii] {
            if let value = String(data: data, encoding: encoding), !value.contains("\0") { return value }
        }
        return nil
    }
}

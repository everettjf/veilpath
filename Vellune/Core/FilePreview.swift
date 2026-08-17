import CoreTransferable
import Foundation
import UniformTypeIdentifiers

struct ExportedFile: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .data) { file in
            SentTransferredFile(file.url)
        } importing: { received in
            ExportedFile(url: received.file)
        }
    }
}

enum FilePreview: Equatable, Sendable {
    case structured(root: StructuredNode, source: String, format: String)
    case text(String, format: String)
    case image(Data, ImageDetails)
    case machO(MachOInfo)
    case pdf(Data)
    case sqlite(SQLiteSummary)
    case archive(ArchiveSummary)
    case font(FontSummary)
    case binaryCookies(BinaryCookiesSummary)
    case quickLook(URL, kind: String)
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
        let exportURL: URL?
        let hexDump: String
    }

    nonisolated static func load(_ item: FileItem) throws -> Result {
        try Task.checkCancellation()
        #if targetEnvironment(simulator)
        return try loadGranted(item)
        #else
        let parentGrant = try BadQueryClient.acquire(.init(
            path: item.url.deletingLastPathComponent().path,
            createIfMissing: true
        ))
        defer { BadQueryClient.release(parentGrant) }
        let fileGrant = try BadQueryClient.acquire(.init(path: item.url.path, createIfMissing: true))
        defer { BadQueryClient.release(fileGrant) }
        ExportCache.removeExpired()
        return try loadGranted(item)
        #endif
    }

    private nonisolated static func loadGranted(_ item: FileItem) throws -> Result {
        let attributes = try FileManager.default.attributesOfItem(atPath: item.url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? item.size ?? 0
        try Task.checkCancellation()
        if size > FilePreview.maximumInlineBytes {
            let prefix = try readPrefix(of: item.url, maximumBytes: 1024 * 1024)
            try Task.checkCancellation()
            let preview: FilePreview
            if prefix.starts(with: Data("SQLite format 3\0".utf8)) {
                preview = .sqlite(try AdvancedFileAnalyzer.sqlite(at: item.url))
            } else if let thumbnail = FileAnalyzer.imageThumbnail(at: item.url) {
                preview = .image(thumbnail.0, thumbnail.1)
            } else {
                preview = .tooLarge(size)
            }
            return .init(preview: preview, properties: try FileAnalyzer.properties(for: item.url),
                         exportURL: nil, hexDump: FileAnalyzer.hexDump(data: prefix))
        }
        let data = try Data(contentsOf: item.url, options: .mappedIfSafe)
        try Task.checkCancellation()
        let exportURL = try ExportCache.stage(data, named: item.name)
        try Task.checkCancellation()
        return .init(preview: try makePreview(item: item, data: data, exportURL: exportURL),
                     properties: try FileAnalyzer.properties(for: item.url, data: data),
                     exportURL: exportURL, hexDump: FileAnalyzer.hexDump(data: data))
    }

    private nonisolated static func readPrefix(of url: URL, maximumBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: maximumBytes) ?? Data()
    }

    static func makePreview(item: FileItem, data: Data, exportURL: URL) throws -> FilePreview {
        let ext = item.url.pathExtension.lowercased()
        if let machO = MachOParser.parse(data) { return .machO(machO) }
        if data.starts(with: Data("%PDF".utf8)) { return .pdf(data) }
        if data.starts(with: Data("SQLite format 3\0".utf8)) {
            return .sqlite(try AdvancedFileAnalyzer.sqlite(at: item.url))
        }
        if let cookies = AdvancedFileAnalyzer.binaryCookies(data: data) { return .binaryCookies(cookies) }
        if data.starts(with: [0x50, 0x4b]), let archive = AdvancedFileAnalyzer.zip(data: data) { return .archive(archive) }
        if let details = FileAnalyzer.imageDetails(data: data) { return .image(data, details) }
        if ["ttf", "otf", "ttc", "woff", "woff2"].contains(ext), let font = AdvancedFileAnalyzer.font(data: data) { return .font(font) }

        let plistExtensions: Set<String> = ["plist", "strings", "stringsdict", "mobileconfig", "entitlements", "webarchive", "archive"]
        if data.starts(with: Data("bplist".utf8)) || plistExtensions.contains(ext),
           let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
            var format = PropertyListSerialization.PropertyListFormat.binary
            _ = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
            let xml = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
            let label = (object as? [String: Any])?["$archiver"] != nil ? "NSKeyedArchive" : (format == .binary ? "Binary Plist" : "XML Plist")
            return .structured(root: .make(key: "Root", value: object), source: String(decoding: xml, as: UTF8.self), format: label)
        }
        let trimmed = data.prefix(256).drop(while: { $0 == 0x20 || $0 == 0x09 || $0 == 0x0a || $0 == 0x0d })
        if (ext == "json" || trimmed.first == 0x7b || trimmed.first == 0x5b),
           let object = try? JSONSerialization.jsonObject(with: data) {
            let formatted = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            return .structured(root: .make(key: "Root", value: object), source: String(decoding: formatted, as: UTF8.self), format: "JSON")
        }
        if Int64(data.count) > FilePreview.maximumInlineBytes { return .tooLarge(Int64(data.count)) }
        let quickLookExtensions: Set<String> = [
            "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key",
            "rtf", "rtfd", "html", "htm", "svg", "usdz", "reality",
            "mp3", "m4a", "aac", "wav", "aiff", "caf", "mp4", "mov", "m4v",
            "vcf", "ics", "ttf", "otf", "ttc", "woff", "woff2"
        ]
        if quickLookExtensions.contains(ext) { return .quickLook(exportURL, kind: ext.uppercased()) }
        if let text = decodeText(data) { return .text(text, format: ext == "xml" ? "XML" : (ext.isEmpty ? "Text" : ext.uppercased())) }
        return .binary
    }

    private static func decodeText(_ data: Data) -> String? {
        for encoding in [String.Encoding.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .ascii] {
            if let value = String(data: data, encoding: encoding), !value.contains("\0") { return value }
        }
        return nil
    }
}

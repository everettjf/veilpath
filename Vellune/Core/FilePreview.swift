import Foundation

enum FilePreview: Equatable, Sendable {
    case text(String)
    case image(Data)
    case metadata
    case tooLarge(Int64)

    static let maximumInlineBytes: Int64 = 8 * 1024 * 1024
}

enum FilePreviewLoader {
    struct Result: Sendable {
        let preview: FilePreview
        let exportURL: URL
    }

    nonisolated static func load(_ item: FileItem) throws -> Result {
        let grant = try BadQueryClient.acquire(.init(path: item.url.path))
        defer { BadQueryClient.release(grant) }

        let exportDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Exports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        let exportURL = exportDirectory.appending(path: item.name)
        if FileManager.default.fileExists(atPath: exportURL.path) {
            try FileManager.default.removeItem(at: exportURL)
        }
        try FileManager.default.copyItem(at: item.url, to: exportURL)

        if let size = item.size, size > FilePreview.maximumInlineBytes {
            return .init(preview: .tooLarge(size), exportURL: exportURL)
        }
        let data = try Data(contentsOf: item.url, options: .mappedIfSafe)
        let ext = item.url.pathExtension.lowercased()

        if ["png", "jpg", "jpeg", "heic", "gif", "webp"].contains(ext) {
            return .init(preview: .image(data), exportURL: exportURL)
        }
        if ext == "plist" {
            let object = try PropertyListSerialization.propertyList(from: data, format: nil)
            let xml = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
            return .init(preview: .text(String(decoding: xml, as: UTF8.self)), exportURL: exportURL)
        }
        if ext == "json" {
            let object = try JSONSerialization.jsonObject(with: data)
            let formatted = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            return .init(preview: .text(String(decoding: formatted, as: UTF8.self)), exportURL: exportURL)
        }
        if let text = String(data: data, encoding: .utf8) {
            return .init(preview: .text(text), exportURL: exportURL)
        }
        return .init(preview: .metadata, exportURL: exportURL)
    }
}

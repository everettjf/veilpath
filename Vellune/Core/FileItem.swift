import Foundation

struct FileItem: Identifiable, Hashable, Sendable {
    let url: URL
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let size: Int64?
    let modifiedAt: Date?

    var id: String { url.path }
    var name: String { url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent }

    var systemImage: String {
        if isSymbolicLink { return "link" }
        if isDirectory { return "folder.fill" }
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "heic", "gif", "webp": return "photo"
        case "plist", "json": return "curlybraces"
        case "txt", "md", "log": return "doc.text"
        case "pdf": return "doc.richtext"
        case "zip", "ipa", "tar", "gz": return "archivebox"
        default: return "doc"
        }
    }
}

struct DirectoryContentsSummary: Hashable, Sendable {
    let fileCount: Int
    let folderCount: Int

    var isEmpty: Bool { fileCount == 0 && folderCount == 0 }
}

enum FileSortOrder: String, CaseIterable, Identifiable, Sendable {
    case name, date, size

    var id: Self { self }
    var localizedName: LocalizedStringResource {
        switch self {
        case .name: "Name"
        case .date: "Date Modified"
        case .size: "Size"
        }
    }
}

enum FileSystemReader {
    static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .isHiddenKey
    ]

    static func contents(at path: String, showHidden: Bool, sortOrder: FileSortOrder = .name) throws -> [FileItem] {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !showHidden { options.insert(.skipsHiddenFiles) }
        return try FileManager.default
            .contentsOfDirectory(at: url, includingPropertiesForKeys: Array(resourceKeys), options: options)
            .map { child in
                let values = try child.resourceValues(forKeys: resourceKeys)
                return FileItem(
                    url: child,
                    isDirectory: values.isDirectory ?? false,
                    isSymbolicLink: values.isSymbolicLink ?? false,
                    size: values.fileSize.map(Int64.init),
                    modifiedAt: values.contentModificationDate
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                switch sortOrder {
                case .name:
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                case .date:
                    if lhs.modifiedAt != rhs.modifiedAt { return (lhs.modifiedAt ?? .distantPast) > (rhs.modifiedAt ?? .distantPast) }
                case .size:
                    if lhs.size != rhs.size { return (lhs.size ?? 0) > (rhs.size ?? 0) }
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    static func directContentsSummary(at path: String, showHidden: Bool) throws -> DirectoryContentsSummary {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let keys: Set<URLResourceKey> = [.isDirectoryKey]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !showHidden { options.insert(.skipsHiddenFiles) }

        var fileCount = 0
        var folderCount = 0
        for child in try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: options
        ) {
            let values = try child.resourceValues(forKeys: keys)
            if values.isDirectory == true {
                folderCount += 1
            } else {
                fileCount += 1
            }
        }
        return .init(fileCount: fileCount, folderCount: folderCount)
    }

    static func search(at path: String, query: String, showHidden: Bool, limit: Int = 500) -> [FileItem] {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !showHidden { options.insert(.skipsHiddenFiles) }
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(resourceKeys), options: options) else { return [] }
        var results: [FileItem] = []
        while let url = enumerator.nextObject() as? URL, results.count < limit {
            guard url.lastPathComponent.localizedCaseInsensitiveContains(query),
                  let values = try? url.resourceValues(forKeys: resourceKeys) else { continue }
            results.append(.init(url: url, isDirectory: values.isDirectory ?? false,
                                 isSymbolicLink: values.isSymbolicLink ?? false,
                                 size: values.fileSize.map(Int64.init), modifiedAt: values.contentModificationDate))
        }
        return results.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }
}

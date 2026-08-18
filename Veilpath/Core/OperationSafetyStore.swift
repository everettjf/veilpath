import Foundation

enum OperationSafetyStore {
    enum Category: String, Sendable {
        case deletedItems = "Deleted Items"
        case containerRestore = "Container Restore"
    }

    private static let retentionAge: TimeInterval = 30 * 24 * 60 * 60
    private static let maximumFilesPerCategory = 10

    static func makeArchiveURL(category: Category, stem: String) throws -> URL {
        let directory = try directory(for: category)
        try prune(category: category, keepingAtMost: maximumFilesPerCategory - 1)
        let timestamp = String(Int(Date.now.timeIntervalSince1970 * 1_000))
        let safeStem = sanitized(stem)
        return directory.appending(path: "\(safeStem)-\(timestamp)-\(UUID().uuidString).zip")
    }

    static func pruneAll() {
        for category in [Category.deletedItems, .containerRestore] {
            try? prune(category: category)
        }
    }

    static func prune(category: Category, now: Date = .now, keepingAtMost limit: Int = maximumFilesPerCategory) throws {
        let directory = try directory(for: category)
        try prune(directory: directory, now: now, keepingAtMost: limit)
    }

    static func prune(directory: URL, now: Date = .now, keepingAtMost limit: Int = maximumFilesPerCategory) throws {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ).compactMap { url -> (URL, Date)? in
            guard url.pathExtension.lowercased() == "zip",
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.1 > $1.1 }

        for (index, file) in files.enumerated()
        where index >= max(0, limit) || now.timeIntervalSince(file.1) > retentionAge {
            try? FileManager.default.removeItem(at: file.0)
        }
    }

    private static func directory(for category: Category) throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "Operation Safety Backups", directoryHint: .isDirectory)
        let directory = root.appending(path: category.rawValue, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func sanitized(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:\0").union(.controlCharacters)
        let cleaned = value.components(separatedBy: invalid).filter { !$0.isEmpty }.joined(separator: "-")
        return cleaned.isEmpty ? "Safety Backup" : String(cleaned.prefix(100))
    }

}

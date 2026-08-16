import Foundation

struct DirectoryMarkdownExportOptions: Sendable {
    var recursively = false
    var includeHidden = true
}

struct DirectoryMarkdownExportResult: Sendable {
    let url: URL
    let itemCount: Int
}

enum DirectoryMarkdownExporter {
    nonisolated static func export(
        path: String,
        options: DirectoryMarkdownExportOptions
    ) throws -> DirectoryMarkdownExportResult {
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        #if !targetEnvironment(simulator)
        let grant = try BadQueryClient.acquire(.forPath(root.path))
        defer { BadQueryClient.release(grant) }
        #endif

        let enumerationOptions: FileManager.DirectoryEnumerationOptions = options.includeHidden ? [] : [.skipsHiddenFiles]
        let urls: [URL]
        if options.recursively {
            urls = try recursiveContents(at: root, options: enumerationOptions)
        } else {
            urls = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: Array(FileSystemReader.resourceKeys),
                options: enumerationOptions
            )
        }

        let rows = urls.sorted { relativePath($0, root: root).localizedStandardCompare(relativePath($1, root: root)) == .orderedAscending }
            .map { url -> String in
                let values = try? url.resourceValues(forKeys: FileSystemReader.resourceKeys)
                let kind = values?.isDirectory == true ? "Directory" : (values?.isSymbolicLink == true ? "Symbolic link" : "File")
                let size = values?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "—"
                let modified = values?.contentModificationDate?.formatted(.iso8601) ?? "—"
                return "| `\(escape(relativePath(url, root: root)))` | \(kind) | \(size) | \(modified) |"
            }

        let markdown = """
        # Directory listing

        - Root: `\(escape(root.path))`
        - Scope: \(options.recursively ? "Recursive" : "Current folder only")
        - Items: \(rows.count)
        - Generated: \(Date().formatted(.iso8601))

        | Path | Type | Size | Modified |
        |---|---|---:|---|
        \(rows.joined(separator: "\n"))
        """
        let filename = "\(root.lastPathComponent.isEmpty ? "root" : root.lastPathComponent)-listing.md"
        return .init(url: try ExportCache.stage(Data(markdown.utf8), named: filename), itemCount: rows.count)
    }

    private nonisolated static func relativePath(_ url: URL, root: URL) -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let itemComponents = url.standardizedFileURL.pathComponents
        if itemComponents.starts(with: rootComponents) {
            return itemComponents.dropFirst(rootComponents.count).joined(separator: "/")
        }

        // iOS may spell the same data-container path as either /var or
        // /private/var. Anchor at the selected directory name as a fallback.
        if let anchor = itemComponents.lastIndex(of: root.lastPathComponent),
           anchor < itemComponents.index(before: itemComponents.endIndex) {
            return itemComponents[itemComponents.index(after: anchor)...].joined(separator: "/")
        }
        return url.lastPathComponent
    }

    private nonisolated static func recursiveContents(
        at root: URL,
        options: FileManager.DirectoryEnumerationOptions
    ) throws -> [URL] {
        var result: [URL] = []
        var pendingDirectories = [root]
        while let directory = pendingDirectories.popLast() {
            let children = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(FileSystemReader.resourceKeys),
                options: options
            )
            result.append(contentsOf: children)
            for child in children {
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isDirectory == true, values.isSymbolicLink != true {
                    pendingDirectories.append(child)
                }
            }
        }
        return result
    }

    private nonisolated static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "`", with: "&#96;")
            .replacingOccurrences(of: "|", with: "&#124;")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

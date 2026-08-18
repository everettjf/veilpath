import Foundation

enum FileClipboardMode: String, Sendable { case copy, cut }

struct FileClipboard: Equatable, Sendable {
    let mode: FileClipboardMode
    let sourceURLs: [URL]
}

struct FileOperationResult: Sendable {
    let affectedURLs: [URL]
    let failures: [FileOperationFailure]
    let skippedURLs: [URL]
    let safetyArchiveURL: URL?

    var completedFully: Bool { failures.isEmpty && skippedURLs.isEmpty }
}

struct FileOperationFailure: Sendable {
    let sourceURL: URL
    let message: String
}

enum FileOperationError: LocalizedError {
    case emptySelection, symbolicLinkUnsupported, destinationInsideSource, sourceMissing, archiveRequired, invalidSourcePath(String)

    var errorDescription: String? {
        switch self {
        case .emptySelection: "Select at least one file or folder."
        case .symbolicLinkUnsupported: "Symbolic links are skipped for guarded file operations."
        case .destinationInsideSource: "A folder cannot be copied or moved inside itself."
        case .sourceMissing: "One or more selected items no longer exist."
        case .archiveRequired: "Choose a ZIP or IPA archive."
        case .invalidSourcePath(let path): "A selected item contains a path outside its source folder: \(path)."
        }
    }
}

enum FileOperationService {
    typealias Progress = StoredZIPArchive.Progress

    nonisolated static func duplicate(_ item: FileItem) throws -> URL {
        guard !item.isSymbolicLink else { throw FileOperationError.symbolicLinkUnsupported }
        let parent = item.url.deletingLastPathComponent()
        let grant = try acquireGrant(parent)
        defer { release(grant) }
        let destination = uniqueDestination(for: item.url.lastPathComponent, in: parent, suffix: " copy")
        try FileManager.default.copyItem(at: item.url, to: destination)
        return destination
    }

    nonisolated static func paste(_ clipboard: FileClipboard, into destination: URL) throws -> FileOperationResult {
        guard !clipboard.sourceURLs.isEmpty else { throw FileOperationError.emptySelection }
        let grants = try acquireGrants(clipboard.sourceURLs.map { $0.deletingLastPathComponent() } + [destination])
        defer { grants.forEach(release) }
        var outputs: [URL] = []
        var failures: [FileOperationFailure] = []
        for (index, source) in clipboard.sourceURLs.enumerated() {
            if Task.isCancelled {
                failures.append(contentsOf: clipboard.sourceURLs[index...].map {
                    .init(sourceURL: $0, message: "Operation cancelled before this item was changed.")
                })
                break
            }
            do {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else { throw FileOperationError.sourceMissing }
                if try source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw FileOperationError.symbolicLinkUnsupported }
                if isDirectory.boolValue, canonicalPath(destination).hasPrefix(canonicalPath(source) + "/") {
                    throw FileOperationError.destinationInsideSource
                }
                let target = uniqueDestination(for: source.lastPathComponent, in: destination)
                switch clipboard.mode {
                case .copy: try FileManager.default.copyItem(at: source, to: target)
                case .cut: try FileManager.default.moveItem(at: source, to: target)
                }
                outputs.append(target)
            } catch {
                failures.append(.init(sourceURL: source, message: error.localizedDescription))
            }
        }
        return .init(affectedURLs: outputs, failures: failures, skippedURLs: [], safetyArchiveURL: nil)
    }

    nonisolated static func compress(
        _ items: [FileItem],
        into destination: URL,
        named requestedName: String,
        progress: Progress
    ) async throws -> FileOperationResult {
        guard !items.isEmpty else { throw FileOperationError.emptySelection }
        let grants = try acquireGrants(items.map { $0.url.deletingLastPathComponent() } + [destination])
        defer { grants.forEach(release) }
        let archived = try archiveEntries(for: items)
        guard !archived.entries.isEmpty else { throw FileOperationError.emptySelection }
        let name = requestedName.lowercased().hasSuffix(".zip") ? requestedName : requestedName + ".zip"
        let output = uniqueDestination(for: name, in: destination)
        try await StoredZIPArchive.write(entries: archived.entries, to: output, progress: progress)
        return .init(affectedURLs: [output], failures: [], skippedURLs: archived.skippedURLs, safetyArchiveURL: nil)
    }

    nonisolated static func extract(
        _ item: FileItem,
        into destination: URL,
        progress: Progress
    ) async throws -> FileOperationResult {
        guard !item.isDirectory, ["zip", "ipa"].contains(item.url.pathExtension.lowercased()) else {
            throw FileOperationError.archiveRequired
        }
        let grants = try acquireGrants([item.url.deletingLastPathComponent(), destination])
        defer { grants.forEach(release) }
        let base = item.url.deletingPathExtension().lastPathComponent
        let output = uniqueDestination(for: base, in: destination)
        do {
            let extracted = try await StoredZIPArchive.extract(item.url, to: output, progress: progress)
            return .init(affectedURLs: extracted.map(\.destinationURL), failures: [], skippedURLs: [], safetyArchiveURL: nil)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    nonisolated static func delete(_ items: [FileItem], progress: Progress) async throws -> FileOperationResult {
        guard !items.isEmpty else { throw FileOperationError.emptySelection }
        let grants = try acquireGrants(items.map { $0.url.deletingLastPathComponent() })
        defer { grants.forEach(release) }
        let deletable = items.filter { !$0.isSymbolicLink }
        let skipped = items.filter(\.isSymbolicLink).map(\.url)
        guard !deletable.isEmpty else { throw FileOperationError.symbolicLinkUnsupported }
        let archive = try OperationSafetyStore.makeArchiveURL(category: .deletedItems, stem: "Deleted Items")
        let archived = try archiveEntries(for: deletable)
        try await StoredZIPArchive.write(entries: archived.entries, to: archive, progress: progress)
        var removed: [URL] = []
        var failures: [FileOperationFailure] = []
        for (index, item) in deletable.enumerated() {
            if Task.isCancelled {
                failures.append(contentsOf: deletable[index...].map {
                    .init(sourceURL: $0.url, message: "Operation cancelled before this item was deleted.")
                })
                break
            }
            do {
                try FileManager.default.removeItem(at: item.url)
                removed.append(item.url)
            } catch {
                failures.append(.init(sourceURL: item.url, message: error.localizedDescription))
            }
        }
        return .init(affectedURLs: removed, failures: failures, skippedURLs: skipped + archived.skippedURLs,
                     safetyArchiveURL: archive)
    }

    private static func archiveEntries(for items: [FileItem]) throws -> (entries: [StoredZIPEntry], skippedURLs: [URL]) {
        var entries: [StoredZIPEntry] = []
        var skippedURLs: [URL] = []
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        for item in items {
            if item.isSymbolicLink { skippedURLs.append(item.url); continue }
            if !item.isDirectory {
                entries.append(.file(item.url, path: item.name, modifiedAt: item.modifiedAt))
                continue
            }
            entries.append(.directory(item.name, modifiedAt: item.modifiedAt))
            guard let enumerator = FileManager.default.enumerator(at: item.url, includingPropertiesForKeys: Array(keys), options: []) else { continue }
            while let url = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                let values = try url.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true {
                    skippedURLs.append(url)
                    if values.isDirectory == true { enumerator.skipDescendants() }
                    continue
                }
                let relative = item.name + "/" + (try relativePath(of: url, under: item.url))
                if values.isDirectory == true {
                    entries.append(.directory(relative, modifiedAt: values.contentModificationDate))
                } else {
                    entries.append(.file(url, path: relative, modifiedAt: values.contentModificationDate))
                }
            }
        }
        return (entries.sorted { $0.archivePath.localizedStandardCompare($1.archivePath) == .orderedAscending },
                skippedURLs)
    }

    private static func relativePath(of child: URL, under root: URL) throws -> String {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let childPath = child.resolvingSymlinksInPath().standardizedFileURL.path
        guard childPath.hasPrefix(rootPath + "/") else { throw FileOperationError.invalidSourcePath(child.path) }
        return String(childPath.dropFirst(rootPath.count + 1))
    }

    private static func uniqueDestination(for sourceName: String, in directory: URL, suffix: String = "") -> URL {
        let source = sourceName as NSString
        let ext = source.pathExtension
        let stem = source.deletingPathExtension
        var candidate = directory.appending(path: stem + suffix + (ext.isEmpty ? "" : "." + ext))
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appending(path: "\(stem)\(suffix) \(index)\(ext.isEmpty ? "" : "." + ext)")
            index += 1
        }
        return candidate
    }

    private static func canonicalPath(_ url: URL) -> String {
        var path = url.resolvingSymlinksInPath().standardizedFileURL.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path == "/var" || path.hasPrefix("/var/") { path = "/private" + path }
        return path
    }

    private static func acquireGrant(_ url: URL) throws -> BadQueryGrant? {
        #if targetEnvironment(simulator)
        nil
        #else
        try BadQueryClient.acquire(.forPath(url.path))
        #endif
    }

    private static func acquireGrants(_ urls: [URL]) throws -> [BadQueryGrant?] {
        var grants: [BadQueryGrant?] = []
        do {
            for url in Set(urls.map(\.standardizedFileURL)) { grants.append(try acquireGrant(url)) }
            return grants
        } catch {
            grants.forEach(release)
            throw error
        }
    }

    private static func release(_ grant: BadQueryGrant?) { if let grant { BadQueryClient.release(grant) } }
}

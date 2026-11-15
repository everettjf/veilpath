import CryptoKit
import Darwin
import Foundation

enum CacheLocation: String, Codable, CaseIterable, Identifiable, Sendable {
    case caches = "Library/Caches"
    case temporary = "tmp"
    var id: String { rawValue }
    var title: LocalizedStringResource {
        switch self { case .caches: "Caches"; case .temporary: "Temporary Files" }
    }
}

struct AppStorageSnapshot: Identifiable, Sendable {
    let container: ContainerDescriptor
    let documentsBytes: Int64
    let libraryBytes: Int64
    let cacheBytes: Int64
    let temporaryBytes: Int64
    let otherBytes: Int64
    let fileCount: Int
    let unreadableCount: Int
    let skippedLinks: Int
    let scannedAt: Date
    var id: String { container.id }
    var totalBytes: Int64 { documentsBytes + libraryBytes + cacheBytes + temporaryBytes + otherBytes }
    var isComplete: Bool { unreadableCount == 0 }
}

enum AppManagementError: LocalizedError {
    case incompleteScan, unsafeTree, sourceChanged, invalidBackup, wrongApplication, busy, recoveryRequired, selfOperation, backupInUse
    var errorDescription: String? {
        switch self {
        case .incompleteScan: String(localized: "Some files could not be read. Refresh the scan before cleaning.")
        case .unsafeTree: String(localized: "This operation contains a symbolic link or unsupported file and was stopped.")
        case .sourceChanged: String(localized: "The app changed its files during this operation. Close it and try again.")
        case .invalidBackup: String(localized: "The backup is incomplete, damaged, or has been changed.")
        case .wrongApplication: String(localized: "This backup does not belong to the selected application.")
        case .busy: String(localized: "Wait for the current app data operation to finish.")
        case .recoveryRequired: String(localized: "An interrupted cache operation needs recovery. Its backup and staged files have been preserved.")
        case .selfOperation: String(localized: "Veilpath cannot clean or back up its own active data container here.")
        case .backupInUse: String(localized: "This backup contains recovery work and cannot be deleted.")
        }
    }
}

enum AppStorageService {
    static func scan(_ container: ContainerDescriptor) throws -> AppStorageSnapshot {
        let root = URL(fileURLWithPath: container.path)
        let grant = try ManagedAppFiles.acquire(root)
        defer { ManagedAppFiles.release(grant) }
        var sizes = [Int64](repeating: 0, count: 5)
        var files = 0, failures = 0, links = 0, visited = 0
        var measuredBytes: Int64 = 0
        guard try ManagedAppFiles.kind(root) == S_IFDIR else { throw AppManagementError.unsafeTree }
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
            options: [], errorHandler: { _, _ in failures += 1; return true }) else { throw AppManagementError.incompleteScan }
        while let url = iterator.nextObject() as? URL {
            try Task.checkCancellation()
            visited += 1
            if visited > 200_000 { failures += 1; break }
            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                if values.isSymbolicLink == true { links += 1; iterator.skipDescendants(); continue }
                guard values.isRegularFile == true else { continue }
                guard let size = values.fileSize, size >= 0 else { failures += 1; continue }
                let (nextSize, overflow) = measuredBytes.addingReportingOverflow(Int64(size))
                guard !overflow else { failures += 1; continue }
                let relative = try ManagedAppFiles.relative(url, root: root)
                let bucket: Int
                if relative.hasPrefix("Documents/") { bucket = 0 }
                else if relative.hasPrefix("Library/Caches/") { bucket = 2 }
                else if relative.hasPrefix("Library/") { bucket = 1 }
                else if relative.hasPrefix("tmp/") { bucket = 3 }
                else { bucket = 4 }
                sizes[bucket] += Int64(size); files += 1
                measuredBytes = nextSize
            } catch is CancellationError { throw CancellationError() }
            catch { failures += 1; iterator.skipDescendants() }
        }
        return .init(container: container, documentsBytes: sizes[0], libraryBytes: sizes[1], cacheBytes: sizes[2],
                     temporaryBytes: sizes[3], otherBytes: sizes[4], fileCount: files,
                     unreadableCount: failures, skippedLinks: links, scannedAt: .now)
    }
}

struct ManagedTreeEntry: Codable, Equatable, Sendable {
    let path: String
    let directory: Bool
    let size: Int64
    let sha256: String?
    let permissions: Int
    let modifiedAt: Date?
    // File dates/permissions are preserved but do not affect content comparison.
    var contentKey: String { "\(directory)|\(path)|\(size)|\(sha256 ?? "")" }
}

enum ManagedAppFiles {
    static func acquire(_ root: URL) throws -> SandboxAccessGrant? {
        #if targetEnvironment(simulator)
        return nil
        #else
        return try SandboxAccessClient.acquire(.forPath(root.path))
        #endif
    }
    static func release(_ grant: SandboxAccessGrant?) { if let grant { SandboxAccessClient.release(grant) } }
    static func canonical(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path == "/var" || path.hasPrefix("/var/") ? "/private" + path : path
    }
    static func relative(_ url: URL, root: URL) throws -> String {
        let base = canonical(root), path = canonical(url)
        guard path.hasPrefix(base + "/"), canonical(url.resolvingSymlinksInPath()) == path else {
            throw AppManagementError.unsafeTree
        }
        return String(path.dropFirst(base.count + 1))
    }
    static func kind(_ url: URL) throws -> mode_t? {
        var info = stat()
        if lstat(url.path, &info) == 0 { return info.st_mode & S_IFMT }
        if errno == ENOENT { return nil }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    static func hash(_ url: URL, checkCancellation: Bool = true) throws -> String {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw AppManagementError.unsafeTree }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        var before = stat(), after = stat(), named = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw AppManagementError.unsafeTree }
        var digest = SHA256()
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            if checkCancellation { try Task.checkCancellation() }
            digest.update(data: chunk)
        }
        guard fstat(fd, &after) == 0, lstat(url.path, &named) == 0,
              before.st_dev == named.st_dev, before.st_ino == named.st_ino,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw AppManagementError.sourceChanged }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func tree(_ root: URL, prefix: String = "", checkCancellation: Bool = true) throws -> [ManagedTreeEntry] {
        guard try kind(root) == S_IFDIR, canonical(root.resolvingSymlinksInPath()) == canonical(root) else {
            throw AppManagementError.unsafeTree
        }
        var entries: [ManagedTreeEntry] = []
        var enumerationError: Error?
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
            options: [], errorHandler: { _, error in enumerationError = error; return false }) else { throw AppManagementError.incompleteScan }
        var paths = [root]
        while let url = iterator.nextObject() as? URL {
            if checkCancellation { try Task.checkCancellation() }
            paths.append(url)
            if paths.count > 60_000 { throw StoredZIPError.archiveTooLarge }
        }
        if let enumerationError { throw enumerationError }
        for url in paths {
            if checkCancellation { try Task.checkCancellation() }
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw AppManagementError.sourceChanged }
            let directory = info.st_mode & S_IFMT == S_IFDIR
            guard directory || info.st_mode & S_IFMT == S_IFREG else { throw AppManagementError.unsafeTree }
            let relative = url == root ? "" : try relative(url, root: root)
            let path = [prefix, relative].filter { !$0.isEmpty }.joined(separator: "/")
            entries.append(.init(path: path, directory: directory, size: directory ? 0 : info.st_size,
                                 sha256: directory ? nil : try hash(url, checkCancellation: checkCancellation), permissions: Int(info.st_mode & 0o777),
                                 modifiedAt: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))))
        }
        return entries.sorted { $0.path < $1.path }
    }
    static func sameContents(_ lhs: [ManagedTreeEntry], _ rhs: [ManagedTreeEntry]) -> Bool {
        lhs.map(\.contentKey).sorted() == rhs.map(\.contentKey).sorted()
    }
    static func validate(_ container: ContainerDescriptor) throws {
        let root = URL(fileURLWithPath: container.path)
        guard container.kind == .application, container.identifier != nil,
              canonical(root) != canonical(URL(fileURLWithPath: NSHomeDirectory())),
              canonical(root.resolvingSymlinksInPath()) == canonical(root) else { throw AppManagementError.selfOperation }
        let parent = canonical(root.deletingLastPathComponent())
        if parent == canonical(URL(fileURLWithPath: ContainerKind.application.rootPath)), UUID(uuidString: root.lastPathComponent) != nil { return }
        // Dedicated regression fixtures are direct children of our own tmp.
        // A stored journal can never use this exception to target another app.
        let fixturePrefix = "veilpath-management-"
        if canonical(root.deletingLastPathComponent()) == canonical(FileManager.default.temporaryDirectory),
           root.lastPathComponent.hasPrefix(fixturePrefix),
           UUID(uuidString: String(root.lastPathComponent.dropFirst(fixturePrefix.count))) != nil { return }
        throw AppManagementError.unsafeTree
    }
    static func verifyIdentity(_ container: ContainerDescriptor) throws {
        let root = URL(fileURLWithPath: container.path)
        if canonical(root.deletingLastPathComponent()) != canonical(URL(fileURLWithPath: ContainerKind.application.rootPath)) { return }
        let metadata = root.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
        let grant = try acquire(metadata); defer { release(grant) }
        guard try kind(metadata) == S_IFREG,
              let size = try metadata.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1024 * 1024,
              let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: metadata), format: nil) as? [String: Any],
              plist["MCMMetadataIdentifier"] as? String == container.identifier else { throw AppManagementError.wrongApplication }
    }
    static func freeSpace() -> Int64? {
        let values = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        return (values?[.systemFreeSize] as? NSNumber)?.int64Value
    }
}

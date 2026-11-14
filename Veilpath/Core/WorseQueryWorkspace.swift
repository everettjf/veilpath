import Darwin
import Foundation

/// Only the app's own group is staged. The original directory is renamed, never
/// deleted; its fixed recovery name also covers a crash at any staging step.
struct WorseQueryWorkspace {
    let root: URL

    func withStagedCache<T>(target: String, operation: () throws -> T) throws -> T {
        try withLock {
            try recoverLocked()
            let library = root.appendingPathComponent("Library")
            if try kind(library) == nil {
                try FileManager.default.createDirectory(at: library, withIntermediateDirectories: false)
            }
            guard try kind(library) == S_IFDIR else { throw WorkspaceError.unsafeState }
            let cache = library.appendingPathComponent("Caches")
            let saved = library.appendingPathComponent(".veilpath-worse-query-preserved")
            if try kind(cache) == nil {
                try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
            }
            guard try kind(cache) == S_IFDIR else { throw WorkspaceError.unsafeState }
            // Never allow the temporary link to point back into the staged tree.
            let resolvedTarget = URL(fileURLWithPath: target).resolvingSymlinksInPath().path
            let resolvedLibrary = library.resolvingSymlinksInPath().path
            guard resolvedTarget != resolvedLibrary,
                  !resolvedTarget.hasPrefix(resolvedLibrary + "/") else { throw WorkspaceError.unsupportedTarget }
            guard rename(cache.path, saved.path) == 0 else { throw posixError() }
            let result = Result { () throws -> T in
                guard symlink(target, cache.path) == 0 else { throw posixError() }
                return try operation()
            }
            // Restoration is mandatory, including when the query fails. A failed
            // restoration retains the original at `saved` for the next launch.
            try recoverLocked()
            return try result.get()
        }
    }

    func recover() throws { try withLock { try recoverLocked() } }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        let lockURL = root.appendingPathComponent(".veilpath-worse-query.lock")
        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError() }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1 else { throw WorkspaceError.unsafeState }
        guard flock(fd, LOCK_EX) == 0 else { throw posixError() }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private func recoverLocked() throws {
        let library = root.appendingPathComponent("Library")
        guard let libraryKind = try kind(library) else { return }
        guard libraryKind == S_IFDIR else { throw WorkspaceError.unsafeState }
        let cache = library.appendingPathComponent("Caches")
        let saved = library.appendingPathComponent(".veilpath-worse-query-preserved")
        guard let savedKind = try kind(saved) else { return }
        guard savedKind == S_IFDIR else { throw WorkspaceError.unsafeState }
        if let cacheKind = try kind(cache) {
            guard cacheKind == S_IFLNK else { throw WorkspaceError.unsafeState }
            // unlink removes only the link, without following its target.
            guard unlink(cache.path) == 0 else { throw posixError() }
        }
        guard rename(saved.path, cache.path) == 0 else { throw posixError() }
    }

    private func kind(_ url: URL) throws -> mode_t? {
        var info = stat()
        if lstat(url.path, &info) == 0 { return info.st_mode & S_IFMT }
        if errno == ENOENT { return nil }
        throw posixError()
    }

    private func posixError() -> Error { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

    enum WorkspaceError: LocalizedError {
        case unsafeState
        case unsupportedTarget
        var errorDescription: String? {
            switch self {
            case .unsafeState:
                String(localized: "The App Group access workspace needs recovery. Its original contents have been preserved.")
            case .unsupportedTarget:
                String(localized: "worse_query cannot stage access inside its own App Group Library.")
            }
        }
    }
}

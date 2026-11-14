import Darwin
import Foundation

enum BadQueryError: LocalizedError, Equatable {
    case dynamicSymbolsUnavailable
    case queryCreationFailed
    case outsideContainerManagerSandbox
    case kernelRejectedExtension
    case allocationFailed
    case missingPath
    case invalidAbsolutePath
    case extensionConsumptionFailed(Int64)

    init(code: Int64) {
        switch code {
        case -1: self = .dynamicSymbolsUnavailable
        case -2: self = .queryCreationFailed
        case -3: self = .outsideContainerManagerSandbox
        case -4: self = .kernelRejectedExtension
        case -5: self = .allocationFailed
        case -254: self = .missingPath
        case -255: self = .invalidAbsolutePath
        default: self = .extensionConsumptionFailed(code)
        }
    }

    var errorDescription: String? {
        switch self {
        case .dynamicSymbolsUnavailable: String(localized: "Required private symbols are unavailable.")
        case .queryCreationFailed: String(localized: "Container Manager query creation failed.")
        case .outsideContainerManagerSandbox: String(localized: "Container Manager rejected the requested path.")
        case .kernelRejectedExtension: String(localized: "The kernel refused to issue a sandbox extension.")
        case .allocationFailed: String(localized: "The access query could not allocate required memory.")
        case .missingPath: String(localized: "The target path does not exist.")
        case .invalidAbsolutePath: String(localized: "The target must be an absolute path.")
        case .extensionConsumptionFailed(let code): String(localized: "Consuming the sandbox extension failed (\(code)).")
        }
    }
}

struct SandboxAccessRequest: Equatable, Sendable {
    var path: String
    var createIfMissing = false
    var groupIdentifier: String?
    var targetsAppGroup = false

    static func forPath(_ path: String) -> Self {
        let normalized = path.hasPrefix("/private/var/") ? String(path.dropFirst(8)) : path
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26,
           (normalized == ContainerKind.appGroup.rootPath || normalized.hasPrefix(ContainerKind.appGroup.rootPath + "/")) {
            return .init(path: path, groupIdentifier: SandboxAccessClient.appGroupIdentifier, targetsAppGroup: true)
        }
        return .init(path: path)
    }
}

struct SandboxAccessGrant: Identifiable, Equatable, Sendable {
    let id: UUID
    let path: String
    let handle: Int64
    let acquiredAt: Date
    let backend: SandboxBackend
}

enum SandboxBackend: String, CaseIterable, Sendable {
    case badQuery = "bad_query"
    case worseQuery = "worse_query"
}

enum SandboxBackendSelection: String, Sendable {
    case automatic
    case badQuery = "bad_query"
    case worseQuery = "worse_query"

}

enum SandboxAccessError: LocalizedError {
    case noAppGroup
    case busy
    case worseQuery(Int64)
    case bothFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .noAppGroup:
            String(localized: "No usable App Group is available. Re-sign Veilpath with its App Group entitlement.")
        case .busy:
            String(localized: "Wait for file operations to finish before changing the access backend.")
        case .worseQuery(let code):
            String(localized: "worse_query could not grant access (code: \(code)).")
        case .bothFailed(let worse, let bad):
            String(localized: "Both access backends failed. worse_query: \(worse) bad_query: \(bad)")
        }
    }
}

/// All callers keep operation-scoped grants. Fallback only acquires a grant;
/// it never retries the caller's read, write, restore, or replacement operation.
enum SandboxAccessClient {
    static let defaultAppGroupIdentifier = "group.com.xnu.veilpath"
    static let appGroupIdentifier = resolveAppGroupIdentifier(
        remappedGroups: Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] ?? []
    ) { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil }
    private static let state = State()

    /// AltStore records its team-suffixed groups in ALTAppGroups when re-signing.
    /// Accept only our own group, and require an actual accessible container.
    /// Never stage query work in an unrelated installer's shared group.
    static func resolveAppGroupIdentifier(remappedGroups: [String], isAccessible: (String) -> Bool) -> String {
        if isAccessible(defaultAppGroupIdentifier) { return defaultAppGroupIdentifier }
        let prefix = defaultAppGroupIdentifier + "."
        let candidates = Set(remappedGroups.filter { group in
            guard group.hasPrefix(prefix) else { return false }
            let team = group.dropFirst(prefix.count)
            return team.utf8.count == 10 && team.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) }
        }).filter(isAccessible)
        // Missing or ambiguous mappings retain the existing fail-closed path.
        return candidates.count == 1 ? candidates.first! : defaultAppGroupIdentifier
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var selection: SandboxBackendSelection
        var lastBackend: SandboxBackend?
        var grants: Set<UUID> = []
        var preferred: [String: SandboxBackend] = [:]
        var workspaceRecovered = false

        init() {
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "--access-backend"), arguments.indices.contains(index + 1),
               let override = SandboxBackendSelection(rawValue: arguments[index + 1]) {
                selection = override
                return
            }
            #endif
            // Backend selection is automatic in the product. Ignore preferences
            // saved by earlier builds; explicit overrides exist only for tests.
            selection = .automatic
        }
    }

    static var selection: SandboxBackendSelection { state.lock.withLock { state.selection } }
    static var lastBackend: SandboxBackend? { state.lock.withLock { state.lastBackend } }

    #if DEBUG
    static func setSelection(_ selection: SandboxBackendSelection) throws {
        try state.lock.withLock {
            guard state.grants.isEmpty else { throw SandboxAccessError.busy }
            state.selection = selection
            state.lastBackend = nil
            state.preferred.removeAll()
        }
    }
    #endif

    static func recoverWorkspace() throws {
        try state.lock.withLock { try recoverWorkspaceLocked() }
    }

    private static func recoverWorkspaceLocked() throws {
        if let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            try WorseQueryWorkspace(root: root).recover()
        }
        state.workspaceRecovered = true
    }

    static func acquire(_ request: SandboxAccessRequest) throws -> SandboxAccessGrant {
        guard request.path.hasPrefix("/") else { throw BadQueryError.invalidAbsolutePath }
        // Preview/export callers may construct a request directly. Apply the
        // iOS 26 App Group compatibility path consistently for both backends.
        var request = request
        if request.groupIdentifier == nil {
            let defaults = SandboxAccessRequest.forPath(request.path)
            request.groupIdentifier = defaults.groupIdentifier
            request.targetsAppGroup = request.targetsAppGroup || defaults.targetsAppGroup
        }
        return try state.lock.withLock {
            if !state.workspaceRecovered { try recoverWorkspaceLocked() }
            let category = ContainerKind.allCases.first {
                request.path == $0.rootPath || request.path.hasPrefix($0.rootPath + "/")
            }?.rawValue ?? "Other"
            let backends: [SandboxBackend]
            switch state.selection {
            case .badQuery: backends = [.badQuery]
            case .worseQuery: backends = [.worseQuery]
            case .automatic:
                backends = state.preferred[category] == .badQuery ? [.badQuery, .worseQuery] : [.worseQuery, .badQuery]
            }
            var failures: [SandboxBackend: Error] = [:]
            for backend in backends {
                do {
                    let handle = try backend == .badQuery ? acquireBadQuery(request) : acquireWorseQuery(request)
                    let grant = SandboxAccessGrant(id: UUID(), path: request.path, handle: handle, acquiredAt: .now, backend: backend)
                    state.grants.insert(grant.id)
                    state.lastBackend = backend
                    state.preferred[category] = backend
                    return grant
                } catch {
                    // A workspace recovery failure must stop all access, not be
                    // hidden by fallback to another backend.
                    if case WorseQueryWorkspace.WorkspaceError.unsafeState = error { throw error }
                    if (error as NSError).domain == NSPOSIXErrorDomain { throw error }
                    failures[backend] = error
                }
            }
            if failures.count == 1, let error = failures.values.first { throw error }
            throw SandboxAccessError.bothFailed(
                failures[.worseQuery]?.localizedDescription ?? "unknown",
                failures[.badQuery]?.localizedDescription ?? "unknown"
            )
        }
    }

    private static func acquireBadQuery(_ request: SandboxAccessRequest) throws -> Int64 {
        let handle: Int64 = request.path.withCString { path in
            if let groupIdentifier = request.groupIdentifier, !groupIdentifier.isEmpty {
                return groupIdentifier.withCString { group in
                    bad_query(
                        UnsafeMutablePointer(mutating: path),
                        request.createIfMissing,
                        UnsafeMutablePointer(mutating: group),
                        request.targetsAppGroup
                    )
                }
            }
            return bad_query(
                UnsafeMutablePointer(mutating: path),
                request.createIfMissing,
                nil,
                request.targetsAppGroup
            )
        }

        guard handle >= 0 else { throw BadQueryError(code: handle) }
        return handle
    }

    private static func acquireWorseQuery(_ request: SandboxAccessRequest) throws -> Int64 {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw SandboxAccessError.noAppGroup
        }
        if !request.createIfMissing {
            var info = stat()
            guard lstat(request.path, &info) == 0 else { throw BadQueryError.missingPath }
        }
        let normalized = request.path.hasPrefix("/private/var/") ? String(request.path.dropFirst(8)) : request.path
        let alternate = ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26
            && (normalized == ContainerKind.appGroup.rootPath || normalized.hasPrefix(ContainerKind.appGroup.rootPath + "/"))
        var handle: Int64 = -1
        do {
            return try WorseQueryWorkspace(root: root).withStagedCache(target: request.path) {
                handle = veilpath_worse_query(appGroupIdentifier, alternate)
                guard handle >= 0 else { throw SandboxAccessError.worseQuery(handle) }
                return handle
            }
        } catch {
            if handle >= 0 { bad_query_release(handle) }
            throw error
        }
    }

    static func release(_ grant: SandboxAccessGrant) {
        state.lock.withLock {
            guard state.grants.remove(grant.id) != nil else { return }
            bad_query_release(grant.handle)
        }
    }

    static func inodeChildren(at path: String, maximumInode: Int64) -> [String] {
        guard maximumInode > 0 else { return [] }
        return path.withCString { pathPointer in
            guard let result = bad_query_list(UnsafeMutablePointer(mutating: pathPointer), maximumInode) else {
                return []
            }
            defer { free(result) }
            return String(cString: result)
                .split(separator: "\n")
                .map(String.init)
        }
    }
}

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
        case .dynamicSymbolsUnavailable: "Required private symbols are unavailable."
        case .queryCreationFailed: "Container Manager query creation failed."
        case .outsideContainerManagerSandbox: "Container Manager rejected the requested path."
        case .kernelRejectedExtension: "The kernel refused to issue a sandbox extension."
        case .allocationFailed: "The access query could not allocate required memory."
        case .missingPath: "The target path does not exist."
        case .invalidAbsolutePath: "The target must be an absolute path."
        case .extensionConsumptionFailed(let code): "Consuming the sandbox extension failed (\(code))."
        }
    }
}

struct BadQueryRequest: Equatable, Sendable {
    var path: String
    var createIfMissing = false
    var groupIdentifier: String?
    var targetsAppGroup = false

    static func forPath(_ path: String) -> Self {
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26,
           path.hasPrefix(ContainerKind.appGroup.rootPath) {
            return .init(path: path, groupIdentifier: "group.com.eevv.Vellune", targetsAppGroup: true)
        }
        return .init(path: path)
    }
}

struct BadQueryGrant: Identifiable, Equatable, Sendable {
    let id: UUID
    let path: String
    let handle: Int64
    let acquiredAt: Date
}

enum BadQueryClient {
    static func acquire(_ request: BadQueryRequest) throws -> BadQueryGrant {
        guard request.path.hasPrefix("/") else { throw BadQueryError.invalidAbsolutePath }

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
        return BadQueryGrant(id: UUID(), path: request.path, handle: handle, acquiredAt: .now)
    }

    static func release(_ grant: BadQueryGrant) {
        bad_query_release(grant.handle)
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

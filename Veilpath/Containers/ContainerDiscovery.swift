import Foundation

enum ContainerKind: String, Codable, CaseIterable, Sendable {
    case application = "Application"
    case appGroup = "App Group"
    case plugin = "Plugin"
    case internalDaemon = "Internal Daemon"
    case systemData = "System Data"
    case systemGroup = "System Group"

    var localizedName: LocalizedStringResource {
        switch self {
        case .application: "Application"
        case .appGroup: "App Group"
        case .plugin: "Plugin"
        case .internalDaemon: "Internal Daemon"
        case .systemData: "System Data"
        case .systemGroup: "System Group"
        }
    }

    var localizedContainerTitle: LocalizedStringResource {
        switch self {
        case .application: "Application Containers"
        case .appGroup: "App Group Containers"
        case .plugin: "Plugin Containers"
        case .internalDaemon: "Internal Daemon Containers"
        case .systemData: "System Data Containers"
        case .systemGroup: "System Group Containers"
        }
    }

    var systemImage: String {
        switch self {
        case .application: "app.dashed"
        case .appGroup: "person.2.badge.gearshape"
        case .plugin: "puzzlepiece.extension"
        case .internalDaemon: "gearshape.arrow.triangle.2.circlepath"
        case .systemData: "gearshape.2"
        case .systemGroup: "square.3.layers.3d"
        }
    }

    var rootPath: String {
        switch self {
        case .application: "/var/mobile/Containers/Data/Application"
        case .appGroup: "/var/mobile/Containers/Shared/AppGroup"
        case .plugin: "/var/mobile/Containers/Data/PluginKitPlugin"
        case .internalDaemon: "/var/mobile/Containers/Data/InternalDaemon"
        case .systemData: "/var/containers/Data/System"
        case .systemGroup: "/var/containers/Shared/SystemGroup"
        }
    }
}

struct ContainerDescriptor: Identifiable, Codable, Hashable, Sendable {
    let path: String
    let identifier: String?
    let uuid: String
    let kind: ContainerKind
    let metadataDiagnostic: String?

    var id: String { path }
    var displayName: String { identifier ?? uuid }
}

enum ContainerDiscoveryService {
    nonisolated private static let cacheDirectory = FileManager.default.urls(
        for: .cachesDirectory,
        in: .userDomainMask
    )[0].appending(path: "ContainerIndexes", directoryHint: .isDirectory)

    nonisolated static func discoverApplications(maximumInode: Int64) -> [ContainerDescriptor] {
        let root = ContainerKind.application.rootPath
        let paths = BadQueryClient.inodeChildren(at: root, maximumInode: maximumInode)
        let descriptors = paths.compactMap { descriptor(path: $0, kind: .application) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        persist(descriptors, kind: .application)
        return descriptors
    }

    nonisolated static func discover(_ kind: ContainerKind) -> [ContainerDescriptor] {
        if kind == .application { return discoverApplications(maximumInode: 5_000_000) }
        let root = kind.rootPath
        let paths: [String]
        if let rootGrant = try? BadQueryClient.acquire(.forPath(root)) {
            defer { BadQueryClient.release(rootGrant) }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            paths = names.map { URL(fileURLWithPath: root).appending(path: $0).path }
        } else {
            paths = BadQueryClient.inodeChildren(at: root, maximumInode: 5_000_000)
        }
        let descriptors = paths.compactMap {
            descriptor(path: $0, kind: kind)
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        persist(descriptors, kind: kind)
        return descriptors
    }

    nonisolated static func discoverSystemData() -> [ContainerDescriptor] {
        discover(.systemData)
    }

    nonisolated static func loadCached(_ kind: ContainerKind) -> [ContainerDescriptor] {
        loadCache(at: cacheURL(for: kind))
    }

    nonisolated private static func loadCache(at url: URL) -> [ContainerDescriptor] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([ContainerDescriptor].self, from: data) else {
            return []
        }
        return decoded
    }

    nonisolated private static func descriptor(
        path: String,
        kind: ContainerKind
    ) -> ContainerDescriptor? {
        guard let grant = try? BadQueryClient.acquire(.forPath(path)) else { return nil }
        defer { BadQueryClient.release(grant) }

        let metadataURL = URL(fileURLWithPath: path)
            .appending(path: ".com.apple.mobile_container_manager.metadata.plist")
        let identifier: String?
        let metadataDiagnostic: String?
        do {
            let metadataGrant = try BadQueryClient.acquire(.forPath(metadataURL.path))
            defer { BadQueryClient.release(metadataGrant) }
            let data = try Data(contentsOf: metadataURL)
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
            guard let dictionary = plist as? [String: Any] else {
                throw ContainerMetadataError.invalidRoot
            }
            identifier = dictionary["MCMMetadataIdentifier"] as? String
            metadataDiagnostic = "keys=\(dictionary.keys.sorted().joined(separator: ","))"
        } catch {
            identifier = nil
            metadataDiagnostic = error.localizedDescription
        }

        return ContainerDescriptor(
            path: path,
            identifier: identifier,
            uuid: URL(fileURLWithPath: path).lastPathComponent,
            kind: kind,
            metadataDiagnostic: metadataDiagnostic
        )
    }

    nonisolated private static func cacheURL(for kind: ContainerKind) -> URL {
        cacheDirectory.appending(path: "\(kind.rawValue.replacingOccurrences(of: " ", with: "-"))-containers.json")
    }

    nonisolated private static func persist(_ descriptors: [ContainerDescriptor], kind: ContainerKind) {
        guard let data = try? JSONEncoder().encode(descriptors) else { return }
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: cacheURL(for: kind), options: .atomic)
    }

    private enum ContainerMetadataError: LocalizedError {
        case invalidRoot
        var errorDescription: String? { "Container metadata root is not a dictionary" }
    }
}

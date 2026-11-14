import Darwin
import Foundation

enum AppNameResolver {
    private static let systemNames: [String: LocalizedStringResource] = [
        "com.apple.Preferences": "Settings", "com.apple.DocumentsApp": "Files",
        "com.apple.mobileslideshow": "Photos", "com.apple.camera": "Camera",
        "com.apple.mobilenotes": "Notes", "com.apple.mobilephone": "Phone",
        "com.apple.Maps": "Maps", "com.apple.weather": "Weather", "com.apple.Music": "Music",
        "com.apple.mobilecal": "Calendar", "com.apple.mobiletimer": "Clock",
        "com.apple.reminders": "Reminders", "com.apple.AppStore": "App Store"
    ]
    private final class Diagnostics: @unchecked Sendable {
        let lock = NSLock()
        var value = "not attempted"
    }
    private static let diagnostics = Diagnostics()
    static var lastDiagnostic: String { diagnostics.lock.withLock { diagnostics.value } }
    static func names(for containers: [ContainerDescriptor]) -> [String: String] {
        var names: [String: String] = [:]
        for container in containers {
            if let identifier = container.identifier, let name = systemNames[identifier] {
                names[identifier] = String(localized: name)
            }
        }
        let builtInCount = names.count
        let apiNames = veilpath_application_names(containers.compactMap(\.identifier)) ?? [:]
        names.merge(apiNames) { _, api in api }
        var detail = "api=\(apiNames.count), builtIn=\(builtInCount)"
        #if !targetEnvironment(simulator)
        var daemons = ContainerDiscoveryService.loadCached(.internalDaemon)
        if daemons.isEmpty { daemons = ContainerDiscoveryService.discover(.internalDaemon) }
        for daemon in daemons where daemon.identifier?.lowercased().contains("lsd") == true {
            do {
                let root = URL(fileURLWithPath: daemon.path)
                let grant = try SandboxAccessClient.acquire(.forPath(root.path))
                defer { SandboxAccessClient.release(grant) }
                let caches = root.appendingPathComponent("Library/Caches")
                let cacheGrant = try SandboxAccessClient.acquire(.forPath(caches.path))
                defer { SandboxAccessClient.release(cacheGrant) }
                let files = try FileManager.default.contentsOfDirectory(at: caches, includingPropertiesForKeys: [.contentModificationDateKey])
                    .filter { $0.lastPathComponent.hasPrefix("com.apple.LaunchServices-") && $0.pathExtension == "csstore" }
                    .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                        > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
                for file in files.prefix(3) {
                    do {
                    let fileGrant = try SandboxAccessClient.acquire(.forPath(file.path))
                    defer { SandboxAccessClient.release(fileGrant) }
                    let data = try readStable(file)
                    let databaseNames = parse(data, containers: containers, anchors: names)
                    detail += ", databaseBytes=\(data.count), databaseNames=\(databaseNames.count)"
                    guard !databaseNames.isEmpty else { continue }
                    names.merge(databaseNames) { preferred, _ in preferred }
                    break
                    } catch { detail += ", storeError=\(error.localizedDescription)" }
                }
                if files.isEmpty { detail += ", store=not-found" }
            } catch { detail += ", daemonError=\(error.localizedDescription)" }
        }
        #endif
        diagnostics.lock.withLock { diagnostics.value = detail }
        return names
    }

    private static func readStable(_ file: URL) throws -> Data {
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw AppManagementError.unsafeTree }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 4096, before.st_size <= 64 * 1024 * 1024 else { throw AppManagementError.unsafeTree }
        let data = try handle.read(upToCount: Int(before.st_size) + 1) ?? Data()
        guard data.count == before.st_size, fstat(fd, &after) == 0,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw AppManagementError.sourceChanged }
        return data
    }

    /// Independent bounded CSStore reader. Field layout observations:
    /// https://github.com/kolbicz/WQFiles/blob/main/WQLaunchServices.m
    /// A name is accepted only when both container path and identifier match
    /// independently discovered metadata; unknown schemas simply produce no names.
    static func parse(_ data: Data, containers: [ContainerDescriptor], anchors: [String: String] = [:]) -> [String: String] {
        guard data.count >= 4096, data.count <= 64 * 1024 * 1024,
              data.prefix(4) == Data("bdsl".utf8) else { return [:] }
        let known = Dictionary(containers.compactMap { item -> (String, String)? in
            guard let identifier = item.identifier else { return nil }
            return (ManagedAppFiles.canonical(URL(fileURLWithPath: item.path)), identifier)
        }, uniquingKeysWith: { first, _ in first })
        // (record length, identifier offset, container offset, name offset, display offset)
        let layouts = [(0x23c, 0x0c, 0x64, 0x68, 0x70), (0x23c, 0x0c, 0x60, 0x64, 0x6c),
                       (0x250, 0x0c, 0x68, 0x6c, 0x74), (0x25c, 0x0c, 0x6c, 0x70, 0x78)]
        struct Record { let bundle: UInt32; let container: UInt32; let name: UInt32; let display: UInt32 }
        var records: [Record] = [], needed: Set<UInt32> = []
        let heap = data.range(of: Data("<string>".utf8))?.lowerBound ?? data.count
        let matched = data.withUnsafeBytes { bytes -> [String: String] in
            func word(_ offset: Int) -> UInt32 {
                UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            }
            for offset in stride(from: 0, through: data.count - 8, by: 4) {
                let length = Int(word(offset + 4))
                for layout in layouts where length == layout.0 && offset + 8 + length <= data.count {
                    let base = offset + 8
                    let refs = [word(base + layout.1), word(base + layout.2), word(base + layout.3), word(base + layout.4)]
                    guard refs[0] > 0, refs[0] & 3 == 0, refs[1] > 0, refs[1] & 3 == 0 else { continue }
                    records.append(.init(bundle: refs[0] >> 2, container: refs[1] >> 2,
                                         name: refs[2] & 3 == 0 ? refs[2] >> 2 : 0,
                                         display: refs[3] & 3 == 0 ? refs[3] >> 2 : 0))
                    needed.formUnion(refs.filter { $0 > 0 && $0 & 3 == 0 }.map { $0 >> 2 })
                    if records.count > 30_000 || needed.count > 100_000 { return [:] }
                }
            }
            var strings: [UInt32: String] = [:], paths: [UInt32: String] = [:], conflicts: Set<UInt32> = []
            var heapIDs: Set<UInt32> = [], decodedBytes = 0
            for offset in stride(from: 0, through: data.count - 8, by: 4) {
                let id = word(offset)
                guard needed.contains(id) else { continue }
                let length = Int(word(offset + 4))
                guard length > 0, length <= 2048, offset + 8 + length <= data.count else { continue }
                let stringBytes = UnsafeRawBufferPointer(rebasing: bytes[(offset + 8)..<(offset + 8 + length)])
                guard !stringBytes.contains(0), let value = String(bytes: stringBytes, encoding: .utf8) else { continue }
                decodedBytes += length
                if decodedBytes > 8 * 1024 * 1024 { return [:] }
                if value.hasPrefix("/") {
                    let path = ManagedAppFiles.canonical(URL(fileURLWithPath: value))
                    if let old = paths[id], old != path { conflicts.insert(id) }
                    else { paths[id] = path }
                }
                if strings[id] == nil || (offset >= heap && !heapIDs.contains(id)) {
                    strings[id] = value
                    if offset >= heap { heapIDs.insert(id) }
                }
            }
            var result: [String: String] = [:], ambiguous: Set<String> = []
            for record in records {
                guard !conflicts.contains(record.container), let path = paths[record.container],
                      let identifier = strings[record.bundle], known[path] == identifier else { continue }
                let name = [strings[record.display], strings[record.name]].compactMap { $0 }.first {
                    !$0.isEmpty && $0.count <= 120 && !$0.contains("/") && $0 != identifier
                        && $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.illegalCharacters.contains($0)
                            && !(0x202A...0x202E).contains($0.value) && !(0x2066...0x2069).contains($0.value) }
                }
                if let name {
                    if let previous = result[identifier], previous != name { ambiguous.insert(identifier) }
                    else { result[identifier] = name }
                }
            }
            for id in ambiguous { result[id] = nil }
            return result
        }
        if !matched.isEmpty { return matched }
        return inferNames(data, known: known, anchors: anchors)
    }

    /// Unknown layouts are accepted only when multiple independently resolved
    /// application names agree on the same record size and field offsets.
    /// No database or raw records leave this in-memory parser.
    private static func inferNames(_ data: Data, known: [String: String], anchors: [String: String]) -> [String: String] {
        guard anchors.count >= 2 else { return [:] }
        let identifiers = Set(known.values)
        struct Candidate { let size: Int; let offset: Int; let bundle: String; let pathField: Int; let bundleField: Int }
        struct Layout: Hashable { let size: Int; let path: Int; let bundle: Int; let name: Int }
        return data.withUnsafeBytes { bytes in
            func word(_ offset: Int) -> UInt32 { UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
            let heap = data.range(of: Data("<string>".utf8))?.lowerBound ?? data.count
            var strings: [UInt32: String] = [:], knownPaths: [UInt32: String] = [:], knownIDs: [UInt32: String] = [:]
            var pathConflicts: Set<UInt32> = [], heapIDs: Set<UInt32> = []
            var totalBytes = 0
            for offset in stride(from: 0, through: data.count - 8, by: 4) {
                let id = word(offset), length = Int(word(offset + 4))
                guard id > 0, id < 0x01000000, length > 0, length <= 2048,
                      offset + 8 + length <= data.count else { continue }
                let raw = UnsafeRawBufferPointer(rebasing: bytes[(offset + 8)..<(offset + 8 + length)])
                guard !raw.contains(0), let value = String(bytes: raw, encoding: .utf8) else { continue }
                totalBytes += length
                if totalBytes > 8 * 1024 * 1024 || strings.count > 100_000 { return [:] }
                if value.hasPrefix("/") {
                    let path = ManagedAppFiles.canonical(URL(fileURLWithPath: value))
                    if known[path] != nil {
                        if let previous = knownPaths[id], previous != path { pathConflicts.insert(id) }
                        else { knownPaths[id] = path }
                    }
                }
                if identifiers.contains(value) { knownIDs[id] = value }
                if strings[id] == nil || (offset >= heap && !heapIDs.contains(id)) {
                    strings[id] = value
                    if offset >= heap { heapIDs.insert(id) }
                }
            }
            var candidates: [Candidate] = []
            var evidence: [Layout: Set<String>] = [:]
            for offset in stride(from: 0, through: data.count - 8, by: 4) {
                let size = Int(word(offset + 4)), base = offset + 8
                guard size >= 0x100, size <= 0x400, size % 4 == 0, base + size <= data.count else { continue }
                var pathFields: [(Int, String)] = [], bundleFields: [(Int, String)] = []
                for field in stride(from: 0, through: size - 4, by: 4) {
                    let reference = word(base + field)
                    guard reference > 0, reference & 3 == 0 else { continue }
                    let id = reference >> 2
                    if !pathConflicts.contains(id), let path = knownPaths[id] { pathFields.append((field, path)) }
                    if let bundle = knownIDs[id] { bundleFields.append((field, bundle)) }
                }
                for (pathField, path) in pathFields {
                    for (bundleField, bundle) in bundleFields where known[path] == bundle {
                        candidates.append(.init(size: size, offset: base, bundle: bundle, pathField: pathField, bundleField: bundleField))
                        if candidates.count > 30_000 { return [:] }
                        guard let anchor = anchors[bundle] else { continue }
                        for field in stride(from: 0, through: size - 4, by: 4) {
                            let reference = word(base + field)
                            guard reference > 0, reference & 3 == 0, strings[reference >> 2] == anchor else { continue }
                            evidence[.init(size: size, path: pathField, bundle: bundleField, name: field), default: []].insert(bundle)
                        }
                    }
                }
            }
            let layouts = evidence.filter { $0.value.count >= 2 }.sorted {
                if $0.value.count != $1.value.count { return $0.value.count > $1.value.count }
                if $0.key.size != $1.key.size { return $0.key.size < $1.key.size }
                if $0.key.path != $1.key.path { return $0.key.path < $1.key.path }
                if $0.key.bundle != $1.key.bundle { return $0.key.bundle < $1.key.bundle }
                return $0.key.name < $1.key.name
            }
            guard let selected = layouts.first else { return [:] }
            var names: [String: String] = [:], ambiguous: Set<String> = []
            for record in candidates where record.size == selected.key.size && record.pathField == selected.key.path && record.bundleField == selected.key.bundle {
                let reference = word(record.offset + selected.key.name)
                guard reference & 3 == 0, let name = strings[reference >> 2], name != record.bundle,
                      !name.isEmpty, name.count <= 120, !name.contains("/"),
                      name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0)
                          && !(0x202A...0x202E).contains($0.value) && !(0x2066...0x2069).contains($0.value) }) else { continue }
                if let previous = names[record.bundle], previous != name { ambiguous.insert(record.bundle) }
                else { names[record.bundle] = name }
            }
            for id in ambiguous { names[id] = nil }
            return names
        }
    }
}

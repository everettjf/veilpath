import Foundation
import OSLog

struct SelfTestReport: Codable, Sendable {
    struct Check: Codable, Sendable {
        enum Status: String, Codable, Sendable { case passed, failed, unsupported }

        let name: String
        let path: String
        let status: Status
        let detail: String
        let durationMilliseconds: Int

        var passed: Bool { status != .failed }
    }

    let schemaVersion: Int
    let appVersion: String
    let systemVersion: String
    let startedAt: Date
    let finishedAt: Date
    let checks: [Check]

    var passed: Bool { checks.allSatisfy(\.passed) }
}

enum SelfTestRunner {
    private static let logger = Logger(subsystem: "com.eevv.Vellune", category: "SelfTest")

    nonisolated static let reportURL: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appending(path: "vellune-self-test.json")

    nonisolated static func run() -> SelfTestReport {
        let startedAt = Date()
        var checks: [SelfTestReport.Check] = []

        checks.append(testFileAccess(
            name: "MobileGestalt file access",
            path: "/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist"
        ))
        checks.append(testPreviewAndExport(
            path: "/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist"
        ))
        checks.append(testDiscoveredApplicationContainer(
            rootPath: "/var/mobile/Containers/Data/Application",
            maximumInode: 5_000_000
        ))
        checks.append(testDirectoryAccess(
            name: "System data containers",
            path: "/var/containers/Data/System"
        ))
        checks.append(testDirectoryAccess(name: "Plugin containers", path: ContainerKind.plugin.rootPath))
        checks.append(testDirectoryAccess(name: "Internal daemon containers", path: ContainerKind.internalDaemon.rootPath))
        checks.append(testDirectoryAccess(name: "App Group containers", path: ContainerKind.appGroup.rootPath))
        checks.append(testDirectoryAccess(name: "System Group containers", path: ContainerKind.systemGroup.rootPath))
        checks.append(testStructuredFormats())
        checks.append(testFileAnalysis())
        checks.append(testMachOAnalysis())
        checks.append(testExportCache())
        checks.append(testLocalSearch())

        let report = SelfTestReport(
            schemaVersion: 8,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            startedAt: startedAt,
            finishedAt: Date(),
            checks: checks
        )
        persist(report)
        logger.notice("Self-test finished: \(report.passed ? "PASS" : "FAIL", privacy: .public)")
        return report
    }

    nonisolated static func loadPersistedReport() -> SelfTestReport? {
        guard let data = try? Data(contentsOf: reportURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SelfTestReport.self, from: data)
    }

    nonisolated private static func testFileAccess(name: String, path: String) -> SelfTestReport.Check {
        timedCheck(name: name, path: path) {
            let baselineReadable = FileManager.default.isReadableFile(atPath: path)
            let grant = try BadQueryClient.acquire(.forPath(path))
            defer { BadQueryClient.release(grant) }
            let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
            guard !data.isEmpty else { throw SelfTestFailure("File was readable but empty") }
            return "baselineReadable=\(baselineReadable), handle=\(grant.handle), bytes=\(data.count)"
        }
    }

    nonisolated private static func testPreviewAndExport(path: String) -> SelfTestReport.Check {
        timedCheck(name: "Preview and safe export", path: path) {
            let url = URL(fileURLWithPath: path)
            let grant = try BadQueryClient.acquire(.init(path: path))
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            BadQueryClient.release(grant)
            let item = FileItem(
                url: url,
                isDirectory: false,
                isSymbolicLink: false,
                size: (attributes[.size] as? NSNumber)?.int64Value,
                modifiedAt: attributes[.modificationDate] as? Date
            )
            let result = try FilePreviewLoader.load(item)
            guard FileManager.default.fileExists(atPath: result.exportURL.path) else {
                throw SelfTestFailure("Export cache file was not created")
            }
            guard case .structured(_, let text, _) = result.preview, text.contains("<plist") else {
                throw SelfTestFailure("Property list preview was not converted to XML text")
            }
            return "previewCharacters=\(text.count), export=\(result.exportURL.path)"
        }
    }

    nonisolated private static func testDirectoryAccess(name: String, path: String) -> SelfTestReport.Check {
        timedCheck(name: name, path: path) {
            let baseline = (try? FileManager.default.contentsOfDirectory(atPath: path).count)
            let kind = ContainerKind.allCases.first { $0.rootPath == path }
            let indexed = kind.map(ContainerDiscoveryService.discover).map(\.count) ?? 0
            guard let grant = try? BadQueryClient.acquire(.forPath(path)) else {
                if indexed > 0 { return "rootGrant=unavailable, inodeIndexed=\(indexed)" }
                throw UnsupportedCapability("Root grant and inode discovery unavailable on this OS build")
            }
            defer { BadQueryClient.release(grant) }
            let children = try FileManager.default.contentsOfDirectory(atPath: path)
            return "baselineCount=\(baseline.map(String.init) ?? "denied"), handle=\(grant.handle), childCount=\(children.count), indexed=\(indexed)"
        }
    }

    nonisolated private static func testStructuredFormats() -> SelfTestReport.Check {
        timedCheck(name: "Structured plist and JSON", path: "self-test fixtures") {
            let plist: [String: Any] = ["name": "Vellune", "enabled": true, "items": [1, 2, 3]]
            let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            let parsed = try PropertyListSerialization.propertyList(from: plistData, format: nil)
            let root = StructuredNode.make(key: "Root", value: parsed)
            guard root.searchableText.contains("Vellune"), root.matching("enabled") != nil else { throw SelfTestFailure("Plist tree search failed") }
            let jsonData = try JSONSerialization.data(withJSONObject: plist)
            guard let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any], json["name"] as? String == "Vellune" else { throw SelfTestFailure("JSON parsing failed") }
            return "binaryPlistBytes=\(plistData.count), treeChildren=\(root.children.count), jsonBytes=\(jsonData.count)"
        }
    }

    nonisolated private static func testFileAnalysis() -> SelfTestReport.Check {
        timedCheck(name: "File properties SHA-256 and hex", path: "temporary fixture") {
            let data = Data("abc".utf8)
            let url = FileManager.default.temporaryDirectory.appending(path: "vellune-analysis-\(UUID().uuidString).txt")
            defer { try? FileManager.default.removeItem(at: url) }
            try data.write(to: url)
            let properties = try FileAnalyzer.properties(for: url, data: data)
            guard properties.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" else { throw SelfTestFailure("SHA-256 mismatch") }
            let hex = FileAnalyzer.hexDump(data: data)
            guard hex.contains("61 62 63"), hex.contains("|abc|") else { throw SelfTestFailure("Hex output mismatch") }
            return "sha256=\(properties.sha256), permissions=\(String(format: "%04o", properties.posixPermissions))"
        }
    }

    nonisolated private static func testMachOAnalysis() -> SelfTestReport.Check {
        timedCheck(name: "Mach-O and code signature analysis", path: Bundle.main.executablePath ?? "") {
            guard let path = Bundle.main.executablePath else { throw SelfTestFailure("Missing executable path") }
            let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
            guard let info = MachOParser.parse(data), !info.architectures.isEmpty else { throw SelfTestFailure("Mach-O parsing failed") }
            let names = info.architectures.map(\.name).joined(separator: ",")
            return "architectures=\(names), codeSignature=\(info.codeSignaturePresent), dependencies=\(info.architectures.reduce(0) { $0 + $1.dependencies.count })"
        }
    }

    nonisolated private static func testExportCache() -> SelfTestReport.Check {
        timedCheck(name: "Export cache lifecycle", path: ExportCache.directory.path) {
            try? ExportCache.removeAll()
            let source = FileManager.default.temporaryDirectory.appending(path: "vellune-export-\(UUID().uuidString).txt")
            defer { try? FileManager.default.removeItem(at: source); try? ExportCache.removeAll() }
            try Data("export".utf8).write(to: source)
            let first = try ExportCache.stage(source, named: "fixture.txt")
            let second = try ExportCache.stage(source, named: "fixture.txt")
            guard first != second, FileManager.default.fileExists(atPath: first.path), FileManager.default.fileExists(atPath: second.path) else { throw SelfTestFailure("Export cache collision handling failed") }
            return "uniqueCopies=2"
        }
    }

    nonisolated private static func testLocalSearch() -> SelfTestReport.Check {
        timedCheck(name: "Recursive container search", path: FileManager.default.temporaryDirectory.path) {
            let root = FileManager.default.temporaryDirectory.appending(path: "vellune-search-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root.appending(path: "nested", directoryHint: .isDirectory), withIntermediateDirectories: true)
            try Data().write(to: root.appending(path: "nested/UniqueNeedle.plist"))
            let results = FileSystemReader.search(at: root.path, query: "needle", showHidden: true)
            guard results.count == 1, results[0].name == "UniqueNeedle.plist" else { throw SelfTestFailure("Recursive search failed") }
            return "matches=\(results.count)"
        }
    }

    nonisolated private static func testDiscoveredApplicationContainer(
        rootPath: String,
        maximumInode: Int64
    ) -> SelfTestReport.Check {
        timedCheck(name: "Application container discovery", path: rootPath) {
            let discovered = ContainerDiscoveryService.discoverApplications(maximumInode: maximumInode)
            guard let sample = discovered.first else {
                throw SelfTestFailure("No application container was found below inode \(maximumInode)")
            }
            let grant = try BadQueryClient.acquire(.init(path: sample.path))
            defer { BadQueryClient.release(grant) }
            let children = try FileManager.default.contentsOfDirectory(atPath: sample.path)
            let identified = discovered.lazy.filter { $0.identifier != nil }.count
            return "scannedThrough=\(maximumInode), discovered=\(discovered.count), identified=\(identified), sample=\(sample.displayName), handle=\(grant.handle), children=\(children.sorted().joined(separator: ",")), metadata=\(sample.metadataDiagnostic ?? "none")"
        }
    }

    nonisolated private static func timedCheck(
        name: String,
        path: String,
        operation: () throws -> String
    ) -> SelfTestReport.Check {
        let start = ContinuousClock.now
        do {
            let detail = try operation()
            let duration = milliseconds(since: start)
            logger.notice("PASS \(name, privacy: .public): \(detail, privacy: .public)")
            return .init(name: name, path: path, status: .passed, detail: detail, durationMilliseconds: duration)
        } catch let error as UnsupportedCapability {
            let duration = milliseconds(since: start)
            logger.notice("UNSUPPORTED \(name, privacy: .public): \(error.message, privacy: .public)")
            return .init(name: name, path: path, status: .unsupported, detail: error.message, durationMilliseconds: duration)
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let duration = milliseconds(since: start)
            logger.error("FAIL \(name, privacy: .public): \(detail, privacy: .public)")
            return .init(name: name, path: path, status: .failed, detail: detail, durationMilliseconds: duration)
        }
    }

    nonisolated private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let duration = start.duration(to: .now)
        return Int(duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    nonisolated private static func persist(_ report: SelfTestReport) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(report)
            try data.write(to: reportURL, options: .atomic)
        } catch {
            logger.fault("Could not persist self-test report: \(error.localizedDescription, privacy: .public)")
        }
    }

    private struct SelfTestFailure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private struct UnsupportedCapability: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}

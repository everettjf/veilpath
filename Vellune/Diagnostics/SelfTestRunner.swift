import Foundation
import OSLog
import SQLite3

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

    nonisolated static func run() async -> SelfTestReport {
        let startedAt = Date()
        var checks: [SelfTestReport.Check] = []

        #if !targetEnvironment(simulator)
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
        #endif
        checks.append(testStructuredFormats())
        checks.append(testAdvancedPreviewFormats())
        checks.append(testFileAnalysis())
        checks.append(testLargeFilePreviewBudget())
        checks.append(testMachOAnalysis())
        checks.append(testExportCache())
        checks.append(await testOnDemandShareExport())
        checks.append(testDirectoryMarkdownExport())
        checks.append(testBackupReplaceAndRestore())
        checks.append(testSafeStructuredEditing())
        checks.append(testLocalSearch())
        checks.append(testDirectorySorting())

        let report = SelfTestReport(
            schemaVersion: 19,
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

    nonisolated static func verifyAccess() -> SelfTestReport.Check {
        testDiscoveredApplicationContainer(
            rootPath: "/var/mobile/Containers/Data/Application",
            maximumInode: 5_000_000
        )
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
            guard let exportURL = result.exportURL,
                  FileManager.default.fileExists(atPath: exportURL.path) else {
                throw SelfTestFailure("Export cache file was not created")
            }
            guard case .structured(_, let text, _) = result.preview, text.contains("<plist") else {
                throw SelfTestFailure("Property list preview was not converted to XML text")
            }
            return "previewCharacters=\(text.count), export=\(exportURL.path)"
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

    nonisolated private static func testAdvancedPreviewFormats() -> SelfTestReport.Check {
        timedCheck(name: "Advanced file format detection", path: "self-test fixtures") {
            let root = FileManager.default.temporaryDirectory.appending(path: "vellune-formats-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            func preview(_ name: String, data: Data) throws -> FilePreview {
                let url = root.appending(path: name)
                try data.write(to: url)
                let item = FileItem(url: url, isDirectory: false, isSymbolicLink: false, size: Int64(data.count), modifiedAt: nil)
                return try FilePreviewLoader.makePreview(item: item, data: data, exportURL: url)
            }

            let plist = try PropertyListSerialization.data(fromPropertyList: ["key": "value"], format: .binary, options: 0)
            guard case .structured = try preview("no-extension", data: plist) else { throw SelfTestFailure("Binary plist magic detection failed") }
            guard case .structured = try preview("payload", data: Data("{\"answer\":42}".utf8)) else { throw SelfTestFailure("JSON content detection failed") }
            guard case .pdf = try preview("document.bin", data: Data("%PDF-1.7\n%%EOF".utf8)) else { throw SelfTestFailure("PDF magic detection failed") }
            guard case .quickLook = try preview("document.docx", data: Data("office fixture".utf8)) else { throw SelfTestFailure("Quick Look fallback detection failed") }
            guard case .quickLook = try preview("clip.mp4", data: Data("media fixture".utf8)) else { throw SelfTestFailure("Media Quick Look routing failed") }
            guard case .quickLook = try preview("contact.vcf", data: Data("BEGIN:VCARD\nEND:VCARD".utf8)) else { throw SelfTestFailure("Contact Quick Look routing failed") }
            guard case .quickLook = try preview("event.ics", data: Data("BEGIN:VCALENDAR\nEND:VCALENDAR".utf8)) else { throw SelfTestFailure("Calendar Quick Look routing failed") }

            let webArchive = try PropertyListSerialization.data(
                fromPropertyList: ["WebMainResource": ["WebResourceURL": "https://example.com"]],
                format: .binary,
                options: 0
            )
            guard case .structured = try preview("page.webarchive", data: webArchive) else { throw SelfTestFailure("WebArchive parsing failed") }

            let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
            guard case .image = try preview("image.unknown", data: png) else { throw SelfTestFailure("Image content detection failed") }

            var cookieData = Data("cook".utf8)
            cookieData.append(contentsOf: [0, 0, 0, 1, 0, 0, 0, 4])
            cookieData.append(contentsOf: [0, 0, 0, 0])
            guard case .binaryCookies(let cookies) = try preview("Cookies.binarycookies", data: cookieData), cookies.pageCount == 1 else {
                throw SelfTestFailure("Binary cookies detection failed")
            }

            let zipName = Data("file.txt".utf8)
            let zipPayload = Data("archive preview".utf8)
            var local = Data(repeating: 0, count: 30)
            local.replaceSubrange(0..<4, with: [0x50, 0x4b, 0x03, 0x04])
            local.replaceSubrange(18..<22, with: [UInt8(zipPayload.count), 0, 0, 0])
            local.replaceSubrange(22..<26, with: [UInt8(zipPayload.count), 0, 0, 0])
            local.replaceSubrange(26..<28, with: [UInt8(zipName.count), 0])
            local.append(zipName)
            local.append(zipPayload)
            var central = Data(repeating: 0, count: 46)
            central.replaceSubrange(0..<4, with: [0x50, 0x4b, 0x01, 0x02])
            central.replaceSubrange(20..<24, with: [UInt8(zipPayload.count), 0, 0, 0])
            central.replaceSubrange(24..<28, with: [UInt8(zipPayload.count), 0, 0, 0])
            central.replaceSubrange(28..<30, with: [UInt8(zipName.count), 0])
            central.append(zipName)
            local.append(central)
            guard let archive = AdvancedFileAnalyzer.zip(data: local),
                  archive.entries.first?.name == "file.txt",
                  archive.entries.first?.previewText == "archive preview" else {
                throw SelfTestFailure("ZIP central directory parsing failed")
            }

            let databaseURL = root.appending(path: "fixture.sqlite")
            var database: OpaquePointer?
            guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else { throw SelfTestFailure("SQLite fixture creation failed") }
            guard sqlite3_exec(database, "CREATE TABLE sample(id INTEGER PRIMARY KEY, name TEXT); INSERT INTO sample(name) VALUES('Vellune');", nil, nil, nil) == SQLITE_OK else {
                sqlite3_close(database)
                throw SelfTestFailure("SQLite fixture population failed")
            }
            sqlite3_close(database)
            let sqliteData = try Data(contentsOf: databaseURL)
            guard case .sqlite(let summary) = try preview("fixture.sqlite", data: sqliteData), summary.tables.first?.name == "sample" else {
                throw SelfTestFailure("SQLite summary failed")
            }
            return "plist,json,image,pdf,quicklook,media,contact,calendar,webarchive,cookies,zip,sqlite=passed"
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
            return "sha256=\(properties.sha256 ?? "missing"), permissions=\(String(format: "%04o", properties.posixPermissions))"
        }
    }

    nonisolated private static func testLargeFilePreviewBudget() -> SelfTestReport.Check {
        timedCheck(name: "Bounded large-file preview", path: "temporary sparse fixture") {
            let url = FileManager.default.temporaryDirectory.appending(path: "vellune-large-\(UUID().uuidString).bin")
            defer { try? FileManager.default.removeItem(at: url) }
            FileManager.default.createFile(atPath: url.path, contents: Data("large-file-prefix".utf8))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(FilePreview.maximumInlineBytes + 1))
            try handle.close()
            let item = FileItem(url: url, isDirectory: false, isSymbolicLink: false,
                                size: FilePreview.maximumInlineBytes + 1, modifiedAt: nil)
            let result = try FilePreviewLoader.load(item)
            guard case .tooLarge(let size) = result.preview,
                  size == FilePreview.maximumInlineBytes + 1,
                  result.exportURL == nil,
                  result.properties.sha256 == nil,
                  result.hexDump.contains("6C 61 72 67 65 2D 66 69 6C 65") else {
                throw SelfTestFailure("Large file was fully processed instead of using the bounded path")
            }
            return "bytes=\(size), exportSkipped=true, hashSkipped=true, prefixBytes<=1048576"
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

    nonisolated private static func testOnDemandShareExport() async -> SelfTestReport.Check {
        await timedAsyncCheck(name: "On-demand file and folder sharing", path: "temporary fixtures") {
            let root = FileManager.default.temporaryDirectory.appending(path: "vellune-share-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let large = root.appending(path: "large.bin")
            FileManager.default.createFile(atPath: large.path, contents: Data("stream-prefix".utf8))
            let largeHandle = try FileHandle(forWritingTo: large)
            try largeHandle.truncate(atOffset: 3 * 1024 * 1024 + 17)
            try largeHandle.close()
            let recorder = ShareProgressRecorder()
            let exported = try await ShareExportService.prepareFile(at: large, named: "large.bin") { update in
                await recorder.append(update)
            }
            let exportedSize = try exported.resourceValues(forKeys: [.fileSizeKey]).fileSize
            let progressValues = await recorder.values
            guard exportedSize == 3 * 1024 * 1024 + 17,
                  progressValues.filter({ $0.phase == .copying }).count >= 3,
                  progressValues.last?.phase == .finalizing else {
                throw SelfTestFailure("File export was not streamed or finalized correctly")
            }

            let cacheBeforeCancellation = (try? FileManager.default.contentsOfDirectory(at: ExportCache.directory, includingPropertiesForKeys: nil).count) ?? 0
            let cancellationRecorder = ShareProgressRecorder()
            let cancellationTask = Task {
                do {
                    let result = try await ShareExportService.prepareFile(at: large, named: "cancel.bin") { update in
                        await cancellationRecorder.append(update)
                        if update.completedBytes >= 1024 * 1024 {
                            try? await Task.sleep(for: .seconds(30))
                        }
                    }
                    await cancellationRecorder.markFinished()
                    return result
                } catch {
                    await cancellationRecorder.markFinished()
                    throw error
                }
            }
            while true {
                let state = await cancellationRecorder.state
                if state.reachedCancellationThreshold { break }
                if state.finished {
                    _ = try await cancellationTask.value
                    throw SelfTestFailure("Cancellation fixture completed before reaching its test threshold")
                }
                await Task.yield()
            }
            cancellationTask.cancel()
            do {
                _ = try await cancellationTask.value
                throw SelfTestFailure("Cancelled export unexpectedly completed")
            } catch is CancellationError {}
            let cacheAfterCancellation = (try? FileManager.default.contentsOfDirectory(at: ExportCache.directory, includingPropertiesForKeys: nil).count) ?? 0
            guard cacheAfterCancellation == cacheBeforeCancellation else { throw SelfTestFailure("Cancelled export left a partial cache directory") }

            let folder = root.appending(path: "Folder", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder.appending(path: "Nested/Empty", directoryHint: .isDirectory), withIntermediateDirectories: true)
            try Data("top-level".utf8).write(to: folder.appending(path: "top.txt"))
            try Data("nested-value".utf8).write(to: folder.appending(path: "Nested/value.txt"))
            try Data("hidden".utf8).write(to: folder.appending(path: ".secret"))
            try FileManager.default.createSymbolicLink(at: folder.appending(path: "outside-link"), withDestinationURL: large)
            let archive = try await ShareExportService.prepareDirectoryZIP(at: folder, named: "Folder", includeHidden: false) { _ in }
            let archiveData = try Data(contentsOf: archive.url)
            guard let summary = AdvancedFileAnalyzer.zip(data: archiveData) else { throw SelfTestFailure("Prepared ZIP could not be parsed") }
            let names = Set(summary.entries.map(\.name))
            guard names.contains("top.txt"), names.contains("Nested/value.txt"), names.contains("Nested/Empty/"),
                  !names.contains(".secret"), !names.contains("outside-link"), archive.skippedSymbolicLinks == 1,
                  summary.entries.first(where: { $0.name == "Nested/value.txt" })?.previewText == "nested-value" else {
                throw SelfTestFailure("ZIP contents, hidden-file policy, or symbolic-link policy was incorrect")
            }

            let expired = try ExportCache.createOperationDirectory()
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3_600)], ofItemAtPath: expired.path)
            ExportCache.removeExpired(olderThan: 60)
            guard !FileManager.default.fileExists(atPath: expired.path) else { throw SelfTestFailure("Expired share cache was not removed") }
            return "streamed=true, cancellationClean=true, zipEntries=\(summary.entries.count), hiddenExcluded=true, symlinkSkipped=true, expiration=true"
        }
    }

    nonisolated private static func testDirectoryMarkdownExport() -> SelfTestReport.Check {
        timedCheck(name: "Directory Markdown export", path: "temporary fixture") {
            let root = FileManager.default.temporaryDirectory
                .appending(path: "vellune-markdown-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(
                at: root.appending(path: "Nested", directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
            try Data("top".utf8).write(to: root.appending(path: "top.txt"))
            try Data("nested".utf8).write(to: root.appending(path: "Nested/child.txt"))

            let shallow = try DirectoryMarkdownExporter.export(
                path: root.path,
                options: .init(recursively: false, includeHidden: true)
            )
            let recursive = try DirectoryMarkdownExporter.export(
                path: root.path,
                options: .init(recursively: true, includeHidden: true)
            )
            defer {
                try? FileManager.default.removeItem(at: shallow.url)
                try? FileManager.default.removeItem(at: recursive.url)
            }
            let markdown = try String(contentsOf: recursive.url, encoding: .utf8)
            let containsNestedFile = markdown.contains("Nested/child.txt")
            guard shallow.itemCount == 2,
                  recursive.itemCount == 3,
                  containsNestedFile else {
                throw SelfTestFailure(
                    "Markdown scope or relative paths were incorrect " +
                    "(shallow=\(shallow.itemCount), recursive=\(recursive.itemCount), nested=\(containsNestedFile))"
                )
            }
            return "shallowItems=\(shallow.itemCount), recursiveItems=\(recursive.itemCount)"
        }
    }

    nonisolated private static func testBackupReplaceAndRestore() -> SelfTestReport.Check {
        timedCheck(name: "Backup, replace, verify, and restore", path: "temporary fixture") {
            let target = FileManager.default.temporaryDirectory
                .appending(path: "vellune-replace-\(UUID().uuidString).txt")
            let original = Data("original".utf8)
            let replacement = Data("replacement".utf8)
            try original.write(to: target)
            var createdFolders: [URL] = []
            defer {
                try? FileManager.default.removeItem(at: target)
                createdFolders.forEach { try? FileManager.default.removeItem(at: $0) }
            }

            let backup = try FileBackupService.replace(target: target, replacementData: replacement)
            createdFolders.append(backup.folderURL)
            guard backup.manifest.completed,
                  backup.manifest.effectiveRole == .original,
                  try Data(contentsOf: target) == replacement else {
                throw SelfTestFailure("Replacement was not committed")
            }
            let repeated = try FileBackupService.replace(target: target, replacementData: replacement)
            createdFolders.append(repeated.folderURL)
            let repeatedAgain = try FileBackupService.replace(target: target, replacementData: replacement)
            createdFolders.append(repeatedAgain.folderURL)
            guard repeated.manifest.effectiveRole == .revision,
                  repeated.manifest.blobName == repeatedAgain.manifest.blobName else {
                throw SelfTestFailure("Original permanence or content-addressed deduplication failed")
            }
            let safetyBackup = try FileBackupService.restore(backup)
            createdFolders.append(safetyBackup.folderURL)
            guard safetyBackup.manifest.completed,
                  try Data(contentsOf: target) == original else {
                throw SelfTestFailure("Original content was not restored")
            }
            return "replacementVerified=true, restoreVerified=true, originalPermanent=true, deduplicated=true"
        }
    }

    nonisolated private static func testSafeStructuredEditing() -> SelfTestReport.Check {
        timedCheck(name: "JSON and plist safe editing", path: "temporary fixtures") {
            let root = FileManager.default.temporaryDirectory.appending(path: "vellune-editor-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let jsonURL = root.appending(path: "fixture.json")
            try Data("{\"value\":1}".utf8).write(to: jsonURL)
            var session = try SafeStructuredEditor.open(target: jsonURL)
            guard FileManager.default.fileExists(atPath: session.draftURL.path) else { throw SelfTestFailure("Temporary edit draft was not created") }
            do {
                _ = try SafeStructuredEditor.validate(session, text: "{")
                throw SelfTestFailure("Invalid JSON passed validation")
            } catch is StructuredEditorError {}

            try Data("{\"external\":true}".utf8).write(to: jsonURL)
            do {
                _ = try SafeStructuredEditor.save(session, text: "{\"value\":2}")
                throw SelfTestFailure("External modification conflict was not detected")
            } catch StructuredEditorError.externalModification {}
            SafeStructuredEditor.discard(session)

            try Data("{\"value\":1}".utf8).write(to: jsonURL)
            session = try SafeStructuredEditor.open(target: jsonURL)
            let jsonBackup = try SafeStructuredEditor.save(session, text: "{\"value\":2}")
            defer { try? FileManager.default.removeItem(at: jsonBackup.folderURL) }
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Int]
            guard json?["value"] == 2, jsonBackup.manifest.effectiveRole == .original else {
                throw SelfTestFailure("Validated JSON was not saved through the Original snapshot")
            }

            let plistURL = root.appending(path: "fixture.plist")
            let plistData = try PropertyListSerialization.data(fromPropertyList: ["enabled": false], format: .binary, options: 0)
            try plistData.write(to: plistURL)
            let plistSession = try SafeStructuredEditor.open(target: plistURL)
            guard plistSession.kind == .propertyList(.binary) else { throw SelfTestFailure("Binary plist format was not retained") }
            let plistBackup = try SafeStructuredEditor.save(
                plistSession,
                text: "<?xml version=\"1.0\" encoding=\"UTF-8\"?><!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\"><plist version=\"1.0\"><dict><key>enabled</key><true/></dict></plist>"
            )
            defer { try? FileManager.default.removeItem(at: plistBackup.folderURL) }
            let savedPlist = try Data(contentsOf: plistURL)
            guard savedPlist.starts(with: Data("bplist".utf8)) else { throw SelfTestFailure("Binary plist was not written back in its original format") }
            return "draft=true, validation=true, conflict=true, atomicSave=true, binaryFormatPreserved=true"
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

    nonisolated private static func testDirectorySorting() -> SelfTestReport.Check {
        timedCheck(name: "Directory filtering and sorting", path: FileManager.default.temporaryDirectory.path) {
            let root = FileManager.default.temporaryDirectory.appending(path: "vellune-sort-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root.appending(path: "Folder", directoryHint: .isDirectory), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 4).write(to: root.appending(path: "small.txt"))
            try Data(repeating: 2, count: 16).write(to: root.appending(path: "large.txt"))
            let bySize = try FileSystemReader.contents(at: root.path, showHidden: true, sortOrder: .size)
            guard bySize.map(\.name) == ["Folder", "large.txt", "small.txt"] else { throw SelfTestFailure("Size sorting or directories-first policy failed") }
            let byName = try FileSystemReader.contents(at: root.path, showHidden: true, sortOrder: .name)
            guard byName.map(\.name) == ["Folder", "large.txt", "small.txt"] else { throw SelfTestFailure("Name sorting failed") }
            return "orders=name,size; directoriesFirst=true"
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

    nonisolated private static func timedAsyncCheck(
        name: String,
        path: String,
        operation: () async throws -> String
    ) async -> SelfTestReport.Check {
        let start = ContinuousClock.now
        do {
            let detail = try await operation()
            return .init(name: name, path: path, status: .passed, detail: detail,
                         durationMilliseconds: milliseconds(since: start))
        } catch let error as UnsupportedCapability {
            return .init(name: name, path: path, status: .unsupported, detail: error.message,
                         durationMilliseconds: milliseconds(since: start))
        } catch {
            return .init(name: name, path: path, status: .failed, detail: error.localizedDescription,
                         durationMilliseconds: milliseconds(since: start))
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

private actor ShareProgressRecorder {
    private(set) var values: [ShareExportProgress] = []
    private var finished = false

    struct State: Sendable {
        let reachedCancellationThreshold: Bool
        let finished: Bool
    }

    var state: State {
        .init(reachedCancellationThreshold: values.contains { $0.completedBytes >= 1024 * 1024 }, finished: finished)
    }

    func append(_ value: ShareExportProgress) { values.append(value) }
    func markFinished() { finished = true }
}

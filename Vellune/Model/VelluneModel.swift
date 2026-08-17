import Foundation
import Observation

@Observable
@MainActor
final class VelluneModel {
    var path = ""
    var currentContainerRoot = ""
    var selectedContainer: ContainerDescriptor?
    private(set) var backHistory: [String] = []
    private(set) var forwardHistory: [String] = []
    private var loadedPath = ""
    var items: [FileItem] = []
    private(set) var directorySummaries: [String: DirectoryContentsSummary] = [:]
    var selectedItem: FileItem?
    var selectedPreview: FilePreview?
    var selectedProperties: FileProperties?
    var selectedHexDump = ""
    var previewError: String?
    var selectedExportURL: URL?
    var isLoadingPreview = false
    var logs: [LogEntry] = []
    var showHiddenFiles = true
    var fileSortOrder: FileSortOrder = .name
    var isWorking = false
    var isVerifyingAccess = false
    var isRunningDiagnostics = false
    var lastError: String?
    var selfTestReport: SelfTestReport?
    var accessVerification: SelfTestReport.Check?
    var containerIndexes: [ContainerKind: [ContainerDescriptor]] = [:]
    var searchResults: [FileItem] = []
    var isSearching = false
    var directoryExportRecursive = false
    var directoryExportURL: URL?
    var isExportingDirectory = false
    var backupRecords: [FileBackupRecord] = []
    var isReplacingFile = false

    @ObservationIgnored private var directorySummaryTask: Task<Void, Never>?
    @ObservationIgnored private var directorySummaryModificationDates: [String: Date] = [:]
    @ObservationIgnored private var directorySummaryIncludesHidden: Bool?

    var containers: [ContainerDescriptor] { containerIndexes[.application, default: []] }
    var systemContainers: [ContainerDescriptor] { containerIndexes[.systemData, default: []] }
    var canGoBack: Bool { !backHistory.isEmpty && !isWorking }
    var canGoForward: Bool { !forwardHistory.isEmpty && !isWorking }

    struct LogEntry: Identifiable, Equatable {
        let id = UUID()
        let date: Date
        let message: String
        let isError: Bool
    }

    init() {
        for kind in ContainerKind.allCases {
            containerIndexes[kind] = ContainerDiscoveryService.loadCached(kind)
        }
        selfTestReport = SelfTestRunner.loadPersistedReport()
        accessVerification = selfTestReport?.checks.first { $0.name == "Application container discovery" }
        ExportCache.removeExpired()
        backupRecords = (try? FileBackupService.records()) ?? []
        log("Vellune started on \(ProcessInfo.processInfo.operatingSystemVersionString)")
        #if targetEnvironment(simulator)
        log("bad_query self-test skipped in Simulator")
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            seedUITestContainers()
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-browser") {
            seedUITestBrowser()
            if (ProcessInfo.processInfo.arguments.contains("--ui-testing-preview")
                || ProcessInfo.processInfo.arguments.contains("--ui-testing-selection")),
               let item = items.last {
                Task { await open(item) }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-self-test") {
            Task { await runSelfTest() }
        }
        #else
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        if selfTestReport?.schemaVersion != 13
            || selfTestReport?.appVersion != currentVersion
            || containers.isEmpty
            || systemContainers.isEmpty {
            Task {
                await verifyAccess()
                await runSelfTest()
            }
        } else {
            Task { await verifyAccess() }
            log("Loaded cached self-test and container indexes")
        }
        #endif
    }

    #if targetEnvironment(simulator)
    private func seedUITestContainers() {
        containerIndexes[.application] = [
            .init(path: "/var/mobile/Containers/Data/Application/A111", identifier: "com.example.DocumentsResearchWorkspace", uuid: "A1111111-2222-3333-4444-555555555555", kind: .application, metadataDiagnostic: nil),
            .init(path: "/var/mobile/Containers/Data/Application/B222", identifier: "com.example.MediaCatalog", uuid: "B2222222-3333-4444-5555-666666666666", kind: .application, metadataDiagnostic: nil),
            .init(path: "/var/mobile/Containers/Data/Application/C333", identifier: "com.example.DeveloperTools", uuid: "C3333333-4444-5555-6666-777777777777", kind: .application, metadataDiagnostic: nil),
            .init(path: "/var/mobile/Containers/Data/Application/D444", identifier: "com.apple.DocumentsApp", uuid: "D4444444-5555-6666-7777-888888888888", kind: .application, metadataDiagnostic: nil),
            .init(path: "/var/mobile/Containers/Data/Application/E555", identifier: "com.apple.Preferences", uuid: "E5555555-6666-7777-8888-999999999999", kind: .application, metadataDiagnostic: nil)
        ]
        containerIndexes[.appGroup] = [
            .init(path: "/var/mobile/Containers/Shared/AppGroup/G111", identifier: "group.com.example.SharedWorkspace", uuid: "G1111111-2222-3333-4444-555555555555", kind: .appGroup, metadataDiagnostic: nil)
        ]
    }

    private func seedUITestBrowser() {
        let fixtureRoot = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "UI Test Container", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: fixtureRoot.appending(path: "Documents", directoryHint: .isDirectory), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: fixtureRoot.appending(path: "Library", directoryHint: .isDirectory), withIntermediateDirectories: true)
        let plistURL = fixtureRoot.appending(path: "settings.plist")
        if let data = try? PropertyListSerialization.data(
            fromPropertyList: ["Feature": "File Browser", "Recursive Export": true],
            format: .binary,
            options: 0
        ) { try? data.write(to: plistURL, options: .atomic) }
        currentContainerRoot = fixtureRoot.path
        selectedContainer = .init(
            path: fixtureRoot.path,
            identifier: "com.example.DocumentsResearchWorkspace",
            uuid: "A1111111-2222-3333-4444-555555555555",
            kind: .application,
            metadataDiagnostic: nil
        )
        path = currentContainerRoot
        loadedPath = path
        items = (try? FileSystemReader.contents(at: path, showHidden: true)) ?? []
        scheduleDirectorySummaries(for: items)
    }
    #endif

    func verifyAccess() async {
        guard !isVerifyingAccess else { return }
        isVerifyingAccess = true
        log("Verifying application container access")
        let check = await Task.detached(priority: .userInitiated) {
            SelfTestRunner.verifyAccess()
        }.value
        accessVerification = check
        containerIndexes[.application] = ContainerDiscoveryService.loadCached(.application)
        log("\(check.passed ? "PASS" : "FAIL") \(check.name): \(check.detail)", isError: !check.passed)
        isVerifyingAccess = false
    }

    func runSelfTest() async {
        guard !isRunningDiagnostics else { return }
        isRunningDiagnostics = true
        log("Starting bad_query self-test")
        let report = await Task.detached(priority: .userInitiated) {
            SelfTestRunner.run()
        }.value
        selfTestReport = report
        containerIndexes[.application] = ContainerDiscoveryService.loadCached(.application)
        let discoveredIndexes = await Task.detached(priority: .userInitiated) {
            Dictionary(uniqueKeysWithValues: ContainerKind.allCases.filter { $0 != .application }.map {
                ($0, ContainerDiscoveryService.discover($0))
            })
        }.value
        for (kind, descriptors) in discoveredIndexes { containerIndexes[kind] = descriptors }
        for check in report.checks {
            log("\(check.passed ? "PASS" : "FAIL") \(check.name): \(check.detail)", isError: !check.passed)
        }
        log("Self-test \(report.passed ? "passed" : "failed")")
        isRunningDiagnostics = false
    }

    func open(_ container: ContainerDescriptor) async {
        selectedContainer = container
        currentContainerRoot = container.path
        backHistory = []
        forwardHistory = []
        loadedPath = ""
        path = container.path
        await acquireAndLoad()
    }

    func closeCurrentContainer() {
        selectedContainer = nil
        currentContainerRoot = ""
        path = ""
        loadedPath = ""
        backHistory = []
        forwardHistory = []
        items = []
        directorySummaryTask?.cancel()
        directorySummaries = [:]
        directorySummaryModificationDates = [:]
        directorySummaryIncludesHidden = nil
        selectedItem = nil
        selectedPreview = nil
        selectedProperties = nil
        selectedHexDump = ""
        previewError = nil
        selectedExportURL = nil
        directoryExportURL = nil
        searchResults = []
    }

    func acquireAndLoad() async {
        guard !isWorking else { return }
        isWorking = true
        lastError = nil
        defer { isWorking = false }

        do {
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            path = normalized
            log("Requesting access: \(normalized)")
            let showHiddenFiles = showHiddenFiles
            let fileSortOrder = fileSortOrder
            let result = try await Task.detached(priority: .userInitiated) {
                let grant = try BadQueryClient.acquire(.forPath(normalized))
                defer { BadQueryClient.release(grant) }
                let items = try FileSystemReader.contents(
                    at: normalized,
                    showHidden: showHiddenFiles,
                    sortOrder: fileSortOrder
                )
                return (grant.handle, items)
            }.value
            log("Access granted with handle \(result.0)")
            applyLoadedItems(result.1)
            loadedPath = normalized
        } catch {
            report(error)
        }
    }

    func loadCurrentDirectory() throws {
        let loadedItems = try FileSystemReader.contents(at: path, showHidden: showHiddenFiles, sortOrder: fileSortOrder)
        applyLoadedItems(loadedItems)
    }

    private func applyLoadedItems(_ loadedItems: [FileItem]) {
        items = loadedItems
        scheduleDirectorySummaries(for: loadedItems)
        selectedItem = nil
        selectedPreview = nil
        selectedProperties = nil
        selectedHexDump = ""
        previewError = nil
        selectedExportURL = nil
        isLoadingPreview = false
        log("Listed \(loadedItems.count) items at \(path)")
    }

    private func scheduleDirectorySummaries(for loadedItems: [FileItem]) {
        directorySummaryTask?.cancel()

        if directorySummaryIncludesHidden != showHiddenFiles {
            directorySummaries = [:]
            directorySummaryModificationDates = [:]
            directorySummaryIncludesHidden = showHiddenFiles
        }

        let visiblePaths = Set(loadedItems.lazy.filter(\.isDirectory).map(\.url.path))
        directorySummaries = directorySummaries.filter { visiblePaths.contains($0.key) }
        directorySummaryModificationDates = directorySummaryModificationDates.filter { visiblePaths.contains($0.key) }

        let directories = loadedItems.filter { item in
            item.isDirectory
                && directorySummaryModificationDates[item.url.path] != (item.modifiedAt ?? .distantPast)
        }
        for directory in directories {
            directorySummaries.removeValue(forKey: directory.url.path)
        }
        guard !directories.isEmpty else { return }

        let includesHidden = showHiddenFiles
        directorySummaryTask = Task { [weak self] in
            for directory in directories {
                guard !Task.isCancelled else { return }
                let path = directory.url.path
                let summary = await Task.detached(priority: .utility) {
                    try? Self.loadDirectorySummary(at: path, showHidden: includesHidden)
                }.value
                guard !Task.isCancelled else { return }
                if let summary {
                    self?.directorySummaries[path] = summary
                    self?.directorySummaryModificationDates[path] = directory.modifiedAt ?? .distantPast
                }
            }
        }
    }

    nonisolated private static func loadDirectorySummary(
        at path: String,
        showHidden: Bool
    ) throws -> DirectoryContentsSummary {
        #if targetEnvironment(simulator)
        return try FileSystemReader.directContentsSummary(at: path, showHidden: showHidden)
        #else
        let grant = try BadQueryClient.acquire(.forPath(path))
        defer { BadQueryClient.release(grant) }
        return try FileSystemReader.directContentsSummary(at: path, showHidden: showHidden)
        #endif
    }

    func refresh() async {
        guard !path.isEmpty else { return }
        await acquireAndLoad()
    }

    func open(_ item: FileItem) async {
        guard item.isDirectory else {
            selectedItem = item
            selectedPreview = nil
            selectedProperties = nil
            selectedHexDump = ""
            previewError = nil
            selectedExportURL = nil
            isLoadingPreview = true
            defer {
                if selectedItem == item { isLoadingPreview = false }
            }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try FilePreviewLoader.load(item)
                }.value
                guard selectedItem == item else { return }
                selectedPreview = result.preview
                selectedProperties = result.properties
                selectedHexDump = result.hexDump
                selectedExportURL = result.exportURL
            } catch {
                guard selectedItem == item else { return }
                previewError = error.localizedDescription
                log("Preview failed for \(item.url.path): \(error.localizedDescription)", isError: true)
            }
            return
        }
        await navigate(to: item.url.path)
    }

    func goUp() async {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard parent != path else { return }
        await navigate(to: parent)
    }

    func openEnteredPath(_ enteredPath: String) async {
        await navigate(to: enteredPath)
    }

    func goBack() async {
        guard let destination = backHistory.last else { return }
        let source = loadedPath
        path = destination
        await acquireAndLoad()
        guard loadedPath == destination else { path = source; return }
        backHistory.removeLast()
        if !source.isEmpty { forwardHistory.append(source) }
    }

    func goForward() async {
        guard let destination = forwardHistory.last else { return }
        let source = loadedPath
        path = destination
        await acquireAndLoad()
        guard loadedPath == destination else { path = source; return }
        forwardHistory.removeLast()
        if !source.isEmpty { backHistory.append(source) }
    }

    private func navigate(to destination: String) async {
        let normalized = URL(fileURLWithPath: destination).standardizedFileURL.path
        guard normalized != loadedPath else {
            path = normalized
            return
        }
        let source = loadedPath
        path = normalized
        await acquireAndLoad()
        guard loadedPath == normalized else { path = source; return }
        if !source.isEmpty { backHistory.append(source) }
        forwardHistory = []
    }

    func searchCurrentContainer(for query: String) async {
        guard !path.isEmpty, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchResults = []
            return
        }
        isSearching = true
        defer { isSearching = false }
        let root = currentContainerRoot.isEmpty ? path : currentContainerRoot
        let includesHidden = showHiddenFiles
        do {
            let grant = try BadQueryClient.acquire(.forPath(root))
            defer { BadQueryClient.release(grant) }
            searchResults = await Task.detached(priority: .userInitiated) {
                FileSystemReader.search(at: root, query: query, showHidden: includesHidden)
            }.value
        } catch { report(error) }
    }

    func prepareDirectoryMarkdownExport() async {
        guard !path.isEmpty, !isExportingDirectory else { return }
        isExportingDirectory = true
        defer { isExportingDirectory = false }
        do {
            let requestedPath = path
            let options = DirectoryMarkdownExportOptions(
                recursively: directoryExportRecursive,
                includeHidden: showHiddenFiles
            )
            let result = try await Task.detached(priority: .userInitiated) {
                try DirectoryMarkdownExporter.export(path: requestedPath, options: options)
            }.value
            directoryExportURL = result.url
            log("Prepared Markdown listing with \(result.itemCount) items")
        } catch { report(error) }
    }

    func replaceSelectedFile(with source: URL) async {
        guard let item = selectedItem, !item.isDirectory, !isReplacingFile else { return }
        isReplacingFile = true
        defer { isReplacingFile = false }
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: source, options: .mappedIfSafe)
            let target = item.url
            _ = try await Task.detached(priority: .userInitiated) {
                try FileBackupService.replace(target: target, replacementData: data)
            }.value
            backupRecords = (try? FileBackupService.records()) ?? []
            log("Backed up, replaced, and verified \(item.name)")
            await open(item)
        } catch { report(error) }
    }

    func restore(_ record: FileBackupRecord) async {
        guard !isReplacingFile else { return }
        isReplacingFile = true
        defer { isReplacingFile = false }
        do {
            _ = try await Task.detached(priority: .userInitiated) {
                try FileBackupService.restore(record)
            }.value
            backupRecords = (try? FileBackupService.records()) ?? []
            log("Created a safety backup and restored \(URL(fileURLWithPath: record.manifest.targetPath).lastPathComponent)")
            if let item = selectedItem, item.url.path == record.manifest.targetPath { await open(item) }
        } catch { report(error) }
    }

    func log(_ message: String, isError: Bool = false) {
        logs.append(.init(date: .now, message: message, isError: isError))
    }

    private func report(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        lastError = message
        log(message, isError: true)
    }
}

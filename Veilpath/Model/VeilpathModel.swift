import Foundation
import Observation

@Observable
@MainActor
final class VeilpathModel {
    var path = ""
    var currentContainerRoot = ""
    var selectedContainer: ContainerDescriptor?
    var isAdvancedWorkspace = false
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
    let accessBackendSelection = SandboxAccessClient.selection
    var lastAccessBackend: SandboxBackend? { SandboxAccessClient.lastBackend }

    var canRunDiagnostics: Bool {
        !isWorking && !isRunningDiagnostics && !isVerifyingAccess && !isLoadingPreview
            && !isSearching && !isPreparingShare
            && !isReplacingFile && !isRunningFileOperation && !isScanningStorage && scanningStoragePaths.isEmpty
    }

    var isAccessVerificationPending: Bool {
        isVerifyingAccess || (accessVerification == nil && isRunningDiagnostics)
    }
    var containerIndexes: [ContainerKind: [ContainerDescriptor]] = [:]
    var searchResults: [FileItem] = []
    var isSearching = false
    var backupRecords: [FileBackupRecord] = []
    var isReplacingFile = false
    var sharePreparation: SharePreparation?
    var selectedFilePaths: Set<String> = []
    var isSelectingFiles = false
    var fileClipboard: FileClipboard?
    var fileOperationProgress: ShareExportProgress?
    var fileOperationTitle: LocalizedStringResource?
    var isRunningFileOperation = false
    var appStorage: [String: AppStorageSnapshot] = [:]
    var storageScanErrors: [String: String] = [:]
    var isScanningStorage = false
    var storageScanCompleted = 0
    var storageScanTotal = 0
    var storageScanAppName = ""
    private(set) var scanningStoragePaths: Set<String> = []
    var managedBackups: [AppLibraryBackup] = []
    var lastCreatedAppBackup: AppLibraryBackup?
    var lastRestoredAppBackupID: UUID?
    var cacheCleaningResults: [String: CacheCleaningResult] = [:]
    @ObservationIgnored private var storageScanTask: Task<Void, Never>?

    @ObservationIgnored private var directorySummaryTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var shareTask: Task<Void, Never>?
    @ObservationIgnored private var fileOperationCancellation: (() -> Void)?
    @ObservationIgnored private var directorySummaryModificationDates: [String: Date] = [:]
    @ObservationIgnored private var directorySummaryIncludesHidden: Bool?

    var containers: [ContainerDescriptor] { containerIndexes[.application, default: []] }
    var systemContainers: [ContainerDescriptor] { containerIndexes[.systemData, default: []] }
    var canGoBack: Bool { !backHistory.isEmpty && !isWorking }
    var canGoForward: Bool { !forwardHistory.isEmpty && !isWorking }
    var isPreparingShare: Bool {
        guard case .preparing? = sharePreparation?.state else { return false }
        return true
    }

    struct LogEntry: Identifiable, Equatable {
        let id = UUID()
        let date: Date
        let message: String
        let isError: Bool
    }

    init() {
        do { try SandboxAccessClient.recoverWorkspace() }
        catch { lastError = error.localizedDescription }
        for kind in ContainerKind.allCases {
            containerIndexes[kind] = ContainerDiscoveryService.loadCached(kind)
        }
        selfTestReport = SelfTestRunner.loadPersistedReport()
        if selfTestReport?.accessBackendSelection == accessBackendSelection.rawValue {
            accessVerification = selfTestReport?.checks.first { $0.name == "Application container discovery" }
        }
        ExportCache.removeExpired()
        OperationSafetyStore.pruneAll()
        backupRecords = (try? FileBackupService.records()) ?? []
        reloadManagedBackups()
        Task {
            do { try await AppDataOperations.shared.recoverInterruptedOperations() }
            catch { report(error) }
        }
        log("Veilpath started on \(ProcessInfo.processInfo.operatingSystemVersionString)")
        #if targetEnvironment(simulator)
        log("Sandbox access checks skipped in Simulator")
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            seedUITestContainers()
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-management") {
            seedManagementUITests()
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
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-self-test") {
            Task { await runSelfTest() }
        } else {
            Task { await verifyAccess() }
            log("Loaded cached application index")
        }
        #endif
    }

    #if targetEnvironment(simulator)
    private func seedManagementUITests() {
        var previews: [ContainerDescriptor] = []
        for (index, name) in ["Notes Preview", "Media Preview"].enumerated() {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("veilpath-management-" + UUID().uuidString)
            do {
                for path in ["Documents", "Library/Caches", "tmp"] {
                    try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
                }
                try Data(repeating: 65, count: (index + 1) * 1024 * 1024).write(to: root.appendingPathComponent("Library/Caches/sample.cache"))
                try Data(repeating: 66, count: 256 * 1024).write(to: root.appendingPathComponent("Documents/sample.txt"))
                var container = ContainerDescriptor(path: root.path, identifier: "com.example.ManagementPreview\(index)",
                    uuid: root.lastPathComponent, kind: .application, metadataDiagnostic: nil)
                container.applicationName = name
                previews.append(container)
                appStorage[container.path] = try AppStorageService.scan(container)
            } catch { log("Management UI fixture: \(error.localizedDescription)", isError: true) }
        }
        containerIndexes[.application] = previews
        if let container = previews.first { Task { await createManagedBackup(for: container) } }
    }

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
        log("Starting self-test with \(accessBackendSelection.rawValue) access")
        let report = await Task.detached(priority: .userInitiated) {
            await SelfTestRunner.run()
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

    func open(_ container: ContainerDescriptor, advanced: Bool = false) async {
        isAdvancedWorkspace = advanced
        showHiddenFiles = advanced
        selectedContainer = container
        currentContainerRoot = container.path
        backHistory = []
        forwardHistory = []
        loadedPath = ""
        path = container.path
        await acquireAndLoad()
    }

    func closeCurrentContainer() {
        isAdvancedWorkspace = false
        selectedContainer = nil
        currentContainerRoot = ""
        path = ""
        loadedPath = ""
        backHistory = []
        forwardHistory = []
        items = []
        directorySummaryTask?.cancel()
        shareTask?.cancel()
        directorySummaries = [:]
        directorySummaryModificationDates = [:]
        directorySummaryIncludesHidden = nil
        selectedItem = nil
        selectedPreview = nil
        selectedProperties = nil
        selectedHexDump = ""
        previewError = nil
        selectedExportURL = nil
        searchResults = []
        sharePreparation = nil
        selectedFilePaths = []
        isSelectingFiles = false
        fileClipboard = nil
        fileOperationProgress = nil
        fileOperationTitle = nil
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
                #if targetEnvironment(simulator)
                let ownRoot = ManagedAppFiles.canonical(URL(fileURLWithPath: NSHomeDirectory()))
                let actual = ManagedAppFiles.canonical(URL(fileURLWithPath: normalized).resolvingSymlinksInPath())
                guard actual == ownRoot || actual.hasPrefix(ownRoot + "/") else { throw AppManagementError.unsafeTree }
                #endif
                let grant = try ManagedAppFiles.acquire(URL(fileURLWithPath: normalized))
                defer { ManagedAppFiles.release(grant) }
                let items = try FileSystemReader.contents(
                    at: normalized,
                    showHidden: showHiddenFiles,
                    sortOrder: fileSortOrder
                )
                return (grant?.handle, items)
            }.value
            if let handle = result.0 { log("Access granted with handle \(handle)") }
            else { log("Reading simulator-owned fixture") }
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
        selectedFilePaths = []
        isSelectingFiles = false
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
        let grant = try SandboxAccessClient.acquire(.forPath(path))
        defer { SandboxAccessClient.release(grant) }
        return try FileSystemReader.directContentsSummary(at: path, showHidden: showHidden)
        #endif
    }

    func refresh() async {
        guard !path.isEmpty else { return }
        await acquireAndLoad()
    }

    func refreshContainers(for kind: ContainerKind) async {
        if kind == .application {
            await verifyAccess()
            return
        }
        guard !isWorking else { return }
        isWorking = true
        log("Refreshing \(kind.rawValue) containers")
        let descriptors = await Task.detached(priority: .userInitiated) {
            ContainerDiscoveryService.discover(kind)
        }.value
        containerIndexes[kind] = descriptors
        log("Loaded \(descriptors.count) \(kind.rawValue) containers")
        isWorking = false
    }

    func open(_ item: FileItem) async {
        guard item.isDirectory else {
            previewTask?.cancel()
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
            let task = Task { [weak self] in
                do {
                    let result = try await Task.detached(priority: .userInitiated) {
                    try FilePreviewLoader.load(item)
                    }.value
                    try Task.checkCancellation()
                    guard self?.selectedItem == item else { return }
                    self?.selectedPreview = result.preview
                    self?.selectedProperties = result.properties
                    self?.selectedHexDump = result.hexDump
                    self?.selectedExportURL = result.exportURL
                } catch is CancellationError {
                    return
                } catch {
                    guard self?.selectedItem == item else { return }
                    self?.previewError = error.localizedDescription
                    self?.log("Preview failed for \(item.url.path): \(error.localizedDescription)", isError: true)
                }
            }
            previewTask = task
            await task.value
            return
        }
        await navigate(to: item.url.path)
    }

    func goUp() async {
        guard isAdvancedWorkspace || path != currentContainerRoot else { return }
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
        if !isAdvancedWorkspace {
            let root = ManagedAppFiles.canonical(URL(fileURLWithPath: currentContainerRoot))
            let resolved = ManagedAppFiles.canonical(URL(fileURLWithPath: normalized).resolvingSymlinksInPath())
            guard !currentContainerRoot.isEmpty, resolved == root || resolved.hasPrefix(root + "/") else {
                report(AppManagementError.unsafeTree)
                return
            }
        }
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
            let grant = try ManagedAppFiles.acquire(URL(fileURLWithPath: root))
            defer { ManagedAppFiles.release(grant) }
            searchResults = await Task.detached(priority: .userInitiated) {
                FileSystemReader.search(at: root, query: query, showHidden: includesHidden)
            }.value
        } catch { report(error) }
    }

    func prepareShare(for item: FileItem) {
        if !item.isDirectory,
           selectedItem == item,
           let selectedExportURL,
           FileManager.default.fileExists(atPath: selectedExportURL.path) {
            let size = item.size ?? (try? selectedExportURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            sharePreparation = .init(
                id: UUID(), request: .file(item),
                progress: .init(phase: .finalizing, completedBytes: size, totalBytes: size, completedItems: 1, totalItems: 1),
                state: .ready(selectedExportURL, detail: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
            )
            return
        }
        if item.isDirectory {
            startSharePreparation(.directory(url: item.url, name: item.name, includeHidden: showHiddenFiles))
        } else {
            startSharePreparation(.file(item))
        }
    }

    func prepareCurrentDirectoryZIP() {
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        startSharePreparation(.directory(url: url, name: url.lastPathComponent.isEmpty ? "Directory" : url.lastPathComponent,
                                         includeHidden: showHiddenFiles))
    }

    func retrySharePreparation() {
        guard let request = sharePreparation?.request else { return }
        startSharePreparation(request)
    }

    func cancelSharePreparation() {
        shareTask?.cancel()
        shareTask = nil
        sharePreparation = nil
    }

    private func startSharePreparation(_ request: ShareExportRequest) {
        shareTask?.cancel()
        let id = UUID()
        sharePreparation = .init(
            id: id, request: request,
            progress: .init(phase: .preparing, completedBytes: 0, totalBytes: 0, completedItems: 0, totalItems: 0),
            state: .preparing
        )
        shareTask = Task { [weak self] in
            do {
                let progress: ShareExportService.ProgressHandler = { update in
                    await MainActor.run {
                        guard self?.sharePreparation?.id == id else { return }
                        self?.sharePreparation?.progress = update
                    }
                }
                let ready: (URL, String)
                switch request {
                case .file(let item):
                    let url = try await ShareExportService.prepareFile(at: item.url, named: item.name, progress: progress)
                    let size = item.size ?? 0
                    ready = (url, ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                case .directory(let url, let name, let includeHidden):
                    let result = try await ShareExportService.prepareDirectoryZIP(
                        at: url, named: name, includeHidden: includeHidden, progress: progress
                    )
                    var detail = "\(result.itemCount) items · \(ByteCountFormatter.string(fromByteCount: result.totalBytes, countStyle: .file))"
                    if result.skippedSymbolicLinks > 0 { detail += " · \(result.skippedSymbolicLinks) links skipped" }
                    ready = (result.url, detail)
                case .managedBackup(let record):
                    try await Task.detached(priority: .userInitiated) { try AppBackupLibrary.verifyArchive(record) }.value
                    let url = try await ShareExportService.prepareFile(at: record.archive, named: record.exportName, progress: progress)
                    let digest = try await Task.detached(priority: .userInitiated) { try ManagedAppFiles.hash(url) }.value
                    guard digest == record.archiveSHA256 else { throw AppManagementError.invalidBackup }
                    ready = (url, ByteCountFormatter.string(fromByteCount: record.archiveBytes, countStyle: .file))
                }
                try Task.checkCancellation()
                guard self?.sharePreparation?.id == id else { return }
                self?.sharePreparation?.state = .ready(ready.0, detail: ready.1)
                self?.log("Prepared share export: \(ready.0.lastPathComponent)")
            } catch is CancellationError {
                return
            } catch {
                guard self?.sharePreparation?.id == id else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self?.sharePreparation?.state = .failed(message)
                self?.log("Share preparation failed: \(message)", isError: true)
            }
        }
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

    func finishedEditing(_ item: FileItem) async {
        backupRecords = (try? FileBackupService.records()) ?? []
        log("Safely edited and versioned \(item.name)")
        if selectedItem == item { await open(item) }
    }

    var selectedFiles: [FileItem] { items.filter { selectedFilePaths.contains($0.url.path) } }

    func beginFileSelection(with item: FileItem? = nil) {
        isSelectingFiles = true
        if let item { selectedFilePaths.insert(item.url.path) }
    }

    func toggleFileSelection(_ item: FileItem) {
        if selectedFilePaths.contains(item.url.path) { selectedFilePaths.remove(item.url.path) }
        else { selectedFilePaths.insert(item.url.path) }
        if selectedFilePaths.isEmpty { isSelectingFiles = false }
    }

    func selectAllFiles() {
        isSelectingFiles = true
        selectedFilePaths = Set(items.map { $0.url.path })
    }

    func cancelFileSelection() {
        selectedFilePaths = []
        isSelectingFiles = false
    }

    func copySelectedFiles(mode: FileClipboardMode) {
        let selection = selectedFiles
        let urls = selection.filter { !$0.isSymbolicLink }.map(\.url)
        let skipped = selection.filter(\.isSymbolicLink).map(\.url.path)
        guard !urls.isEmpty else { return }
        fileClipboard = .init(mode: mode, sourceURLs: urls)
        log("Prepared \(urls.count) items to \(mode.rawValue)")
        selectedFilePaths = Set(skipped)
        isSelectingFiles = !skipped.isEmpty
        if !skipped.isEmpty { reportSkipped(skipped.count) }
    }

    func pasteFiles() async {
        guard let fileClipboard, !path.isEmpty else { return }
        let destination = URL(fileURLWithPath: path, isDirectory: true)
        let title: LocalizedStringResource = fileClipboard.mode == .copy ? "Copying Items" : "Moving Items"
        if let result = await performFileOperation(title: title, operation: { _ in
            try FileOperationService.paste(fileClipboard, into: destination)
        }) {
            reportPartial(result)
            if fileClipboard.mode == .cut {
                let remaining = result.failures.map(\.sourceURL)
                self.fileClipboard = remaining.isEmpty ? nil : .init(mode: .cut, sourceURLs: remaining)
            }
        }
    }

    func duplicate(_ item: FileItem) async {
        await performFileOperation(title: "Duplicating \(item.name)") {
            _ = try FileOperationService.duplicate(item)
        }
    }

    func compressSelectedFiles() async {
        let selection = selectedFiles
        guard !selection.isEmpty else { return }
        let destination = URL(fileURLWithPath: path, isDirectory: true)
        if let result = await performFileOperation(title: "Compressing \(selection.count) Items", operation: { progress in
            try await FileOperationService.compress(selection, into: destination,
                                                    named: "Archive", progress: progress)
        }) {
            selectedFilePaths = Set(result.skippedURLs.map(\.path))
            isSelectingFiles = !selectedFilePaths.isEmpty
            reportPartial(result)
        }
    }

    func extract(_ item: FileItem) async {
        let destination = URL(fileURLWithPath: path, isDirectory: true)
        await performFileOperation(title: "Extracting \(item.name)") { progress in
            _ = try await FileOperationService.extract(item, into: destination, progress: progress)
        }
    }

    func deleteSelectedFiles() async {
        let selection = selectedFiles
        guard !selection.isEmpty else { return }
        if let result = await performFileOperation(title: "Creating Safety Backup and Deleting", operation: { progress in
            try await FileOperationService.delete(selection, progress: progress)
        }) {
            if let url = result.safetyArchiveURL { log("Deleted items are recoverable from \(url.lastPathComponent)") }
            selectedFilePaths = Set(result.failures.map(\.sourceURL.path) + result.skippedURLs.map(\.path))
            isSelectingFiles = !selectedFilePaths.isEmpty
            reportPartial(result)
        }
    }

    func cancelFileOperation() {
        fileOperationCancellation?()
    }

    func reloadManagedBackups() {
        do { managedBackups = try AppBackupLibrary.records() }
        catch { report(error) }
    }

    func scanAppStorage() async {
        guard canRunDiagnostics else { return }
        isScanningStorage = true
        storageScanCompleted = 0; storageScanTotal = containers.count
        let applications = containers
        let task = Task {
            for container in applications {
                if Task.isCancelled { break }
                storageScanAppName = container.displayName
                await scanStorage(for: container)
                storageScanCompleted += 1
            }
        }
        storageScanTask = task
        await task.value
        storageScanTask = nil; isScanningStorage = false; storageScanAppName = ""
    }

    func cancelStorageScan() { storageScanTask?.cancel() }

    func scanStorage(for container: ContainerDescriptor) async {
        guard !scanningStoragePaths.contains(container.path) else { return }
        scanningStoragePaths.insert(container.path)
        defer { scanningStoragePaths.remove(container.path) }
        let worker = Task.detached(priority: .utility) { try AppStorageService.scan(container) }
        do {
            let snapshot = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            appStorage[container.path] = snapshot
            storageScanErrors[container.path] = nil
        } catch is CancellationError {}
        catch {
            appStorage[container.path] = nil
            storageScanErrors[container.path] = error.localizedDescription
        }
    }

    @discardableResult
    func createManagedBackup(for container: ContainerDescriptor) async -> AppLibraryBackup? {
        guard !isScanningStorage else { return nil }
        let record = await performFileOperation(title: "Creating App Backup") { progress in
            try await AppDataOperations.shared.createBackup(container, progress: progress)
        }
        if let record { lastCreatedAppBackup = record }
        reloadManagedBackups()
        return record
    }

    func cleanCaches(for container: ContainerDescriptor, locations: [CacheLocation]) async {
        guard !isScanningStorage, let snapshot = appStorage[container.path], snapshot.isComplete else {
            report(AppManagementError.incompleteScan); return
        }
        if let result = await performFileOperation(title: "Backing Up and Cleaning Caches", operation: { progress in
            try await AppDataOperations.shared.clean(container, locations: locations, progress: progress)
        }) {
            cacheCleaningResults[container.path] = result
        }
        reloadManagedBackups()
        await scanStorage(for: container)
    }

    func restoreManagedBackup(_ record: AppLibraryBackup, to container: ContainerDescriptor) async {
        guard !isScanningStorage else { return }
        let completed: Void? = await performFileOperation(title: "Verifying and Restoring App Backup") { progress in
            try await AppDataOperations.shared.restore(record, to: container, progress: progress)
        }
        if case .some = completed {
            lastRestoredAppBackupID = record.id
            cacheCleaningResults[container.path] = nil
        }
        reloadManagedBackups()
        await scanStorage(for: container)
    }

    func exportManagedBackup(_ record: AppLibraryBackup) {
        startSharePreparation(.managedBackup(record))
    }

    func deleteManagedBackup(_ record: AppLibraryBackup) async -> Bool {
        guard !isScanningStorage else { return false }
        let completed: Void? = await performFileOperation(title: "Deleting Backup") {
            try await AppDataOperations.shared.deleteBackup(record)
        }
        reloadManagedBackups()
        guard case .some = completed else { return false }
        if lastCreatedAppBackup?.id == record.id { lastCreatedAppBackup = nil }
        if lastRestoredAppBackupID == record.id { lastRestoredAppBackupID = nil }
        return true
    }

    func importManagedBackup(from source: URL) async {
        guard !isScanningStorage else { return }
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let applications = containers
        await performFileOperation(title: "Importing and Verifying Backup") { _ in
            _ = try await AppDataOperations.shared.importBackup(source, applications: applications)
        }
        reloadManagedBackups()
    }

    private func performFileOperation<T: Sendable>(
        title: LocalizedStringResource,
        operation: @escaping @Sendable () async throws -> T
    ) async -> T? {
        await performFileOperation(title: title) { _ in try await operation() }
    }

    private func performFileOperation<T: Sendable>(
        title: LocalizedStringResource,
        operation: @escaping @Sendable (@escaping FileOperationService.Progress) async throws -> T
    ) async -> T? {
        guard !isRunningFileOperation else { return nil }
        isRunningFileOperation = true
        fileOperationTitle = title
        fileOperationProgress = .init(phase: .preparing, completedBytes: 0, totalBytes: 0, completedItems: 0, totalItems: 0)
        defer {
            fileOperationCancellation = nil
            isRunningFileOperation = false
            fileOperationTitle = nil
            fileOperationProgress = nil
        }
        do {
            let progress: FileOperationService.Progress = { completedBytes, totalBytes, completedItems, totalItems in
                await MainActor.run {
                    let next = ShareExportProgress(phase: .archiving, completedBytes: completedBytes, totalBytes: totalBytes,
                                                   completedItems: completedItems, totalItems: totalItems)
                    if self.fileOperationProgress != next { self.fileOperationProgress = next }
                }
            }
            let task = Task { try await operation(progress) }
            fileOperationCancellation = { task.cancel() }
            let result = try await task.value
            await refresh()
            log("Completed: \(String(localized: title))")
            return result
        } catch is CancellationError {
            log("Operation cancelled")
        } catch { report(error) }
        return nil
    }

    private func reportPartial(_ result: FileOperationResult) {
        if !result.skippedURLs.isEmpty { reportSkipped(result.skippedURLs.count) }
        guard !result.failures.isEmpty else { return }
        let message = "\(result.affectedURLs.count) completed, \(result.failures.count) failed. Failed items remain selected."
        lastError = message
        log(message, isError: true)
    }

    private func reportSkipped(_ count: Int) {
        let message = "\(count) symbolic link\(count == 1 ? " was" : "s were") skipped for safety."
        log(message)
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

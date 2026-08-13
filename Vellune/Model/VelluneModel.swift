import Foundation
import Observation

@Observable
@MainActor
final class VelluneModel {
    var path = ""
    var currentContainerRoot = ""
    var items: [FileItem] = []
    var selectedItem: FileItem?
    var selectedPreview: FilePreview?
    var selectedProperties: FileProperties?
    var selectedHexDump = ""
    var previewError: String?
    var selectedExportURL: URL?
    var logs: [LogEntry] = []
    var showHiddenFiles = true
    var isWorking = false
    var lastError: String?
    var selfTestReport: SelfTestReport?
    var containerIndexes: [ContainerKind: [ContainerDescriptor]] = [:]
    var searchResults: [FileItem] = []
    var isSearching = false

    var containers: [ContainerDescriptor] { containerIndexes[.application, default: []] }
    var systemContainers: [ContainerDescriptor] { containerIndexes[.systemData, default: []] }

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
        ExportCache.removeExpired()
        log("Vellune started on \(ProcessInfo.processInfo.operatingSystemVersionString)")
        #if targetEnvironment(simulator)
        log("bad_query self-test skipped in Simulator")
        #else
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        if selfTestReport?.schemaVersion != 8
            || selfTestReport?.appVersion != currentVersion
            || containers.isEmpty
            || systemContainers.isEmpty {
            Task { await runSelfTest() }
        } else {
            log("Loaded cached self-test and container indexes")
        }
        #endif
    }

    func runSelfTest() async {
        guard !isWorking else { return }
        isWorking = true
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
        isWorking = false
    }

    func open(_ container: ContainerDescriptor) async {
        currentContainerRoot = container.path
        path = container.path
        await acquireAndLoad()
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
            let grant = try BadQueryClient.acquire(.forPath(normalized))
            defer { BadQueryClient.release(grant) }
            log("Access granted with handle \(grant.handle)")
            try loadCurrentDirectory()
        } catch {
            report(error)
        }
    }

    func loadCurrentDirectory() throws {
        items = try FileSystemReader.contents(at: path, showHidden: showHiddenFiles)
        selectedItem = nil
        selectedPreview = nil
        selectedProperties = nil
        selectedHexDump = ""
        previewError = nil
        selectedExportURL = nil
        log("Listed \(items.count) items at \(path)")
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
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try FilePreviewLoader.load(item)
                }.value
                selectedPreview = result.preview
                selectedProperties = result.properties
                selectedHexDump = result.hexDump
                selectedExportURL = result.exportURL
            } catch {
                previewError = error.localizedDescription
                log("Preview failed for \(item.url.path): \(error.localizedDescription)", isError: true)
            }
            return
        }
        path = item.url.path
        await acquireAndLoad()
    }

    func goUp() async {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard parent != path else { return }
        path = parent
        await acquireAndLoad()
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

    func log(_ message: String, isError: Bool = false) {
        logs.append(.init(date: .now, message: message, isError: isError))
    }

    private func report(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        lastError = message
        log(message, isError: true)
    }
}

import SwiftUI
import UniformTypeIdentifiers

private func storageSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

struct AppStorageView: View {
    @Bindable var model: VeilpathModel
    @State private var search = ""

    private var applications: [ContainerDescriptor] {
        model.containers.filter {
            search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search)
                || ($0.identifier?.localizedCaseInsensitiveContains(search) ?? false)
        }.sorted {
            let lhs = model.appStorage[$0.path]?.totalBytes ?? -1
            let rhs = model.appStorage[$1.path]?.totalBytes ?? -1
            return lhs == rhs ? $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending : lhs > rhs
        }
    }

    var body: some View {
        List {
            if model.isVerifyingAccess || model.isRunningDiagnostics {
                Section { ProgressView("Preparing App Access…") }
            } else if model.accessVerification?.status == .failed {
                Section {
                    Text("App access needs attention.")
                    Button("Verify Access") { Task { await model.verifyAccess() } }
                }
            }
            if model.isScanningStorage {
                Section {
                    ProgressView(value: Double(model.storageScanCompleted), total: Double(max(1, model.storageScanTotal))) {
                        Text("Scanning \(model.storageScanAppName)")
                    }
                    Button("Stop Scan", role: .cancel) { model.cancelStorageScan() }
                }
            }
            Section {
                ForEach(applications) { container in
                    NavigationLink {
                        AppStorageDetailView(model: model, container: container)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "app").foregroundStyle(.secondary).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(container.displayName)
                                if let scan = model.appStorage[container.path] {
                                    Text("Cache: \(storageSize(scan.cacheBytes))").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if let scan = model.appStorage[container.path] {
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(storageSize(scan.totalBytes)).monospacedDigit()
                                    if !scan.isComplete { Text("Partial Scan").font(.caption).foregroundStyle(.orange) }
                                }
                            } else {
                                Text(model.storageScanErrors[container.path] == nil ? LocalizedStringResource("Not Scanned") : LocalizedStringResource("Unavailable"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } footer: {
                Text("Measured app data excludes the installed app itself. Scan storage to sort by file size; partial scans cannot enable cleaning.")
            }
        }
        .overlay {
            if applications.isEmpty && !model.isVerifyingAccess && !model.isRunningDiagnostics {
                ContentUnavailableView.search(text: search)
            }
        }
        .navigationTitle("Applications")
        .searchable(text: $search, prompt: "App name or Bundle ID")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Scan App Storage", systemImage: "chart.bar.xaxis") { Task { await model.scanAppStorage() } }
                    .disabled(!model.canRunDiagnostics)
            }
        }
        .refreshable { await model.refreshContainers(for: .application) }
    }
}

struct AppStorageDetailView: View {
    @Bindable var model: VeilpathModel
    let container: ContainerDescriptor
    @State private var showingUndoConfirmation = false
    private var snapshot: AppStorageSnapshot? { model.appStorage[container.path] }
    private var isOwnContainer: Bool { container.identifier == Bundle.main.bundleIdentifier }

    var body: some View {
        List {
            Section {
                if let snapshot {
                    LabeledContent("Measured App Data", value: storageSize(snapshot.totalBytes))
                    if !snapshot.isComplete { Text("Partial Scan").foregroundStyle(.orange) }
                } else if let error = model.storageScanErrors[container.path] {
                    Text(error).foregroundStyle(.secondary)
                } else { ProgressView("Scanning App Data…") }
                Button("Browse and Export Files", systemImage: "folder") {
                    Task { await model.open(container) }
                }
                .disabled(!model.canRunDiagnostics)
            }
            Section {
                Button("Create App Backup", systemImage: "externaldrive.badge.plus") {
                    Task { await model.createManagedBackup(for: container) }
                }
                .disabled(!model.canRunDiagnostics || isOwnContainer || container.identifier == nil)
                if model.lastCreatedAppBackup?.container.path == container.path {
                    Label("App Backup Created", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
                NavigationLink {
                    AppCacheManagementView(model: model, container: container)
                } label: {
                    LabeledContent("Manage Caches", value: snapshot.map { storageSize($0.cacheBytes) } ?? "—")
                }
                .disabled(isOwnContainer)
            }
            if let result = model.cacheCleaningResults[container.path] {
                Section("Last Cleanup") {
                    LabeledContent("Cache Data Removed", value: storageSize(result.processedBytes))
                    LabeledContent("Recovery Backup Size", value: storageSize(result.backup.archiveBytes))
                    if let freed = result.netFreedBytes { LabeledContent("Available Space Change", value: storageSize(freed)) }
                    if model.managedBackups.contains(where: { $0.id == result.backup.id }) {
                        Button("Undo This Cleanup", systemImage: "arrow.uturn.backward") { showingUndoConfirmation = true }
                            .disabled(!model.canRunDiagnostics)
                    }
                }
            }
            Section {
                NavigationLink {
                    AppStorageInfoView(model: model, container: container)
                } label: { Label("App Data Details", systemImage: "info.circle") }
                let records = model.managedBackups.filter { $0.container.identifier == container.identifier }
                if !records.isEmpty {
                    NavigationLink {
                        AppBackupGroupView(model: model, identifier: container.identifier ?? container.uuid)
                    } label: { Label("App Backups", systemImage: "clock.arrow.circlepath") }
                }
            }
        }
        .navigationTitle(container.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.isVerifyingAccess || model.isRunningDiagnostics) {
            if snapshot == nil && !model.isVerifyingAccess && !model.isRunningDiagnostics { await model.scanStorage(for: container) }
        }
        .confirmationDialog("Undo This Cleanup?", isPresented: $showingUndoConfirmation, titleVisibility: .visible) {
            Button("Create Safety Backup and Restore", role: .destructive) {
                if let backup = model.cacheCleaningResults[container.path]?.backup {
                    Task { await model.restoreManagedBackup(backup, to: container) }
                }
            }
        } message: { Text("Close the target app first. Its current caches receive a new safety backup before the previous caches are restored.") }
    }
}

private struct AppStorageInfoView: View {
    @Bindable var model: VeilpathModel
    let container: ContainerDescriptor
    var body: some View {
        List {
            Section("Application") {
                LabeledContent("Bundle Identifier", value: container.identifier ?? "")
                Text(container.path).font(.caption.monospaced()).textSelection(.enabled)
            }
            if let scan = model.appStorage[container.path] {
                Section("Storage Breakdown") {
                    LabeledContent("Documents", value: storageSize(scan.documentsBytes))
                    LabeledContent("Library Data", value: storageSize(scan.libraryBytes))
                    LabeledContent("Caches", value: storageSize(scan.cacheBytes))
                    LabeledContent("Temporary Files", value: storageSize(scan.temporaryBytes))
                    LabeledContent("Other Files", value: storageSize(scan.otherBytes))
                    LabeledContent("Last Scanned") { Text(scan.scannedAt, style: .relative) }
                    if !scan.isComplete { Text("This scan is incomplete. Cleaning is disabled.").foregroundStyle(.orange) }
                    if scan.skippedLinks > 0 { Text("Symbolic links were skipped. Selected cache folders are checked again before cleaning.") }
                }
            }
            Button("Refresh Storage", systemImage: "arrow.clockwise") { Task { await model.scanStorage(for: container) } }
                .disabled(!model.canRunDiagnostics)
        }
        .navigationTitle("App Data Details")
    }
}

private struct AppCacheManagementView: View {
    @Bindable var model: VeilpathModel
    let container: ContainerDescriptor
    @State private var includeTemporary = false
    @State private var showingCleanConfirmation = false
    private var snapshot: AppStorageSnapshot? { model.appStorage[container.path] }
    private var selectedBytes: Int64 { (snapshot?.cacheBytes ?? 0) + (includeTemporary ? snapshot?.temporaryBytes ?? 0 : 0) }
    private var canClean: Bool {
        snapshot?.isComplete == true && container.identifier != nil
            && container.identifier != Bundle.main.bundleIdentifier && model.canRunDiagnostics
            && selectedBytes > 0 && selectedBytes <= Int64(UInt32.max)
    }
    var body: some View {
        List {
            Section {
                LabeledContent("Caches", value: storageSize(snapshot?.cacheBytes ?? 0))
                Toggle("Include Temporary Files", isOn: $includeTemporary)
                if includeTemporary { LabeledContent("Temporary Files", value: storageSize(snapshot?.temporaryBytes ?? 0)) }
            } footer: { Text("Caches are selected. Documents and app settings are kept.") }
            Section {
                Button("Back Up and Clean Caches", systemImage: "arrow.down.doc", role: .destructive) { showingCleanConfirmation = true }
                    .disabled(!canClean)
                if snapshot?.isComplete != true { Text("This scan is incomplete. Cleaning is disabled.").foregroundStyle(.secondary) }
                if selectedBytes > Int64(UInt32.max) { Text("The selected caches exceed the 4 GB recovery archive limit.") }
                Text("Close the target app first. Some cached downloads may need to be downloaded again. A verified recovery backup is kept in Backup Center.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Recovery backups remain on this device. Available space is measured before and after the operation and can also change with other activity.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let result = model.cacheCleaningResults[container.path] {
                Section("Last Cleanup") {
                    LabeledContent("Cache Data Removed", value: storageSize(result.processedBytes))
                    LabeledContent("Recovery Backup Size", value: storageSize(result.backup.archiveBytes))
                    if let freed = result.netFreedBytes { LabeledContent("Available Space Change", value: storageSize(freed)) }
                    Text("Return to the app to undo this cleanup.").foregroundStyle(.secondary)
                }
            }
            Button("Refresh Storage") { Task { await model.scanStorage(for: container) } }.disabled(!model.canRunDiagnostics)
        }
        .navigationTitle("Manage Caches")
        .confirmationDialog("Clean Selected Cache Folders?", isPresented: $showingCleanConfirmation, titleVisibility: .visible) {
            Button("Create Recovery Backup and Clean", role: .destructive) {
                Task { await model.cleanCaches(for: container, locations: includeTemporary ? [.caches, .temporary] : [.caches]) }
            }
        } message: { Text("Close this app before continuing. Veilpath verifies a backup before changing the selected cache folders. You can restore that backup from Backup Center.") }
    }
}

struct AppBackupsView: View {
    @Bindable var model: VeilpathModel
    @State private var showingImporter = false
    @State private var search = ""
    private var groups: [AppBackupGroup] { AppBackupGroup.group(model.managedBackups).filter {
        search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search)
    } }
    var body: some View {
        List {
            Section {
                LabeledContent("Backup Archive Storage", value: storageSize(model.managedBackups.reduce(0) { $0 + $1.archiveBytes }))
            } footer: { Text("Backups stay on this device without automatic expiry. Export or delete old backups when you no longer need them.") }
            if groups.isEmpty {
                ContentUnavailableView("No App Backups", systemImage: "externaldrive", description: Text("Create an app backup or clean caches to keep a recovery copy here."))
            }
            ForEach(groups) { group in
                NavigationLink { AppBackupGroupView(model: model, identifier: group.id) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(group.name)
                        HStack {
                            Text("\(group.records.count) backups")
                            Spacer()
                            Text(storageSize(group.bytes))
                        }.font(.caption).foregroundStyle(.secondary)
                        if let latest = group.records.first { Text(latest.createdAt, format: .dateTime).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .navigationTitle("Backups")
        .searchable(text: $search, prompt: "App name or Bundle ID")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Import Backup", systemImage: "square.and.arrow.down") { showingImporter = true }.disabled(!model.canRunDiagnostics)
            }
        }
        .task { model.reloadManagedBackups() }
        .refreshable { model.reloadManagedBackups() }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.zip]) { result in
            switch result {
            case .success(let url): Task { await model.importManagedBackup(from: url) }
            case .failure(let error): model.lastError = error.localizedDescription
            }
        }
    }
}

private struct AppBackupGroup: Identifiable {
    let id: String
    let records: [AppLibraryBackup]
    var name: String { records.first?.container.displayName ?? id }
    var bytes: Int64 { records.reduce(0) { $0 + $1.archiveBytes } }
    static func group(_ records: [AppLibraryBackup]) -> [Self] {
        Dictionary(grouping: records, by: { $0.container.identifier ?? $0.container.uuid })
            .map { Self(id: $0.key, records: $0.value.sorted { $0.createdAt > $1.createdAt }) }
            .sorted { ($0.records.first?.createdAt ?? .distantPast) > ($1.records.first?.createdAt ?? .distantPast) }
    }
}

private struct AppBackupGroupView: View {
    @Bindable var model: VeilpathModel
    let identifier: String
    private var records: [AppLibraryBackup] { model.managedBackups.filter { ($0.container.identifier ?? $0.container.uuid) == identifier } }
    var body: some View {
        List(records) { record in
            NavigationLink { AppBackupDetailView(model: model, record: record) } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(record.kind == .application ? LocalizedStringResource("App Backup") : LocalizedStringResource("Cache Recovery"))
                    if record.reason == .beforeRestore { Text("Before Restore").font(.caption).foregroundStyle(.secondary) }
                    HStack { Text(record.createdAt, format: .dateTime); Spacer(); Text(storageSize(record.archiveBytes)) }
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(records.first?.container.displayName ?? identifier)
        .overlay { if records.isEmpty { ContentUnavailableView("No App Backups", systemImage: "externaldrive") } }
    }
}

private struct AppBackupDetailView: View {
    @Bindable var model: VeilpathModel
    let record: AppLibraryBackup
    @State private var destination: ContainerDescriptor?
    @State private var showingRestoreConfirmation = false
    @State private var showingDeleteConfirmation = false
    @Environment(\.dismiss) private var dismiss
    private var targets: [ContainerDescriptor] { model.containers.filter { $0.identifier == record.container.identifier } }
    private var canDelete: Bool { AppBackupLibrary.canDelete(record) }
    var body: some View {
        List {
            if model.lastRestoredAppBackupID == record.id {
                Section { Label("Backup Restored", systemImage: "checkmark.circle"); Text("The previous contents were saved in a safety backup before restoration.") }
            }
            Section("Backup Details") {
                LabeledContent("Application", value: record.container.displayName)
                LabeledContent("Created") { Text(record.createdAt, format: .dateTime) }
                LabeledContent("Archive Size", value: storageSize(record.archiveBytes))
                DisclosureGroup("Technical Details") {
                    LabeledContent("Bundle Identifier", value: record.container.identifier ?? "")
                    LabeledContent("Payload Size", value: storageSize(record.payloadBytes))
                    if let count = record.skippedSymbolicLinks, count > 0 { LabeledContent("Skipped Symbolic Links") { Text(count, format: .number) } }
                    Text(record.archiveSHA256).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            Section {
                Button("Export Backup", systemImage: "square.and.arrow.up") { model.exportManagedBackup(record) }.disabled(!model.canRunDiagnostics)
            }
            Section("Restore to Application") {
                ForEach(targets) { target in
                    Button { destination = target; showingRestoreConfirmation = true } label: {
                        VStack(alignment: .leading) {
                            Text(target.displayName)
                            if targets.count > 1 { Text(target.uuid).font(.caption.monospaced()).foregroundStyle(.secondary) }
                        }
                    }
                    .disabled(!model.canRunDiagnostics || target.identifier == Bundle.main.bundleIdentifier)
                }
                if targets.isEmpty { Text("No matching app container is available on this device.").foregroundStyle(.secondary) }
                Text("Close the target app first. Its current data receives a safety backup before restoration. App backups contain container files, not a complete device backup.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Delete Backup", systemImage: "trash", role: .destructive) { showingDeleteConfirmation = true }
                    .disabled(!model.canRunDiagnostics || !canDelete)
                if !canDelete { Text("This backup contains recovery work and cannot be deleted.").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(record.kind == .application ? Text("App Backup") : Text("Cache Recovery"))
        .confirmationDialog("Restore This Backup?", isPresented: $showingRestoreConfirmation, titleVisibility: .visible) {
            Button("Create Safety Backup and Restore", role: .destructive) {
                if let destination { Task { await model.restoreManagedBackup(record, to: destination) } }
            }
        } message: { Text(destination?.displayName ?? "") }
        .confirmationDialog("Delete This Backup?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete Backup", role: .destructive) { Task { if await model.deleteManagedBackup(record) { dismiss() } } }
        } message: { Text("This permanently removes this recovery copy from Veilpath. Export it first if you want to keep it.") }
    }
}

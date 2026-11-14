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
            Section {
                if model.isRunningDiagnostics || model.isVerifyingAccess {
                    ProgressView("Preparing App Access…")
                } else if model.isScanningStorage {
                    ProgressView(value: Double(model.storageScanCompleted), total: Double(max(1, model.storageScanTotal))) {
                        Text("Scanning \(model.storageScanAppName)")
                    }
                    Button("Stop Scan", role: .cancel) { model.cancelStorageScan() }
                } else {
                    Button("Scan App Storage", systemImage: "arrow.clockwise") { Task { await model.scanAppStorage() } }
                        .disabled(!model.canRunDiagnostics)
                }
                Text("Sizes are measured from readable app files. Partial scans are marked and cannot be used for cleaning.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Applications") {
                ForEach(applications) { container in
                    NavigationLink {
                        AppStorageDetailView(model: model, container: container)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(container.displayName)
                                Text(container.identifier ?? container.uuid).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let snapshot = model.appStorage[container.path] {
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(storageSize(snapshot.totalBytes)).monospacedDigit()
                                    if !snapshot.isComplete { Text("Partial Scan").font(.caption).foregroundStyle(.orange) }
                                }
                            } else if model.storageScanErrors[container.path] != nil {
                                Text("Unavailable").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("Not Scanned").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("App Storage")
        .searchable(text: $search, prompt: "App name or Bundle ID")
        .task(id: model.isRunningDiagnostics || model.isVerifyingAccess) {
            if model.appStorage.isEmpty && !model.isRunningDiagnostics && !model.isVerifyingAccess { await model.scanAppStorage() }
        }
    }
}

struct AppStorageDetailView: View {
    @Bindable var model: VeilpathModel
    let container: ContainerDescriptor
    @State private var includeTemporary = false
    @State private var showingCleanConfirmation = false

    private var snapshot: AppStorageSnapshot? { model.appStorage[container.path] }
    private var isOwnContainer: Bool { container.identifier == Bundle.main.bundleIdentifier }
    private var canClean: Bool {
        guard let snapshot else { return false }
        return snapshot.isComplete && !isOwnContainer
            && model.canRunDiagnostics && container.identifier != nil
            && snapshot.cacheBytes + (includeTemporary ? snapshot.temporaryBytes : 0) > 0
            && snapshot.cacheBytes + (includeTemporary ? snapshot.temporaryBytes : 0) <= Int64(UInt32.max)
    }

    var body: some View {
        List {
            Section {
                Text(container.displayName).font(.headline)
                Text(container.identifier ?? container.uuid).font(.caption).textSelection(.enabled)
            }
            if let snapshot {
                Section("Storage Breakdown") {
                    LabeledContent("Documents", value: storageSize(snapshot.documentsBytes))
                    LabeledContent("Library Data", value: storageSize(snapshot.libraryBytes))
                    LabeledContent("Caches", value: storageSize(snapshot.cacheBytes))
                    LabeledContent("Temporary Files", value: storageSize(snapshot.temporaryBytes))
                    LabeledContent("Other Files", value: storageSize(snapshot.otherBytes))
                    LabeledContent("Total File Size", value: storageSize(snapshot.totalBytes))
                    if !snapshot.isComplete { Text("This scan is incomplete. Cleaning is disabled.").foregroundStyle(.orange) }
                    if snapshot.skippedLinks > 0 { Text("Symbolic links were skipped. Selected cache folders are checked again before cleaning.").foregroundStyle(.secondary) }
                    Text(snapshot.scannedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                }
            } else if let error = model.storageScanErrors[container.path] {
                Section { Text(error).foregroundStyle(.secondary) }
            }
            Section("Recoverable Cache Cleaning") {
                Text("Caches are selected. Documents and app settings are kept.")
                Toggle("Include Temporary Files", isOn: $includeTemporary)
                if let snapshot, snapshot.cacheBytes + (includeTemporary ? snapshot.temporaryBytes : 0) > Int64(UInt32.max) {
                    Text("The selected caches exceed the 4 GB recovery archive limit.").foregroundStyle(.secondary)
                }
                Button("Back Up and Clean Caches", systemImage: "sparkles", role: .destructive) {
                    showingCleanConfirmation = true
                }
                .disabled(!canClean)
                Text("Close the target app first. Some cached downloads may need to be downloaded again. A verified recovery backup is kept in Backup Center.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let result = model.cacheCleaningResults[container.path] {
                Section("Last Cleanup") {
                    LabeledContent("Cache Data Removed", value: storageSize(result.processedBytes))
                    LabeledContent("Recovery Backup Size", value: storageSize(result.backup.archiveBytes))
                    if let freed = result.netFreedBytes { LabeledContent("Available Space Change", value: storageSize(freed)) }
                    Text("Recovery backups remain on this device. Available space is measured before and after the operation and can also change with other activity.")
                        .font(.caption).foregroundStyle(.secondary)
                    NavigationLink("Open Backup Center") { AppBackupsView(model: model) }
                }
            }
            Section {
                Button("Refresh Storage", systemImage: "arrow.clockwise") { Task { await model.scanStorage(for: container) } }
                    .disabled(!model.canRunDiagnostics)
                Button("Create App Backup", systemImage: "externaldrive.badge.plus") {
                    Task { await model.createManagedBackup(for: container) }
                }
                .disabled(!model.canRunDiagnostics || isOwnContainer || container.identifier == nil)
                if model.lastCreatedAppBackup?.container.path == container.path {
                    Label("App Backup Created", systemImage: "checkmark.circle").foregroundStyle(.green)
                }
                NavigationLink("Open Backup Center") { AppBackupsView(model: model) }
            }
        }
        .navigationTitle("App Storage")
        .confirmationDialog("Clean Selected Cache Folders?", isPresented: $showingCleanConfirmation, titleVisibility: .visible) {
            Button("Create Recovery Backup and Clean", role: .destructive) {
                Task { await model.cleanCaches(for: container, locations: includeTemporary ? [.caches, .temporary] : [.caches]) }
            }
        } message: {
            Text("Close this app before continuing. Veilpath verifies a backup before changing the selected cache folders. You can restore that backup from Backup Center.")
        }
        .task { if snapshot == nil { await model.scanStorage(for: container) } }
    }
}

struct AppBackupsView: View {
    @Bindable var model: VeilpathModel
    @State private var showingAppPicker = false
    @State private var showingImporter = false
    @State private var search = ""

    private var backups: [AppLibraryBackup] {
        model.managedBackups.filter {
            search.isEmpty || $0.container.displayName.localizedCaseInsensitiveContains(search)
                || ($0.container.identifier?.localizedCaseInsensitiveContains(search) ?? false)
        }
    }

    var body: some View {
        List {
            Section {
                Button("Create App Backup", systemImage: "externaldrive.badge.plus") { showingAppPicker = true }
                    .disabled(!model.canRunDiagnostics)
                Button("Import Backup", systemImage: "square.and.arrow.down") { showingImporter = true }
                    .disabled(!model.canRunDiagnostics)
                Text("App backups and cache recovery backups are kept here without automatic expiry. They are verified again before restoration and can be exported individually.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if backups.isEmpty {
                ContentUnavailableView("No App Backups", systemImage: "externaldrive", description: Text("Create an app backup or clean caches to keep a recovery copy here."))
            } else {
                Section("Backups") {
                    ForEach(backups) { record in
                        NavigationLink { AppBackupDetailView(model: model, record: record) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(record.container.displayName).font(.headline)
                                if record.reason == .beforeRestore {
                                    Text("Before Restore").font(.caption).foregroundStyle(.secondary)
                                }
                                HStack {
                                    Text(record.kind == .application ? LocalizedStringResource("App Backup") : LocalizedStringResource("Cache Recovery"))
                                    Spacer()
                                    Text(storageSize(record.archiveBytes))
                                }.font(.caption).foregroundStyle(.secondary)
                                Text(record.createdAt, format: .dateTime).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Backup Center")
        .searchable(text: $search, prompt: "App name or Bundle ID")
        .task { model.reloadManagedBackups() }
        .refreshable { model.reloadManagedBackups() }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.zip]) { result in
            switch result {
            case .success(let url): Task { await model.importManagedBackup(from: url) }
            case .failure(let error): model.lastError = error.localizedDescription
            }
        }
        .sheet(isPresented: $showingAppPicker) {
            NavigationStack {
                List(model.containers) { container in
                    Button {
                        showingAppPicker = false
                        Task { await model.createManagedBackup(for: container) }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(container.displayName)
                            Text(container.identifier ?? container.uuid).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(container.identifier == nil || container.identifier == Bundle.main.bundleIdentifier)
                }
                .navigationTitle("Choose an App")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingAppPicker = false } } }
            }
        }
    }
}

private struct AppBackupDetailView: View {
    @Bindable var model: VeilpathModel
    let record: AppLibraryBackup
    @State private var destination: ContainerDescriptor?
    @State private var showingRestoreConfirmation = false
    private var targets: [ContainerDescriptor] { model.containers.filter { $0.identifier == record.container.identifier } }

    var body: some View {
        List {
            if model.lastRestoredAppBackupID == record.id {
                Section {
                    Label("Backup Restored", systemImage: "checkmark.circle").foregroundStyle(.green)
                    Text("The previous contents were saved in a safety backup before restoration.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Backup Details") {
                LabeledContent("Application", value: record.container.displayName)
                LabeledContent("Bundle Identifier", value: record.container.identifier ?? "")
                LabeledContent("Created") { Text(record.createdAt, format: .dateTime) }
                LabeledContent("Archive Size", value: storageSize(record.archiveBytes))
                LabeledContent("Payload Size", value: storageSize(record.payloadBytes))
                if let count = record.skippedSymbolicLinks, count > 0 {
                    LabeledContent("Skipped Symbolic Links") { Text(count, format: .number) }
                }
                Text(record.archiveSHA256).font(.caption.monospaced()).textSelection(.enabled)
            }
            Section {
                Button("Export Backup", systemImage: "square.and.arrow.up") { model.exportManagedBackup(record) }
                    .disabled(!model.canRunDiagnostics)
            }
            Section("Restore to Application") {
                ForEach(targets) { target in
                    Button {
                        destination = target; showingRestoreConfirmation = true
                    } label: {
                        VStack(alignment: .leading) {
                            Text(target.displayName)
                            Text(target.uuid).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!model.canRunDiagnostics || target.identifier == Bundle.main.bundleIdentifier)
                }
                if targets.isEmpty { Text("No matching app container is available on this device.").foregroundStyle(.secondary) }
                Text("Close the target app first. Its current data receives a safety backup before restoration. App backups contain container files, not a complete device backup.")
                    .font(.caption).foregroundStyle(.secondary)
                if record.kind == .application {
                    Text("Symbolic links are not included in app backups.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(record.kind == .application ? Text("App Backup") : Text("Cache Recovery"))
        .confirmationDialog("Restore This Backup?", isPresented: $showingRestoreConfirmation, titleVisibility: .visible) {
            Button("Create Safety Backup and Restore", role: .destructive) {
                if let destination { Task { await model.restoreManagedBackup(record, to: destination) } }
            }
        } message: { Text(destination?.path ?? "") }
    }
}

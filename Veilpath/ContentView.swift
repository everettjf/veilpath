import SwiftUI
import UIKit
import UniformTypeIdentifiers
import PDFKit
import QuickLook

private enum AppSection: Hashable { case applications, backups, settings }

struct ContentView: View {
    @Bindable var model: VeilpathModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showInspector = false
    @State private var presentedPreview: FileItem?
    @State private var previewWidthFraction: CGFloat = 0.75
    @State private var previewIsFullScreen = false
    @State private var previewDragStartFraction: CGFloat?
    @State private var showingReplacementImporter = false
    @State private var pendingReplacementURL: URL?
    @State private var showingReplacementConfirmation = false
    @State private var pendingRestore: FileBackupRecord?
    @State private var showingRestoreConfirmation = false
    @State private var editingItem: FileItem?
    @State private var section = AppSection.applications

    var body: some View {
        GeometryReader { geometry in
            TabView(selection: $section) {
                Tab("Applications", systemImage: "square.stack", value: .applications) {
                    ZStack(alignment: .trailing) {
                        NavigationStack { AppStorageView(model: model) }
                            .opacity(model.currentContainerRoot.isEmpty ? 1 : 0)
                            .allowsHitTesting(model.currentContainerRoot.isEmpty)
                            .accessibilityHidden(!model.currentContainerRoot.isEmpty)
                            .zIndex(0)
                        if !model.currentContainerRoot.isEmpty {
                            workspace
                                .transition(workspaceTransition)
                                .zIndex(1)
                        }

                        if let presentedPreview {
                            FilePreviewOverlay(
                                item: presentedPreview,
                                preview: model.selectedPreview,
                                previewError: model.previewError,
                                exportURL: model.selectedExportURL,
                                hexDump: model.selectedHexDump,
                                isLoading: model.isLoadingPreview,
                                allowsAdvancedTools: model.isAdvancedWorkspace,
                                availableWidth: geometry.size.width,
                                allowsResizing: horizontalSizeClass != .compact,
                                widthFraction: $previewWidthFraction,
                                isFullScreen: $previewIsFullScreen,
                                dragStartFraction: $previewDragStartFraction,
                                requestShare: { model.prepareShare(for: presentedPreview) },
                                showInfo: { showInspector = true },
                                close: closePreview
                            )
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                            .zIndex(10)

                            if horizontalSizeClass != .compact, !previewIsFullScreen {
                                PreviewFileList(
                                    model: model,
                                    presentedPreview: $presentedPreview
                                )
                                .frame(width: geometry.size.width * (1 - previewWidthFraction))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .transition(.opacity)
                                .zIndex(11)
                            }
                        }
                    }
                    .animation(.snappy, value: model.currentContainerRoot.isEmpty)
                    .animation(.snappy, value: presentedPreview?.id)
                    .animation(.snappy, value: previewIsFullScreen)
                    .toolbar(model.currentContainerRoot.isEmpty ? .visible : .hidden, for: .tabBar)
                }
                Tab("Backups", systemImage: "externaldrive", value: .backups) {
                    NavigationStack { AppBackupsView(model: model) }
                }
                Tab("Settings", systemImage: "gearshape", value: .settings) {
                    NavigationStack { SettingsView(model: model) }
                }
            }
            .tabViewStyle(.sidebarAdaptable)
        }
        .onChange(of: model.currentContainerRoot) { _, root in
            if !root.isEmpty {
                closePreview()
                showInspector = false
                section = .applications
            }
        }
        .onChange(of: presentedPreview) { _, item in
            if item != nil, horizontalSizeClass == .compact {
                previewIsFullScreen = true
            }
        }
        .onChange(of: model.selectedPreview) { _, preview in
            #if targetEnvironment(simulator)
            if preview != nil,
               ProcessInfo.processInfo.arguments.contains("--ui-testing-preview"),
               let item = model.selectedItem {
                showInspector = false
                presentedPreview = item
            }
            #endif
        }
        .alert("Operation Failed", isPresented: errorPresented) {
            Button("OK") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? String(localized: "Unknown error"))
        }
        .sheet(isPresented: $showInspector) {
            NavigationStack {
                inspectorContent
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showInspector = false }
                        }
                    }
            }
        }
        .sheet(item: $editingItem) { item in
            NavigationStack {
                SafeStructuredEditorView(item: item) {
                    editingItem = nil
                    Task { await model.finishedEditing(item) }
                }
            }
        }
        .sheet(item: $model.sharePreparation, onDismiss: model.cancelSharePreparation) { _ in
            SharePreparationView(model: model)
        }
        .fileImporter(isPresented: $showingReplacementImporter, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url):
                pendingReplacementURL = url
                showingReplacementConfirmation = true
            case .failure(let error): model.lastError = error.localizedDescription
            }
        }
        .confirmationDialog("Replace Selected File?", isPresented: $showingReplacementConfirmation) {
            Button("Back Up and Replace", role: .destructive) {
                guard let pendingReplacementURL else { return }
                Task { await model.replaceSelectedFile(with: pendingReplacementURL) }
                self.pendingReplacementURL = nil
            }
            Button("Cancel", role: .cancel) { pendingReplacementURL = nil }
        } message: {
            Text("The original file will be backed up and verified before replacement.")
        }
        .confirmationDialog("Restore This Backup?", isPresented: $showingRestoreConfirmation) {
            Button("Create Safety Backup and Restore", role: .destructive) {
                guard let pendingRestore else { return }
                Task { await model.restore(pendingRestore) }
                self.pendingRestore = nil
            }
            Button("Cancel", role: .cancel) { pendingRestore = nil }
        } message: {
            Text("The current file will receive its own safety backup before restoration.")
        }
        .overlay(alignment: .bottom) {
            if model.isRunningFileOperation {
                FileOperationProgressBanner(model: model)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .zIndex(101)
            }
        }
        .onAppear {
            #if targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-settings") { section = .settings }
            #endif
        }
    }

    private var workspaceTransition: AnyTransition {
        guard horizontalSizeClass == .compact else { return .opacity }
        return .move(edge: .trailing).combined(with: .opacity)
    }

    @ViewBuilder
    private var workspace: some View {
        if horizontalSizeClass == .compact {
            NavigationStack {
                BrowserView(
                    model: model,
                    presentedPreview: $presentedPreview,
                    opensPreviewImmediately: true,
                    closeWorkspace: closeWorkspace
                )
            }
        } else {
            NavigationSplitView {
                BrowserView(
                    model: model,
                    presentedPreview: $presentedPreview,
                    opensPreviewImmediately: false,
                    closeWorkspace: closeWorkspace
                )
                .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 520)
            } detail: {
                if model.selectedItem == nil {
                    ContentUnavailableView(
                        "Select a File",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Choose a file to inspect its properties or open a preview.")
                    )
                } else {
                    inspectorContent
                }
            }
            .navigationSplitViewStyle(.balanced)
        }
    }

    private var inspectorContent: some View {
        InspectorView(
            item: model.selectedItem,
            exportURL: model.selectedExportURL,
            properties: model.selectedProperties,
            isLoading: model.isLoadingPreview,
            allowsAdvancedTools: model.isAdvancedWorkspace,
            openPreview: {
                showInspector = false
                openSelectedPreview()
            },
            requestReplacement: requestReplacement,
            requestShare: { requestShare(model.selectedItem) },
            canEdit: canEditSelectedFile,
            requestEdit: requestSafeEdit,
            backups: selectedBackups,
            requestRestore: requestRestore
        )
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } }
        )
    }

    private func openSelectedPreview() {
        guard let item = model.selectedItem else { return }
        showInspector = false
        presentedPreview = item
    }

    private func closePreview() {
        presentedPreview = nil
        previewIsFullScreen = false
        previewDragStartFraction = nil
    }

    private func closeWorkspace() {
        let wasAdvanced = model.isAdvancedWorkspace
        closePreview()
        showInspector = false
        model.closeCurrentContainer()
        if wasAdvanced { section = .settings }
    }

    private func requestReplacement() {
        showInspector = false
        Task { @MainActor in
            await Task.yield()
            showingReplacementImporter = true
        }
    }

    private func requestSafeEdit() {
        let item = model.selectedItem
        showInspector = false
        Task { @MainActor in
            await Task.yield()
            editingItem = item
        }
    }

    private func requestShare(_ item: FileItem?) {
        guard let item else { return }
        showInspector = false
        Task { @MainActor in
            await Task.yield()
            model.prepareShare(for: item)
        }
    }

    private func requestRestore(_ record: FileBackupRecord) {
        showInspector = false
        pendingRestore = record
        Task { @MainActor in
            await Task.yield()
            showingRestoreConfirmation = true
        }
    }

    private var selectedBackups: [FileBackupRecord] {
        guard let path = model.selectedItem?.url.path else { return [] }
        return model.backupRecords.filter { $0.manifest.targetPath == path }
    }

    private var canEditSelectedFile: Bool {
        guard let item = model.selectedItem, !item.isDirectory else { return false }
        if ["json", "plist"].contains(item.url.pathExtension.lowercased()) { return true }
        if case .structured(_, _, let format)? = model.selectedPreview {
            return format == "JSON" || format.contains("Plist")
        }
        return false
    }

}

private struct PreviewFileList: View {
    @Bindable var model: VeilpathModel
    @Binding var presentedPreview: FileItem?

    var body: some View {
        NavigationStack {
            List(model.items) { item in
                Button {
                    Task {
                        await model.open(item)
                        if !item.isDirectory, model.selectedItem == item {
                            presentedPreview = item
                        }
                    }
                } label: {
                    FileRow(item: item, directorySummary: model.directorySummaries[item.url.path])
                }
                .buttonStyle(.plain)
                .listRowBackground(model.selectedItem == item ? Color.accentColor.opacity(0.12) : Color.clear)
            }
            .listStyle(.plain)
            .navigationTitle("Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Up", systemImage: "arrow.up") {
                        Task { await model.goUp() }
                    }
                    .labelStyle(.iconOnly)
                    .disabled(model.isWorking || model.path == "/")
                }
            }
        }
        .background(.background)
        .overlay(alignment: .trailing) { Divider() }
    }
}

private struct SettingsView: View {
    @Bindable var model: VeilpathModel
    @State private var cacheMessage: String?

    var body: some View {
        List {
            Section {
                HStack { Text("Access"); Spacer(); AccessStateLabel(model: model) }
                NavigationLink {
                    AdvancedToolsView(model: model)
                } label: { Label("Advanced Tools", systemImage: "wrench.and.screwdriver") }
            }
            Section("Storage") {
                Button("Clear Export Cache", systemImage: "trash", role: .destructive) {
                    do { try ExportCache.removeAll(); cacheMessage = String(localized: "Export cache cleared") }
                    catch { model.lastError = error.localizedDescription }
                }
                .disabled(!model.canRunDiagnostics)
                if let cacheMessage { Text(cacheMessage).foregroundStyle(.secondary) }
                Text("Shared files are copied to a private cache and automatically removed after 24 hours.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown")
                Link("Report an Issue", destination: FeedbackSupport.issueURL())
                Link("Veilpath Website", destination: URL(string: "https://xnu.app/veilpath/")!)
                Link("Source Code", destination: URL(string: "https://github.com/everettjf/veilpath")!)
                Link("Discord", destination: URL(string: "https://discord.gg/eGzEaP6TzR")!)
            }
        }
        .navigationTitle("Settings")
    }
}

private struct AdvancedToolsView: View {
    @Bindable var model: VeilpathModel
    var body: some View {
        List {
            Section {
                NavigationLink {
                    DiagnosticsView(model: model, showsDismissButton: false)
                } label: { Label("Diagnostics and Logs", systemImage: "waveform.path.ecg") }
                Button("Verify Access", systemImage: "checkmark.shield") { Task { await model.verifyAccess() } }
                    .disabled(!model.canRunDiagnostics)
                Text("Advanced workspaces include technical previews and guarded file operations.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Containers") {
                ForEach(ContainerKind.allCases, id: \.self) { kind in
                    NavigationLink {
                        AdvancedContainerList(model: model, kind: kind)
                    } label: { Label(kind.localizedName, systemImage: kind.systemImage) }
                }
            }
        }
        .navigationTitle("Advanced Tools")
    }
}

private struct AdvancedContainerList: View {
    @Bindable var model: VeilpathModel
    let kind: ContainerKind
    @State private var search = ""
    private var containers: [ContainerDescriptor] {
        model.containerIndexes[kind, default: []].filter {
            search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search)
                || ($0.identifier?.localizedCaseInsensitiveContains(search) ?? false)
                || $0.uuid.localizedCaseInsensitiveContains(search)
        }
    }
    var body: some View {
        List(containers) { container in
            Button { Task { await model.open(container, advanced: true) } } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(container.displayName)
                    Text(container.uuid).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            .disabled(!model.canRunDiagnostics)
        }
        .navigationTitle(Text(kind.localizedName))
        .searchable(text: $search, prompt: "Container name or UUID")
        .overlay { if containers.isEmpty { ContentUnavailableView("No containers indexed", systemImage: "folder") } }
        .refreshable { await model.refreshContainers(for: kind) }
        .task { if model.containerIndexes[kind, default: []].isEmpty && model.canRunDiagnostics { await model.refreshContainers(for: kind) } }
    }
}

private struct AccessStatusView: View {
    let model: VeilpathModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.callout.weight(.medium))
                Text(statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var statusIcon: String {
        if model.isAccessVerificationPending { return "shield.lefthalf.filled.badge.checkmark" }
        if model.accessVerification == nil { return "shield.slash" }
        return "exclamationmark.shield.fill"
    }

    private var statusColor: Color {
        if model.isAccessVerificationPending { return .secondary }
        if model.accessVerification == nil { return .secondary }
        return .orange
    }

    private var statusTitle: LocalizedStringResource {
        if model.isAccessVerificationPending { return "Verifying access…" }
        if model.accessVerification == nil { return "Access not verified" }
        return "Access verification failed"
    }

    private var statusDetail: LocalizedStringResource {
        if model.isAccessVerificationPending { return "Testing application container access" }
        if model.accessVerification == nil { return "Run the access check from Settings" }
        return "Open Settings to review diagnostics"
    }
}

private struct BrowserView: View {
    @Bindable var model: VeilpathModel
    @Binding var presentedPreview: FileItem?
    let opensPreviewImmediately: Bool
    let closeWorkspace: () -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @FocusState private var pathFocused: Bool
    @State private var showFileSearch = false
    @State private var fileFilter = ""
    @State private var pathInput = ""
    @State private var isEditingPath = false
    @State private var showingDeleteConfirmation = false

    private var visibleItems: [FileItem] {
        guard !fileFilter.isEmpty else { return model.items }
        return model.items.filter { $0.name.localizedCaseInsensitiveContains(fileFilter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !model.path.isEmpty {
                Group {
                    if horizontalSizeClass == .compact {
                        compactNavigationHeader
                    } else {
                        regularPathHeader
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, horizontalSizeClass == .compact ? 8 : 16)

                Divider()
            }

            if model.isWorking && model.items.isEmpty {
                ProgressView("Requesting access…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.items.isEmpty {
                if model.path.isEmpty {
                    ContentUnavailableView(
                        "Choose a Container",
                        systemImage: "sidebar.left",
                        description: Text("Select a container in the sidebar to browse its files.")
                    )
                } else {
                    ContentUnavailableView(
                        "Empty Directory",
                        systemImage: "folder",
                        description: Text("This directory does not contain any visible items.")
                    )
                }
            } else {
                List(visibleItems) { item in
                    Button {
                        if model.isSelectingFiles {
                            model.toggleFileSelection(item)
                        } else {
                            Task {
                                await model.open(item)
                                if opensPreviewImmediately,
                                   !item.isDirectory,
                                   model.selectedItem == item {
                                    presentedPreview = item
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            if model.isSelectingFiles {
                                Image(systemName: model.selectedFilePaths.contains(item.url.path) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(model.selectedFilePaths.contains(item.url.path) ? Color.accentColor : .secondary)
                            }
                            FileRow(item: item, directorySummary: model.directorySummaries[item.url.path])
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground((model.selectedItem == item || model.selectedFilePaths.contains(item.url.path)) ? Color.accentColor.opacity(0.12) : Color.clear)
                    .accessibilityAddTraits((model.selectedItem == item || model.selectedFilePaths.contains(item.url.path)) ? .isSelected : [])
                    .contextMenu {
                        if model.isAdvancedWorkspace {
                            Button("Select", systemImage: "checkmark.circle") { model.beginFileSelection(with: item) }
                        }
                        Button(item.isDirectory ? "Share Folder as ZIP" : "Share File",
                               systemImage: item.isDirectory ? "archivebox" : "square.and.arrow.up") {
                            model.prepareShare(for: item)
                        }
                        if model.isAdvancedWorkspace && !item.isSymbolicLink {
                            Button("Duplicate", systemImage: "plus.square.on.square") { Task { await model.duplicate(item) } }
                        }
                        if model.isAdvancedWorkspace, !item.isDirectory, ["zip", "ipa"].contains(item.url.pathExtension.lowercased()) {
                            Button("Extract Here", systemImage: "archivebox.badge.plus") { Task { await model.extract(item) } }
                        }
                    }
                }
                .listStyle(.plain)
                .refreshable { await model.refresh() }
                .overlay {
                    if visibleItems.isEmpty {
                        ContentUnavailableView.search(text: fileFilter)
                    }
                }
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if horizontalSizeClass == .compact {
                    Button("Applications", systemImage: "chevron.backward", action: closeWorkspace)
                        .labelStyle(.iconOnly)
                } else {
                    Button("Applications", systemImage: "chevron.backward", action: closeWorkspace)
                }
            }
            if horizontalSizeClass != .compact && !model.path.isEmpty {
                ToolbarItemGroup(placement: .topBarLeading) {
                    toolbarNavigationButton("Back", systemImage: "chevron.backward", disabled: !model.canGoBack) {
                        await model.goBack()
                    }
                    toolbarNavigationButton("Forward", systemImage: "chevron.forward", disabled: !model.canGoForward) {
                        await model.goForward()
                    }
                    toolbarNavigationButton("Up", systemImage: "arrow.up", disabled: model.isWorking || model.path == "/" || (!model.isAdvancedWorkspace && model.path == model.currentContainerRoot)) {
                        await model.goUp()
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if model.isSelectingFiles {
                    Button("Done") { model.cancelFileSelection() }
                } else if model.path.isEmpty {
                    if model.isWorking { ProgressView() }
                } else {
                    Menu("View Options", systemImage: "ellipsis.circle") {
                        Label("\(visibleItems.count) items", systemImage: "doc.on.doc")
                        Divider()
                        Button("Search This Container", systemImage: "magnifyingglass") { showFileSearch = true }
                        Menu("Sort By", systemImage: "arrow.up.arrow.down") {
                            Picker("Sort By", selection: $model.fileSortOrder) {
                                ForEach(FileSortOrder.allCases) { order in
                                    Text(order.localizedName).tag(order)
                                }
                            }
                        }
                        if model.isAdvancedWorkspace { Toggle("Show Hidden Files", isOn: $model.showHiddenFiles) }
                        Divider()
                        Button("Share Folder as ZIP", systemImage: "archivebox") {
                            model.prepareCurrentDirectoryZIP()
                        }
                        .disabled(model.isPreparingShare)
                        Divider()
                        if model.isAdvancedWorkspace { Button("Select Items", systemImage: "checkmark.circle") { model.beginFileSelection() } }
                        if model.isAdvancedWorkspace && model.fileClipboard != nil {
                            Button("Paste", systemImage: "doc.on.clipboard") { Task { await model.pasteFiles() } }
                                .disabled(model.isRunningFileOperation)
                        }
                    }
                    .onChange(of: model.showHiddenFiles) {
                        Task { await model.refresh() }
                    }
                    .onChange(of: model.fileSortOrder) {
                        Task { await model.refresh() }
                    }
                }
            }
        }
        .searchable(text: $fileFilter, placement: .toolbar, prompt: "Filter Current Directory")
        .searchToolbarBehavior(.minimize)
        .sheet(isPresented: $showFileSearch) { ContainerSearchView(model: model) }
        .confirmationDialog("Delete Selected Items?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("Back Up and Delete", role: .destructive) { Task { await model.deleteSelectedFiles() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A recoverable ZIP safety archive will be created before deletion.")
        }
        .safeAreaInset(edge: .bottom) {
            if model.isSelectingFiles {
                FileSelectionBar(model: model, showDeleteConfirmation: $showingDeleteConfirmation)
            }
        }
        .onChange(of: model.path, initial: true) { _, newPath in
            if !pathFocused { pathInput = newPath }
        }
    }

    private var navigationTitle: String {
        guard !model.path.isEmpty else { return String(localized: "Files") }
        if horizontalSizeClass == .compact { return String(localized: "Files") }
        guard model.path != model.currentContainerRoot else {
            guard let container = model.selectedContainer else { return String(localized: "Files") }
            return container.identifier?.split(separator: ".").last.map(String.init) ?? container.displayName
        }
        return URL(fileURLWithPath: model.path).lastPathComponent
    }

    private var regularPathHeader: some View {
        Group {
            if !model.isAdvancedWorkspace {
                Text(relativePath).font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if isEditingPath {
                HStack(spacing: 10) {
                    pathEntry
                }
            } else {
                pathDisplay
            }
        }
    }

    private var compactNavigationHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                compactNavigationButton("Back", systemImage: "chevron.backward", disabled: !model.canGoBack) {
                    await model.goBack()
                }
                compactNavigationButton("Forward", systemImage: "chevron.forward", disabled: !model.canGoForward) {
                    await model.goForward()
                }
                compactNavigationButton("Up", systemImage: "arrow.up", disabled: model.isWorking || model.path == "/" || (!model.isAdvancedWorkspace && model.path == model.currentContainerRoot)) {
                    await model.goUp()
                }
                Spacer()
                Text("\(visibleItems.count) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !model.isAdvancedWorkspace {
                Text(relativePath).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if isEditingPath {
                HStack(spacing: 10) {
                    pathEntry
                }
            } else {
                pathDisplay
            }
        }
    }

    private var pathDisplay: some View {
        Button {
            isEditingPath = true
            pathFocused = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(model.path)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text("\(visibleItems.count) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "pencil")
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 32)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Edit the absolute path")
    }

    private var relativePath: String {
        if model.path == model.currentContainerRoot { return model.selectedContainer?.displayName ?? String(localized: "Files") }
        let prefix = model.currentContainerRoot + "/"
        return model.path.hasPrefix(prefix) ? String(model.path.dropFirst(prefix.count)) : URL(fileURLWithPath: model.path).lastPathComponent
    }

    private func compactNavigationButton(
        _ title: LocalizedStringKey,
        systemImage: String,
        disabled: Bool,
        action: @escaping @MainActor () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .disabled(disabled)
    }

    private func toolbarNavigationButton(
        _ title: LocalizedStringKey,
        systemImage: String,
        disabled: Bool,
        action: @escaping @MainActor () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            Label(title, systemImage: systemImage)
        }
        .labelStyle(.iconOnly)
        .disabled(disabled)
    }

    @ViewBuilder private var pathEntry: some View {
                    TextField("Absolute path", text: $pathInput)
                        .font(.system(.callout, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($pathFocused)
                        .onSubmit { openPathInput() }

                    Button("Open", systemImage: "arrow.right.circle.fill") {
                        pathFocused = false
                        openPathInput()
                    }
                    .labelStyle(.iconOnly)
                    .disabled(model.isWorking)
    }

    private func openPathInput() {
        pathFocused = false
        Task {
            await model.openEnteredPath(pathInput)
            pathInput = model.path
            isEditingPath = false
        }
    }
}

private struct FileSelectionBar: View {
    @Bindable var model: VeilpathModel
    @Binding var showDeleteConfirmation: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button("Select All", systemImage: "checkmark.circle") { model.selectAllFiles() }
                .labelStyle(.iconOnly)
                .disabled(model.isRunningFileOperation)
            Divider().frame(height: 24)
            Button("Copy", systemImage: "doc.on.doc") { model.copySelectedFiles(mode: .copy) }
                .disabled(model.selectedFilePaths.isEmpty || model.isRunningFileOperation)
            Button("Cut", systemImage: "scissors") { model.copySelectedFiles(mode: .cut) }
                .disabled(model.selectedFilePaths.isEmpty || model.isRunningFileOperation)
            Button("Compress", systemImage: "archivebox") { Task { await model.compressSelectedFiles() } }
                .disabled(model.selectedFilePaths.isEmpty || model.isRunningFileOperation)
            Spacer()
            Text("\(model.selectedFilePaths.count) selected")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button("Delete", systemImage: "trash", role: .destructive) { showDeleteConfirmation = true }
                .labelStyle(.iconOnly)
                .disabled(model.selectedFilePaths.isEmpty || model.isRunningFileOperation)
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct FileOperationProgressBanner: View {
    @Bindable var model: VeilpathModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProgressView()
                if let title = model.fileOperationTitle {
                    Text(title).font(.subheadline.weight(.semibold))
                } else {
                    Text("Working…").font(.subheadline.weight(.semibold))
                }
                Spacer()
                if let progress = model.fileOperationProgress, progress.totalItems > 0 {
                    Text("\(progress.completedItems)/\(progress.totalItems)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button("Cancel", role: .cancel) { model.cancelFileOperation() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            if let progress = model.fileOperationProgress, progress.totalBytes > 0 {
                ProgressView(value: Double(progress.completedBytes), total: Double(progress.totalBytes))
            }
        }
        .padding(14)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .shadow(radius: 12, y: 4)
        .frame(maxWidth: 560)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Cancel") { model.cancelFileOperation() }
    }
}

private struct FileRow: View {
    let item: FileItem
    let directorySummary: DirectoryContentsSummary?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.systemImage)
                .foregroundStyle(item.isDirectory ? .blue : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                if item.isDirectory {
                    if let directorySummary {
                        DirectorySummaryLabel(summary: directorySummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    fileMetadata
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if item.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var fileMetadata: some View {
        if let size = item.size, let modifiedAt = item.modifiedAt {
            Text("\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) · Modified \(modifiedAt.formatted(.dateTime.year().month().day().hour().minute()))")
                .lineLimit(2)
        } else if let size = item.size {
            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        } else if let modifiedAt = item.modifiedAt {
            Text("Modified \(modifiedAt.formatted(.dateTime.year().month().day().hour().minute()))")
                .lineLimit(2)
        }
    }
}

private struct DirectorySummaryLabel: View {
    let summary: DirectoryContentsSummary

    var body: some View {
        if summary.isEmpty {
            Text("Empty")
        } else {
            HStack(spacing: 3) {
                if summary.folderCount > 0 {
                    Text(summary.folderCount, format: .number)
                    if summary.folderCount == 1 { Text("folder") } else { Text("folders") }
                }
                if summary.folderCount > 0, summary.fileCount > 0 {
                    Text("·")
                        .padding(.horizontal, 2)
                }
                if summary.fileCount > 0 {
                    Text(summary.fileCount, format: .number)
                    if summary.fileCount == 1 { Text("file") } else { Text("files") }
                }
            }
        }
    }
}

private struct SharePreparationView: View {
    @Bindable var model: VeilpathModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let preparation = model.sharePreparation {
                    VStack(spacing: 22) {
                        Image(systemName: stateImage(preparation.state))
                            .font(.system(size: 44))
                            .foregroundStyle(stateColor(preparation.state))
                            .accessibilityHidden(true)
                        VStack(spacing: 6) {
                            Text(preparation.request.title)
                                .font(.headline)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                            Text(statusText(preparation))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        progressView(preparation.progress, state: preparation.state)
                            .frame(maxWidth: 420)
                        actions(preparation)
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("Share Preparation Ended", systemImage: "square.and.arrow.up")
                }
            }
            .navigationTitle("Prepare to Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.isPreparingShare ? "Cancel" : "Done") {
                        model.cancelSharePreparation()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(model.isPreparingShare)
    }

    @ViewBuilder
    private func progressView(_ progress: ShareExportProgress, state: SharePreparation.State) -> some View {
        if case .preparing = state {
            VStack(spacing: 8) {
                if progress.totalBytes > 0 {
                    ProgressView(value: Double(progress.completedBytes), total: Double(progress.totalBytes))
                    HStack {
                        Text(ByteCountFormatter.string(fromByteCount: progress.completedBytes, countStyle: .file))
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
                if progress.totalItems > 1 {
                    Text("\(progress.completedItems) of \(progress.totalItems) items")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Export progress")
            .accessibilityValue(progress.totalBytes > 0
                                ? "\(Int(Double(progress.completedBytes) / Double(progress.totalBytes) * 100)) percent"
                                : "Preparing")
        }
    }

    @ViewBuilder
    private func actions(_ preparation: SharePreparation) -> some View {
        switch preparation.state {
        case .preparing:
            Button("Cancel Export", role: .cancel) {
                model.cancelSharePreparation()
                dismiss()
            }
            .buttonStyle(.bordered)
        case .ready(let url, _):
            ShareLink(item: ExportedFile(url: url), preview: SharePreview(url.lastPathComponent)) {
                Label("Open Share Sheet", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: 280)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        case .failed:
            Button("Try Again", systemImage: "arrow.clockwise") { model.retrySharePreparation() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func statusText(_ preparation: SharePreparation) -> String {
        switch preparation.state {
        case .preparing:
            switch preparation.progress.phase {
            case .preparing: "Inspecting source…"
            case .copying: "Copying to a protected share cache…"
            case .archiving: "Building ZIP archive…"
            case .finalizing: "Verifying export…"
            }
        case .ready(_, let detail): "Ready to share · \(detail)"
        case .failed(let message): message
        }
    }

    private func stateImage(_ state: SharePreparation.State) -> String {
        switch state { case .preparing: "arrow.down.doc"; case .ready: "checkmark.circle.fill"; case .failed: "exclamationmark.triangle.fill" }
    }

    private func stateColor(_ state: SharePreparation.State) -> Color {
        switch state { case .preparing: .accentColor; case .ready: .green; case .failed: .orange }
    }
}

private struct InspectorView: View {
    let item: FileItem?
    let exportURL: URL?
    let properties: FileProperties?
    let isLoading: Bool
    let allowsAdvancedTools: Bool
    let openPreview: () -> Void
    let requestReplacement: () -> Void
    let requestShare: () -> Void
    let canEdit: Bool
    let requestEdit: () -> Void
    let backups: [FileBackupRecord]
    let requestRestore: (FileBackupRecord) -> Void
    @State private var showVersionHistory = false

    var body: some View {
        if let item {
            VStack(spacing: 0) {
                FilePropertiesView(item: item, properties: properties, allowsAdvancedTools: allowsAdvancedTools)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if allowsAdvancedTools {
                  Divider()
                  HStack {
                    if canEdit {
                        Button("Edit Safely", systemImage: "pencil.and.outline", action: requestEdit)
                            .disabled(isLoading)
                    }
                    Button("Back Up and Replace", systemImage: "arrow.triangle.2.circlepath", action: requestReplacement)
                        .disabled(isLoading)
                    Spacer()
                    if !backups.isEmpty {
                        Button("Version History", systemImage: "clock.arrow.circlepath") { showVersionHistory = true }
                    }
                }
                .padding()
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Open Preview", systemImage: "doc.text.magnifyingglass", action: openPreview)
                Button("Share", systemImage: "square.and.arrow.up", action: requestShare)
                    .disabled(isLoading)
                if allowsAdvancedTools {
                  Menu("File Actions", systemImage: "doc.badge.gearshape") {
                    if let hash = properties?.sha256 { Button("Copy SHA-256", systemImage: "number") { UIPasteboard.general.string = hash } }
                    Button("Copy Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = item.url.path }
                }
                }
            }
            .sheet(isPresented: $showVersionHistory) {
                NavigationStack {
                    VersionHistoryView(records: backups) { record in
                        showVersionHistory = false
                        requestRestore(record)
                    }
                }
            }
        } else {
            ContentUnavailableView("Select a File", systemImage: "doc.text.magnifyingglass")
        }
    }
}

private struct SafeStructuredEditorView: View {
    let item: FileItem
    let completed: () -> Void
    @State private var session: StructuredEditSession?
    @State private var text = ""
    @State private var status = "Preparing a protected draft…"
    @State private var error: String?
    @State private var showSaveConfirmation = false
    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if session != nil {
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, 6)
                    .safeAreaInset(edge: .bottom) {
                        HStack {
                            Image(systemName: "lock.shield")
                            Text(status)
                            Spacer()
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal).padding(.vertical, 8)
                        .background(.bar)
                    }
                    .onChange(of: text) { _, value in
                        guard let session else { return }
                        status = "Draft has unsaved changes"
                        Task.detached(priority: .utility) { try? SafeStructuredEditor.updateDraft(session, text: value) }
                    }
            } else if let error {
                ContentUnavailableView("Cannot Edit This File", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView(status)
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    if let session { SafeStructuredEditor.discard(session) }
                    dismiss()
                }
            }
            ToolbarItemGroup(placement: .confirmationAction) {
                Button("Validate") { validate() }.disabled(session == nil || isSaving)
                Button("Save") { validateAndConfirm() }.disabled(session == nil || isSaving)
            }
        }
        .task { await prepare() }
        .confirmationDialog("Save This Version?", isPresented: $showSaveConfirmation, titleVisibility: .visible) {
            Button("Back Up Original and Save") { save() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The original and every pre-save version remain available in Version Vault. The target is replaced only after validation and conflict checks pass.")
        }
        .alert("Safe Edit", isPresented: Binding(get: { error != nil && session != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "Unknown error") }
    }

    private func prepare() async {
        do {
            let value = try await Task.detached(priority: .userInitiated) { try SafeStructuredEditor.open(target: item.url) }.value
            session = value
            text = value.text
            status = "Protected \(value.kind.title) draft · original SHA recorded"
        } catch { self.error = error.localizedDescription }
    }

    private func validate() {
        guard let session else { return }
        do {
            _ = try SafeStructuredEditor.validate(session, text: text)
            status = "Valid \(session.kind.title) · ready to save"
        } catch { self.error = error.localizedDescription }
    }

    private func validateAndConfirm() {
        guard let session else { return }
        do {
            _ = try SafeStructuredEditor.validate(session, text: text)
            status = "Validation passed"
            showSaveConfirmation = true
        } catch { self.error = error.localizedDescription }
    }

    private func save() {
        guard let session else { return }
        let draftText = text
        isSaving = true
        status = "Checking for conflicts and saving…"
        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) { try SafeStructuredEditor.save(session, text: draftText) }.value
                status = "Saved and verified"
                completed()
                dismiss()
            } catch {
                self.error = error.localizedDescription
                status = "Not saved"
            }
            isSaving = false
        }
    }
}

private struct VersionHistoryView: View {
    let records: [FileBackupRecord]
    let restore: (FileBackupRecord) -> Void
    @State private var previewRecord: FileBackupRecord?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(records) { record in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(record.manifest.effectiveRole == .original ? "Original" : "Saved Version",
                          systemImage: record.manifest.effectiveRole == .original ? "lock.shield" : "clock")
                        .font(.headline)
                    Spacer()
                    Text(record.manifest.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text(ByteCountFormatter.string(fromByteCount: record.manifest.originalSize, countStyle: .file))
                    Text(record.manifest.originalSHA256.prefix(12)).monospaced()
                    Spacer()
                    Button("Preview") { previewRecord = record }.buttonStyle(.borderless)
                    Button("Restore") { restore(record) }.buttonStyle(.borderless)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        .overlay {
            if records.isEmpty {
                ContentUnavailableView("No Versions Yet", systemImage: "clock",
                                       description: Text("The first edit or replacement permanently saves the original file."))
            }
        }
        .navigationTitle("Version Vault")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("Done") { dismiss() } }
        .sheet(item: $previewRecord) { record in
            NavigationStack { VersionSnapshotPreview(record: record) }
        }
    }
}

private struct VersionSnapshotPreview: View {
    let record: FileBackupRecord
    @State private var preview: FilePreview?
    @State private var error: String?
    @State private var isLoading = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PreviewContent(preview: preview, error: error, isLoading: isLoading)
            .navigationTitle(record.manifest.effectiveRole == .original ? "Original" : "Saved Version")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .task(id: record.id) {
                isLoading = true
                do {
                    let loaded = try await Task.detached(priority: .userInitiated) {
                        let source = try FileBackupService.contentURL(for: record)
                        let item = FileItem(url: source, isDirectory: false, isSymbolicLink: false,
                                            size: record.manifest.originalSize, modifiedAt: record.manifest.createdAt)
                        return try FilePreviewLoader.load(item).preview
                    }.value
                    preview = loaded
                } catch { self.error = error.localizedDescription }
                isLoading = false
            }
    }
}

private struct FilePreviewOverlay: View {
    let item: FileItem
    let preview: FilePreview?
    let previewError: String?
    let exportURL: URL?
    let hexDump: String
    let isLoading: Bool
    let allowsAdvancedTools: Bool
    let availableWidth: CGFloat
    let allowsResizing: Bool
    @Binding var widthFraction: CGFloat
    @Binding var isFullScreen: Bool
    @Binding var dragStartFraction: CGFloat?
    let requestShare: () -> Void
    let showInfo: () -> Void
    let close: () -> Void
    @State private var displayMode = PreviewDisplayMode.bestMatch

    var body: some View {
        HStack(spacing: 0) {
            if allowsResizing, !isFullScreen {
                Color.black.opacity(0.22)
                    .contentShape(.rect)
                    .onTapGesture(perform: close)
            }

            NavigationStack {
                displayedContent
                    .navigationTitle(item.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Close Preview", systemImage: "xmark", action: close)
                                .keyboardShortcut(.cancelAction)
                        }
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            if allowsAdvancedTools { Menu("View As", systemImage: "eye") {
                                Picker("View As", selection: $displayMode) {
                                    ForEach(PreviewDisplayMode.allCases) { mode in
                                        Label(mode.title, systemImage: mode.systemImage).tag(mode)
                                    }
                                }
                            }
                            }
                            Button("File Info", systemImage: "info.circle", action: showInfo)
                            if allowsResizing {
                                Button(isFullScreen ? "Restore Preview Size" : "Full Screen",
                                       systemImage: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                                    isFullScreen.toggle()
                                }
                                .keyboardShortcut("f", modifiers: [.command, .shift])
                            }
                            Button("Share", systemImage: "square.and.arrow.up", action: requestShare)
                                .disabled(isLoading)
                        }
                    }
            }
            .frame(width: isFullScreen || !allowsResizing ? availableWidth : availableWidth * widthFraction)
            .background(.background)
            .shadow(radius: 18)
            .overlay(alignment: .leading) {
                if allowsResizing, !isFullScreen {
                    Capsule()
                        .fill(.secondary.opacity(0.65))
                        .frame(width: 5, height: 64)
                        .padding(.leading, 4)
                        .frame(width: 24, alignment: .leading)
                        .frame(maxHeight: .infinity)
                        .contentShape(.rect)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    if dragStartFraction == nil { dragStartFraction = widthFraction }
                                    let start = dragStartFraction ?? widthFraction
                                    widthFraction = min(0.9, max(0.6, start - value.translation.width / availableWidth))
                                }
                                .onEnded { _ in dragStartFraction = nil }
                        )
                        .accessibilityLabel("Resize Preview")
                        .accessibilityHint("Drag horizontally to resize the preview panel")
                }
            }
        }
        .ignoresSafeArea()
        .onChange(of: item.id) { displayMode = .bestMatch }
    }

    @ViewBuilder
    private var displayedContent: some View {
        if showsHex {
            TextViewer(text: hexDump, format: "Hex")
        } else {
            PreviewContent(preview: preview, error: previewError, isLoading: isLoading, allowsAdvancedTools: allowsAdvancedTools)
        }
    }

    private var showsHex: Bool {
        if allowsAdvancedTools && displayMode == .hex { return true }
        if allowsAdvancedTools, case .binary? = preview { return true }
        return false
    }
}

private struct PreviewContent: View {
    let preview: FilePreview?
    let error: String?
    let isLoading: Bool
    var allowsAdvancedTools = false

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView(
                    "Preview Failed",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else if let preview {
                switch preview {
                case .structured(let root, let source, let format): StructuredViewer(root: root, source: source, format: format)
                case .text(let text, let format): TextViewer(text: text, format: format)
                case .image(let data, let details): ImageViewer(data: data, details: details)
                case .machO(let info):
                    if allowsAdvancedTools { MachOViewer(info: info) }
                    else { ContentUnavailableView("Preview Unavailable", systemImage: "doc", description: Text("Export this file to open it in another app.")) }
                case .pdf(let data): PDFDocumentViewer(data: data)
                case .sqlite(let summary):
                    if allowsAdvancedTools { SQLiteViewer(summary: summary) }
                    else { ContentUnavailableView("Preview Unavailable", systemImage: "doc", description: Text("Export this file to open it in another app.")) }
                case .archive(let summary): ArchiveViewer(summary: summary)
                case .font, .binaryCookies: ContentUnavailableView("Preview Unavailable", systemImage: "doc", description: Text("Export this file to open it in another app."))
                case .quickLook(let url, _): QuickLookViewer(url: url)
                case .binary: ContentUnavailableView("Binary File", systemImage: "doc.badge.gearshape")
                case .tooLarge(let size):
                    ContentUnavailableView(
                        "File Too Large",
                        systemImage: "doc.badge.ellipsis",
                        description: Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    )
                }
            } else if isLoading {
                ProgressView("Loading preview…")
            } else {
                ContentUnavailableView("Preview Unavailable", systemImage: "eye.slash")
            }
        }
    }
}

private struct PDFDocumentViewer: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.dataRepresentation() != data {
            view.document = PDFDocument(data: data)
        }
    }
}

private struct QuickLookViewer: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

private struct SQLiteViewer: View {
    let summary: SQLiteSummary
    var body: some View {
        List {
            Section("Database") {
                LabeledContent("Tables", value: summary.tables.count.formatted())
                LabeledContent("Indexes", value: summary.indexes.count.formatted())
                if let mode = summary.journalMode { LabeledContent("Journal Mode", value: mode.uppercased()) }
                LabeledContent("WAL", value: summary.hasWAL ? "Present" : "Not Found")
                LabeledContent("SHM", value: summary.hasSHM ? "Present" : "Not Found")
            }
            ForEach(summary.tables) { table in
                Section(table.name) {
                    if let count = table.rowCount { LabeledContent("Rows", value: count.formatted()) }
                    DisclosureGroup("Columns (\(table.columns.count))") {
                        ForEach(table.columns, id: \.self) { Text($0).font(.callout.monospaced()) }
                    }
                    if !table.sampleRows.isEmpty {
                        DisclosureGroup("Rows (first \(table.sampleRows.count))") {
                            ForEach(Array(table.sampleRows.enumerated()), id: \.offset) { rowIndex, row in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Row \(rowIndex + 1)").font(.caption.weight(.semibold))
                                    ForEach(Array(row.enumerated()), id: \.offset) { columnIndex, value in
                                        LabeledContent(columnIndex < table.columns.count ? table.columns[columnIndex] : "#\(columnIndex + 1)", value: value)
                                            .font(.caption.monospaced())
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if !summary.indexes.isEmpty {
                Section("Indexes") { ForEach(summary.indexes, id: \.self) { Text($0).font(.callout.monospaced()) } }
            }
        }
    }
}

private struct ArchiveViewer: View {
    let summary: ArchiveSummary
    var body: some View {
        List(summary.entries) { entry in
            HStack {
                Image(systemName: entry.isDirectory ? "folder" : "doc")
                    .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                VStack(alignment: .leading) {
                    Text(entry.name).lineLimit(2)
                    if !entry.isDirectory {
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(entry.uncompressedSize), countStyle: .file)) · compressed \(ByteCountFormatter.string(fromByteCount: Int64(entry.compressedSize), countStyle: .file))")
                            .font(.caption).foregroundStyle(.secondary)
                        if let preview = entry.previewText {
                            DisclosureGroup("Text Preview") {
                                Text(preview).font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .top) {
            Text("\(summary.entries.count) archive entries")
                .font(.caption).foregroundStyle(.secondary).padding(.vertical, 6)
        }
    }
}

private enum PreviewDisplayMode: String, CaseIterable, Identifiable {
    case bestMatch, hex
    var id: Self { self }
    var title: LocalizedStringResource { switch self { case .bestMatch: "Best Match"; case .hex: "Hex" } }
    var systemImage: String { switch self { case .bestMatch: "wand.and.stars"; case .hex: "number" } }
}

private struct StructuredViewer: View {
    let root: StructuredNode
    let source: String
    let format: String
    @State private var query = ""
    @State private var showSource = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(format).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Toggle("Source", isOn: $showSource).toggleStyle(.button)
            }.padding(.horizontal)
            if showSource { TextViewer(text: source, format: format) }
            else if let filtered = root.matching(query) {
                List { OutlineGroup([filtered], children: \.children.optionalWhenNotEmpty) { node in StructuredNodeRow(node: node) } }
                    .searchable(text: $query, prompt: "Search keys and values")
            } else { ContentUnavailableView.search(text: query) }
        }
    }
}

private extension Array where Element == StructuredNode {
    var optionalWhenNotEmpty: [StructuredNode]? { isEmpty ? nil : self }
}

private struct StructuredNodeRow: View {
    let node: StructuredNode
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: node.children.isEmpty ? "circle.fill" : "chevron.right.circle").font(.caption2).foregroundStyle(.secondary)
            Text(node.key).font(.system(.callout, design: .monospaced)).fontWeight(.medium)
            if let value = node.value { Spacer(); Text(value).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled) }
        }
    }
}

private struct TextViewer: View {
    let text: String
    let format: String
    @State private var query = ""
    @State private var wrapLines = true
    private var displayed: String {
        guard !query.isEmpty else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false).filter { $0.localizedCaseInsensitiveContains(query) }.joined(separator: "\n")
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(format).font(.caption.weight(.semibold)).foregroundStyle(.secondary); Spacer(); Toggle("Wrap", isOn: $wrapLines).toggleStyle(.button) }.padding(.horizontal)
            ScrollView(wrapLines ? .vertical : [.horizontal, .vertical]) {
                Text(displayed).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding()
            }.searchable(text: $query, prompt: "Search in file")
        }
    }
}

private struct ImageViewer: View {
    let data: Data
    let details: ImageDetails
    @State private var scale = 1.0
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(details.width) × \(details.height)").monospacedDigit()
                Spacer()
                Text("\(details.frameCount) frame(s)").foregroundStyle(.secondary)
                Menu("Image Details", systemImage: "info.circle") {
                    if let type = details.typeIdentifier { Text(type) }
                    ForEach(details.properties.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        Text("\(key): \(value)")
                    }
                }
                Stepper("Zoom", value: $scale, in: 0.25...8, step: 0.25).labelsHidden()
            }.font(.caption).padding(.horizontal)
            if let image = UIImage(data: data) {
                ScrollView([.horizontal, .vertical]) { Image(uiImage: image).resizable().interpolation(.high).scaledToFit().scaleEffect(scale).padding(30) }
                    .onTapGesture(count: 2) { withAnimation { scale = scale == 1 ? 2 : 1 } }
            } else { ContentUnavailableView("Invalid Image", systemImage: "photo.badge.exclamationmark") }
        }
    }
}

private struct MachOViewer: View {
    let info: MachOInfo
    var body: some View {
        List {
            Section("Overview") { LabeledContent("Architectures", value: info.architectures.map(\.name).joined(separator: ", ")); LabeledContent("Code Signature", value: info.codeSignaturePresent ? "Present" : "Not Found") }
            ForEach(info.architectures) { arch in
                Section(arch.name) {
                    LabeledContent("File Type", value: arch.fileType); LabeledContent("Flags", value: arch.flags)
                    if let value = arch.minimumOS { LabeledContent("Minimum OS", value: value) }
                    if let value = arch.sdk { LabeledContent("SDK", value: value) }
                    if let value = arch.uuid { LabeledContent("UUID", value: value) }
                    if let value = arch.encrypted { LabeledContent("Encrypted", value: value ? "Yes" : "No") }
                    if !arch.rpaths.isEmpty { DisclosureGroup("RPATHs") { ForEach(arch.rpaths, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) } } }
                    DisclosureGroup("Dependencies (\(arch.dependencies.count))") { ForEach(arch.dependencies, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) } }
                }
            }
            if let entitlements = info.entitlements { Section("Entitlements") { Text(entitlements).font(.caption.monospaced()).textSelection(.enabled) } }
        }
    }
}

private struct FilePropertiesView: View {
    let item: FileItem
    let properties: FileProperties?
    let allowsAdvancedTools: Bool
    var body: some View {
        List {
            Section("File") {
                LabeledContent("Name", value: item.name)
                if allowsAdvancedTools { LabeledContent("Path", value: item.url.path) }
                LabeledContent("Kind", value: item.isDirectory ? "Directory" : "File")
            }
            if let properties {
                Section("Properties") {
                    LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: properties.size, countStyle: .file))
                    LabeledContent("Type", value: properties.typeIdentifier ?? "Unknown")
                    if allowsAdvancedTools {
                    LabeledContent("Permissions", value: String(format: "%04o", properties.posixPermissions))
                    if let owner = properties.owner { LabeledContent("Owner", value: owner) }; if let group = properties.group { LabeledContent("Group", value: group) }; if let inode = properties.inode { LabeledContent("Inode", value: String(inode)) }
                    }
                    if let createdAt = properties.createdAt { LabeledContent("Created", value: createdAt.formatted(date: .abbreviated, time: .standard)) }
                    if let modifiedAt = properties.modifiedAt { LabeledContent("Modified", value: modifiedAt.formatted(date: .abbreviated, time: .standard)) }
                }
                if allowsAdvancedTools { if let hash = properties.sha256 {
                    Section("SHA-256") { Text(hash).font(.caption.monospaced()).textSelection(.enabled) }
                } else {
                    Section("SHA-256") { Text("Calculated on demand for large files").foregroundStyle(.secondary) }
                }
                }
            }
        }
    }
}

private struct ContainerSearchView: View {
    @Bindable var model: VeilpathModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    var body: some View {
        NavigationStack {
            List(model.searchResults) { item in Button { Task { await model.open(item); dismiss() } } label: { VStack(alignment: .leading) { Text(item.name); Text(item.url.path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2) } } }
                .overlay { if model.isSearching { ProgressView("Searching…") } else if model.searchResults.isEmpty && !query.isEmpty { ContentUnavailableView.search(text: query) } }
                .searchable(text: $query, prompt: "Search filenames")
                .onSubmit(of: .search) { Task { await model.searchCurrentContainer(for: query) } }
                .navigationTitle("Container Search")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct DiagnosticsView: View {
    @Bindable var model: VeilpathModel
    var showsDismissButton = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("Runtime") {
                LabeledContent("System", value: ProcessInfo.processInfo.operatingSystemVersionString)
                LabeledContent("Last Granted Backend") {
                    if let backend = model.lastAccessBackend {
                        Text(verbatim: backend.rawValue)
                    } else {
                        Text("Not verified")
                    }
                }
                LabeledContent("Grant policy", value: "Per operation")
                if let report = model.selfTestReport {
                    LabeledContent("Self-test") {
                        TestResultText(passed: report.passed)
                    }
                    LabeledContent("Report Schema") { Text(report.schemaVersion, format: .number) }
                    if report.schemaVersion != SelfTestRunner.schemaVersion { Text("Run diagnostics to update this report.").foregroundStyle(.secondary) }
                } else {
                    LabeledContent("Self-test") { Text(model.isRunningDiagnostics ? LocalizedStringResource("Running") : LocalizedStringResource("Not Run")) }
                }
            }

            if let report = model.selfTestReport {
                Section("Checks") {
                    ForEach(report.checks, id: \.name) { check in
                        LabeledContent {
                            switch check.status {
                            case .passed:
                                Text("Passed").foregroundStyle(.green)
                            case .failed:
                                Text("Failed").foregroundStyle(.red)
                            case .unsupported:
                                Text("Unsupported").foregroundStyle(.secondary)
                            }
                        } label: {
                            Text(check.localizedName)
                        }
                    }
                }
            }

            Section("Log") {
                ForEach(model.logs) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.date, format: .dateTime.hour().minute().second())
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(entry.message)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(entry.isError ? .red : .primary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
        .toolbar {
            if showsDismissButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Run Self-Test", systemImage: "checkmark.shield") {
                    Task { await model.runSelfTest() }
                }
                .disabled(!model.canRunDiagnostics)
            }

        }
    }
}

private struct TestResultText: View {
    let passed: Bool

    var body: some View {
        Text(passed ? LocalizedStringResource("Passed") : LocalizedStringResource("Failed"))
    }
}

private struct AccessStateLabel: View {
    let model: VeilpathModel

    var body: some View {
        if model.isAccessVerificationPending {
            Label("Verifying…", systemImage: "progress.indicator")
                .foregroundStyle(.secondary)
        } else if let check = model.accessVerification {
            if check.passed {
                Label("Verified", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Failed", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            }
        } else {
            Label("Not verified", systemImage: "minus.circle")
                .foregroundStyle(.secondary)
        }
    }
}

private extension SelfTestReport.Check {
    var localizedName: LocalizedStringResource {
        switch name {
        case "Sandbox access backend": "Sandbox Access Backend"
        case "Application name resolution": "Application Name Resolution"
        case "On-device app storage scan": "On-device App Storage Scan"
        case "App storage and recoverable cache cleaning": "App Storage and Recoverable Cache Cleaning"
        case "Backup deletion and interrupted removal": "Backup Deletion and Interrupted Removal"
        case "MobileGestalt file access": "MobileGestalt File Access"
        case "Preview and safe export": "Preview and Safe Export"
        case "Application container discovery": "Application Container Discovery"
        case "System data containers": "System Data Containers"
        case "Plugin containers": "Plugin Containers"
        case "Internal daemon containers": "Internal Daemon Containers"
        case "App Group containers": "App Group Containers"
        case "System Group containers": "System Group Containers"
        case "Structured plist and JSON": "Structured Plist and JSON"
        case "File properties SHA-256 and hex": "File Properties, SHA-256, and Hex"
        case "Mach-O and code signature analysis": "Mach-O and Code Signature Analysis"
        case "Export cache lifecycle": "Export Cache Lifecycle"
        case "Recursive container search": "Recursive Container Search"
        case "Directory filtering and sorting": "Directory Filtering and Sorting"
        default: "Unknown Check"
        }
    }
}

#Preview {
    ContentView(model: VeilpathModel())
}

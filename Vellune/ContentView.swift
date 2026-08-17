import SwiftUI
import UIKit
import UniformTypeIdentifiers
import PDFKit
import QuickLook

struct ContentView: View {
    @Bindable var model: VelluneModel
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
    @State private var screenshotFeedback: ScreenshotFeedbackContext?
    @AppStorage("feedback.screenshotPromptEnabled") private var screenshotPromptEnabled = true

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .trailing) {
                if model.currentContainerRoot.isEmpty {
                    ContainerHomeView(model: model)
                        .transition(homeTransition)
                        .zIndex(0)
                } else {
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
                        availableWidth: geometry.size.width,
                        allowsResizing: horizontalSizeClass != .compact,
                        widthFraction: $previewWidthFraction,
                        isFullScreen: $previewIsFullScreen,
                        dragStartFraction: $previewDragStartFraction,
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
        .alert("Access Failed", isPresented: errorPresented) {
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
            if let screenshotFeedback {
                ScreenshotFeedbackPrompt(
                    context: screenshotFeedback,
                    dismiss: { self.screenshotFeedback = nil }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(100)
            }
        }
        .animation(.snappy, value: screenshotFeedback?.id)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            presentScreenshotFeedbackIfEnabled()
        }
        .onAppear {
            #if targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-screenshot-feedback") {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(750))
                    presentScreenshotFeedbackIfEnabled()
                }
            }
            #endif
        }
    }

    private var homeTransition: AnyTransition {
        guard horizontalSizeClass == .compact else { return .opacity }
        return .move(edge: .leading).combined(with: .opacity)
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
            openPreview: {
                showInspector = false
                openSelectedPreview()
            },
            requestReplacement: requestReplacement,
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
        closePreview()
        showInspector = false
        model.closeCurrentContainer()
    }

    private func requestReplacement() {
        showInspector = false
        Task { @MainActor in
            await Task.yield()
            showingReplacementImporter = true
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

    private var currentScreenDescription: String {
        if let presentedPreview {
            return "File preview: \(presentedPreview.name)"
        }
        if model.currentContainerRoot.isEmpty {
            return "Container home"
        }
        if let identifier = model.selectedContainer?.identifier {
            return "File browser: \(identifier)"
        }
        return "File browser"
    }

    private func presentScreenshotFeedbackIfEnabled() {
        guard screenshotPromptEnabled else { return }
        do {
            let screenshot = try FeedbackSupport.captureCurrentWindow()
            screenshotFeedback = .init(
                screenshotURL: screenshot.url,
                previewImage: screenshot.image,
                screenDescription: currentScreenDescription
            )
        } catch {
            model.log("Screenshot sharing preparation failed: \(error.localizedDescription)", isError: true)
        }
    }
}

private struct ScreenshotFeedbackPrompt: View {
    let context: ScreenshotFeedbackContext
    let dismiss: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label("Screenshot captured", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                Spacer()
                Button("Dismiss", systemImage: "xmark", action: dismiss)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .accessibilityHint("Closes the screenshot actions.")
            }

            Text("Share it or report an issue while the context is fresh.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                ShareLink(
                    item: context.screenshotURL,
                    preview: SharePreview("Vellune Screenshot", image: Image(uiImage: context.previewImage))
                ) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    openURL(FeedbackSupport.issueURL(screenDescription: context.screenDescription))
                    dismiss()
                } label: {
                    Label("Report Issue", systemImage: "exclamationmark.bubble")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: .rect(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 16, y: 6)
        .accessibilityElement(children: .contain)
    }

}

private enum ContainerHomeLayout: String, CaseIterable, Identifiable {
    case grid
    case list

    var id: Self { self }
    var title: LocalizedStringResource {
        switch self {
        case .grid: "Grid"
        case .list: "List"
        }
    }
    var systemImage: String {
        switch self {
        case .grid: "square.grid.2x2"
        case .list: "list.bullet"
        }
    }
}

private struct ContainerHomeView: View {
    @Bindable var model: VelluneModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("home.containerLayout") private var layoutRawValue = ContainerHomeLayout.grid.rawValue
    @State private var searchText = ""
    @State private var selectedKind: ContainerKind = .application
    @State private var showSettings = false

    private var layout: ContainerHomeLayout {
        get { ContainerHomeLayout(rawValue: layoutRawValue) ?? .grid }
        nonmutating set { layoutRawValue = newValue.rawValue }
    }

    private var filteredContainers: [ContainerDescriptor] {
        let containers = model.containerIndexes[selectedKind, default: []]
        guard !searchText.isEmpty else { return containers }
        return containers.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
                || $0.uuid.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var sections: [ContainerHomeSection] {
        guard selectedKind == .application else {
            return [.init(id: selectedKind.rawValue, title: selectedKind.localizedContainerTitle, containers: filteredContainers)]
        }
        let applications = filteredContainers.filter { $0.identifier?.hasPrefix("com.apple.") != true }
        let appleApplications = filteredContainers.filter { $0.identifier?.hasPrefix("com.apple.") == true }
        return [
            .init(id: "applications", title: "Applications", containers: applications),
            .init(id: "apple-applications", title: "Apple Applications", containers: appleApplications)
        ].filter { !$0.containers.isEmpty }
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.isWorking && filteredContainers.isEmpty {
                    ProgressView("Loading containers…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredContainers.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else if layout == .grid {
                    gridContent
                } else {
                    listContent
                }
            }
            .navigationTitle("Vellune")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { locationsMenu }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    layoutPicker
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                        .labelStyle(.iconOnly)
                }
            }
            .searchable(text: $searchText, placement: .toolbar, prompt: "App name or Bundle ID")
            .searchToolbarBehavior(.minimize)
        }
        .fullScreenCover(isPresented: $showSettings) { SettingsView(model: model) }
        .onAppear {
            #if targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-list-home") {
                layoutRawValue = ContainerHomeLayout.list.rawValue
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-settings") {
                showSettings = true
            }
            #endif
        }
    }

    private var gridContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if model.accessVerification?.status != .passed {
                    AccessStatusView(model: model)
                        .padding(.horizontal)
                }
                ForEach(sections, id: \.id) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        sectionHeader(section)
                        LazyVGrid(
                            columns: homeGridColumns,
                            alignment: .leading,
                            spacing: 6
                        ) {
                            ForEach(section.containers) { container in
                                ContainerTile(container: container) { open(container) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    private var listContent: some View {
        List {
            if model.accessVerification?.status != .passed {
                Section { AccessStatusView(model: model) }
            }
            ForEach(sections, id: \.id) { section in
                Section {
                    ForEach(section.containers) { container in
                        Button { open(container) } label: { ContainerRow(container: container) }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens this app container")
                    }
                } header: {
                    sectionHeader(section)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var homeGridColumns: [GridItem] {
        if horizontalSizeClass == .compact {
            return [GridItem(.flexible())]
        }
        return [GridItem(.adaptive(minimum: 290, maximum: 420), spacing: 14)]
    }

    private func sectionHeader(_ section: ContainerHomeSection) -> some View {
        HStack {
            Text(section.title)
                .font(.headline)
            Spacer()
            Text(section.containers.count, format: .number)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var locationsMenu: some View {
        Menu("Locations", systemImage: selectedKind.systemImage) {
            ForEach(ContainerKind.allCases, id: \.self) { kind in
                Button {
                    selectedKind = kind
                    searchText = ""
                } label: {
                    Label {
                        HStack {
                            Text(kind.localizedName)
                            Text(model.containerIndexes[kind, default: []].count, format: .number)
                        }
                    } icon: {
                        Image(systemName: selectedKind == kind ? "checkmark" : kind.systemImage)
                    }
                }
            }
        }
        .accessibilityValue(selectedKind.localizedName)
    }

    private var layoutPicker: some View {
        Menu("Layout", systemImage: layout.systemImage) {
            Picker("Layout", selection: Binding(get: { layout }, set: { layout = $0 })) {
                ForEach(ContainerHomeLayout.allCases) { option in
                    Label(option.title, systemImage: option.systemImage).tag(option)
                }
            }
        }
        .labelStyle(.iconOnly)
        .accessibilityValue(layout.title)
    }

    private func open(_ container: ContainerDescriptor) {
        Task { await model.open(container) }
    }
}

private struct ContainerHomeSection: Identifiable {
    let id: String
    let title: LocalizedStringResource
    let containers: [ContainerDescriptor]
}

private struct ContainerTile: View {
    let container: ContainerDescriptor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(container.homeTitle)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    if container.kind != .application {
                        ContainerKindBadge(container: container)
                    }
                }
                Text(container.identifier ?? container.uuid)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .background(container.homeAccent.opacity(0.11), in: .rect(cornerRadius: 14))
            .overlay(alignment: .leading) {
                UnevenRoundedRectangle(
                    topLeadingRadius: 14,
                    bottomLeadingRadius: 14,
                    bottomTrailingRadius: 2,
                    topTrailingRadius: 2
                )
                .fill(container.homeAccent)
                .frame(width: 5)
            }
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this app container")
    }

}

private struct ContainerKindBadge: View {
    let container: ContainerDescriptor

    var body: some View {
        Text(container.homeKindLabel)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(container.homeAccent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(container.homeAccent.opacity(0.12), in: .capsule)
    }
}

private extension ContainerDescriptor {
    var homeTitle: String {
        guard let identifier else { return uuid }
        let components = identifier.split(separator: ".").map(String.init)
        guard let last = components.last else { return identifier }

        let genericSuffixes: Set<String> = [
            "app", "application", "ios", "mobile", "client", "prod", "release"
        ]
        if genericSuffixes.contains(last.lowercased()), components.count >= 2 {
            return components[components.count - 2]
        }
        if last.count < 4, components.count >= 2 {
            return components.suffix(2).joined(separator: ".")
        }
        return last
    }

    var homeKindLabel: String {
        switch kind {
        case .application: "APP"
        case .appGroup: "GROUP"
        case .plugin: "PLUGIN"
        case .internalDaemon: "DAEMON"
        case .systemData: "SYSTEM"
        case .systemGroup: "GROUP"
        }
    }

    var homeAccent: Color {
        let palette: [Color] = [.blue, .indigo, .purple, .pink, .orange, .green, .teal, .cyan]
        let key = identifier ?? uuid
        let hash = key.unicodeScalars.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1.value)) &* 1_099_511_628_211
        }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

private struct PreviewFileList: View {
    @Bindable var model: VelluneModel
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

private struct SidebarView: View {
    @Bindable var model: VelluneModel
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @Binding var preferredCompactColumn: NavigationSplitViewColumn
    let usesCompactNavigation: Bool
    @State private var searchText = ""
    @State private var selectedKind: ContainerKind = .application
    @State private var showSettings = false
    @AppStorage("sidebar.applicationsExpanded") private var applicationsExpanded = true
    @AppStorage("sidebar.appleApplicationsExpanded") private var appleApplicationsExpanded = false

    var body: some View {
        List {
            if model.accessVerification?.status != .passed {
                Section {
                    AccessStatusView(model: model)
                }
            }

            Section {
                let containers = filteredContainers(for: selectedKind)
                if containers.isEmpty {
                    if searchText.isEmpty {
                        Text("No containers indexed")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No matches")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    if selectedKind == .application {
                        groupedApplicationRows(containers)
                    } else {
                        containerRows(containers)
                    }
                }
            } header: {
                HStack {
                    Label(selectedKind.localizedContainerTitle, systemImage: selectedKind.systemImage)
                    Spacer()
                    Text(filteredContainers(for: selectedKind).count, format: .number)
                        .monospacedDigit()
                }
            }

        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, placement: .sidebar, prompt: "Container name or UUID")
        .navigationTitle("Vellune")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                locationsMenu
                    .labelStyle(.iconOnly)
            }
            ToolbarItem(placement: .topBarTrailing) {
                settingsButton
            }
        }
        .fullScreenCover(isPresented: $showSettings) {
            SettingsView(model: model)
        }
        .onAppear {
            #if targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-apple-search") {
                searchText = "com.apple"
            }
            #endif
        }
    }

    private var locationsMenu: some View {
        Menu("Locations", systemImage: "square.grid.2x2") {
            ForEach(ContainerKind.allCases, id: \.self) { kind in
                Button {
                    selectedKind = kind
                    searchText = ""
                } label: {
                    Label {
                        HStack {
                            Text(kind.localizedName)
                            Text(model.containerIndexes[kind, default: []].count, format: .number)
                        }
                    } icon: {
                        Image(systemName: selectedKind == kind ? "checkmark" : kind.systemImage)
                    }
                }
            }
        }
        .accessibilityValue(selectedKind.localizedName)
    }

    private var settingsButton: some View {
        Button("Settings", systemImage: "gearshape") {
            showSettings = true
        }
        .labelStyle(.iconOnly)
    }

    private func filteredContainers(for kind: ContainerKind) -> [ContainerDescriptor] {
        let containers = model.containerIndexes[kind, default: []]
        guard !searchText.isEmpty else { return containers }
        return containers.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
                || $0.uuid.localizedCaseInsensitiveContains(searchText)
        }
    }

    @ViewBuilder
    private func groupedApplicationRows(_ containers: [ContainerDescriptor]) -> some View {
        let applications = containers.filter { !isAppleApplication($0) }
        let appleApplications = containers.filter(isAppleApplication)

        if !applications.isEmpty {
            DisclosureGroup(isExpanded: applicationsExpansion) {
                containerRows(applications)
            } label: {
                containerGroupLabel("Applications", count: applications.count)
            }
        }

        if !appleApplications.isEmpty {
            DisclosureGroup(isExpanded: appleApplicationsExpansion) {
                containerRows(appleApplications)
            } label: {
                containerGroupLabel("Apple Applications", count: appleApplications.count)
            }
        }
    }

    @ViewBuilder
    private func containerRows(_ containers: [ContainerDescriptor]) -> some View {
        ForEach(containers) { container in
            Button {
                preferredCompactColumn = .detail
                columnVisibility = .detailOnly
                Task {
                    await model.open(container)
                }
            } label: {
                ContainerRow(container: container)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the container at \(container.path)")
        }
    }

    private func containerGroupLabel(
        _ title: LocalizedStringResource,
        count: Int
    ) -> some View {
        HStack {
            Text(title)
                .font(.callout.weight(.semibold))
            Spacer()
            Text(count, format: .number)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var applicationsExpansion: Binding<Bool> {
        Binding(
            get: { !searchText.isEmpty || applicationsExpanded },
            set: { if searchText.isEmpty { applicationsExpanded = $0 } }
        )
    }

    private var appleApplicationsExpansion: Binding<Bool> {
        Binding(
            get: { !searchText.isEmpty || appleApplicationsExpanded },
            set: { if searchText.isEmpty { appleApplicationsExpanded = $0 } }
        )
    }

    private func isAppleApplication(_ container: ContainerDescriptor) -> Bool {
        container.identifier?.hasPrefix("com.apple.") == true
    }

}

private struct SettingsView: View {
    @Bindable var model: VelluneModel
    @Environment(\.dismiss) private var dismiss
    @State private var cacheMessage: String?
    @AppStorage("feedback.screenshotPromptEnabled") private var screenshotPromptEnabled = true

    var body: some View {
        NavigationStack {
            List {
                Section("Diagnostics") {
                    NavigationLink {
                        DiagnosticsView(model: model, showsDismissButton: false)
                    } label: {
                        Label("Activity Log", systemImage: "waveform.path.ecg")
                    }
                }

                Section("Access") {
                    LabeledContent("Status") {
                        AccessStateLabel(model: model)
                    }
                    LabeledContent("Grant policy", value: "Per operation")
                    LabeledContent("Mode", value: "Read only by default")
                }

                Section("Storage") {
                    Button("Clear Export Cache", systemImage: "trash", role: .destructive) {
                        do {
                            try ExportCache.removeAll()
                            cacheMessage = String(localized: "Export cache cleared")
                        } catch {
                            cacheMessage = error.localizedDescription
                        }
                    }
                    if let cacheMessage {
                        Text(cacheMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Shared files are copied to a private cache and automatically removed after 24 hours.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(
                        forInfoDictionaryKey: "CFBundleShortVersionString"
                    ) as? String ?? "Unknown")
                    LabeledContent("System", value: ProcessInfo.processInfo.operatingSystemVersionString)
                    Link(destination: URL(string: "https://xnu.app/vellune/")!) {
                        Label("Vellune Website", systemImage: "safari")
                    }
                    Link(destination: URL(string: "https://github.com/everettjf/vellune")!) {
                        Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }

                Section("Feedback") {
                    Toggle("Screenshot feedback prompt", isOn: $screenshotPromptEnabled)
                    Link(destination: FeedbackSupport.issueURL()) {
                        Label("Report an Issue", systemImage: "exclamationmark.bubble")
                    }
                    Text("After you take a screenshot in Vellune, show quick actions to share it or report an issue.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("GitHub reports include app and system versions. Review screenshots for sensitive information before attaching them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

}

private struct AccessStatusView: View {
    let model: VelluneModel

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
        if model.isVerifyingAccess { return "shield.lefthalf.filled.badge.checkmark" }
        if model.accessVerification == nil { return "shield.slash" }
        return "exclamationmark.shield.fill"
    }

    private var statusColor: Color {
        if model.isVerifyingAccess { return .secondary }
        if model.accessVerification == nil { return .secondary }
        return .orange
    }

    private var statusTitle: LocalizedStringResource {
        if model.isVerifyingAccess { return "Verifying access…" }
        if model.accessVerification == nil { return "Access not verified" }
        return "Access verification failed"
    }

    private var statusDetail: LocalizedStringResource {
        if model.isVerifyingAccess { return "Testing application container access" }
        if model.accessVerification == nil { return "Run the access check from Settings" }
        return "Open Settings to review diagnostics"
    }
}

private struct ContainerRow: View {
    let container: ContainerDescriptor

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(container.homeTitle)
                    .font(.callout)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(container.uuid)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if container.kind != .application {
                ContainerKindBadge(container: container)
            }
        }
        .padding(.vertical, 3)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

private struct BrowserView: View {
    @Bindable var model: VelluneModel
    @Binding var presentedPreview: FileItem?
    let opensPreviewImmediately: Bool
    let closeWorkspace: () -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @FocusState private var pathFocused: Bool
    @State private var showFileSearch = false
    @State private var fileFilter = ""
    @State private var pathInput = ""
    @State private var isEditingPath = false

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
                        Task {
                            await model.open(item)
                            if opensPreviewImmediately,
                               !item.isDirectory,
                               model.selectedItem == item {
                                presentedPreview = item
                            }
                        }
                    } label: {
                        FileRow(item: item, directorySummary: model.directorySummaries[item.url.path])
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(model.selectedItem == item ? Color.accentColor.opacity(0.12) : Color.clear)
                    .accessibilityAddTraits(model.selectedItem == item ? .isSelected : [])
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
                    toolbarNavigationButton("Up", systemImage: "arrow.up", disabled: model.isWorking || model.path == "/") {
                        await model.goUp()
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if model.path.isEmpty {
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
                        Toggle("Show Hidden Files", isOn: $model.showHiddenFiles)
                        Divider()
                        Toggle("Recursive Markdown Export", isOn: $model.directoryExportRecursive)
                        Button("Prepare Markdown Listing", systemImage: "doc.badge.arrow.up") {
                            Task { await model.prepareDirectoryMarkdownExport() }
                        }
                        .disabled(model.isExportingDirectory)
                        if let directoryExportURL = model.directoryExportURL {
                            ShareLink(
                                item: ExportedFile(url: directoryExportURL),
                                preview: SharePreview(directoryExportURL.lastPathComponent)
                            ) {
                                Label("Share Markdown Listing", systemImage: "square.and.arrow.up")
                            }
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
            if isEditingPath {
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
                compactNavigationButton("Up", systemImage: "arrow.up", disabled: model.isWorking || model.path == "/") {
                    await model.goUp()
                }
                Spacer()
                Text("\(visibleItems.count) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isEditingPath {
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

private struct InspectorView: View {
    let item: FileItem?
    let exportURL: URL?
    let properties: FileProperties?
    let isLoading: Bool
    let openPreview: () -> Void
    let requestReplacement: () -> Void
    let backups: [FileBackupRecord]
    let requestRestore: (FileBackupRecord) -> Void
    @State private var confirmWebSearch = false
    @State private var showVersionHistory = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let item {
            VStack(spacing: 0) {
                FilePropertiesView(item: item, properties: properties)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack {
                    Button("Back Up and Replace", systemImage: "arrow.triangle.2.circlepath", action: requestReplacement)
                        .disabled(isLoading)
                    Spacer()
                    if !backups.isEmpty {
                        Button("Version History", systemImage: "clock.arrow.circlepath") { showVersionHistory = true }
                    }
                }
                .padding()
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Open Preview", systemImage: "doc.text.magnifyingglass", action: openPreview)
                if let exportURL {
                    ShareLink(
                        item: ExportedFile(url: exportURL),
                        preview: SharePreview(item.name)
                    ) {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
                Menu("File Actions", systemImage: "doc.badge.gearshape") {
                    Button("Search Filename on Web", systemImage: "safari") { confirmWebSearch = true }
                    if let hash = properties?.sha256 { Button("Copy SHA-256", systemImage: "number") { UIPasteboard.general.string = hash } }
                    Button("Copy Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = item.url.path }
                }
            }
            .confirmationDialog("Search the Web?", isPresented: $confirmWebSearch, titleVisibility: .visible) {
                Button("Search for “\(item.name)”") {
                    var components = URLComponents(string: "https://www.google.com/search")!
                    components.queryItems = [.init(name: "q", value: item.name)]
                    if let url = components.url { openURL(url) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Only the filename will be sent to your web browser. The full path is never included.") }
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
                        let data = try Data(contentsOf: source, options: .mappedIfSafe)
                        let name = URL(fileURLWithPath: record.manifest.targetPath).lastPathComponent
                        let staged = try ExportCache.stage(data, named: name)
                        let item = FileItem(url: staged, isDirectory: false, isSymbolicLink: false,
                                            size: Int64(data.count), modifiedAt: record.manifest.createdAt)
                        return try FilePreviewLoader.makePreview(item: item, data: data, exportURL: staged)
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
    let availableWidth: CGFloat
    let allowsResizing: Bool
    @Binding var widthFraction: CGFloat
    @Binding var isFullScreen: Bool
    @Binding var dragStartFraction: CGFloat?
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
                            Menu("View As", systemImage: "eye") {
                                Picker("View As", selection: $displayMode) {
                                    ForEach(PreviewDisplayMode.allCases) { mode in
                                        Label(mode.title, systemImage: mode.systemImage).tag(mode)
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
                            if let exportURL {
                                ShareLink(
                                    item: ExportedFile(url: exportURL),
                                    preview: SharePreview(item.name)
                                ) {
                                    Label("Export", systemImage: "square.and.arrow.up")
                                }
                            }
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
            PreviewContent(preview: preview, error: previewError, isLoading: isLoading)
        }
    }

    private var showsHex: Bool {
        if displayMode == .hex { return true }
        if case .binary? = preview { return true }
        return false
    }
}

private struct PreviewContent: View {
    let preview: FilePreview?
    let error: String?
    let isLoading: Bool

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
                case .machO(let info): MachOViewer(info: info)
                case .pdf(let data): PDFDocumentViewer(data: data)
                case .sqlite(let summary): SQLiteViewer(summary: summary)
                case .archive(let summary): ArchiveViewer(summary: summary)
                case .font(let summary): FontViewer(summary: summary)
                case .binaryCookies(let summary): BinaryCookiesViewer(summary: summary)
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

private struct FontViewer: View {
    let summary: FontSummary
    var body: some View {
        List {
            Section("Font") {
                LabeledContent("PostScript Name", value: summary.postScriptName)
                if let name = summary.fullName { LabeledContent("Full Name", value: name) }
                LabeledContent("Glyphs", value: summary.glyphCount.formatted())
            }
            Section("Sample") {
                Text("Aa Bb Cc 123 中文")
                    .font(.system(size: 32))
            }
        }
    }
}

private struct BinaryCookiesViewer: View {
    let summary: BinaryCookiesSummary
    var body: some View {
        List {
            Section("Binary Cookies") {
                LabeledContent("Pages", value: summary.pageCount.formatted())
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(summary.totalBytes), countStyle: .file))
            }
            Section("Page Sizes") {
                ForEach(Array(summary.pageSizes.enumerated()), id: \.offset) { index, size in
                    LabeledContent("Page \(index + 1)", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                }
            }
            if !summary.cookies.isEmpty {
                Section("Cookies") {
                    ForEach(summary.cookies) { cookie in
                        DisclosureGroup(cookie.name.isEmpty ? "Unnamed Cookie" : cookie.name) {
                            LabeledContent("Domain", value: cookie.domain)
                            LabeledContent("Path", value: cookie.path)
                            LabeledContent("Value", value: cookie.value)
                            if let date = cookie.expiresAt { LabeledContent("Expires", value: date.formatted()) }
                        }
                    }
                }
            }
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
    var body: some View {
        List {
            Section("File") { LabeledContent("Name", value: item.name); LabeledContent("Path", value: item.url.path); LabeledContent("Kind", value: item.isDirectory ? "Directory" : "File") }
            if let properties {
                Section("Properties") {
                    LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: properties.size, countStyle: .file))
                    LabeledContent("Type", value: properties.typeIdentifier ?? "Unknown")
                    LabeledContent("Permissions", value: String(format: "%04o", properties.posixPermissions))
                    if let owner = properties.owner { LabeledContent("Owner", value: owner) }; if let group = properties.group { LabeledContent("Group", value: group) }; if let inode = properties.inode { LabeledContent("Inode", value: String(inode)) }
                    if let createdAt = properties.createdAt { LabeledContent("Created", value: createdAt.formatted(date: .abbreviated, time: .standard)) }
                    if let modifiedAt = properties.modifiedAt { LabeledContent("Modified", value: modifiedAt.formatted(date: .abbreviated, time: .standard)) }
                }
                if let hash = properties.sha256 {
                    Section("SHA-256") { Text(hash).font(.caption.monospaced()).textSelection(.enabled) }
                } else {
                    Section("SHA-256") { Text("Calculated on demand for large files").foregroundStyle(.secondary) }
                }
            }
        }
    }
}

private struct ContainerSearchView: View {
    @Bindable var model: VelluneModel
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
    @Bindable var model: VelluneModel
    var showsDismissButton = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("Runtime") {
                LabeledContent("System", value: ProcessInfo.processInfo.operatingSystemVersionString)
                LabeledContent("Grant policy", value: "Per operation")
                if let report = model.selfTestReport {
                    LabeledContent("Self-test") {
                        TestResultText(passed: report.passed)
                    }
                } else {
                    LabeledContent("Self-test", value: "Running")
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
                .disabled(model.isRunningDiagnostics)
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
    let model: VelluneModel

    var body: some View {
        if model.isVerifyingAccess {
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
    ContentView(model: VelluneModel())
}

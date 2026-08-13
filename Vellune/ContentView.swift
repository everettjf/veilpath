import SwiftUI

struct ContentView: View {
    @Bindable var model: VelluneModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showInspector = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                model: model,
                columnVisibility: $columnVisibility,
                usesCompactNavigation: horizontalSizeClass == .compact
            )
                .navigationSplitViewColumnWidth(min: 290, ideal: 340, max: 430)
        } detail: {
            BrowserView(model: model, showInspector: $showInspector)
                .inspector(isPresented: $showInspector) {
                    InspectorView(
                        item: model.selectedItem,
                        preview: model.selectedPreview,
                        previewError: model.previewError,
                        exportURL: model.selectedExportURL,
                        properties: model.selectedProperties,
                        hexDump: model.selectedHexDump,
                        isLoading: model.isLoadingPreview
                    )
                    .inspectorColumnWidth(min: 300, ideal: 380, max: 520)
                }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: model.selectedItem) { _, item in
            if item != nil { showInspector = true }
        }
        .alert("Access Failed", isPresented: errorPresented) {
            Button("OK") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? String(localized: "Unknown error"))
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } }
        )
    }
}

private struct SidebarView: View {
    @Bindable var model: VelluneModel
    @Binding var columnVisibility: NavigationSplitViewVisibility
    let usesCompactNavigation: Bool
    @State private var searchText = ""
    @State private var selectedKind: ContainerKind = .application
    @State private var showSettings = false

    var body: some View {
        List {
            if model.selfTestReport?.passed != true {
                Section {
                    AccessStatusView(model: model)
                }
            }

            if !usesCompactNavigation {
                locationsSection
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
                    ForEach(containers) { container in
                        Button {
                            Task {
                                await model.open(container)
                                if usesCompactNavigation { columnVisibility = .detailOnly }
                            }
                        } label: {
                            ContainerRow(container: container)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens the container at \(container.path)")
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
                HStack(spacing: 8) {
                    Button("Settings", systemImage: "gearshape") {
                        showSettings = true
                    }
                    .labelStyle(.iconOnly)
                    if usesCompactNavigation {
                        locationsMenu
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showSettings) {
            SettingsView(model: model)
        }
    }

    @ViewBuilder private var locationsSection: some View {
        Section("Locations") {
            ForEach(ContainerKind.allCases, id: \.self) { kind in
                locationButton(kind)
            }
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

    private func locationButton(_ kind: ContainerKind) -> some View {
        Button {
            selectedKind = kind
        } label: {
            HStack {
                Label(kind.localizedName, systemImage: kind.systemImage)
                Spacer()
                Text(model.containerIndexes[kind, default: []].count, format: .number)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .fontWeight(selectedKind == kind ? .semibold : .regular)
        .listRowBackground(selectedKind == kind ? Color.accentColor.opacity(0.12) : Color.clear)
        .accessibilityAddTraits(selectedKind == kind ? .isSelected : [])
    }

    private func filteredContainers(for kind: ContainerKind) -> [ContainerDescriptor] {
        let containers = model.containerIndexes[kind, default: []]
        guard !searchText.isEmpty else { return containers }
        return containers.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
                || $0.uuid.localizedCaseInsensitiveContains(searchText)
        }
    }

}

private struct SettingsView: View {
    @Bindable var model: VelluneModel
    @Environment(\.dismiss) private var dismiss
    @State private var cacheMessage: String?

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
                    LabeledContent("Mode", value: "Read only")
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
        if model.isRunningDiagnostics { return "shield.lefthalf.filled.badge.checkmark" }
        if model.selfTestReport == nil { return "shield.slash" }
        return "exclamationmark.shield.fill"
    }

    private var statusColor: Color {
        if model.isRunningDiagnostics { return .secondary }
        if model.selfTestReport == nil { return .secondary }
        return .orange
    }

    private var statusTitle: LocalizedStringResource {
        if model.isRunningDiagnostics { return "Verifying access…" }
        if model.selfTestReport == nil { return "Access not verified" }
        return "Access verification failed"
    }

    private var statusDetail: LocalizedStringResource {
        if model.isRunningDiagnostics { return "Running on-device compatibility checks" }
        if model.selfTestReport == nil { return "Run the self-test from Settings" }
        return "Open Settings to review diagnostics"
    }
}

private struct ContainerRow: View {
    let container: ContainerDescriptor

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "shippingbox")
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(container.displayName)
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
        }
        .padding(.vertical, 3)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

private struct BrowserView: View {
    @Bindable var model: VelluneModel
    @Binding var showInspector: Bool
    @FocusState private var pathFocused: Bool
    @State private var showFileSearch = false
    @State private var fileFilter = ""
    @State private var pathInput = ""

    private var visibleItems: [FileItem] {
        guard !fileFilter.isEmpty else { return model.items }
        return model.items.filter { $0.name.localizedCaseInsensitiveContains(fileFilter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !model.path.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        navigationButtons
                        pathEntry
                    }
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            navigationButtons
                            Spacer()
                            Text("\(visibleItems.count) items")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        pathEntry
                    }
                }
                .padding()

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
                        Task { await model.open(item) }
                    } label: {
                        FileRow(item: item)
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
        .navigationTitle(model.path.isEmpty ? String(localized: "Files") : URL(fileURLWithPath: model.path).lastPathComponent)
        .toolbar {
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
                        if model.selectedItem != nil {
                            Button("File Info", systemImage: "info.circle") {
                                showInspector = true
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

    @ViewBuilder private var navigationButtons: some View {
                    Button("Back", systemImage: "chevron.backward") {
                        Task { await model.goBack() }
                    }
                    .labelStyle(.iconOnly)
                    .disabled(!model.canGoBack)

                    Button("Forward", systemImage: "chevron.forward") {
                        Task { await model.goForward() }
                    }
                    .labelStyle(.iconOnly)
                    .disabled(!model.canGoForward)

                    Button("Up", systemImage: "chevron.up") {
                        Task { await model.goUp() }
                    }
                    .labelStyle(.iconOnly)
                    .disabled(model.isWorking || model.path == "/")
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
        }
    }
}

private struct FileRow: View {
    let item: FileItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.systemImage)
                .foregroundStyle(item.isDirectory ? .blue : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                HStack {
                    if let size = item.size, !item.isDirectory {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    }
                    if let modifiedAt = item.modifiedAt {
                        Text(modifiedAt, format: .dateTime.year().month().day().hour().minute())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
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
}

private struct InspectorView: View {
    let item: FileItem?
    let preview: FilePreview?
    let previewError: String?
    let exportURL: URL?
    let properties: FileProperties?
    let hexDump: String
    let isLoading: Bool
    @State private var selection: InspectorSection = .preview
    @State private var confirmWebSearch = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let item {
            VStack(spacing: 0) {
                Picker("View", selection: $selection) {
                    ForEach(InspectorSection.allCases) { section in Label(section.title, systemImage: section.icon).tag(section) }
                }
                .pickerStyle(.segmented)
                .padding()
                Group {
                    switch selection {
                    case .preview: PreviewContent(preview: preview, error: previewError, isLoading: isLoading)
                    case .properties: FilePropertiesView(item: item, properties: properties)
                    case .hex: TextViewer(text: hexDump, format: "Hex")
                    }
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("Info")
            .toolbar {
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
                Menu("More", systemImage: "ellipsis.circle") {
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
        } else {
            ContentUnavailableView("Select a File", systemImage: "doc.text.magnifyingglass")
        }
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
                case .binary: ContentUnavailableView("Binary File", systemImage: "doc.badge.gearshape", description: Text("Use the Hex view to inspect this file."))
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

private enum InspectorSection: String, CaseIterable, Identifiable {
    case preview, properties, hex
    var id: Self { self }
    var title: LocalizedStringResource { switch self { case .preview: "Preview"; case .properties: "Properties"; case .hex: "Hex" } }
    var icon: String { switch self { case .preview: "eye"; case .properties: "list.bullet.rectangle"; case .hex: "number" } }
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
                Section("SHA-256") { Text(properties.sha256).font(.caption.monospaced()).textSelection(.enabled) }
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
        if model.isRunningDiagnostics {
            Label("Verifying…", systemImage: "progress.indicator")
                .foregroundStyle(.secondary)
        } else if let report = model.selfTestReport {
            if report.passed {
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

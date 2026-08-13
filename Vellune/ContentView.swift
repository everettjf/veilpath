import SwiftUI

struct ContentView: View {
    @Bindable var model: VelluneModel
    @State private var showInspector = false

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 290, ideal: 340, max: 430)
        } detail: {
            BrowserView(model: model, showInspector: $showInspector)
                .inspector(isPresented: $showInspector) {
                    InspectorView(
                        item: model.selectedItem,
                        preview: model.selectedPreview,
                        previewError: model.previewError,
                        exportURL: model.selectedExportURL
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
    @State private var searchText = ""
    @State private var selectedKind: ContainerKind = .application
    @State private var showSettings = false

    var body: some View {
        List {
            Section {
                AccessStatusView(model: model)
            }

            Section("Locations") {
                ForEach(ContainerKind.allCases, id: \.self) { kind in
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
                            Task { await model.open(container) }
                        } label: {
                            ContainerRow(container: container)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens the container at \(container.path)")
                    }
                }
            } header: {
                Text(selectedKind.localizedContainerTitle)
            }

        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, placement: .sidebar, prompt: "Container name or UUID")
        .navigationTitle("Vellune")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Settings", systemImage: "gearshape") {
                    showSettings = true
                }
            }
        }
        .fullScreenCover(isPresented: $showSettings) {
            SettingsView(model: model)
        }
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
                    LabeledContent("Grant policy", value: "Per operation")
                    LabeledContent("Mode", value: "Read only")
                    if let report = model.selfTestReport {
                        LabeledContent("Self-test") {
                            TestResultText(passed: report.passed)
                        }
                    }
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
            Image(systemName: model.selfTestReport?.passed == true ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                .foregroundStyle(model.selfTestReport?.passed == true ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selfTestReport?.passed == true
                    ? LocalizedStringResource("Access verified")
                    : LocalizedStringResource("Per-operation access"))
                    .font(.callout.weight(.medium))
                Text("Grants are released after each operation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
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

    var body: some View {
        VStack(spacing: 0) {
            if !model.path.isEmpty {
                HStack(spacing: 10) {
                    Button("Up", systemImage: "chevron.up") {
                        Task { await model.goUp() }
                    }
                    .labelStyle(.iconOnly)
                    .disabled(model.isWorking || model.path == "/")

                    TextField("Absolute path", text: $model.path)
                        .font(.system(.callout, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($pathFocused)
                        .onSubmit { Task { await model.acquireAndLoad() } }

                    Button("Open", systemImage: "arrow.right.circle.fill") {
                        pathFocused = false
                        Task { await model.acquireAndLoad() }
                    }
                    .labelStyle(.iconOnly)
                    .disabled(model.isWorking)
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
                List(model.items, selection: $model.selectedItem) { item in
                    Button {
                        Task { await model.open(item) }
                    } label: {
                        FileRow(item: item)
                    }
                    .buttonStyle(.plain)
                    .tag(item)
                }
                .listStyle(.plain)
                .refreshable { await model.refresh() }
            }
        }
        .navigationTitle(model.path.isEmpty ? String(localized: "Files") : URL(fileURLWithPath: model.path).lastPathComponent)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if model.path.isEmpty {
                    if model.isWorking { ProgressView() }
                } else {
                    Menu("View Options", systemImage: "ellipsis.circle") {
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
                }
            }
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

    var body: some View {
        if let item {
            VStack(spacing: 0) {
                PreviewContent(preview: preview, error: previewError)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                List {
                    Section("File") {
                        LabeledContent("Name", value: item.name)
                        LabeledContent("Path", value: item.url.path)
                        LabeledContent("Kind") {
                            Text(item.isDirectory ? LocalizedStringResource("Directory") : LocalizedStringResource("File"))
                        }
                        if let size = item.size {
                            LabeledContent(
                                "Size",
                                value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                            )
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
            .navigationTitle("Info")
            .toolbar {
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
            }
        } else {
            ContentUnavailableView("Select a File", systemImage: "doc.text.magnifyingglass")
        }
    }
}

private struct PreviewContent: View {
    let preview: FilePreview?
    let error: String?

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
                case .text(let text):
                    ScrollView([.horizontal, .vertical]) {
                        Text(text)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding()
                    }
                case .image(let data):
                    if let image = UIImage(data: data) {
                        ScrollView([.horizontal, .vertical]) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .padding()
                        }
                    } else {
                        ContentUnavailableView("Invalid Image", systemImage: "photo.badge.exclamationmark")
                    }
                case .metadata:
                    ContentUnavailableView("No Inline Preview", systemImage: "doc")
                case .tooLarge(let size):
                    ContentUnavailableView(
                        "File Too Large",
                        systemImage: "doc.badge.ellipsis",
                        description: Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    )
                }
            } else {
                ProgressView("Loading preview…")
            }
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
                .disabled(model.isWorking)
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
        default: "Unknown Check"
        }
    }
}

#Preview {
    ContentView(model: VelluneModel())
}

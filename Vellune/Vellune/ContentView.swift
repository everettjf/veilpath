import SwiftUI

struct ContentView: View {
    @Bindable var model: VelluneModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } content: {
            BrowserView(model: model)
        } detail: {
            InspectorView(
                item: model.selectedItem,
                preview: model.selectedPreview,
                previewError: model.previewError,
                exportURL: model.selectedExportURL
            )
        }
        .alert("Access Failed", isPresented: errorPresented) {
            Button("OK") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "Unknown error")
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

    var body: some View {
        List {
            Section("Access") {
                Text("Access is granted per operation and released immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(ContainerKind.allCases, id: \.self) { kind in
                Section("\(kind.rawValue) Containers") {
                    let containers = model.containerIndexes[kind, default: []]
                    if containers.isEmpty {
                        Text(model.isWorking ? "Discovering…" : "No containers indexed")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(containers) { container in
                        Button {
                            Task { await model.open(container) }
                        } label: {
                            Label(container.displayName, systemImage: container.kind.systemImage)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                            .accessibilityHint("Opens the container at \(container.path)")
                        }
                    }
                }
            }

            Section("Diagnostics") {
                NavigationLink {
                    DiagnosticsView(model: model)
                } label: {
                    Label("Activity Log", systemImage: "waveform.path.ecg")
                }
            }
        }
        .navigationTitle("Vellune")
    }
}

private struct BrowserView: View {
    @Bindable var model: VelluneModel
    @FocusState private var pathFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Absolute path", text: $model.path)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($pathFocused)
                    .onSubmit { Task { await model.acquireAndLoad() } }

                Button("Open", systemImage: "arrow.right.circle.fill") {
                    pathFocused = false
                    Task { await model.acquireAndLoad() }
                }
                .labelStyle(.iconOnly)
                .disabled(model.path.isEmpty || model.isWorking)
            }
            .padding()

            Divider()

            if model.isWorking && model.items.isEmpty {
                ProgressView("Requesting access…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.items.isEmpty {
                ContentUnavailableView(
                    "No Directory Loaded",
                    systemImage: "folder.badge.questionmark",
                    description: Text("Enter an absolute path, then request access.")
                )
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
                .refreshable { model.refresh() }
            }
        }
        .navigationTitle(URL(fileURLWithPath: model.path).lastPathComponent)
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button("Up", systemImage: "arrow.up") {
                    Task { await model.goUp() }
                }
                .disabled(model.isWorking || model.path == "/")

                Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
                    .disabled(model.isWorking || model.items.isEmpty)
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                Toggle("Show Hidden Files", systemImage: "eye", isOn: $model.showHiddenFiles)
                    .onChange(of: model.showHiddenFiles) { model.refresh() }

                if model.isWorking { ProgressView() }
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
                        LabeledContent("Kind", value: item.isDirectory ? "Directory" : "File")
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

    var body: some View {
        List {
            Section("Runtime") {
                LabeledContent("System", value: ProcessInfo.processInfo.operatingSystemVersionString)
                LabeledContent("Grant policy", value: "Per operation")
                if let report = model.selfTestReport {
                    LabeledContent("Self-test", value: report.passed ? "Passed" : "Failed")
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
                            Text(check.name)
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
            Button("Run Self-Test", systemImage: "checkmark.circle") {
                Task { await model.runSelfTest() }
            }
            .disabled(model.isWorking)

        }
    }
}

#Preview {
    ContentView(model: VelluneModel())
}

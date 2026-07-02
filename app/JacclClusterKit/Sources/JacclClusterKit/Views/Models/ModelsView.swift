import SwiftUI
import AppKit

public struct ModelsView: View {
    @Bindable var model: AppModel
    @State private var tab: Tab = .library

    enum Tab: String, CaseIterable {
        case library = "Library"
        case browse = "Browse Hub"
    }

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
            .padding(10)
            Divider()
            switch tab {
            case .library: LibraryListView(model: model)
            case .browse: HubBrowseView(model: model)
            }
        }
        .navigationTitle("Models")
    }
}

// MARK: - Library

struct LibraryListView: View {
    @Bindable var model: AppModel

    private var library: ModelLibraryStore { model.library }

    var body: some View {
        List {
            if library.models.isEmpty {
                ContentUnavailableView(
                    "No models yet",
                    systemImage: "shippingbox",
                    description: Text("Download from the Hub tab, or drop model folders into \(model.settings.config.modelsDirectory).")
                )
            }
            ForEach(library.models) { local in
                LibraryRow(model: model, local: local)
            }
        }
        .overlay(alignment: .bottom) {
            if let error = library.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(8)
            }
        }
    }
}

struct LibraryRow: View {
    @Bindable var model: AppModel
    let local: LocalModel

    private var library: ModelLibraryStore { model.library }
    private var hosts: [String] { model.hostfiles.hosts }
    /// Workers only — rank 0 already holds the local copy.
    private var syncTargets: [String] { Array(hosts.dropFirst()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                classificationBadge
                Text(local.name).font(.headline)
                if let manifest = local.manifest {
                    Text(ByteCountFormatter.string(fromByteCount: manifest.totalBytes, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                actions
            }

            if let record = library.libraryState.downloads.values.first(where: { $0.dirName == local.name }),
               case .running(let fraction) = record.phase {
                ProgressView(value: fraction) {
                    Text("Downloading… \(ByteCountFormatter.string(fromByteCount: record.receivedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: record.totalBytes, countStyle: .file))")
                        .font(.caption)
                }
            }

            syncStatus
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var classificationBadge: some View {
        switch local.classification {
        case .complete:
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).help("Complete (verified manifest)")
        case .resumable:
            Image(systemName: "pause.circle.fill").foregroundStyle(.yellow).help("Interrupted download — resumable")
        case .imported:
            Image(systemName: "tray.and.arrow.down.fill").foregroundStyle(.blue).help("Imported manually (no manifest)")
        case .unknown:
            Image(systemName: "questionmark.circle").foregroundStyle(.secondary).help("Not recognized as a model")
        }
    }

    @ViewBuilder
    private var actions: some View {
        if local.classification == .resumable {
            Button("Resume") { library.resumeDownload(model: local) }
        }
        if local.classification == .imported {
            Button("Adopt") { library.adopt(model: local) }
                .help("Generate a manifest so this model is sync-verifiable")
        }
        if local.isServable && !syncTargets.isEmpty {
            if case .running = (library.libraryState.syncs[local.name]?.phase ?? .queued) {
                Button("Cancel sync") { library.cancelSync(model: local) }
            } else {
                Button("Sync to nodes") { library.startSync(model: local, hosts: syncTargets) }
                Button("Verify nodes") { library.verifySync(model: local, hosts: syncTargets) }
            }
        }
        Menu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([local.url])
            }
            Button("Delete from library", role: .destructive) {
                library.delete(model: local)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .fixedSize()
    }

    @ViewBuilder
    private var syncStatus: some View {
        let states = library.nodeStates(for: local)
        let record = library.libraryState.syncs[local.name]
        if !syncTargets.isEmpty && (!states.isEmpty || record != nil) {
            HStack(spacing: 10) {
                ForEach(syncTargets, id: \.self) { host in
                    HStack(spacing: 4) {
                        nodeStateIcon(states[host])
                        Text(host).font(.caption)
                        if let record, case .running = record.phase,
                           let progress = record.nodeProgress[host] {
                            ProgressView(value: progress)
                                .frame(width: 70)
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func nodeStateIcon(_ state: NodeSyncState?) -> some View {
        switch state {
        case .inSync: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        case .stale: Image(systemName: "arrow.triangle.2.circlepath.circle.fill").foregroundStyle(.orange).font(.caption)
        case .missing: Image(systemName: "circle.dashed").foregroundStyle(.secondary).font(.caption)
        case .unknown, nil: Image(systemName: "questionmark.circle").foregroundStyle(.secondary).font(.caption)
        }
    }
}

// MARK: - Hub browse

struct HubBrowseView: View {
    @Bindable var model: AppModel
    @State private var selectedModelID: String?

    private var library: ModelLibraryStore { model.library }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                searchField
                Divider()
                resultsList
            }
            .frame(minWidth: 380)

            detailPane
                .frame(minWidth: 300)
        }
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search MLX models on HuggingFace", text: searchBinding)
                .textFieldStyle(.plain)
                .onSubmit { Task { await library.search() } }
            if library.isSearching {
                ProgressView().controlSize(.small)
            }
        }
        .padding(10)
    }

    private var searchBinding: Binding<String> {
        Binding(get: { library.searchQuery }, set: { library.searchQuery = $0 })
    }

    private var resultsList: some View {
        List(selection: $selectedModelID) {
            if let error = library.searchError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
            ForEach(library.searchResults) { summary in
                HubResultRow(model: model, summary: summary)
                    .tag(summary.id)
                    .onAppear {
                        Task { await library.fetchSize(modelID: summary.id) }
                        if summary.id == library.searchResults.last?.id {
                            Task { await library.loadMore() }
                        }
                    }
            }
        }
        .task {
            if library.searchResults.isEmpty {
                await library.search()
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let id = selectedModelID,
           let summary = library.searchResults.first(where: { $0.id == id }) {
            HubDetailView(model: model, summary: summary)
        } else {
            ContentUnavailableView("Select a model", systemImage: "shippingbox")
        }
    }
}

struct HubResultRow: View {
    @Bindable var model: AppModel
    let summary: HubModelSummary

    private var library: ModelLibraryStore { model.library }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(summary.displayName).font(.callout.weight(.medium))
                    if summary.gated {
                        Text("gated")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.2), in: Capsule())
                    }
                    if let bits = quantBits {
                        Text("\(bits)-bit")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.15), in: Capsule())
                    }
                }
                HStack(spacing: 10) {
                    if let org = summary.organization {
                        Text(org).font(.caption).foregroundStyle(.secondary)
                    }
                    Label("\(summary.downloads)", systemImage: "arrow.down.circle")
                        .font(.caption).foregroundStyle(.secondary)
                    Label("\(summary.likes)", systemImage: "heart")
                        .font(.caption).foregroundStyle(.secondary)
                    if let size = library.sizeCache[summary.id] {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if library.isInstalled(modelID: summary.id) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    .help("Installed")
            }
        }
        .padding(.vertical, 2)
    }

    /// Quant bits from tags like "4-bit" when present.
    private var quantBits: Int? {
        for tag in summary.tags {
            if tag.hasSuffix("-bit"), let bits = Int(tag.dropLast(4)) {
                return bits
            }
        }
        return nil
    }
}

struct HubDetailView: View {
    @Bindable var model: AppModel
    let summary: HubModelSummary

    private var library: ModelLibraryStore { model.library }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(summary.id).font(.title3.weight(.semibold)).textSelection(.enabled)

            HStack(spacing: 10) {
                downloadControls
                if let size = library.sizeCache[summary.id] {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .foregroundStyle(.secondary)
                }
            }

            if let record = library.libraryState.downloads[summary.id] {
                downloadProgress(record)
            }

            Divider()
            Text("Files").font(.headline)
            fileList
            Spacer()
        }
        .padding(14)
        .task(id: summary.id) {
            await library.fetchTree(modelID: summary.id)
            await library.fetchSize(modelID: summary.id)
        }
    }

    @ViewBuilder
    private var downloadControls: some View {
        let record = library.libraryState.downloads[summary.id]
        if library.isInstalled(modelID: summary.id) {
            Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else if let record, case .running = record.phase {
            Button("Cancel") { library.cancelDownload(modelID: summary.id) }
        } else {
            Button {
                library.startDownload(modelID: summary.id)
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private func downloadProgress(_ record: DownloadTaskRecord) -> some View {
        switch record.phase {
        case .running(let fraction):
            ProgressView(value: fraction) {
                Text("\(ByteCountFormatter.string(fromByteCount: record.receivedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: record.totalBytes, countStyle: .file))")
                    .font(.caption)
            }
        case .paused:
            Label("Paused — resume from the Library tab", systemImage: "pause.circle")
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .font(.caption).foregroundStyle(.red)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var fileList: some View {
        if let files = library.treeCache[summary.id] {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(files, id: \.path) { file in
                        HStack {
                            Text(file.path)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }
}

import Foundation
import Observation

/// Narrow seam consumed by the server side (model picker): the library's
/// servable model directories, nothing else.
@MainActor
public protocol ModelLibraryProviding: AnyObject {
    var servableModels: [LocalModel] { get }
}

/// Facade over the whole downloads subsystem: hub search, download engine,
/// local library scan, and cluster sync. All UI state lives here.
@MainActor
@Observable
public final class ModelLibraryStore: ModelLibraryProviding {
    // MARK: Library

    public private(set) var models: [LocalModel] = []
    public var servableModels: [LocalModel] {
        models.filter(\.isServable)
    }

    // MARK: Hub browse

    public var searchQuery: String = ""
    public private(set) var searchResults: [HubModelSummary] = []
    public private(set) var searchCursor: URL?
    public private(set) var isSearching = false
    public private(set) var searchError: String?
    /// Lazy per-row total size cache (modelID → bytes).
    public private(set) var sizeCache: [String: Int64] = [:]
    /// Detail pane: file listing cache.
    public private(set) var treeCache: [String: [HubTreeFile]] = [:]

    // MARK: Tasks

    public private(set) var libraryState: LibraryState
    public private(set) var lastError: String?

    @ObservationIgnored private weak var settings: SettingsStore?
    @ObservationIgnored private var hub: HubClient
    @ObservationIgnored private var downloadEngine: DownloadEngine?
    @ObservationIgnored private var syncEngine: SyncEngine?
    @ObservationIgnored private let watcher = DirectoryWatcher()

    public init(settings: SettingsStore) {
        self.settings = settings
        self.libraryState = LibraryState.load()
        self.hub = HubClient(token: settings.resolveHFToken())
        rebuildEngines()
        rescan()
        libraryState.reconcile(with: models)
        libraryState.save()
        startWatching()
    }

    private var libraryRoot: URL {
        settings?.config.modelsDirectoryURL ?? URL(fileURLWithPath: NSString(string: "~/models_mlx").expandingTildeInPath)
    }

    /// Call after the HF token or rsync path settings change.
    public func rebuildEngines() {
        hub = HubClient(token: settings?.resolveHFToken())
        let hubClient = hub
        downloadEngine = DownloadEngine(hub: hubClient) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleDownloadEvent(event)
            }
        }
        syncEngine = SyncEngine(rsyncPath: settings?.config.rsyncPath ?? "") { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleSyncEvent(event)
            }
        }
    }

    // MARK: Library scan

    public func rescan() {
        try? FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        models = LocalModelScanner.scan(libraryRoot: libraryRoot)
    }

    public func startWatching() {
        watcher.watch(libraryRoot) { [weak self] in
            Task { @MainActor [weak self] in
                self?.rescan()
            }
        }
    }

    public func adopt(model: LocalModel) {
        do {
            _ = try LocalModelScanner.adopt(modelDir: model.url, repoID: nil)
            rescan()
        } catch {
            lastError = "Adopt failed: \(error.localizedDescription)"
        }
    }

    public func delete(model: LocalModel) {
        do {
            try FileManager.default.removeItem(at: model.url)
            libraryState.nodeSyncStates[model.name] = nil
            libraryState.save()
            rescan()
        } catch {
            lastError = "Delete failed: \(error.localizedDescription)"
        }
    }

    public func isInstalled(modelID: String) -> Bool {
        models.contains { $0.repoID == modelID && $0.classification == .complete }
    }

    // MARK: Hub browse

    public func search() async {
        guard !isSearching else { return }
        isSearching = true
        searchError = nil
        defer { isSearching = false }
        do {
            let page = try await hub.search(query: searchQuery)
            searchResults = page.models
            searchCursor = page.nextCursor
        } catch {
            searchError = error.localizedDescription
        }
    }

    public func loadMore() async {
        guard let cursor = searchCursor, !isSearching else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            let page = try await hub.search(query: searchQuery, cursor: cursor)
            searchResults.append(contentsOf: page.models)
            searchCursor = page.nextCursor
        } catch {
            searchError = error.localizedDescription
        }
    }

    /// Lazy per-row size fetch (browse list onAppear).
    public func fetchSize(modelID: String) async {
        guard sizeCache[modelID] == nil else { return }
        if let size = try? await hub.usedStorage(modelID: modelID) {
            sizeCache[modelID] = size
        }
    }

    public func fetchTree(modelID: String) async {
        guard treeCache[modelID] == nil else { return }
        do {
            let info = try await hub.info(modelID: modelID)
            treeCache[modelID] = try await hub.tree(modelID: modelID, revision: info.sha)
        } catch {
            searchError = error.localizedDescription
        }
    }

    // MARK: Downloads

    public func startDownload(modelID: String) {
        guard let engine = downloadEngine else { return }
        var record = libraryState.downloads[modelID]
            ?? DownloadTaskRecord(modelID: modelID, dirName: modelID.split(separator: "/").last.map(String.init) ?? modelID)
        record.phase = .running(fractionCompleted: 0)
        record.updatedAt = Date()
        libraryState.downloads[modelID] = record
        libraryState.save()

        let root = libraryRoot
        Task {
            await engine.download(modelID: modelID, into: root)
        }
    }

    public func cancelDownload(modelID: String) {
        guard let engine = downloadEngine else { return }
        Task {
            await engine.cancel(modelID: modelID)
        }
    }

    public func resumeDownload(model: LocalModel) {
        guard let repoID = model.sidecar?.repoID else { return }
        startDownload(modelID: repoID)
    }

    private func handleDownloadEvent(_ event: DownloadEngineEvent) {
        switch event {
        case .planned(let modelID, let dirName, let totalBytes, _):
            var record = libraryState.downloads[modelID] ?? DownloadTaskRecord(modelID: modelID, dirName: dirName)
            record.dirName = dirName
            record.totalBytes = totalBytes
            record.phase = .running(fractionCompleted: record.totalBytes > 0 ? Double(record.receivedBytes) / Double(record.totalBytes) : 0)
            record.updatedAt = Date()
            libraryState.downloads[modelID] = record
            libraryState.save()
        case .progress(let modelID, let received, let total):
            guard var record = libraryState.downloads[modelID] else { return }
            record.receivedBytes = received
            record.totalBytes = total
            record.phase = .running(fractionCompleted: total > 0 ? Double(received) / Double(total) : 0)
            record.updatedAt = Date()
            libraryState.downloads[modelID] = record
            // High-frequency: skip disk persistence here; byte-resume lives in sidecars.
        case .fileCompleted:
            break
        case .completed(let modelID, _):
            if var record = libraryState.downloads[modelID] {
                record.phase = .completed
                record.receivedBytes = record.totalBytes
                record.updatedAt = Date()
                libraryState.downloads[modelID] = record
            }
            libraryState.save()
            rescan()
        case .failed(let modelID, let message):
            if var record = libraryState.downloads[modelID] {
                record.phase = .failed(message: message)
                record.updatedAt = Date()
                libraryState.downloads[modelID] = record
            }
            libraryState.save()
            lastError = message
            rescan()
        case .cancelled(let modelID):
            if var record = libraryState.downloads[modelID] {
                record.phase = .paused
                record.updatedAt = Date()
                libraryState.downloads[modelID] = record
            }
            libraryState.save()
            rescan()
        }
    }

    // MARK: Sync

    public func nodeStates(for model: LocalModel) -> [String: NodeSyncState] {
        libraryState.nodeSyncStates[model.name] ?? [:]
    }

    public func startSync(model: LocalModel, hosts: [String]) {
        guard let engine = syncEngine, !hosts.isEmpty else { return }
        var record = libraryState.syncs[model.name] ?? SyncTaskRecord(modelName: model.name)
        record.phase = .running(fractionCompleted: 0)
        record.nodeProgress = [:]
        record.updatedAt = Date()
        libraryState.syncs[model.name] = record
        libraryState.save()

        let parallel = max(1, settings?.config.maxParallelSyncs ?? 1)
        Task {
            let states = await engine.sync(model: model, hosts: hosts, maxParallel: parallel)
            await MainActor.run { [weak self] in
                guard let self else { return }
                var nodeStates = self.libraryState.nodeSyncStates[model.name] ?? [:]
                for (host, state) in states {
                    nodeStates[host] = state
                }
                self.libraryState.nodeSyncStates[model.name] = nodeStates
                if var record = self.libraryState.syncs[model.name] {
                    let allInSync = states.values.allSatisfy { $0 == .inSync }
                    record.phase = allInSync ? .completed : .failed(message: "Some nodes are not in sync.")
                    record.nodeStates = nodeStates
                    record.updatedAt = Date()
                    self.libraryState.syncs[model.name] = record
                }
                self.libraryState.save()
            }
        }
    }

    public func cancelSync(model: LocalModel) {
        guard let engine = syncEngine else { return }
        Task {
            await engine.cancel(model: model.name)
        }
    }

    /// Manual "Verify all nodes": a sync of an already-synced model is itself
    /// the verification pass (rsync sends nothing; dry-run itemize confirms).
    public func verifySync(model: LocalModel, hosts: [String]) {
        startSync(model: model, hosts: hosts)
    }

    private func handleSyncEvent(_ event: SyncEngineEvent) {
        switch event {
        case .nodeStarted(let model, let host):
            if var record = libraryState.syncs[model] {
                record.nodeProgress[host] = 0
                libraryState.syncs[model] = record
            }
        case .nodeProgress(let model, let host, let transferred, let total, _):
            if var record = libraryState.syncs[model] {
                record.nodeProgress[host] = total > 0 ? Double(transferred) / Double(total) : 0
                record.phase = .running(fractionCompleted: record.nodeProgress.values.reduce(0, +) / Double(max(record.nodeProgress.count, 1)))
                libraryState.syncs[model] = record
            }
        case .nodeCompleted(let model, let host, let verified):
            var nodeStates = libraryState.nodeSyncStates[model] ?? [:]
            nodeStates[host] = verified ? .inSync : .stale
            libraryState.nodeSyncStates[model] = nodeStates
            if var record = libraryState.syncs[model] {
                record.nodeProgress[host] = 1
                record.nodeStates = nodeStates
                libraryState.syncs[model] = record
            }
            libraryState.save()
        case .nodeFailed(let model, let host, let message):
            var nodeStates = libraryState.nodeSyncStates[model] ?? [:]
            if nodeStates[host] == nil || nodeStates[host] == .inSync {
                nodeStates[host] = .unknown
            }
            libraryState.nodeSyncStates[model] = nodeStates
            libraryState.save()
            lastError = "\(host): \(message)"
        case .modelFinished:
            break
        }
    }
}

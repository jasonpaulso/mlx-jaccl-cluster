import Foundation

/// Unified lifecycle for download and sync tasks.
public enum TaskPhase: Codable, Sendable, Equatable {
    case queued
    case running(fractionCompleted: Double)
    case paused
    case failed(message: String)
    case completed

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed: true
        default: false
        }
    }
}

/// Persisted record of a model download.
public struct DownloadTaskRecord: Codable, Identifiable, Sendable, Equatable {
    public var id: String { modelID }
    public var modelID: String
    public var dirName: String
    public var phase: TaskPhase
    public var receivedBytes: Int64
    public var totalBytes: Int64
    public var updatedAt: Date

    public init(modelID: String, dirName: String, phase: TaskPhase = .queued,
                receivedBytes: Int64 = 0, totalBytes: Int64 = 0, updatedAt: Date = Date()) {
        self.modelID = modelID
        self.dirName = dirName
        self.phase = phase
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.updatedAt = updatedAt
    }
}

/// Persisted record of a model→cluster sync (one entry per node).
public struct SyncTaskRecord: Codable, Identifiable, Sendable, Equatable {
    public var id: String { modelName }
    public var modelName: String
    public var phase: TaskPhase
    public var nodeStates: [String: NodeSyncState]
    public var nodeProgress: [String: Double]
    public var updatedAt: Date

    public init(modelName: String, phase: TaskPhase = .queued,
                nodeStates: [String: NodeSyncState] = [:],
                nodeProgress: [String: Double] = [:], updatedAt: Date = Date()) {
        self.modelName = modelName
        self.phase = phase
        self.nodeStates = nodeStates
        self.nodeProgress = nodeProgress
        self.updatedAt = updatedAt
    }
}

/// Everything the app persists about library work, saved atomically on every
/// phase change. Byte-level download resume lives in the model-dir sidecars;
/// on launch this state is reconciled against a disk scan (disk wins).
public struct LibraryState: Codable, Sendable, Equatable {
    public var downloads: [String: DownloadTaskRecord] = [:]
    public var syncs: [String: SyncTaskRecord] = [:]
    /// Last known per-node sync state per model name: model → host → state.
    public var nodeSyncStates: [String: [String: NodeSyncState]] = [:]

    public init() {}

    public static func defaultURL() -> URL {
        SettingsStore.defaultConfigURL()
            .deletingLastPathComponent()
            .appendingPathComponent("ModelLibrary/state.json")
    }

    public static func load(from url: URL = LibraryState.defaultURL()) -> LibraryState {
        guard let data = try? Data(contentsOf: url),
              let state = try? ModelManifest.decoder().decode(LibraryState.self, from: data)
        else { return LibraryState() }
        return state
    }

    public func save(to url: URL = LibraryState.defaultURL()) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try ModelManifest.encoder().encode(self)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("JacclCluster: failed to save library state: \(error.localizedDescription)")
        }
    }

    /// Disk wins: downloads whose dirs became complete are completed; dirs with
    /// sidecars come back `paused` with all bytes intact; vanished dirs drop out.
    public mutating func reconcile(with models: [LocalModel]) {
        let byDirName = Dictionary(uniqueKeysWithValues: models.map { ($0.name, $0) })
        for (id, record) in downloads {
            var record = record
            guard let model = byDirName[record.dirName] else {
                if record.phase.isTerminal == false {
                    downloads[id] = nil // directory removed out from under us
                }
                continue
            }
            switch model.classification {
            case .complete:
                record.phase = .completed
                record.receivedBytes = record.totalBytes
            case .resumable:
                if case .running = record.phase {
                    record.phase = .paused // app died mid-download
                }
            default:
                break
            }
            downloads[id] = record
        }
        for (name, record) in syncs {
            if case .running = record.phase {
                var record = record
                record.phase = .paused
                syncs[name] = record
            }
        }
    }
}

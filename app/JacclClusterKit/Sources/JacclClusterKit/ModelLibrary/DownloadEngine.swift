import Foundation

/// Progress + lifecycle events emitted by the download engine.
public enum DownloadEngineEvent: Sendable {
    case planned(modelID: String, dirName: String, totalBytes: Int64, fileCount: Int)
    case progress(modelID: String, receivedBytes: Int64, totalBytes: Int64)
    case fileCompleted(modelID: String, path: String)
    case completed(modelID: String, modelDir: URL)
    case failed(modelID: String, message: String)
    case cancelled(modelID: String)
}

public enum DownloadEngineError: Error, LocalizedError, Sendable {
    case insufficientDiskSpace(needed: Int64, available: Int64)
    case alreadyDownloading(String)

    public var errorDescription: String? {
        switch self {
        case .insufficientDiskSpace(let needed, let available):
            let f = ByteCountFormatter()
            return "Not enough disk space: need \(f.string(fromByteCount: needed)), only \(f.string(fromByteCount: available)) available."
        case .alreadyDownloading(let id):
            return "\(id) is already downloading."
        }
    }
}

/// Seam for tests / future alternate backends.
public protocol ModelDownloading: Sendable {
    func download(modelID: String, into libraryRoot: URL) async
    func cancel(modelID: String) async
}

/// Native URLSession download engine: plans from the Hub tree API (commit-pinned),
/// streams files with Range resume + incremental hashes, and finishes by writing
/// the completeness manifest.
public actor DownloadEngine: ModelDownloading {
    private let hub: HubClient
    private let onEvent: @Sendable (DownloadEngineEvent) -> Void
    private var active: [String: Task<Void, Never>] = [:]
    private var sleepAssertion: NSObjectProtocol?

    public let maxConcurrentFiles: Int
    public let maxAttemptsPerFile: Int

    public init(hub: HubClient,
                maxConcurrentFiles: Int = 3,
                maxAttemptsPerFile: Int = 5,
                onEvent: @escaping @Sendable (DownloadEngineEvent) -> Void) {
        self.hub = hub
        self.maxConcurrentFiles = maxConcurrentFiles
        self.maxAttemptsPerFile = maxAttemptsPerFile
        self.onEvent = onEvent
    }

    // MARK: Public API

    public func download(modelID: String, into libraryRoot: URL) async {
        guard active[modelID] == nil else { return }
        let task = Task { await self.runDownload(modelID: modelID, libraryRoot: libraryRoot) }
        active[modelID] = task
        updateSleepAssertion()
        await task.value
        active[modelID] = nil
        updateSleepAssertion()
    }

    /// Resume a `resumable` directory found on launch (sidecar present).
    public func resume(modelDir: URL, libraryRoot: URL) async {
        guard let sidecar = DownloadSidecar.load(fromModelDir: modelDir) else { return }
        await download(modelID: sidecar.repoID, into: libraryRoot)
    }

    public func cancel(modelID: String) {
        active[modelID]?.cancel()
    }

    public var activeModelIDs: [String] {
        Array(active.keys)
    }

    // MARK: Core flow

    private func runDownload(modelID: String, libraryRoot: URL) async {
        do {
            // 1. Resolve + pin revision; refuse gated without token.
            let info = try await hub.info(modelID: modelID)
            if info.gated && hub.token == nil {
                throw HubError.gatedModel(modelID)
            }

            let dirName = Self.directoryName(for: modelID, in: libraryRoot)
            let modelDir = libraryRoot.appendingPathComponent(dirName, isDirectory: true)
            try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

            // 2. Plan: reuse a matching sidecar (resume), else fetch the tree.
            var sidecar: DownloadSidecar
            if let existing = DownloadSidecar.load(fromModelDir: modelDir), existing.revision == info.sha {
                sidecar = existing
            } else {
                let tree = try await hub.tree(modelID: modelID, revision: info.sha)
                let files: [ManifestFile] = tree
                    .filter { $0.path != ".gitattributes" }
                    .map { file in
                        let checksum: FileChecksum
                        if let sha = file.lfsSHA256 {
                            checksum = .sha256(sha)
                        } else if let oid = file.gitOid {
                            checksum = .gitSHA1(oid)
                        } else {
                            checksum = .none
                        }
                        return ManifestFile(path: file.path, size: file.size, checksum: checksum)
                    }
                sidecar = DownloadSidecar(repoID: modelID, revision: info.sha, files: files)
                try sidecar.save(toModelDir: modelDir)
            }

            let totalBytes = sidecar.files.reduce(Int64(0)) { $0 + $1.size }
            onEvent(.planned(modelID: modelID, dirName: dirName, totalBytes: totalBytes, fileCount: sidecar.files.count))

            // 3. Disk preflight — fail the 500GB case before the first byte.
            let remainingBytes = sidecar.files
                .filter { !sidecar.completedPaths.contains($0.path) }
                .reduce(Int64(0)) { $0 + $1.size }
            try Self.preflightDiskSpace(at: libraryRoot, needed: remainingBytes + 2 * 1024 * 1024 * 1024)

            // 4. Fetch (windowed concurrency), tracking overall progress.
            let progress = DownloadProgressAggregator(
                completedBytes: sidecar.files
                    .filter { sidecar.completedPaths.contains($0.path) }
                    .reduce(Int64(0)) { $0 + $1.size },
                totalBytes: totalBytes
            ) { [onEvent] received, total in
                onEvent(.progress(modelID: modelID, receivedBytes: received, totalBytes: total))
            }

            let pending = sidecar.files.filter { !sidecar.completedPaths.contains($0.path) }
            let revision = sidecar.revision

            try await withThrowingTaskGroup(of: String.self) { group in
                var iterator = pending.makeIterator()
                var inFlight = 0

                // Prime the concurrency window.
                while inFlight < maxConcurrentFiles, let file = iterator.next() {
                    inFlight += 1
                    group.addTask {
                        try await self.fetchFile(file, modelID: modelID, revision: revision, modelDir: modelDir, progress: progress)
                        return file.path
                    }
                }
                while inFlight > 0 {
                    guard let completedPath = try await group.next() else { break }
                    inFlight -= 1
                    sidecar.completedPaths.insert(completedPath)
                    try sidecar.save(toModelDir: modelDir)
                    onEvent(.fileCompleted(modelID: modelID, path: completedPath))
                    if let file = iterator.next() {
                        inFlight += 1
                        group.addTask {
                            try await self.fetchFile(file, modelID: modelID, revision: revision, modelDir: modelDir, progress: progress)
                            return file.path
                        }
                    }
                }
            }

            // 5. Finalize: manifest in, sidecar out.
            try sidecar.toManifest().save(toModelDir: modelDir)
            DownloadSidecar.delete(fromModelDir: modelDir)
            onEvent(.completed(modelID: modelID, modelDir: modelDir))
        } catch is CancellationError {
            onEvent(.cancelled(modelID: modelID))
        } catch FileDownloadError.cancelled {
            onEvent(.cancelled(modelID: modelID))
        } catch {
            onEvent(.failed(modelID: modelID, message: error.localizedDescription))
        }
    }

    private func fetchFile(_ file: ManifestFile, modelID: String, revision: String,
                           modelDir: URL, progress: DownloadProgressAggregator) async throws {
        var attempt = 0
        while true {
            attempt += 1
            try Task.checkCancellation()
            do {
                let downloader = FileDownloader(
                    destination: modelDir.appendingPathComponent(file.path),
                    expectedSize: file.size,
                    checksum: file.checksum
                ) { bytes in
                    progress.setFileBytes(path: file.path, bytes: bytes)
                }
                // Fresh resolve URL every attempt — redirect targets expire.
                let url = hub.resolveURL(modelID: modelID, revision: revision, path: file.path)
                try await downloader.run(url: url, token: hub.token)
                progress.markFileDone(path: file.path, size: file.size)
                return
            } catch let error as HubError {
                if case .rateLimited(let retryAfter) = error, attempt < maxAttemptsPerFile {
                    try await Task.sleep(nanoseconds: UInt64((retryAfter ?? 30) * 1_000_000_000))
                    continue
                }
                throw error
            } catch FileDownloadError.cancelled {
                throw FileDownloadError.cancelled
            } catch {
                guard attempt < maxAttemptsPerFile else { throw error }
                // Exponential backoff: 2, 4, 8, 16s.
                let delay = min(pow(2.0, Double(attempt)), 30)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    // MARK: Helpers

    /// Directory named by repo basename (matches the cluster convention);
    /// org-prefixed on collision with a different repo.
    public static func directoryName(for modelID: String, in libraryRoot: URL) -> String {
        let base = modelID.split(separator: "/").last.map(String.init) ?? modelID
        let candidate = libraryRoot.appendingPathComponent(base)
        if let manifest = ModelManifest.load(fromModelDir: candidate), manifest.repoID != modelID {
            return modelID.replacingOccurrences(of: "/", with: "--")
        }
        if let sidecar = DownloadSidecar.load(fromModelDir: candidate), sidecar.repoID != modelID {
            return modelID.replacingOccurrences(of: "/", with: "--")
        }
        return base
    }

    static func preflightDiskSpace(at url: URL, needed: Int64) throws {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return }
        if available < needed {
            throw DownloadEngineError.insufficientDiskSpace(needed: needed, available: available)
        }
    }

    /// Prevent idle sleep while any download is active.
    private func updateSleepAssertion() {
        if active.isEmpty {
            if let token = sleepAssertion {
                ProcessInfo.processInfo.endActivity(token)
                sleepAssertion = nil
            }
        } else if sleepAssertion == nil {
            sleepAssertion = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
                reason: "Downloading model files"
            )
        }
    }
}

/// Thread-safe aggregate progress across concurrently downloading files,
/// throttled to ~4 events/second.
final class DownloadProgressAggregator: @unchecked Sendable {
    private let lock = NSLock()
    private var fileBytes: [String: Int64] = [:]
    private var completedBytes: Int64
    private let totalBytes: Int64
    private var lastReport = Date.distantPast
    private let onProgress: @Sendable (Int64, Int64) -> Void

    init(completedBytes: Int64, totalBytes: Int64, onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.onProgress = onProgress
    }

    func setFileBytes(path: String, bytes: Int64) {
        lock.lock()
        fileBytes[path] = bytes
        let now = Date()
        let shouldReport = now.timeIntervalSince(lastReport) > 0.25
        if shouldReport { lastReport = now }
        let received = completedBytes + fileBytes.values.reduce(0, +)
        lock.unlock()
        if shouldReport {
            onProgress(min(received, totalBytes), totalBytes)
        }
    }

    func markFileDone(path: String, size: Int64) {
        lock.lock()
        fileBytes[path] = nil
        completedBytes += size
        let received = completedBytes + fileBytes.values.reduce(0, +)
        lock.unlock()
        onProgress(min(received, totalBytes), totalBytes)
    }
}

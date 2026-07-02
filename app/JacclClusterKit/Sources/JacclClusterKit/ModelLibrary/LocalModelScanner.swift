import Foundation

/// Classification of a directory in the model library.
public enum ModelDirClassification: String, Sendable, Equatable {
    /// `.jaccl-manifest.json` present — fully downloaded and verified.
    case complete
    /// `.jaccl-download.json` sidecar present — interrupted download, resumable.
    case resumable
    /// Looks like a model (config.json + *.safetensors) but predates the app —
    /// syncable with size-only verify; "adopt" generates a manifest.
    case imported
    /// Anything else.
    case unknown
}

/// One directory in the local model library.
public struct LocalModel: Identifiable, Sendable, Equatable {
    public let url: URL
    public let name: String
    public let classification: ModelDirClassification
    public let manifest: ModelManifest?
    public let sidecar: DownloadSidecar?
    /// Bytes on disk (best effort; nil until computed).
    public var sizeOnDisk: Int64?

    public var id: String { url.path }

    /// Repo the directory came from, when known.
    public var repoID: String? {
        manifest?.repoID ?? sidecar?.repoID
    }

    /// Whether the server may launch against this directory (upholds the
    /// HF_HUB_OFFLINE contract structurally: never point MODEL_DIR at a
    /// partial download).
    public var isServable: Bool {
        classification == .complete || classification == .imported
    }
}

public enum LocalModelScanner {
    /// Scans the library root and classifies each subdirectory.
    public static func scan(libraryRoot: URL) -> [LocalModel] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: libraryRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { classify(modelDir: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func classify(modelDir: URL) -> LocalModel {
        let name = modelDir.lastPathComponent
        if let manifest = ModelManifest.load(fromModelDir: modelDir) {
            return LocalModel(url: modelDir, name: name, classification: .complete, manifest: manifest, sidecar: nil)
        }
        if let sidecar = DownloadSidecar.load(fromModelDir: modelDir) {
            return LocalModel(url: modelDir, name: name, classification: .resumable, manifest: nil, sidecar: sidecar)
        }
        if looksLikeModel(modelDir) {
            return LocalModel(url: modelDir, name: name, classification: .imported, manifest: nil, sidecar: nil)
        }
        return LocalModel(url: modelDir, name: name, classification: .unknown, manifest: nil, sidecar: nil)
    }

    static func looksLikeModel(_ dir: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.appendingPathComponent("config.json").path) else { return false }
        let contents = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        return contents.contains { $0.hasSuffix(".safetensors") }
    }

    /// "Adopt" a pre-existing manual download: generate a size-only manifest so
    /// it becomes a first-class library member (sync-verifiable by name+size).
    public static func adopt(modelDir: URL, repoID: String?) throws -> ModelManifest {
        let fm = FileManager.default
        var files: [ManifestFile] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        // The enumerator returns symlink-resolved URLs (/private/var vs /var);
        // resolve both sides before computing relative paths.
        let basePath = modelDir.resolvingSymlinksInPath().path
        if let enumerator = fm.enumerator(at: modelDir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                let values = try? fileURL.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile == true else { continue }
                let filePath = fileURL.resolvingSymlinksInPath().path
                let relative = String(filePath.dropFirst(basePath.count).drop(while: { $0 == "/" }))
                guard relative != ModelManifest.filename, relative != DownloadSidecar.filename else { continue }
                files.append(ManifestFile(
                    path: relative,
                    size: Int64(values?.fileSize ?? 0),
                    checksum: .none
                ))
            }
        }
        let manifest = ModelManifest(
            repoID: repoID ?? modelDir.lastPathComponent,
            revision: "adopted",
            files: files.sorted { $0.path < $1.path }
        )
        try manifest.save(toModelDir: modelDir)
        return manifest
    }

    public static func sizeOnDisk(_ dir: URL) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        if let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let fileURL as URL in enumerator {
                let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if values?.isRegularFile == true {
                    total += Int64(values?.fileSize ?? 0)
                }
            }
        }
        return total
    }
}

/// Lightweight directory watcher (kqueue via DispatchSource) that fires when
/// the library root's contents change, keeping the list live.
public final class DirectoryWatcher: @unchecked Sendable {
    private var source: (any DispatchSourceFileSystemObject)?
    private var descriptor: CInt = -1

    public init() {}

    public func watch(_ url: URL, onChange: @escaping @Sendable () -> Void) {
        stop()
        descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .global(qos: .utility)
        )
        source.setEventHandler(handler: onChange)
        let fd = descriptor
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        source = nil
        descriptor = -1
    }

    deinit {
        stop()
    }
}

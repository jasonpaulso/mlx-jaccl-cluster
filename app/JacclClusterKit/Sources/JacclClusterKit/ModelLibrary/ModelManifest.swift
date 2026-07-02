import Foundation

/// Checksum kind for a downloaded file.
public enum FileChecksum: Codable, Sendable, Equatable {
    /// LFS files: plain sha256 of the content.
    case sha256(String)
    /// Small (non-LFS) files: git blob sha1 — sha1("blob <len>\0" + content).
    case gitSHA1(String)
    case none
}

public struct ManifestFile: Codable, Sendable, Equatable {
    public var path: String
    public var size: Int64
    public var checksum: FileChecksum

    public init(path: String, size: Int64, checksum: FileChecksum) {
        self.path = path
        self.size = size
        self.checksum = checksum
    }
}

/// `.jaccl-manifest.json`, written atomically into a model directory once every
/// file has downloaded and verified. Manifest presence *is* the definition of a
/// complete model — no heuristics.
public struct ModelManifest: Codable, Sendable, Equatable {
    public static let filename = ".jaccl-manifest.json"

    public var repoID: String
    /// Hub commit sha this download was pinned to ("adopted" for imported dirs).
    public var revision: String
    public var files: [ManifestFile]
    public var createdAt: Date

    public init(repoID: String, revision: String, files: [ManifestFile], createdAt: Date = Date()) {
        self.repoID = repoID
        self.revision = revision
        self.files = files
        self.createdAt = createdAt
    }

    public var totalBytes: Int64 {
        files.reduce(0) { $0 + $1.size }
    }

    public static func load(fromModelDir dir: URL) -> ModelManifest? {
        let url = dir.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder().decode(ModelManifest.self, from: data)
    }

    public func save(toModelDir dir: URL) throws {
        let data = try Self.encoder().encode(self)
        try data.write(to: dir.appendingPathComponent(Self.filename), options: .atomic)
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// `.jaccl-download.json`, the in-progress sidecar: the pinned plan plus
/// per-file completion. Byte-level resume state is implicit in `<path>.jacclpart`
/// sizes on disk. Presence of this sidecar (and no manifest) = resumable.
public struct DownloadSidecar: Codable, Sendable, Equatable {
    public static let filename = ".jaccl-download.json"
    /// Suffix for partially downloaded files.
    public static let partSuffix = ".jacclpart"

    public var repoID: String
    public var revision: String
    public var files: [ManifestFile]
    public var completedPaths: Set<String>
    public var startedAt: Date

    public init(repoID: String, revision: String, files: [ManifestFile], completedPaths: Set<String> = [], startedAt: Date = Date()) {
        self.repoID = repoID
        self.revision = revision
        self.files = files
        self.completedPaths = completedPaths
        self.startedAt = startedAt
    }

    public static func load(fromModelDir dir: URL) -> DownloadSidecar? {
        let url = dir.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? ModelManifest.decoder().decode(DownloadSidecar.self, from: data)
    }

    public func save(toModelDir dir: URL) throws {
        let data = try ModelManifest.encoder().encode(self)
        try data.write(to: dir.appendingPathComponent(Self.filename), options: .atomic)
    }

    public static func delete(fromModelDir dir: URL) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(filename))
    }

    public func toManifest() -> ModelManifest {
        ModelManifest(repoID: repoID, revision: revision, files: files)
    }
}

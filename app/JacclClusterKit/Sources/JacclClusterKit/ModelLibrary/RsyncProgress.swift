import Foundation

/// Parses classic `rsync --progress` output (works on both Apple's openrsync —
/// which rejects `--info=progress2` — and rsync 3.x) and aggregates per-file
/// progress against a known manifest into overall bytes.
///
/// Stream shape (both flavors):
///   sending incremental file list          (rsync 3; openrsync differs)
///   model-00001-of-00004.safetensors       (filename: no leading whitespace)
///        1,234,567  45%   98.76MB/s    0:01:23   (progress: leading whitespace)
public struct RsyncProgressParser: Sendable {
    public struct Snapshot: Sendable, Equatable {
        public let currentFile: String?
        public let transferredBytes: Int64
        public let totalBytes: Int64
    }

    private let fileSizes: [String: Int64]
    public let totalBytes: Int64

    private var currentFile: String?
    private var currentFileBytes: Int64 = 0
    private var completedBytes: Int64 = 0

    public init(fileSizes: [String: Int64]) {
        self.fileSizes = fileSizes
        self.totalBytes = fileSizes.values.reduce(0, +)
    }

    public init(manifest: ModelManifest) {
        self.init(fileSizes: Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0.size) }))
    }

    /// Feed one output line; returns an updated snapshot when the line advanced progress.
    public mutating func consume(line: String) -> Snapshot? {
        if let bytes = Self.parseProgressBytes(line) {
            currentFileBytes = bytes
            return snapshot()
        }
        if let filename = Self.parseFilename(line) {
            finishCurrentFile()
            currentFile = filename
            currentFileBytes = 0
            return snapshot()
        }
        return nil
    }

    /// Call when rsync exits 0 so the last in-flight file counts as complete.
    public mutating func finish() -> Snapshot {
        finishCurrentFile()
        return snapshot()
    }

    private mutating func finishCurrentFile() {
        if let file = currentFile {
            completedBytes += fileSizes[file] ?? currentFileBytes
        }
        currentFile = nil
        currentFileBytes = 0
    }

    private func snapshot() -> Snapshot {
        let transferred = completedBytes + currentFileBytes
        return Snapshot(
            currentFile: currentFile,
            transferredBytes: totalBytes > 0 ? min(transferred, totalBytes) : transferred,
            totalBytes: totalBytes
        )
    }

    // MARK: Line classification

    /// Progress lines start with whitespace: `  1,234,567  45%  1.23MB/s  0:00:12`.
    static func parseProgressBytes(_ line: String) -> Int64? {
        guard line.first == " " || line.first == "\t" else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let firstField = trimmed.split(separator: " ").first else { return nil }
        // Require a percent field to avoid matching "sent 1234 bytes" style lines.
        guard trimmed.contains("%") else { return nil }
        let digits = firstField.replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: ".", with: "")
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return Int64(digits)
    }

    /// Filename lines have no leading whitespace and aren't rsync chatter.
    static func parseFilename(_ line: String) -> String? {
        guard let first = line.first, first != " ", first != "\t" else { return nil }
        let chatterPrefixes = [
            "sending incremental", "building file list", "created directory",
            "sent ", "total size", "receiving ", "deleting ", "rsync:", "rsync error",
            "cannot ", "skipping ",
        ]
        guard !chatterPrefixes.contains(where: { line.hasPrefix($0) }) else { return nil }
        guard !line.hasSuffix("/") else { return nil } // directory entries
        guard !line.isEmpty else { return nil }
        return line
    }
}

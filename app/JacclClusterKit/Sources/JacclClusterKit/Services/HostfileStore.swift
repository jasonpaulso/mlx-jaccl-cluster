import Foundation
import Observation

public enum HostfileStoreError: Error, LocalizedError, Sendable {
    case exampleMissing(repoPath: String)

    public var errorDescription: String? {
        switch self {
        case .exampleMissing(let repoPath):
            return """
            hostfiles/hosts.json.example not found in \(repoPath). \
            Settings → Repo path must point at a checkout of the mlx-jaccl-cluster repo \
            (the folder containing hostfiles/, server/, and scripts/).
            """
        }
    }
}

/// Owns the loaded hostfile document, its dirty state, and the list of
/// available hostfiles under `<repo>/hostfiles/`. Shared by the form editor,
/// the raw-JSON source tab, and everything that needs host lists.
@MainActor
@Observable
public final class HostfileStore {
    public private(set) var fileURL: URL?
    public var document: HostfileDocument = HostfileDocument()
    public private(set) var isDirty = false
    public private(set) var loadError: String?

    /// Live verify results keyed by ssh hostname.
    public private(set) var verifyResults: [String: NodeCheckResult] = [:]
    public private(set) var isVerifying = false

    /// Hostfiles discovered under the repo's hostfiles/ directory.
    public private(set) var availableHostfiles: [URL] = []

    @ObservationIgnored private var cleanSnapshot: HostfileDocument = HostfileDocument()
    @ObservationIgnored private let verifyService: VerifyService

    public init(verifyService: VerifyService = VerifyService()) {
        self.verifyService = verifyService
    }

    // MARK: Discovery

    public func refreshAvailableHostfiles(repoURL: URL?) {
        guard let repoURL else {
            availableHostfiles = []
            return
        }
        let dir = repoURL.appendingPathComponent("hostfiles")
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        )) ?? []
        availableHostfiles = contents
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Copies hosts.json.example → hosts.json (the gitignored working file).
    /// Throws a descriptive error when the repo path isn't actually a checkout.
    @discardableResult
    public func createFromExample(repoURL: URL) throws -> URL {
        let example = repoURL.appendingPathComponent("hostfiles/hosts.json.example")
        let target = repoURL.appendingPathComponent("hostfiles/hosts.json")
        if FileManager.default.fileExists(atPath: target.path) {
            refreshAvailableHostfiles(repoURL: repoURL)
            return target
        }
        guard FileManager.default.fileExists(atPath: example.path) else {
            throw HostfileStoreError.exampleMissing(repoPath: repoURL.path)
        }
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: example, to: target)
        refreshAvailableHostfiles(repoURL: repoURL)
        return target
    }

    // MARK: Load / save

    public func load(from url: URL) {
        do {
            let doc = try HostfileDocument.load(from: url)
            fileURL = url
            document = doc
            cleanSnapshot = doc
            isDirty = false
            loadError = nil
            verifyResults = [:]
        } catch {
            fileURL = url
            loadError = "Failed to parse \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    public func markEdited() {
        isDirty = document != cleanSnapshot
    }

    public func save() throws {
        guard let fileURL else { return }
        try document.save(to: fileURL)
        cleanSnapshot = document
        isDirty = false
    }

    public func revert() {
        document = cleanSnapshot
        isDirty = false
    }

    /// Replaces the document from raw JSON (source tab). Throws on parse failure.
    public func applySource(_ text: String) throws {
        let doc = try HostfileDocument.decode(from: Data(text.utf8))
        document = doc
        markEdited()
    }

    public func sourceText() -> String {
        (try? document.encoded()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    // MARK: Verify

    public var hosts: [String] {
        document.hosts.map(\.ssh)
    }

    public func runVerify(envPrefix: String? = nil) async {
        guard !isVerifying else { return }
        isVerifying = true
        defer { isVerifying = false }
        let results = await verifyService.verify(hosts: hosts, envPrefix: envPrefix)
        var map: [String: NodeCheckResult] = [:]
        for result in results {
            map[result.host] = result
        }
        verifyResults = map
    }

    public func cellStatus(row: Int, column: Int) -> MatrixCellStatus {
        guard document.hosts.indices.contains(row),
              document.hosts[row].rdma.indices.contains(column)
        else { return .unverified }
        return VerifyService.cellStatus(
            device: document.hosts[row].rdma[column],
            row: row,
            column: column,
            results: verifyResults,
            rowHost: document.hosts[row].ssh
        )
    }
}

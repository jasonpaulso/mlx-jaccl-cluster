import Foundation

// MARK: - API models

/// One row in Hub search results.
public struct HubModelSummary: Identifiable, Sendable, Equatable {
    public let id: String // e.g. "mlx-community/Qwen3-4B-4bit"
    public let downloads: Int
    public let likes: Int
    public let gated: Bool
    public let tags: [String]

    public var displayName: String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    public var organization: String? {
        let parts = id.split(separator: "/")
        return parts.count == 2 ? String(parts[0]) : nil
    }
}

extension HubModelSummary: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id = "modelId", fallbackID = "id", downloads, likes, gated, tags
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let modelID = try c.decodeIfPresent(String.self, forKey: .id) {
            id = modelID
        } else {
            id = try c.decode(String.self, forKey: .fallbackID)
        }
        downloads = try c.decodeIfPresent(Int.self, forKey: .downloads) ?? 0
        likes = try c.decodeIfPresent(Int.self, forKey: .likes) ?? 0
        gated = Self.decodeGated(c)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
    }

    /// `gated` is `false` | `"auto"` | `"manual"` on the Hub.
    private static func decodeGated(_ c: KeyedDecodingContainer<CodingKeys>) -> Bool {
        if let b = try? c.decode(Bool.self, forKey: .gated) { return b }
        if let s = try? c.decode(String.self, forKey: .gated) { return !s.isEmpty }
        return false
    }
}

/// Detailed model info (`GET /api/models/{id}`).
public struct HubModelInfo: Sendable, Equatable {
    public let id: String
    /// Commit sha — all download URLs are pinned to this (immutable revision
    /// makes resume-after-quit categorically safe).
    public let sha: String
    public let gated: Bool
    public let tags: [String]
    public let quantizationBits: Int?
    public let usedStorage: Int64?
}

extension HubModelInfo: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id = "modelId", fallbackID = "id", sha, gated, tags, config, usedStorage
    }

    private struct HubConfig: Decodable {
        struct Quant: Decodable {
            let bits: Int?
        }
        let quantization_config: Quant?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let modelID = try c.decodeIfPresent(String.self, forKey: .id) {
            id = modelID
        } else {
            id = try c.decode(String.self, forKey: .fallbackID)
        }
        sha = try c.decode(String.self, forKey: .sha)
        if let b = try? c.decode(Bool.self, forKey: .gated) {
            gated = b
        } else if let s = try? c.decode(String.self, forKey: .gated) {
            gated = !s.isEmpty
        } else {
            gated = false
        }
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        let hubConfig = (try? c.decodeIfPresent(HubConfig.self, forKey: .config)) ?? nil
        quantizationBits = hubConfig?.quantization_config?.bits
        usedStorage = try c.decodeIfPresent(Int64.self, forKey: .usedStorage)
    }
}

/// One file from `GET /api/models/{id}/tree/{rev}?recursive=true`.
/// LFS files carry a sha256 (`lfs.oid`); small files carry a git blob sha1 (`oid`).
public struct HubTreeFile: Sendable, Equatable {
    public let path: String
    public let size: Int64
    public let gitOid: String?
    public let lfsSHA256: String?

    public init(path: String, size: Int64, gitOid: String?, lfsSHA256: String?) {
        self.path = path
        self.size = size
        self.gitOid = gitOid
        self.lfsSHA256 = lfsSHA256
    }
}

extension HubTreeFile {
    struct Raw: Decodable {
        struct LFS: Decodable {
            let oid: String
            let size: Int64?
        }
        let type: String // "file" | "directory"
        let path: String
        let size: Int64?
        let oid: String?
        let lfs: LFS?
    }
}

// MARK: - Errors

public enum HubError: Error, LocalizedError, Sendable {
    case badURL
    case httpStatus(Int, endpoint: String)
    case gatedModel(String)
    case rateLimited(retryAfter: TimeInterval?)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .badURL: "Invalid Hub URL."
        case .httpStatus(let code, let endpoint): "Hub returned HTTP \(code) for \(endpoint)."
        case .gatedModel(let id): "'\(id)' is gated. Add a HuggingFace token with access in Settings."
        case .rateLimited(let after):
            "Rate limited by the Hub." + (after.map { " Retry after \(Int($0))s." } ?? "")
        case .decoding(let detail): "Unexpected Hub response: \(detail)"
        }
    }
}

// MARK: - Link header pagination

public enum LinkHeader {
    /// Extracts the rel="next" URL from an RFC 5988 Link header.
    public static func nextURL(from header: String?) -> URL? {
        guard let header else { return nil }
        for part in header.split(separator: ",") {
            let segments = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard segments.count >= 2,
                  segments.dropFirst().contains(where: { $0.replacingOccurrences(of: " ", with: "") == #"rel="next""# }),
                  segments[0].hasPrefix("<"), segments[0].hasSuffix(">")
            else { continue }
            let urlString = String(segments[0].dropFirst().dropLast())
            return URL(string: urlString)
        }
        return nil
    }
}

// MARK: - Client

/// Thin async client for the HuggingFace Hub REST API. All endpoint shapes
/// were verified live during design (2026-07).
public struct HubClient: Sendable {
    public let baseURL: URL
    public let token: String?
    private let session: URLSession

    public init(baseURL: URL = URL(string: "https://huggingface.co")!, token: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    func request(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        if let token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request(url))
        guard let http = response as? HTTPURLResponse else {
            throw HubError.httpStatus(-1, endpoint: url.path)
        }
        if http.statusCode == 429 {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0) }
            throw HubError.rateLimited(retryAfter: retryAfter)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HubError.httpStatus(http.statusCode, endpoint: url.path)
        }
        return (data, http)
    }

    // MARK: Search

    public struct SearchPage: Sendable {
        public let models: [HubModelSummary]
        public let nextCursor: URL?
    }

    /// Search MLX models. Pass `cursor` (from a previous page) to continue;
    /// pagination is cursor-based via the `Link: <…>; rel="next"` header.
    public func search(query: String, limit: Int = 30, cursor: URL? = nil) async throws -> SearchPage {
        let url: URL
        if let cursor {
            url = cursor
        } else {
            var components = URLComponents(url: baseURL.appendingPathComponent("api/models"), resolvingAgainstBaseURL: false)!
            var items = [
                URLQueryItem(name: "filter", value: "mlx"),
                URLQueryItem(name: "sort", value: "downloads"),
                URLQueryItem(name: "direction", value: "-1"),
                URLQueryItem(name: "limit", value: String(limit)),
            ]
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                items.insert(URLQueryItem(name: "search", value: trimmed), at: 0)
            }
            components.queryItems = items
            guard let built = components.url else { throw HubError.badURL }
            url = built
        }
        let (data, http) = try await get(url)
        do {
            let models = try JSONDecoder().decode([HubModelSummary].self, from: data)
            return SearchPage(models: models, nextCursor: LinkHeader.nextURL(from: http.value(forHTTPHeaderField: "Link")))
        } catch {
            throw HubError.decoding(error.localizedDescription)
        }
    }

    // MARK: Model info

    public func info(modelID: String) async throws -> HubModelInfo {
        // expand[]=usedStorage piggybacks the exact total repo bytes on the same call.
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/models/\(modelID)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "expand[]", value: "usedStorage"),
                                 URLQueryItem(name: "expand[]", value: "gated"),
                                 URLQueryItem(name: "expand[]", value: "sha"),
                                 URLQueryItem(name: "expand[]", value: "tags"),
                                 URLQueryItem(name: "expand[]", value: "config")]
        guard let url = components.url else { throw HubError.badURL }
        let (data, _) = try await get(url)
        do {
            return try JSONDecoder().decode(HubModelInfo.self, from: data)
        } catch {
            throw HubError.decoding(error.localizedDescription)
        }
    }

    /// Lazy per-row total size for the browse list (cached by the store).
    public func usedStorage(modelID: String) async throws -> Int64? {
        try await info(modelID: modelID).usedStorage
    }

    // MARK: File tree

    /// Full recursive file listing at a pinned revision, following Link-header
    /// pagination for large repos. This is the complete download manifest:
    /// per-file path, size, and checksum (sha256 for LFS, git sha1 otherwise).
    public func tree(modelID: String, revision: String) async throws -> [HubTreeFile] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/models/\(modelID)/tree/\(revision)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "recursive", value: "true")]
        guard var pageURL = components.url else { throw HubError.badURL }

        var files: [HubTreeFile] = []
        while true {
            let (data, http) = try await get(pageURL)
            let raw: [HubTreeFile.Raw]
            do {
                raw = try JSONDecoder().decode([HubTreeFile.Raw].self, from: data)
            } catch {
                throw HubError.decoding(error.localizedDescription)
            }
            for entry in raw where entry.type == "file" {
                files.append(HubTreeFile(
                    path: entry.path,
                    size: entry.lfs?.size ?? entry.size ?? 0,
                    gitOid: entry.oid,
                    lfsSHA256: entry.lfs?.oid
                ))
            }
            guard let next = LinkHeader.nextURL(from: http.value(forHTTPHeaderField: "Link")) else {
                break
            }
            pageURL = next
        }
        return files
    }

    // MARK: Download URLs

    /// Commit-pinned resolve URL; 302-redirects to the CDN/Xet bridge and
    /// URLSession follows automatically. Always request fresh on retry —
    /// redirect targets expire.
    public func resolveURL(modelID: String, revision: String, path: String) -> URL {
        baseURL
            .appendingPathComponent(modelID)
            .appendingPathComponent("resolve")
            .appendingPathComponent(revision)
            .appendingPathComponent(path)
    }
}

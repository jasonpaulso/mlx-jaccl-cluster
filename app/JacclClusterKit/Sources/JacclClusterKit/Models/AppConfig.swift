import Foundation

/// Everything `run_openai_cluster_server.sh` parameterizes via env vars.
/// The app mirrors the script's full `--env` set when launching.
public struct ServerLaunchConfig: Codable, Hashable, Sendable {
    public var httpHost: String = "0.0.0.0"
    public var httpPort: Int = 8080
    public var ctrlPort: Int = 18080
    public var queueMax: Int = 8
    public var requestTimeoutSeconds: Int = 120
    public var verbose: Bool = true
    /// Extra `--env KEY=VALUE` pairs forwarded to every rank.
    public var extraEnv: [String: String] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case httpHost, httpPort, ctrlPort, queueMax, requestTimeoutSeconds, verbose, extraEnv
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ServerLaunchConfig()
        httpHost = try c.decodeIfPresent(String.self, forKey: .httpHost) ?? defaults.httpHost
        httpPort = try c.decodeIfPresent(Int.self, forKey: .httpPort) ?? defaults.httpPort
        ctrlPort = try c.decodeIfPresent(Int.self, forKey: .ctrlPort) ?? defaults.ctrlPort
        queueMax = try c.decodeIfPresent(Int.self, forKey: .queueMax) ?? defaults.queueMax
        requestTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .requestTimeoutSeconds) ?? defaults.requestTimeoutSeconds
        verbose = try c.decodeIfPresent(Bool.self, forKey: .verbose) ?? defaults.verbose
        extraEnv = try c.decodeIfPresent([String: String].self, forKey: .extraEnv) ?? defaults.extraEnv
    }
}

/// App-wide configuration, persisted as human-editable JSON at
/// `~/Library/Application Support/JacclCluster/config.json`.
/// All fields have defaults so configs written by older app versions keep decoding.
public struct AppConfig: Codable, Sendable, Equatable {
    /// Absolute path to a checkout of this repo (hostfiles/, server/, scripts/).
    public var repoPath: String = ""
    /// Conda environment name (script default: mlxjccl).
    public var condaEnvName: String = "mlxjccl"
    /// User override for the resolved conda env prefix. Empty = auto-discover.
    public var condaEnvPrefixOverride: String = ""
    /// Hostfile path, relative to repoPath (or absolute).
    public var selectedHostfile: String = "hostfiles/hosts.json"
    /// Local model library root; must be an identical absolute path on all nodes.
    public var modelsDirectory: String = NSString(string: "~/models_mlx").expandingTildeInPath
    public var launch: ServerLaunchConfig = ServerLaunchConfig()
    /// Optional HF token override (falls back to HF_TOKEN env, then the hub token file).
    public var hfToken: String = ""
    /// Optional path to a preferred rsync (e.g. Homebrew rsync 3); empty = /usr/bin/rsync.
    public var rsyncPath: String = ""
    /// Cluster syncs run sequentially by default (single uplink off rank0).
    public var maxParallelSyncs: Int = 1

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case repoPath, condaEnvName, condaEnvPrefixOverride, selectedHostfile
        case modelsDirectory, launch, hfToken, rsyncPath, maxParallelSyncs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        repoPath = try c.decodeIfPresent(String.self, forKey: .repoPath) ?? d.repoPath
        condaEnvName = try c.decodeIfPresent(String.self, forKey: .condaEnvName) ?? d.condaEnvName
        condaEnvPrefixOverride = try c.decodeIfPresent(String.self, forKey: .condaEnvPrefixOverride) ?? d.condaEnvPrefixOverride
        selectedHostfile = try c.decodeIfPresent(String.self, forKey: .selectedHostfile) ?? d.selectedHostfile
        modelsDirectory = try c.decodeIfPresent(String.self, forKey: .modelsDirectory) ?? d.modelsDirectory
        launch = try c.decodeIfPresent(ServerLaunchConfig.self, forKey: .launch) ?? d.launch
        hfToken = try c.decodeIfPresent(String.self, forKey: .hfToken) ?? d.hfToken
        rsyncPath = try c.decodeIfPresent(String.self, forKey: .rsyncPath) ?? d.rsyncPath
        maxParallelSyncs = try c.decodeIfPresent(Int.self, forKey: .maxParallelSyncs) ?? d.maxParallelSyncs
    }

    // MARK: Derived paths

    public var repoURL: URL? {
        repoPath.isEmpty ? nil : URL(fileURLWithPath: NSString(string: repoPath).expandingTildeInPath, isDirectory: true)
    }

    public var hostfileURL: URL? {
        let expanded = NSString(string: selectedHostfile).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        return repoURL?.appendingPathComponent(selectedHostfile)
    }

    public var serverScriptURL: URL? {
        repoURL?.appendingPathComponent("server/openai_cluster_server.py")
    }

    public var modelsDirectoryURL: URL {
        URL(fileURLWithPath: NSString(string: modelsDirectory).expandingTildeInPath, isDirectory: true)
    }
}

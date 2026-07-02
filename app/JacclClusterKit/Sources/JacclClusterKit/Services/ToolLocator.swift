import Foundation

/// GUI apps launch with a bare PATH, and neither `zsh -l -c` (login shells skip
/// .zshrc, where `conda init` writes) nor `conda run` (buffers output, swallows
/// SIGTERM) are usable for a supervised live-log launch. Instead we resolve the
/// conda *env prefix* and exec `<prefix>/bin/mlx.launch` directly with a PATH
/// that puts the env's bin first (mlx.launch itself spawns /usr/bin/ssh).
public struct ToolCheck: Sendable, Equatable {
    public let prefix: String
    public let mlxLaunchPath: String
    public let ok: Bool
    public let detail: String

    public init(prefix: String, mlxLaunchPath: String, ok: Bool, detail: String) {
        self.prefix = prefix
        self.mlxLaunchPath = mlxLaunchPath
        self.ok = ok
        self.detail = detail
    }
}

public enum ToolLocator {
    /// Filesystem probe for common conda/mamba install roots.
    public static func candidatePrefixes(envName: String, home: String = NSHomeDirectory()) -> [String] {
        let roots = [
            "\(home)/miniforge3",
            "\(home)/mambaforge",
            "\(home)/miniconda3",
            "\(home)/anaconda3",
            "\(home)/micromamba",
            "/opt/homebrew/Caskroom/miniforge/base",
            "/opt/homebrew/Caskroom/miniconda/base",
            "/opt/miniconda3",
            "/usr/local/miniconda3",
        ]
        return roots.map { "\($0)/envs/\(envName)" }
    }

    /// First candidate that exists on disk.
    public static func probe(envName: String, fileManager: FileManager = .default) -> String? {
        candidatePrefixes(envName: envName).first { prefix in
            fileManager.fileExists(atPath: "\(prefix)/bin/mlx.launch")
                || fileManager.fileExists(atPath: "\(prefix)/bin/python")
        }
    }

    /// One-shot fallback: interactive zsh sources .zshrc (where conda init lives)
    /// and `conda env list` reveals the prefix. Only used when probing fails —
    /// never on the launch path.
    public static func discoverViaShell(envName: String) async -> String? {
        guard let result = try? await ProcessRunner.run(
            executable: "/bin/zsh",
            arguments: ["-lic", "conda env list 2>/dev/null"],
            timeout: 20
        ), result.exitCode == 0 else { return nil }

        for line in result.stdout.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else { continue }
            // Format: "<name>  [*]  <path>"
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0] == Substring(envName) else { continue }
            if let path = parts.last, path.hasPrefix("/") {
                return String(path)
            }
        }
        return nil
    }

    /// Full resolution order: explicit override → filesystem probe → shell discovery.
    public static func resolvePrefix(envName: String, override: String) async -> String? {
        let trimmedOverride = override.trimmingCharacters(in: .whitespaces)
        if !trimmedOverride.isEmpty {
            return NSString(string: trimmedOverride).expandingTildeInPath
        }
        if let probed = probe(envName: envName) {
            return probed
        }
        return await discoverViaShell(envName: envName)
    }

    /// Settings "Test" button: does the prefix actually contain a runnable mlx.launch?
    public static func validate(prefix: String, fileManager: FileManager = .default) -> ToolCheck {
        let mlxLaunch = "\(prefix)/bin/mlx.launch"
        guard fileManager.fileExists(atPath: prefix) else {
            return ToolCheck(prefix: prefix, mlxLaunchPath: mlxLaunch, ok: false,
                             detail: "Prefix does not exist: \(prefix)")
        }
        guard fileManager.isExecutableFile(atPath: mlxLaunch) else {
            return ToolCheck(prefix: prefix, mlxLaunchPath: mlxLaunch, ok: false,
                             detail: "mlx.launch not found in \(prefix)/bin — is mlx installed in this env?")
        }
        return ToolCheck(prefix: prefix, mlxLaunchPath: mlxLaunch, ok: true,
                         detail: "Found \(mlxLaunch)")
    }

    /// PATH for the supervised child: env bin first, then the system dirs
    /// mlx.launch needs (it spawns /usr/bin/ssh).
    public static func launchPATH(prefix: String) -> String {
        "\(prefix)/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    }
}

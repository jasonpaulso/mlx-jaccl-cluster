import Foundation
import Observation

/// Owns the persisted `AppConfig` (JSON at
/// `~/Library/Application Support/JacclCluster/config.json` — hand-editable).
@MainActor
@Observable
public final class SettingsStore {
    public var config: AppConfig {
        didSet { save() }
    }

    /// Result of the last conda prefix resolution/"Test" run, for SettingsView.
    public var lastToolCheck: ToolCheck?

    @ObservationIgnored private let configURL: URL

    public nonisolated static func defaultConfigURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("JacclCluster/config.json")
    }

    public init(configURL: URL = SettingsStore.defaultConfigURL()) {
        self.configURL = configURL
        if let data = try? Data(contentsOf: configURL),
           let loaded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            self.config = loaded
        } else {
            self.config = AppConfig()
        }
    }

    public func save() {
        do {
            try FileManager.default.createDirectory(
                at: configURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(config)
            try data.write(to: configURL, options: .atomic)
        } catch {
            // Non-fatal: settings stay in memory; surfaced on next app run.
            NSLog("JacclCluster: failed to save config: \(error.localizedDescription)")
        }
    }

    /// Resolves the conda env prefix (override → probe → shell discovery) and
    /// validates it; records the outcome for the Settings "Test" button.
    @discardableResult
    public func resolveAndTestCondaPrefix() async -> ToolCheck {
        let envName = config.condaEnvName
        let override = config.condaEnvPrefixOverride
        guard let prefix = await ToolLocator.resolvePrefix(envName: envName, override: override) else {
            let check = ToolCheck(
                prefix: "",
                mlxLaunchPath: "",
                ok: false,
                detail: "Could not find conda env '\(envName)'. Set the prefix manually in Settings."
            )
            lastToolCheck = check
            return check
        }
        let check = ToolLocator.validate(prefix: prefix)
        lastToolCheck = check
        return check
    }

    /// HF token resolution order: app setting → HF_TOKEN env → hub token file
    /// (respecting HF_HOME); read-only — the app never writes the hub token.
    public func resolveHFToken() -> String? {
        let fromConfig = config.hfToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fromConfig.isEmpty { return fromConfig }
        if let env = ProcessInfo.processInfo.environment["HF_TOKEN"], !env.isEmpty {
            return env
        }
        let hfHome = ProcessInfo.processInfo.environment["HF_HOME"]
            ?? "\(NSHomeDirectory())/.cache/huggingface"
        let tokenPath = "\(NSString(string: hfHome).expandingTildeInPath)/token"
        if let token = try? String(contentsOfFile: tokenPath, encoding: .utf8) {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }
}

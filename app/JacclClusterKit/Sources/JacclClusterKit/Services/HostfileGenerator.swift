import Foundation

public enum HostfileGeneratorError: Error, LocalizedError {
    case repoScriptMissing(String)
    case generationFailed(errors: [String], raw: String)

    public var errorDescription: String? {
        switch self {
        case .repoScriptMissing(let path):
            return "scripts/generate_hostfile.py not found at \(path) — is the repo path set correctly?"
        case .generationFailed(let errors, let raw):
            return errors.isEmpty
                ? "Hostfile generation failed:\n\(raw.trimmingCharacters(in: .whitespacesAndNewlines))"
                : errors.joined(separator: "\n")
        }
    }
}

/// Wraps `scripts/generate_hostfile.py`: SSHes to every node, matches
/// Thunderbolt domain UUIDs across them to discover the physical cabling, and
/// emits a complete hostfile (rdma matrix + rank 0 coordinator IP). The script
/// stays the source of truth — the app only runs it and hands the JSON to the
/// hostfile editor as an unsaved document for review.
public enum HostfileGenerator {
    public struct Output: Sendable {
        /// The generated hostfile JSON (script stdout), ready for
        /// `HostfileStore.applySource`.
        public let hostfileJSON: String
        /// Human-readable "[link] host Thunderbolt N (enX) -> peer [speed]"
        /// lines — worth surfacing so the user sees ports and link speeds.
        public let links: [String]
    }

    public static func generate(repoURL: URL, hosts: [String]) async throws -> Output {
        let script = repoURL.appendingPathComponent("scripts/generate_hostfile.py").path
        guard FileManager.default.fileExists(atPath: script) else {
            throw HostfileGeneratorError.repoScriptMissing(script)
        }
        // The script is stdlib-only, so the system python suffices — no need
        // to resolve the cluster env for this.
        let result = try await ProcessRunner.run(
            executable: "/usr/bin/python3",
            arguments: [script] + hosts,
            timeout: 120
        )
        let parsed = parseStderr(result.stderr)
        guard result.succeeded else {
            throw HostfileGeneratorError.generationFailed(errors: parsed.errors, raw: result.stderr)
        }
        return Output(hostfileJSON: result.stdout, links: parsed.links)
    }

    /// The script narrates on stderr: "[link] ..." per detected cable,
    /// "ERROR: ..." per topology problem (missing/duplicate cables).
    static func parseStderr(_ stderr: String) -> (links: [String], errors: [String]) {
        var links: [String] = []
        var errors: [String] = []
        for line in stderr.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[link] ") {
                links.append(String(trimmed.dropFirst("[link] ".count)))
            } else if trimmed.hasPrefix("ERROR: ") {
                errors.append(String(trimmed.dropFirst("ERROR: ".count)))
            } else if trimmed.hasPrefix("WARNING: ") {
                links.append(String(trimmed))
            }
        }
        return (links, errors)
    }
}

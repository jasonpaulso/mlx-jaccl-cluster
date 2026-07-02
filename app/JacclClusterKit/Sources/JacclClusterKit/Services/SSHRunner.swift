import Foundation

/// Stateless per-call ssh execution. BatchMode is mandatory: the app has no TTY,
/// so any interactive prompt (password, passphrase, host key) would hang forever.
public struct SSHRunner: Sendable {
    public var connectTimeoutSeconds: Int

    public init(connectTimeoutSeconds: Int = 5) {
        self.connectTimeoutSeconds = connectTimeoutSeconds
    }

    public var baseOptions: [String] {
        [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(connectTimeoutSeconds)",
            "-o", "StrictHostKeyChecking=accept-new",
        ]
    }

    public func run(host: String, command: String, timeout: TimeInterval = 15) async throws -> ProcessResult {
        try await ProcessRunner.run(
            executable: "/usr/bin/ssh",
            arguments: baseOptions + [host, command],
            timeout: timeout
        )
    }

    /// Same pkill the shell scripts use; pkill exits 1 when nothing matched,
    /// which counts as success here.
    public func pkillServer(host: String) async -> Result<Void, SSHError> {
        do {
            let result = try await run(host: host, command: "pkill -f openai_cluster_server.py || true", timeout: 15)
            if result.timedOut {
                return .failure(.timeout(host: host))
            }
            if result.exitCode != 0 {
                return .failure(.commandFailed(host: host, detail: Self.humanize(stderr: result.stderr)))
            }
            return .success(())
        } catch {
            return .failure(.commandFailed(host: host, detail: error.localizedDescription))
        }
    }

    /// Maps common opaque ssh failures to actionable hints.
    public static func humanize(stderr: String) -> String {
        if stderr.contains("Permission denied (publickey") {
            return "SSH key authentication failed. If your key has a passphrase, run: ssh-add --apple-use-keychain"
        }
        if stderr.contains("Could not resolve hostname") {
            return "Hostname could not be resolved. Check the ssh name in the hostfile."
        }
        if stderr.contains("Connection refused") {
            return "Connection refused. Enable Remote Login (System Settings → General → Sharing) on the node."
        }
        if stderr.contains("Operation timed out") || stderr.contains("Connection timed out") {
            return "Connection timed out. Check that the node is powered on and reachable."
        }
        if stderr.contains("Host key verification failed") {
            return "Host key verification failed. Remove the stale entry from ~/.ssh/known_hosts."
        }
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "SSH command failed." : trimmed
    }
}

public enum SSHError: Error, LocalizedError, Sendable {
    case timeout(host: String)
    case commandFailed(host: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .timeout(let host): "SSH to \(host) timed out."
        case .commandFailed(let host, let detail): "\(host): \(detail)"
        }
    }
}

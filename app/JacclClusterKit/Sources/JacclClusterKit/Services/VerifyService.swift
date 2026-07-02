import Foundation

/// Per-node result of the cluster verify pass (mirrors scripts/verify_cluster.sh:
/// `ssh <host> hostname` + `ibv_devices | grep -E "rdma_en[0-9]"`).
public struct NodeCheckResult: Identifiable, Sendable, Equatable {
    public let host: String
    public var sshOK: Bool
    public var remoteHostname: String?
    public var rdmaDevices: [String]
    /// Whether the python env exists on the node at rank 0's prefix path
    /// (nil = not checked, e.g. no prefix resolved locally).
    public var envOK: Bool?
    /// Humanized failure detail when sshOK is false.
    public var failureHint: String?
    public var checkedAt: Date

    public var id: String { host }

    public init(host: String, sshOK: Bool = false, remoteHostname: String? = nil,
                rdmaDevices: [String] = [], envOK: Bool? = nil,
                failureHint: String? = nil, checkedAt: Date = Date()) {
        self.host = host
        self.sshOK = sshOK
        self.remoteHostname = remoteHostname
        self.rdmaDevices = rdmaDevices
        self.envOK = envOK
        self.failureHint = failureHint
        self.checkedAt = checkedAt
    }
}

/// Verification status of one RDMA matrix cell, cross-checking the hostfile's
/// claimed device against the devices actually reported by that node.
public enum MatrixCellStatus: Sendable, Equatable {
    /// Node not verified yet (or ssh failed) — nothing to cross-check against.
    case unverified
    /// Device name appears in the node's live `ibv_devices` output.
    case confirmed
    /// Node was verified but does not report this device.
    case missing
}

public struct VerifyService: Sendable {
    public let ssh: SSHRunner

    public init(ssh: SSHRunner = SSHRunner()) {
        self.ssh = ssh
    }

    /// Fans out over all hosts concurrently; one slow node doesn't serialize the rest.
    /// When `envPrefix` is set, each node is also checked for a python env at
    /// that path (rank 0's prefix must exist verbatim on every node).
    public func verify(hosts: [String], envPrefix: String? = nil) async -> [NodeCheckResult] {
        await withTaskGroup(of: NodeCheckResult.self) { group in
            for host in hosts {
                group.addTask { await self.verifyNode(host: host, envPrefix: envPrefix) }
            }
            var results: [NodeCheckResult] = []
            for await result in group {
                results.append(result)
            }
            // Preserve hostfile order.
            return hosts.compactMap { host in results.first { $0.host == host } }
        }
    }

    public func verifyNode(host: String, envPrefix: String? = nil) async -> NodeCheckResult {
        var result = NodeCheckResult(host: host)
        do {
            let hostnameRun = try await ssh.run(host: host, command: "hostname", timeout: 12)
            if hostnameRun.timedOut {
                result.failureHint = "SSH timed out."
                return result
            }
            guard hostnameRun.exitCode == 0 else {
                result.failureHint = SSHRunner.failureDetail(hostnameRun)
                return result
            }
            result.sshOK = true
            result.remoteHostname = hostnameRun.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

            let devicesRun = try await ssh.run(
                host: host,
                command: #"ibv_devices 2>/dev/null | grep -oE "rdma_en[0-9]+" || true"#,
                timeout: 12
            )
            if devicesRun.exitCode == 0 {
                result.rdmaDevices = devicesRun.stdout
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }

            if let envPrefix {
                let envRun = try await ssh.run(
                    host: host,
                    command: "test -x '\(envPrefix)/bin/python3' || test -x '\(envPrefix)/bin/python'",
                    timeout: 12
                )
                result.envOK = (envRun.exitCode == 0)
            }
        } catch {
            result.failureHint = error.localizedDescription
        }
        return result
    }

    /// Cross-checks a hostfile row against live verify results.
    public static func cellStatus(
        device: String?,
        row: Int,
        column: Int,
        results: [String: NodeCheckResult],
        rowHost: String
    ) -> MatrixCellStatus {
        guard row != column, let device, !device.isEmpty else { return .unverified }
        guard let nodeResult = results[rowHost], nodeResult.sshOK else { return .unverified }
        return nodeResult.rdmaDevices.contains(device) ? .confirmed : .missing
    }
}

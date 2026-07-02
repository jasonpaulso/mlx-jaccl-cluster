import Foundation

/// Per-node result of the cluster verify pass (mirrors scripts/verify_cluster.sh:
/// `ssh <host> hostname` + `ibv_devices | grep -E "rdma_en[0-9]"`).
public struct NodeCheckResult: Identifiable, Sendable, Equatable {
    public let host: String
    public var sshOK: Bool
    public var remoteHostname: String?
    public var rdmaDevices: [String]
    /// Devices whose Thunderbolt interface reports an active link — i.e. a
    /// cable is actually plugged in there. These are the right matrix choices.
    public var activeRdmaDevices: [String]
    /// Devices whose interface has no IPv6 link-local — usually because it's
    /// captured by the Thunderbolt Bridge. Their RDMA GID table is empty, so
    /// the QP handshake fails with "Changing queue pair to RTR failed with
    /// errno 96" (ENODATA).
    public var devicesMissingIPv6: [String]
    /// Whether the python env exists on the node at rank 0's prefix path
    /// (nil = not checked, e.g. no prefix resolved locally).
    public var envOK: Bool?
    /// The node's live IPv4 addresses (loopback excluded) — feeds the
    /// coordinator-IP suggestions and the stale-IP preflight.
    public var ipv4Addresses: [String]
    /// Humanized failure detail when sshOK is false.
    public var failureHint: String?
    public var checkedAt: Date

    public var id: String { host }

    public init(host: String, sshOK: Bool = false, remoteHostname: String? = nil,
                rdmaDevices: [String] = [], activeRdmaDevices: [String] = [],
                devicesMissingIPv6: [String] = [],
                envOK: Bool? = nil,
                ipv4Addresses: [String] = [],
                failureHint: String? = nil, checkedAt: Date = Date()) {
        self.host = host
        self.sshOK = sshOK
        self.remoteHostname = remoteHostname
        self.rdmaDevices = rdmaDevices
        self.activeRdmaDevices = activeRdmaDevices
        self.devicesMissingIPv6 = devicesMissingIPv6
        self.envOK = envOK
        self.ipv4Addresses = ipv4Addresses
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
    /// Device exists but its interface has no IPv6 link-local (Thunderbolt
    /// Bridge member) — JACCL's QP handshake will fail on it.
    case noIPv6
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
            let hostnameRun = try await ssh.runExplained(host: host, command: "hostname", timeout: 12)
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

            // One pass per device: link status of its enN Thunderbolt
            // interface (active = cable plugged in) and whether it has an
            // IPv6 link-local (no fe80 = empty GID table = RTR errno 96,
            // typically because the port is a Thunderbolt Bridge member).
            let devicesRun = try await ssh.run(
                host: host,
                command: #"for d in $(ibv_devices 2>/dev/null | grep -oE 'rdma_en[0-9]+'); do i="${d#rdma_}"; s=$(ifconfig "$i" 2>/dev/null | awk '/status:/{print $2}'); ll=$(ifconfig "$i" 2>/dev/null | awk '/inet6 fe80/{print "ll"; exit}'); echo "$d ${s:-unknown} ${ll:-noll}"; done"#,
                timeout: 12
            )
            if devicesRun.exitCode == 0 {
                let parsed = Self.parseDeviceStatus(devicesRun.stdout)
                result.rdmaDevices = parsed.devices
                result.activeRdmaDevices = parsed.active
                result.devicesMissingIPv6 = parsed.missingIPv6
            }

            let ipsRun = try await ssh.run(
                host: host,
                command: #"ifconfig -a 2>/dev/null | awk '/inet /{print $2}'"#,
                timeout: 12
            )
            if ipsRun.exitCode == 0 {
                result.ipv4Addresses = ipsRun.stdout
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && $0 != "127.0.0.1" }
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

    /// Parses "rdma_enN <status> <ll|noll>" lines from the device+link probe.
    static func parseDeviceStatus(_ output: String) -> (devices: [String], active: [String], missingIPv6: [String]) {
        var devices: [String] = []
        var active: [String] = []
        var missingIPv6: [String] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard let device = parts.first, device.hasPrefix("rdma_en") else { continue }
            devices.append(String(device))
            if parts.count > 1, parts[1] == "active" {
                active.append(String(device))
            }
            if parts.count > 2, parts[2] == "noll" {
                missingIPv6.append(String(device))
            }
        }
        return (devices, active, missingIPv6)
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
        guard nodeResult.rdmaDevices.contains(device) else { return .missing }
        if nodeResult.devicesMissingIPv6.contains(device) { return .noIPv6 }
        return .confirmed
    }
}

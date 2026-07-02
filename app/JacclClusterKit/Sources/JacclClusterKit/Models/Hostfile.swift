import Foundation

/// One node in the JACCL hostfile. Mirrors the JSON contract consumed by
/// `mlx.launch --hostfile` and the repo's shell scripts:
/// `{ "ssh": "node1.local", "ips": ["192.168.1.100"], "rdma": [null, "rdma_en5", ...] }`
///
/// `rdma[j]` is *this node's* local RDMA device facing node `j`; the matrix is
/// not symmetric in device names. The diagonal entry (facing itself) is `null`.
public struct HostEntry: Identifiable, Hashable, Sendable {
    /// SwiftUI identity only — never serialized.
    public let id: UUID
    public var ssh: String
    public var ips: [String]
    public var rdma: [String?]

    public init(id: UUID = UUID(), ssh: String, ips: [String] = [], rdma: [String?] = []) {
        self.id = id
        self.ssh = ssh
        self.ips = ips
        self.rdma = rdma
    }
}

extension HostEntry: Codable {
    private enum CodingKeys: String, CodingKey {
        case ssh, ips, rdma
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.ssh = try c.decode(String.self, forKey: .ssh)
        self.ips = try c.decodeIfPresent([String].self, forKey: .ips) ?? []
        self.rdma = try c.decodeIfPresent([String?].self, forKey: .rdma) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ssh, forKey: .ssh)
        try c.encode(ips, forKey: .ips)
        // Encode nils as JSON null so the diagonal round-trips.
        var rdmaContainer = c.nestedUnkeyedContainer(forKey: .rdma)
        for device in rdma {
            if let device {
                try rdmaContainer.encode(device)
            } else {
                try rdmaContainer.encodeNil()
            }
        }
    }
}

/// A validation finding for a hostfile.
public struct HostfileIssue: Identifiable, Hashable, Sendable {
    public enum Severity: Sendable {
        case error, warning
    }

    public let id: UUID
    public let severity: Severity
    public let message: String
    /// Node index the issue refers to, if node-specific.
    public let nodeIndex: Int?
    /// Matrix cell (row, column) the issue refers to, if cell-specific.
    public let cell: MatrixCell?

    public init(severity: Severity, message: String, nodeIndex: Int? = nil, cell: MatrixCell? = nil) {
        self.id = UUID()
        self.severity = severity
        self.message = message
        self.nodeIndex = nodeIndex
        self.cell = cell
    }
}

public struct MatrixCell: Hashable, Sendable {
    public let row: Int
    public let column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }
}

/// The hostfile document: owns validation and structural mutations so the
/// matrix always stays square (every add/remove fixes every row).
public struct HostfileDocument: Sendable, Equatable {
    public var hosts: [HostEntry]

    public init(hosts: [HostEntry] = []) {
        self.hosts = hosts
    }

    // MARK: Serialization

    public static func decode(from data: Data) throws -> HostfileDocument {
        HostfileDocument(hosts: try JSONDecoder().decode([HostEntry].self, from: data))
    }

    public static func load(from url: URL) throws -> HostfileDocument {
        try decode(from: try Data(contentsOf: url))
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(hosts)
    }

    /// Atomic save; the scripts and `mlx.launch` read the same file.
    public func save(to url: URL) throws {
        var data = try encoded()
        data.append(Data("\n".utf8))
        try data.write(to: url, options: .atomic)
    }

    // MARK: Structural mutations (row/column co-mutation)

    /// Appends a node and grows every existing row by one column.
    /// New off-diagonal cells are nil (invalid until the user fills them in).
    public mutating func addNode(ssh: String) {
        for i in hosts.indices {
            hosts[i].rdma.append(nil)
        }
        var row = [String?](repeating: nil, count: hosts.count + 1)
        row[hosts.count] = nil // own diagonal
        hosts.append(HostEntry(ssh: ssh, ips: [], rdma: row))
    }

    /// Removes a node and its column from every remaining row.
    public mutating func removeNode(at index: Int) {
        guard hosts.indices.contains(index) else { return }
        hosts.remove(at: index)
        for i in hosts.indices {
            if hosts[i].rdma.indices.contains(index) {
                hosts[i].rdma.remove(at: index)
            }
        }
    }

    public mutating func moveNode(from source: Int, to destination: Int) {
        guard hosts.indices.contains(source), hosts.indices.contains(destination), source != destination else { return }
        let entry = hosts.remove(at: source)
        hosts.insert(entry, at: destination)
        for i in hosts.indices {
            guard hosts[i].rdma.indices.contains(source) else { continue }
            let cell = hosts[i].rdma.remove(at: source)
            hosts[i].rdma.insert(cell, at: destination)
        }
    }

    // MARK: Validation

    // Computed: Regex isn't Sendable, so a static stored property is rejected in Swift 6.
    private static var devicePattern: Regex<Substring> { #/^rdma_en\d+$/# }

    public func validate() -> [HostfileIssue] {
        var issues: [HostfileIssue] = []
        let n = hosts.count

        guard n > 0 else {
            issues.append(HostfileIssue(severity: .error, message: "Hostfile has no nodes."))
            return issues
        }

        // Duplicate hostnames
        var seen: [String: Int] = [:]
        for (i, host) in hosts.enumerated() {
            let name = host.ssh.trimmingCharacters(in: .whitespaces)
            if name.isEmpty {
                issues.append(HostfileIssue(severity: .error, message: "Node \(i + 1) has an empty ssh hostname.", nodeIndex: i))
            } else if let first = seen[name] {
                issues.append(HostfileIssue(
                    severity: .error,
                    message: "Duplicate ssh hostname '\(name)' (nodes \(first + 1) and \(i + 1)).",
                    nodeIndex: i
                ))
            } else {
                seen[name] = i
            }
        }

        // Rank 0 coordinator IP
        if let rank0 = hosts.first {
            if let ip = rank0.ips.first, !ip.isEmpty {
                if !Self.isIPv4(ip) {
                    issues.append(HostfileIssue(
                        severity: .error,
                        message: "Rank 0 coordinator address '\(ip)' is not a valid IPv4 address.",
                        nodeIndex: 0
                    ))
                }
            } else {
                issues.append(HostfileIssue(
                    severity: .error,
                    message: "Rank 0 (first node) must carry the coordinator LAN IP in ips[0].",
                    nodeIndex: 0
                ))
            }
        }

        // Matrix shape + diagonal + device names
        for (i, host) in hosts.enumerated() {
            if host.rdma.count != n {
                issues.append(HostfileIssue(
                    severity: .error,
                    message: "Node \(i + 1) ('\(host.ssh)') has \(host.rdma.count) rdma entries; expected \(n).",
                    nodeIndex: i
                ))
                continue
            }
            for j in 0..<n {
                let device = host.rdma[j]
                if i == j {
                    if device != nil {
                        issues.append(HostfileIssue(
                            severity: .error,
                            message: "Node \(i + 1) diagonal rdma entry must be null.",
                            cell: MatrixCell(row: i, column: j)
                        ))
                    }
                } else if n > 1 {
                    guard let device, !device.isEmpty else {
                        issues.append(HostfileIssue(
                            severity: .error,
                            message: "Missing RDMA device: '\(host.ssh)' facing '\(hosts[j].ssh)'.",
                            cell: MatrixCell(row: i, column: j)
                        ))
                        continue
                    }
                    if device.firstMatch(of: Self.devicePattern) == nil {
                        issues.append(HostfileIssue(
                            severity: .warning,
                            message: "Device '\(device)' ('\(host.ssh)' → '\(hosts[j].ssh)') doesn't match rdma_en<N>.",
                            cell: MatrixCell(row: i, column: j)
                        ))
                    }
                }
            }
        }

        return issues
    }

    public var hasErrors: Bool {
        validate().contains { $0.severity == .error }
    }

    static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber),
                  let value = Int(part), (0...255).contains(value),
                  // No leading zeros like "01"
                  !(part.count > 1 && part.first == "0")
            else { return false }
        }
        return true
    }
}

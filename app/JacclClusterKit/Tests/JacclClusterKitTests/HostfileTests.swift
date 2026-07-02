import XCTest
@testable import JacclClusterKit

final class HostfileTests: XCTestCase {
    private func fixtureData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testDecodeExampleHostfile() throws {
        let doc = try HostfileDocument.decode(from: try fixtureData("hosts-4node.json"))
        XCTAssertEqual(doc.hosts.count, 4)
        XCTAssertEqual(doc.hosts[0].ssh, "node1.local")
        XCTAssertEqual(doc.hosts[0].ips, ["192.168.1.100"])
        XCTAssertEqual(doc.hosts[1].ips, [])
        // Diagonal is nil, off-diagonal populated.
        XCTAssertNil(doc.hosts[0].rdma[0])
        XCTAssertEqual(doc.hosts[0].rdma[1], "rdma_en5")
        XCTAssertNil(doc.hosts[3].rdma[3])
    }

    func testRoundTripPreservesNulls() throws {
        let original = try fixtureData("hosts-4node.json")
        let doc = try HostfileDocument.decode(from: original)
        let encoded = try doc.encoded()

        // The nulls must survive as JSON null (the scripts and mlx.launch rely on them).
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(json.contains("null"), "diagonal null entries must round-trip")

        // Structural equality after re-decode.
        let redecoded = try HostfileDocument.decode(from: encoded)
        XCTAssertEqual(redecoded.hosts.map(\.ssh), doc.hosts.map(\.ssh))
        XCTAssertEqual(redecoded.hosts.map(\.rdma), doc.hosts.map(\.rdma))
        XCTAssertEqual(redecoded.hosts.map(\.ips), doc.hosts.map(\.ips))
    }

    func testValidExampleHasNoErrors() throws {
        let doc = try HostfileDocument.decode(from: try fixtureData("hosts-4node.json"))
        let errors = doc.validate().filter { $0.severity == .error }
        XCTAssertTrue(errors.isEmpty, "\(errors.map(\.message))")
    }

    func testValidationCatchesMissingCoordinatorIP() throws {
        var doc = try HostfileDocument.decode(from: try fixtureData("hosts-4node.json"))
        doc.hosts[0].ips = []
        let errors = doc.validate().filter { $0.severity == .error }
        XCTAssertTrue(errors.contains { $0.message.contains("coordinator") })
    }

    func testValidationCatchesBadIPv4() throws {
        var doc = try HostfileDocument.decode(from: try fixtureData("hosts-4node.json"))
        doc.hosts[0].ips = ["999.1.2.3"]
        XCTAssertTrue(doc.validate().contains { $0.severity == .error && $0.message.contains("IPv4") })
        XCTAssertTrue(HostfileDocument.isIPv4("192.168.0.36"))
        XCTAssertFalse(HostfileDocument.isIPv4("192.168.0"))
        XCTAssertFalse(HostfileDocument.isIPv4("a.b.c.d"))
        XCTAssertFalse(HostfileDocument.isIPv4("01.2.3.4"))
    }

    func testValidationCatchesDuplicateHosts() throws {
        var doc = try HostfileDocument.decode(from: try fixtureData("hosts-4node.json"))
        doc.hosts[2].ssh = doc.hosts[1].ssh
        XCTAssertTrue(doc.validate().contains { $0.severity == .error && $0.message.contains("Duplicate") })
    }

    func testValidationCatchesRowLengthMismatch() throws {
        var doc = try HostfileDocument.decode(from: try fixtureData("hosts-4node.json"))
        doc.hosts[1].rdma.removeLast()
        XCTAssertTrue(doc.validate().contains { $0.severity == .error && $0.message.contains("expected 4") })
    }

    func testValidationCatchesNonNullDiagonal() throws {
        var doc = try HostfileDocument.decode(from: try fixtureData("hosts-4node.json"))
        doc.hosts[2].rdma[2] = "rdma_en1"
        XCTAssertTrue(doc.validate().contains { $0.severity == .error && $0.message.contains("diagonal") })
    }

    func testValidationWarnsOnOddDeviceName() throws {
        var doc = try HostfileDocument.decode(from: try fixtureData("hosts-4node.json"))
        doc.hosts[0].rdma[1] = "en5"
        XCTAssertTrue(doc.validate().contains { $0.severity == .warning && $0.message.contains("rdma_en") })
    }

    func testAddNodeCoMutatesEveryRow() throws {
        var doc = try HostfileDocument.decode(from: try fixtureData("hosts-4node.json"))
        doc.addNode(ssh: "node5.local")
        XCTAssertEqual(doc.hosts.count, 5)
        for (i, host) in doc.hosts.enumerated() {
            XCTAssertEqual(host.rdma.count, 5, "row \(i) must grow to 5 columns")
            XCTAssertNil(host.rdma[i], "diagonal must stay nil")
        }
        // New off-diagonal cells are nil → validation flags them until filled.
        XCTAssertTrue(doc.validate().contains { $0.severity == .error && $0.message.contains("Missing RDMA device") })
    }

    func testRemoveNodeCoMutatesEveryRow() throws {
        var doc = try HostfileDocument.decode(from: try fixtureData("hosts-4node.json"))
        doc.removeNode(at: 1)
        XCTAssertEqual(doc.hosts.count, 3)
        for (i, host) in doc.hosts.enumerated() {
            XCTAssertEqual(host.rdma.count, 3, "row \(i) must shrink to 3 columns")
            XCTAssertNil(host.rdma[i], "diagonal must stay nil after column removal")
        }
        let errors = doc.validate().filter { $0.severity == .error }
        XCTAssertTrue(errors.isEmpty, "removing a node must leave a valid square matrix: \(errors.map(\.message))")
    }

    func testAddThenRemoveRoundTrips() throws {
        let original = try HostfileDocument.decode(from: try fixtureData("hosts-4node.json"))
        var doc = original
        doc.addNode(ssh: "temp.local")
        doc.removeNode(at: 4)
        XCTAssertEqual(doc.hosts.map(\.ssh), original.hosts.map(\.ssh))
        XCTAssertEqual(doc.hosts.map(\.rdma), original.hosts.map(\.rdma))
    }

    @MainActor
    func testCreateFromExampleThrowsWhenFolderIsNotARepo() throws {
        // Regression: an empty folder as repo path must produce a descriptive
        // error, not a silent no-op.
        let emptyDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyDir) }

        let store = HostfileStore()
        XCTAssertThrowsError(try store.createFromExample(repoURL: emptyDir)) { error in
            XCTAssertTrue(error.localizedDescription.contains("hosts.json.example"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: emptyDir.appendingPathComponent("hostfiles/hosts.json").path))
    }

    @MainActor
    func testCreateFromExampleCopiesAndIsIdempotent() throws {
        let repoDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: repoDir.appendingPathComponent("hostfiles"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoDir) }
        try fixtureData("hosts-4node.json").write(to: repoDir.appendingPathComponent("hostfiles/hosts.json.example"))

        let store = HostfileStore()
        let created = try store.createFromExample(repoURL: repoDir)
        XCTAssertEqual(created.lastPathComponent, "hosts.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path))
        let doc = try HostfileDocument.load(from: created)
        XCTAssertEqual(doc.hosts.count, 4)

        // Second call returns the existing file instead of failing.
        let again = try store.createFromExample(repoURL: repoDir)
        XCTAssertEqual(again.path, created.path)
    }

    func testSaveIsConsumableAndStable() throws {
        let doc = try HostfileDocument.decode(from: try fixtureData("hosts-4node.json"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("hosts.json")
        try doc.save(to: url)
        let reloaded = try HostfileDocument.load(from: url)
        XCTAssertEqual(reloaded.hosts.map(\.ssh), doc.hosts.map(\.ssh))
        XCTAssertEqual(reloaded.hosts.map(\.rdma), doc.hosts.map(\.rdma))
    }
}

import XCTest
@testable import JacclClusterKit

final class LocalNetworkTests: XCTestCase {
    func testHostnameNormalization() {
        XCTAssertEqual(LocalNetwork.normalized("Jasons-MacBook-Pro.local"), "jasons-macbook-pro")
        XCTAssertEqual(LocalNetwork.normalized("jasons-mac-studio.local "), "jasons-mac-studio")
        XCTAssertEqual(LocalNetwork.normalized("node1"), "node1")
    }

    func testHostRefersToThisMachine() {
        XCTAssertTrue(LocalNetwork.hostRefersToThisMachine(
            "Jasons-MacBook-Pro.local", localName: "jasons-macbook-pro.local"))
        XCTAssertTrue(LocalNetwork.hostRefersToThisMachine(
            "jasons-macbook-pro", localName: "Jasons-MacBook-Pro.local"))
        XCTAssertFalse(LocalNetwork.hostRefersToThisMachine(
            "jasons-mac-studio.local", localName: "Jasons-MacBook-Pro.local"))
    }

    func testDeviceStatusParsing() {
        let output = """
        rdma_en1 inactive ll
        rdma_en2 active noll
        rdma_en7 unknown ll
        garbage line
        """
        let parsed = VerifyService.parseDeviceStatus(output)
        XCTAssertEqual(parsed.devices, ["rdma_en1", "rdma_en2", "rdma_en7"])
        XCTAssertEqual(parsed.active, ["rdma_en2"])
        XCTAssertEqual(parsed.missingIPv6, ["rdma_en2"], "bridge-captured port: active link but no fe80")
    }

    func testCellStatusFlagsBridgedDevice() {
        // Live-debugged failure shape: device exists, link active, but no
        // link-local because the port sits in the Thunderbolt Bridge.
        let results = [
            "mbp.local": NodeCheckResult(
                host: "mbp.local", sshOK: true,
                rdmaDevices: ["rdma_en2"], activeRdmaDevices: ["rdma_en2"],
                devicesMissingIPv6: ["rdma_en2"]
            ),
        ]
        XCTAssertEqual(
            VerifyService.cellStatus(device: "rdma_en2", row: 0, column: 1, results: results, rowHost: "mbp.local"),
            .noIPv6
        )
    }

    func testIPv4InterfacesExcludeLoopbackAndParse() {
        let interfaces = LocalNetwork.ipv4Interfaces()
        for interface in interfaces {
            XCTAssertNotEqual(interface.address, "127.0.0.1")
            XCTAssertEqual(interface.address.split(separator: ".").count, 4, "\(interface.address) should be dotted-quad")
            XCTAssertFalse(interface.name.isEmpty)
        }
        // Link-local addresses must sort after routable ones.
        if let firstLinkLocal = interfaces.firstIndex(where: \.isLinkLocal) {
            XCTAssertTrue(interfaces[firstLinkLocal...].allSatisfy(\.isLinkLocal))
        }
    }
}

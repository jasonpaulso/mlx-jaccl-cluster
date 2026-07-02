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

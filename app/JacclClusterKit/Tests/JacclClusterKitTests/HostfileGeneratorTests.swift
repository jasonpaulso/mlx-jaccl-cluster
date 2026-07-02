import XCTest
@testable import JacclClusterKit

final class HostfileGeneratorTests: XCTestCase {
    func testParseStderrSeparatesLinksAndErrors() {
        let stderr = """
        [jasons-macbook-pro.local] querying Thunderbolt topology...
        [jasons-mac-studio.local] querying Thunderbolt topology...
        [link] jasons-macbook-pro.local Thunderbolt 3 (en2) -> jasons-mac-studio.local  [Up to 80 Gb/s]
        [link] jasons-mac-studio.local Thunderbolt 2 (en7) -> jasons-macbook-pro.local  [Up to 80 Gb/s]
        ERROR: no Thunderbolt cable detected between a.local and b.local
        WARNING: could not detect LAN IP for a.local; fill ips[0] manually
        """
        let parsed = HostfileGenerator.parseStderr(stderr)
        XCTAssertEqual(parsed.links, [
            "jasons-macbook-pro.local Thunderbolt 3 (en2) -> jasons-mac-studio.local  [Up to 80 Gb/s]",
            "jasons-mac-studio.local Thunderbolt 2 (en7) -> jasons-macbook-pro.local  [Up to 80 Gb/s]",
            "WARNING: could not detect LAN IP for a.local; fill ips[0] manually",
        ])
        XCTAssertEqual(parsed.errors, ["no Thunderbolt cable detected between a.local and b.local"])
    }

    /// The script's stdout must round-trip through the same decoder the
    /// source tab uses, so the generated JSON lands in the form editor.
    func testGeneratedJSONDecodesAsHostfileDocument() throws {
        let json = """
        [
          {"ssh": "jasons-macbook-pro.local", "ips": ["192.168.4.68"], "rdma": [null, "rdma_en2"]},
          {"ssh": "jasons-mac-studio.local", "ips": [], "rdma": ["rdma_en7", null]}
        ]
        """
        let doc = try HostfileDocument.decode(from: Data(json.utf8))
        XCTAssertEqual(doc.hosts.count, 2)
        XCTAssertEqual(doc.hosts[0].ips, ["192.168.4.68"])
        XCTAssertEqual(doc.hosts[0].rdma, [nil, "rdma_en2"])
        XCTAssertEqual(doc.hosts[1].rdma, ["rdma_en7", nil])
    }
}

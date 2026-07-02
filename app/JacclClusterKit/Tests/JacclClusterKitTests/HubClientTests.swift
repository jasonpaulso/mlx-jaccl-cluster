import XCTest
@testable import JacclClusterKit

/// Decoding tests against recorded Hub API fixtures (shapes verified live
/// during design). Live-network checks belong to milestone B1, not CI.
final class HubClientTests: XCTestCase {
    private func fixtureData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testDecodeSearchResults() throws {
        let models = try JSONDecoder().decode([HubModelSummary].self, from: try fixtureData("hub-search.json"))
        XCTAssertEqual(models.count, 2)

        let first = models[0]
        XCTAssertEqual(first.id, "mlx-community/Qwen3-4B-Instruct-2507-4bit")
        XCTAssertEqual(first.displayName, "Qwen3-4B-Instruct-2507-4bit")
        XCTAssertEqual(first.organization, "mlx-community")
        XCTAssertEqual(first.downloads, 12345)
        XCTAssertEqual(first.likes, 42)
        XCTAssertFalse(first.gated)

        // gated can be a string ("manual"/"auto") — decodes as true.
        XCTAssertTrue(models[1].gated)
    }

    func testDecodeModelInfo() throws {
        let info = try JSONDecoder().decode(HubModelInfo.self, from: try fixtureData("hub-info.json"))
        XCTAssertEqual(info.id, "mlx-community/Qwen3-4B-Instruct-2507-4bit")
        XCTAssertEqual(info.sha, "0123456789abcdef0123456789abcdef01234567")
        XCTAssertFalse(info.gated)
        XCTAssertEqual(info.quantizationBits, 4)
        XCTAssertEqual(info.usedStorage, 2_269_206_328)
    }

    func testDecodeTree() throws {
        let raw = try JSONDecoder().decode([HubTreeFile.Raw].self, from: try fixtureData("hub-tree.json"))
        let files = raw.filter { $0.type == "file" }
        XCTAssertEqual(files.count, 4, "directories are filtered out")

        let safetensors = try XCTUnwrap(files.first { $0.path == "model.safetensors" })
        XCTAssertEqual(safetensors.lfs?.oid.count, 64, "LFS oid is a sha256")
        XCTAssertEqual(safetensors.lfs?.size, 2_264_823_904)

        let config = try XCTUnwrap(files.first { $0.path == "config.json" })
        XCTAssertNil(config.lfs)
        XCTAssertEqual(config.oid?.count, 40, "non-LFS oid is a git sha1")
    }

    func testLinkHeaderParsing() {
        XCTAssertEqual(
            LinkHeader.nextURL(from: #"<https://huggingface.co/api/models?cursor=abc123&limit=30>; rel="next""#)?.absoluteString,
            "https://huggingface.co/api/models?cursor=abc123&limit=30"
        )
        XCTAssertEqual(
            LinkHeader.nextURL(from: #"<https://x.co/a>; rel="prev", <https://x.co/b>; rel="next""#)?.absoluteString,
            "https://x.co/b"
        )
        XCTAssertNil(LinkHeader.nextURL(from: #"<https://x.co/a>; rel="prev""#))
        XCTAssertNil(LinkHeader.nextURL(from: nil))
        XCTAssertNil(LinkHeader.nextURL(from: ""))
    }

    func testResolveURLIsCommitPinned() {
        let client = HubClient()
        let url = client.resolveURL(
            modelID: "mlx-community/Qwen3-4B-4bit",
            revision: "0123456789abcdef0123456789abcdef01234567",
            path: "model.safetensors"
        )
        XCTAssertEqual(
            url.absoluteString,
            "https://huggingface.co/mlx-community/Qwen3-4B-4bit/resolve/0123456789abcdef0123456789abcdef01234567/model.safetensors"
        )
    }

    func testSSHHumanizeHints() {
        XCTAssertTrue(SSHRunner.humanize(stderr: "jason@node2.local: Permission denied (publickey,password).")
            .contains("ssh-add --apple-use-keychain"))
        XCTAssertTrue(SSHRunner.humanize(stderr: "ssh: Could not resolve hostname nodeX.local")
            .contains("hostfile"))
    }
}

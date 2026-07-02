import XCTest
@testable import JacclClusterKit

@MainActor
final class ShardingPreflightTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Builds a fake env prefix with an mlx_lm models dir + a model dir.
    private func makeFixture(modelType: String, modelFiles: [String: String]) throws -> (modelDir: String, envPrefix: String) {
        let env = tmp.appendingPathComponent("env")
        let modelsDir = env.appendingPathComponent("lib/python3.11/site-packages/mlx_lm/models")
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        for (name, contents) in modelFiles {
            try Data(contents.utf8).write(to: modelsDir.appendingPathComponent("\(name).py"))
        }
        let model = tmp.appendingPathComponent("MyModel")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data(#"{"model_type": "\#(modelType)"}"#.utf8).write(to: model.appendingPathComponent("config.json"))
        return (model.path, env.path)
    }

    func testShardableModelPasses() throws {
        let (model, env) = try makeFixture(
            modelType: "qwen3",
            modelFiles: ["qwen3": "class Model:\n    def shard(self, group):\n        pass\n"]
        )
        XCTAssertNil(ServerController.shardingSupportIssue(modelDir: model, envPrefix: env))
    }

    func testUnshardableModelIsBlockedWithSupportedList() throws {
        let (model, env) = try makeFixture(
            modelType: "gemma3n",
            modelFiles: [
                "gemma3n": "class Model:\n    pass\n",
                "qwen3": "class Model:\n    def shard(self, group):\n        pass\n",
                "llama": "class Model:\n    def shard(self, group):\n        pass\n",
            ]
        )
        let issue = try XCTUnwrap(ServerController.shardingSupportIssue(modelDir: model, envPrefix: env))
        XCTAssertTrue(issue.contains("gemma3n"))
        XCTAssertTrue(issue.contains("cannot shard"))
        XCTAssertTrue(issue.contains("llama, qwen3"), "should list the shardable architectures: \(issue)")
    }

    func testUnknownModelTypeIsBlocked() throws {
        let (model, env) = try makeFixture(
            modelType: "brand-new-arch",
            modelFiles: ["qwen3": "def shard(): pass"]
        )
        let issue = try XCTUnwrap(ServerController.shardingSupportIssue(modelDir: model, envPrefix: env))
        XCTAssertTrue(issue.contains("isn't known to the mlx-lm"))
    }

    func testUndeterminableStateDoesNotBlock() throws {
        // No config.json → nil; env without mlx_lm → nil.
        let bareModel = tmp.appendingPathComponent("bare")
        try FileManager.default.createDirectory(at: bareModel, withIntermediateDirectories: true)
        XCTAssertNil(ServerController.shardingSupportIssue(modelDir: bareModel.path, envPrefix: "/nonexistent"))

        let (model, _) = try makeFixture(modelType: "qwen3", modelFiles: [:])
        XCTAssertNil(ServerController.shardingSupportIssue(modelDir: model, envPrefix: "/nonexistent"))
    }
}

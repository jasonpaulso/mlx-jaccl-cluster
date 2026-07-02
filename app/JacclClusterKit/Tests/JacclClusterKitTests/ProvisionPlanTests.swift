import XCTest
@testable import JacclClusterKit

final class ProvisionPlanTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeExecutable(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// uv layout: venv inside the repo, python symlinked to a uv-managed
    /// interpreter under $HOME → 3 items, env excluded from the repo sync.
    func testUvVenvInsideRepo() throws {
        let home = tmp.appendingPathComponent("home")
        let repo = home.appendingPathComponent("repos/mlx-jaccl")
        let env = repo.appendingPathComponent("mlxjccl")
        let interpreterRoot = home.appendingPathComponent(".local/share/uv/python/cpython-3.11.15-macos-aarch64-none")
        let realPython = interpreterRoot.appendingPathComponent("bin/python3.11")

        try makeExecutable(at: realPython)
        try FileManager.default.createDirectory(at: env.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: env.appendingPathComponent("bin/python3"),
            withDestinationURL: realPython
        )

        let plan = try ProvisionPlan.make(repoPath: repo.path, envPrefix: env.path, home: home.path)

        XCTAssertEqual(plan.items.map(\.label), ["repo", "python interpreter", "environment"])
        XCTAssertNil(plan.systemInterpreterPath)
        XCTAssertEqual(plan.envPythonPath, env.appendingPathComponent("bin/python3").path)

        let repoItem = plan.items[0]
        XCTAssertEqual(repoItem.path, repo.path)
        XCTAssertTrue(repoItem.excludes.contains("/mlxjccl"), "env inside the repo must be excluded from the repo sync: \(repoItem.excludes)")
        XCTAssertTrue(repoItem.excludes.contains(".git"))

        XCTAssertEqual(plan.items[1].path, interpreterRoot.path)
        XCTAssertEqual(plan.items[2].path, env.path)
    }

    /// conda layout: python is a real file inside the prefix, env outside the
    /// repo → 2 items, no interpreter item, no repo exclusion for the env.
    func testCondaStyleEnvOutsideRepo() throws {
        let home = tmp.appendingPathComponent("home")
        let repo = home.appendingPathComponent("repos/mlx-jaccl")
        let env = home.appendingPathComponent("miniforge3/envs/mlxjccl")

        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try makeExecutable(at: env.appendingPathComponent("bin/python3"))

        let plan = try ProvisionPlan.make(repoPath: repo.path, envPrefix: env.path, home: home.path)

        XCTAssertEqual(plan.items.map(\.label), ["repo", "environment"])
        XCTAssertNil(plan.systemInterpreterPath)
        XCTAssertFalse(plan.items[0].excludes.contains { $0.contains("mlxjccl") })
        XCTAssertEqual(plan.items[1].path, env.path)
    }

    /// venv built from a system python (outside $HOME): can't be synced —
    /// the plan flags the interpreter as a remote prerequisite instead.
    func testSystemPythonBecomesRemotePrerequisite() throws {
        let home = tmp.appendingPathComponent("home")
        let systemArea = tmp.appendingPathComponent("opt/homebrew/Cellar/python@3.11/3.11.9/Frameworks")
        let repo = home.appendingPathComponent("repos/mlx-jaccl")
        let env = home.appendingPathComponent("venvs/mlxjccl")
        let realPython = systemArea.appendingPathComponent("bin/python3.11")

        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try makeExecutable(at: realPython)
        try FileManager.default.createDirectory(at: env.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: env.appendingPathComponent("bin/python3"),
            withDestinationURL: realPython
        )

        let plan = try ProvisionPlan.make(repoPath: repo.path, envPrefix: env.path, home: home.path)

        XCTAssertEqual(plan.items.map(\.label), ["repo", "environment"])
        XCTAssertEqual(plan.systemInterpreterPath, realPython.resolvingSymlinksInPath().path)
    }

    func testMissingPythonThrows() throws {
        let home = tmp.appendingPathComponent("home")
        let repo = home.appendingPathComponent("repo")
        let env = home.appendingPathComponent("empty-env")
        try FileManager.default.createDirectory(at: env.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

        XCTAssertThrowsError(try ProvisionPlan.make(repoPath: repo.path, envPrefix: env.path, home: home.path)) { error in
            XCTAssertTrue(error.localizedDescription.contains("No python found"))
        }
    }
}

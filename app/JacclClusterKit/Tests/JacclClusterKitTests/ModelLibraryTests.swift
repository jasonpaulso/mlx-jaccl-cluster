import XCTest
@testable import JacclClusterKit

final class ModelLibraryTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: Manifest codec

    func testManifestRoundTrip() throws {
        let manifest = ModelManifest(
            repoID: "mlx-community/Qwen3-0.6B-4bit",
            revision: "0123456789abcdef0123456789abcdef01234567",
            files: [
                ManifestFile(path: "config.json", size: 1042, checksum: .gitSHA1("2222222222222222222222222222222222222222")),
                ManifestFile(path: "model.safetensors", size: 2_264_823_904, checksum: .sha256(String(repeating: "a", count: 64))),
                ManifestFile(path: "notes.txt", size: 5, checksum: .none),
            ]
        )
        try manifest.save(toModelDir: tmp)
        let loaded = try XCTUnwrap(ModelManifest.load(fromModelDir: tmp))
        XCTAssertEqual(loaded.repoID, manifest.repoID)
        XCTAssertEqual(loaded.revision, manifest.revision)
        XCTAssertEqual(loaded.files, manifest.files)
        XCTAssertEqual(loaded.totalBytes, 1042 + 2_264_823_904 + 5)
    }

    func testSidecarRoundTripAndCompletion() throws {
        var sidecar = DownloadSidecar(
            repoID: "org/model",
            revision: "deadbeef",
            files: [ManifestFile(path: "a.bin", size: 10, checksum: .none)]
        )
        sidecar.completedPaths.insert("a.bin")
        try sidecar.save(toModelDir: tmp)
        let loaded = try XCTUnwrap(DownloadSidecar.load(fromModelDir: tmp))
        XCTAssertEqual(loaded.completedPaths, ["a.bin"])
        XCTAssertEqual(loaded.toManifest().files, sidecar.files)
        DownloadSidecar.delete(fromModelDir: tmp)
        XCTAssertNil(DownloadSidecar.load(fromModelDir: tmp))
    }

    // MARK: Classification

    func testClassifyComplete() throws {
        let dir = tmp.appendingPathComponent("Complete")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try ModelManifest(repoID: "o/m", revision: "r", files: []).save(toModelDir: dir)
        XCTAssertEqual(LocalModelScanner.classify(modelDir: dir).classification, .complete)
    }

    func testClassifyResumable() throws {
        let dir = tmp.appendingPathComponent("Resumable")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try DownloadSidecar(repoID: "o/m", revision: "r", files: []).save(toModelDir: dir)
        XCTAssertEqual(LocalModelScanner.classify(modelDir: dir).classification, .resumable)
    }

    func testClassifyImported() throws {
        // A hand-copied model dir: config.json + safetensors, no manifest.
        let dir = tmp.appendingPathComponent("Imported")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
        try Data([0x1]).write(to: dir.appendingPathComponent("model.safetensors"))
        let model = LocalModelScanner.classify(modelDir: dir)
        XCTAssertEqual(model.classification, .imported)
        XCTAssertTrue(model.isServable)
    }

    func testClassifyUnknown() throws {
        let dir = tmp.appendingPathComponent("Junk")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: dir.appendingPathComponent("readme.txt"))
        let model = LocalModelScanner.classify(modelDir: dir)
        XCTAssertEqual(model.classification, .unknown)
        XCTAssertFalse(model.isServable)
    }

    func testResumableIsNotServable() throws {
        let dir = tmp.appendingPathComponent("Partial")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
        try Data([0x1]).write(to: dir.appendingPathComponent("model.safetensors"))
        try DownloadSidecar(repoID: "o/m", revision: "r", files: []).save(toModelDir: dir)
        let model = LocalModelScanner.classify(modelDir: dir)
        XCTAssertEqual(model.classification, .resumable, "sidecar wins over looks-like-model")
        XCTAssertFalse(model.isServable, "partial downloads must never be servable (HF_HUB_OFFLINE contract)")
    }

    func testAdoptGeneratesManifest() throws {
        let dir = tmp.appendingPathComponent("Adoptee")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
        try Data(repeating: 0, count: 128).write(to: dir.appendingPathComponent("model.safetensors"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("sub/extra.json"))

        let manifest = try LocalModelScanner.adopt(modelDir: dir, repoID: "org/adoptee")
        XCTAssertEqual(manifest.repoID, "org/adoptee")
        XCTAssertEqual(manifest.revision, "adopted")
        XCTAssertEqual(Set(manifest.files.map(\.path)), ["config.json", "model.safetensors", "sub/extra.json"])
        XCTAssertEqual(manifest.files.first { $0.path == "model.safetensors" }?.size, 128)
        XCTAssertEqual(LocalModelScanner.classify(modelDir: dir).classification, .complete)
    }

    func testScanOrdersAndClassifies() throws {
        for name in ["b-model", "a-model"] {
            let dir = tmp.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try ModelManifest(repoID: "o/\(name)", revision: "r", files: []).save(toModelDir: dir)
        }
        let models = LocalModelScanner.scan(libraryRoot: tmp)
        XCTAssertEqual(models.map(\.name), ["a-model", "b-model"])
    }

    // MARK: Library state reconcile

    func testReconcileMarksInterruptedDownloadsPaused() throws {
        let dir = tmp.appendingPathComponent("Partial")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try DownloadSidecar(repoID: "o/partial", revision: "r", files: []).save(toModelDir: dir)

        var state = LibraryState()
        state.downloads["o/partial"] = DownloadTaskRecord(
            modelID: "o/partial", dirName: "Partial",
            phase: .running(fractionCompleted: 0.9),
            receivedBytes: 280, totalBytes: 300
        )
        state.reconcile(with: LocalModelScanner.scan(libraryRoot: tmp))
        XCTAssertEqual(state.downloads["o/partial"]?.phase, .paused)
        XCTAssertEqual(state.downloads["o/partial"]?.receivedBytes, 280, "bytes stay intact across force-quit")
    }

    func testReconcileCompletesFinishedDownloads() throws {
        let dir = tmp.appendingPathComponent("Done")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try ModelManifest(repoID: "o/done", revision: "r", files: []).save(toModelDir: dir)

        var state = LibraryState()
        state.downloads["o/done"] = DownloadTaskRecord(
            modelID: "o/done", dirName: "Done",
            phase: .running(fractionCompleted: 0.99),
            receivedBytes: 299, totalBytes: 300
        )
        state.reconcile(with: LocalModelScanner.scan(libraryRoot: tmp))
        XCTAssertEqual(state.downloads["o/done"]?.phase, .completed)
    }

    func testReconcileDropsVanishedDirectories() {
        var state = LibraryState()
        state.downloads["o/gone"] = DownloadTaskRecord(
            modelID: "o/gone", dirName: "Gone", phase: .running(fractionCompleted: 0.5)
        )
        state.reconcile(with: [])
        XCTAssertNil(state.downloads["o/gone"])
    }

    // MARK: Incremental hashing

    func testGitBlobSHA1MatchesGit() {
        // git hash-object of the string "hello\n" is ce013625030ba8dba906f756967f9e9ca394464a
        var hasher = IncrementalHasher(expected: .gitSHA1("ce013625030ba8dba906f756967f9e9ca394464a"), fileSize: 6)
        hasher.update(Data("hello\n".utf8))
        XCTAssertTrue(hasher.verify())
    }

    func testSHA256Verify() {
        // sha256("abc")
        var hasher = IncrementalHasher(
            expected: .sha256("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            fileSize: 3
        )
        hasher.update(Data("ab".utf8))
        hasher.update(Data("c".utf8))
        XCTAssertTrue(hasher.verify())
    }

    func testChecksumMismatchDetected() {
        var hasher = IncrementalHasher(expected: .sha256(String(repeating: "0", count: 64)), fileSize: 3)
        hasher.update(Data("abc".utf8))
        XCTAssertFalse(hasher.verify())
    }

    func testHasherResetSupportsRestartAfter200() {
        var hasher = IncrementalHasher(
            expected: .sha256("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            fileSize: 3
        )
        hasher.update(Data("garbage-from-partial".utf8))
        hasher.reset() // server returned 200 instead of 206 → truncate + rehash
        hasher.update(Data("abc".utf8))
        XCTAssertTrue(hasher.verify())
    }

    // MARK: Directory naming

    func testDirectoryNameCollision() throws {
        // Existing dir claimed by a different repo → org-qualified name.
        let dir = tmp.appendingPathComponent("Qwen3-4B")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try ModelManifest(repoID: "someoneelse/Qwen3-4B", revision: "r", files: []).save(toModelDir: dir)

        XCTAssertEqual(
            DownloadEngine.directoryName(for: "mlx-community/Qwen3-4B", in: tmp),
            "mlx-community--Qwen3-4B"
        )
        XCTAssertEqual(
            DownloadEngine.directoryName(for: "someoneelse/Qwen3-4B", in: tmp),
            "Qwen3-4B"
        )
        XCTAssertEqual(
            DownloadEngine.directoryName(for: "mlx-community/Fresh-Model", in: tmp),
            "Fresh-Model"
        )
    }
}

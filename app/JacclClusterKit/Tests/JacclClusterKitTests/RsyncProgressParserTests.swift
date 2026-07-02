import XCTest
@testable import JacclClusterKit

final class RsyncProgressParserTests: XCTestCase {
    private let sizes: [String: Int64] = [
        "config.json": 1_000,
        "model-00001-of-00002.safetensors": 1_000_000,
        "model-00002-of-00002.safetensors": 2_000_000,
    ]

    func testTotalFromManifest() {
        let parser = RsyncProgressParser(fileSizes: sizes)
        XCTAssertEqual(parser.totalBytes, 3_001_000)
    }

    /// rsync 3.x flavor: comma thousands separators, xfr suffix.
    func testRsync3Stream() {
        var parser = RsyncProgressParser(fileSizes: sizes)
        XCTAssertNil(parser.consume(line: "sending incremental file list"))

        var snap = parser.consume(line: "model-00001-of-00002.safetensors")
        XCTAssertEqual(snap?.currentFile, "model-00001-of-00002.safetensors")
        XCTAssertEqual(snap?.transferredBytes, 0)

        snap = parser.consume(line: "        500,000  50%   12.34MB/s    0:00:01")
        XCTAssertEqual(snap?.transferredBytes, 500_000)

        snap = parser.consume(line: "      1,000,000 100%   12.34MB/s    0:00:02 (xfr#1, to-chk=1/3)")
        XCTAssertEqual(snap?.transferredBytes, 1_000_000)

        // Next file: previous counts as its full manifest size.
        snap = parser.consume(line: "model-00002-of-00002.safetensors")
        XCTAssertEqual(snap?.transferredBytes, 1_000_000)
        XCTAssertEqual(snap?.currentFile, "model-00002-of-00002.safetensors")

        snap = parser.consume(line: "      1,500,000  75%    8.00MB/s    0:00:03")
        XCTAssertEqual(snap?.transferredBytes, 2_500_000)

        let final = parser.finish()
        XCTAssertEqual(final.transferredBytes, 3_000_000)
    }

    /// openrsync flavor: plain digits, no separators, no xfr suffix.
    func testOpenrsyncStream() {
        var parser = RsyncProgressParser(fileSizes: sizes)
        _ = parser.consume(line: "config.json")
        var snap = parser.consume(line: "        1000 100%    0.95kB/s    0:00:00")
        XCTAssertEqual(snap?.transferredBytes, 1_000)

        snap = parser.consume(line: "model-00001-of-00002.safetensors")
        XCTAssertEqual(snap?.transferredBytes, 1_000)

        snap = parser.consume(line: "      750000  75%   10.00MB/s   0:00:01")
        XCTAssertEqual(snap?.transferredBytes, 751_000)
    }

    func testChatterLinesIgnored() {
        var parser = RsyncProgressParser(fileSizes: sizes)
        XCTAssertNil(parser.consume(line: "sending incremental file list"))
        XCTAssertNil(parser.consume(line: "building file list ..."))
        XCTAssertNil(parser.consume(line: "created directory /Users/x/models_mlx/Q"))
        XCTAssertNil(parser.consume(line: "sent 3,001,000 bytes  received 100 bytes  600,220.00 bytes/sec"))
        XCTAssertNil(parser.consume(line: "total size is 3,001,000  speedup is 1.00"))
        XCTAssertNil(parser.consume(line: "")) // blank
        XCTAssertNil(parser.consume(line: "subdir/")) // directory entry
    }

    func testProgressLineRequiresPercent() {
        // "sent ..." style summary lines with leading whitespace must not parse as bytes.
        XCTAssertNil(RsyncProgressParser.parseProgressBytes("   1234 bytes/sec"))
        XCTAssertNotNil(RsyncProgressParser.parseProgressBytes("   1234  10%   1.0MB/s  0:00:01"))
        XCTAssertNil(RsyncProgressParser.parseProgressBytes("no-leading-whitespace 10%"))
    }

    func testTransferClampedToTotal() {
        var parser = RsyncProgressParser(fileSizes: ["a": 10])
        _ = parser.consume(line: "a")
        let snap = parser.consume(line: "      50 100%   1.0kB/s   0:00:00")
        XCTAssertEqual(snap?.transferredBytes, 10, "never report more than the manifest total")
    }

    func testItemizeChangeDetection() {
        XCTAssertTrue(SyncEngine.isItemizeChangeLine(">f+++++++++ model.safetensors"))
        XCTAssertTrue(SyncEngine.isItemizeChangeLine(">f.st...... config.json"))
        XCTAssertTrue(SyncEngine.isItemizeChangeLine("cd+++++++++ subdir/"))
        XCTAssertTrue(SyncEngine.isItemizeChangeLine("*deleting   old.bin"))
        XCTAssertFalse(SyncEngine.isItemizeChangeLine(""))
        XCTAssertFalse(SyncEngine.isItemizeChangeLine("sending incremental file list"))
        XCTAssertFalse(SyncEngine.isItemizeChangeLine("sent 100 bytes  received 10 bytes"))
        // Unchanged-file line (all dots) is a no-op, not a change.
        XCTAssertFalse(SyncEngine.isItemizeChangeLine(".f          config.json"))
    }
}

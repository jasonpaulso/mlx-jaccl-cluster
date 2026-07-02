import Foundation
import CryptoKit

/// Incremental checksum over streamed bytes. For git blob sha1 the
/// "blob <len>\0" header is folded in at reset time.
struct IncrementalHasher {
    private enum Kind {
        case sha256(SHA256)
        case gitSHA1(Insecure.SHA1)
        case none
    }

    private var kind: Kind
    private let expected: FileChecksum
    private let fileSize: Int64

    init(expected: FileChecksum, fileSize: Int64) {
        self.expected = expected
        self.fileSize = fileSize
        self.kind = .none
        reset()
    }

    mutating func reset() {
        switch expected {
        case .sha256:
            kind = .sha256(SHA256())
        case .gitSHA1:
            var sha1 = Insecure.SHA1()
            sha1.update(data: Data("blob \(fileSize)\u{0}".utf8))
            kind = .gitSHA1(sha1)
        case .none:
            kind = .none
        }
    }

    mutating func update(_ data: Data) {
        switch kind {
        case .sha256(var h):
            h.update(data: data)
            kind = .sha256(h)
        case .gitSHA1(var h):
            h.update(data: data)
            kind = .gitSHA1(h)
        case .none:
            break
        }
    }

    /// True when the streamed content matches the expected checksum
    /// (vacuously true when no checksum was published).
    func verify() -> Bool {
        switch (kind, expected) {
        case (.sha256(let h), .sha256(let want)):
            return hex(h.finalize()) == want.lowercased()
        case (.gitSHA1(let h), .gitSHA1(let want)):
            return hex(h.finalize()) == want.lowercased()
        case (.none, .none):
            return true
        default:
            return false
        }
    }

    private func hex(_ digest: some Sequence<UInt8>) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum FileDownloadError: Error, LocalizedError {
    case httpStatus(Int)
    case checksumMismatch(path: String)
    case cancelled
    case io(String)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code): "HTTP \(code)"
        case .checksumMismatch(let path): "Checksum mismatch for \(path) — file re-downloaded next attempt."
        case .cancelled: "Cancelled"
        case .io(let m): m
        }
    }
}

/// Downloads one URL into `<destination>.jacclpart` with Range resume and
/// incremental hashing, then atomically renames onto `destination` when the
/// checksum matches. Delegate-based URLSession streaming (fast Data chunks,
/// unlike per-byte AsyncBytes iteration — this must sustain full line rate
/// for 500GB repos).
final class FileDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    // All mutable state is confined to the serial delegate queue.
    private var handle: FileHandle?
    private var hasher: IncrementalHasher
    private var received: Int64 = 0
    private var resumedFrom: Int64 = 0
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?

    private let destination: URL
    private let partURL: URL
    private let expectedSize: Int64
    private let checksum: FileChecksum
    private let onBytes: @Sendable (Int64) -> Void // absolute bytes for this file

    init(destination: URL, expectedSize: Int64, checksum: FileChecksum,
         onBytes: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.partURL = URL(fileURLWithPath: destination.path + DownloadSidecar.partSuffix)
        self.expectedSize = expectedSize
        self.checksum = checksum
        self.hasher = IncrementalHasher(expected: checksum, fileSize: expectedSize)
        self.onBytes = onBytes
    }

    /// Runs the download to completion (throws on failure/cancellation).
    func run(url: URL, token: String?) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Already complete? (e.g. crash between rename and sidecar update)
        if fm.fileExists(atPath: destination.path) {
            if Self.fileSize(atPath: destination.path) == expectedSize {
                onBytes(expectedSize)
                return
            }
            try? fm.removeItem(at: destination)
        }

        // Resume: pre-hash existing partial bytes.
        var partialSize: Int64 = 0
        if fm.fileExists(atPath: partURL.path) {
            partialSize = Self.fileSize(atPath: partURL.path) ?? 0
            if partialSize > expectedSize {
                try? fm.removeItem(at: partURL)
                partialSize = 0
            } else if partialSize > 0 {
                try prehashPartial(size: partialSize)
            }
        }
        if !fm.fileExists(atPath: partURL.path) {
            fm.createFile(atPath: partURL.path, contents: nil)
        }

        let fileHandle = try FileHandle(forWritingTo: partURL)
        _ = try fileHandle.seekToEnd()
        handle = fileHandle
        resumedFrom = partialSize
        received = partialSize
        onBytes(partialSize)

        let request: URLRequest = {
            var req = URLRequest(url: url)
            if let token {
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            if partialSize > 0 {
                req.setValue("bytes=\(partialSize)-", forHTTPHeaderField: "Range")
            }
            return req
        }()

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60       // stall timeout between chunks
        config.timeoutIntervalForResource = 7 * 24 * 3600
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        let urlSession = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        session = urlSession

        defer {
            urlSession.finishTasksAndInvalidate()
            try? handle?.close()
            handle = nil
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                delegateQueue.addOperation { [weak self] in
                    guard let self else {
                        cont.resume(throwing: FileDownloadError.cancelled)
                        return
                    }
                    self.continuation = cont
                    let dataTask = urlSession.dataTask(with: request)
                    self.task = dataTask
                    dataTask.resume()
                }
            }
        } onCancel: {
            task?.cancel()
        }

        // Stream done: verify + atomic rename.
        try? handle?.close()
        handle = nil
        guard received == expectedSize else {
            throw FileDownloadError.io("Size mismatch for \(destination.lastPathComponent): got \(received), expected \(expectedSize).")
        }
        guard hasher.verify() else {
            try? fm.removeItem(at: partURL) // poisoned partial — restart clean next attempt
            throw FileDownloadError.checksumMismatch(path: destination.lastPathComponent)
        }
        // Same-volume rename is atomic; destination was cleared up front.
        try fm.moveItem(at: partURL, to: destination)
        onBytes(expectedSize)
    }

    private static func fileSize(atPath path: String) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return (attrs[.size] as? NSNumber)?.int64Value
    }

    private func prehashPartial(size: Int64) throws {
        let readHandle = try FileHandle(forReadingFrom: partURL)
        defer { try? readHandle.close() }
        var remaining = size
        while remaining > 0 {
            let chunkSize = Int(min(remaining, 4 * 1024 * 1024))
            guard let chunk = try readHandle.read(upToCount: chunkSize), !chunk.isEmpty else {
                throw FileDownloadError.io("Failed to re-read partial file for hashing.")
            }
            hasher.update(chunk)
            remaining -= Int64(chunk.count)
        }
    }

    // MARK: URLSessionDataDelegate (serial queue)

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        switch http.statusCode {
        case 206:
            completionHandler(.allow)
        case 200:
            // Server ignored our Range: truncate and restart the file.
            if resumedFrom > 0 {
                do {
                    try handle?.truncate(atOffset: 0)
                    received = 0
                    resumedFrom = 0
                    hasher.reset()
                    onBytes(0)
                } catch {
                    finish(with: FileDownloadError.io("Failed to truncate partial file: \(error.localizedDescription)"))
                    completionHandler(.cancel)
                    return
                }
            }
            completionHandler(.allow)
        default:
            finish(with: FileDownloadError.httpStatus(http.statusCode))
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
        } catch {
            finish(with: FileDownloadError.io("Write failed: \(error.localizedDescription)"))
            dataTask.cancel()
            return
        }
        hasher.update(data)
        received += Int64(data.count)
        onBytes(received)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if (error as? URLError)?.code == .cancelled {
                finish(with: FileDownloadError.cancelled)
            } else {
                finish(with: error)
            }
        } else {
            finish(with: nil)
        }
    }

    private func finish(with error: Error?) {
        guard let cont = continuation else { return }
        continuation = nil
        if let error {
            cont.resume(throwing: error)
        } else {
            cont.resume()
        }
    }
}

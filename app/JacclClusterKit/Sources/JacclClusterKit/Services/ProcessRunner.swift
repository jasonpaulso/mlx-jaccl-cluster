import Foundation

/// Result of a one-shot subprocess run.
public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool

    public var succeeded: Bool { exitCode == 0 && !timedOut }
}

public enum ProcessRunnerError: Error, LocalizedError {
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let m): "Failed to launch process: \(m)"
        }
    }
}

/// Runs a subprocess to completion with a hard timeout, reading both pipes
/// concurrently (avoids the classic full-pipe deadlock). Stateless; used for
/// ssh, rsync --version probes, conda discovery, etc.
public enum ProcessRunner {
    public static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: String? = nil,
        timeout: TimeInterval = 30
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory, isDirectory: true)
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let exitStream = AsyncStream<Int32> { continuation in
            process.terminationHandler = { p in
                continuation.yield(p.terminationStatus)
                continuation.finish()
            }
        }

        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
        }

        let pid = process.processIdentifier

        // Drain both pipes concurrently so a chatty child can't fill a pipe and hang.
        async let outData = readAll(outPipe.fileHandleForReading)
        async let errData = readAll(errPipe.fileHandleForReading)

        enum Outcome: Sendable {
            case exited(Int32)
            case timedOut
        }

        let outcome: Outcome = await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                for await code in exitStream {
                    return .exited(code)
                }
                return .exited(-1)
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    return .timedOut
                } catch {
                    return .exited(-1) // cancelled: the other branch won
                }
            }
            let first = await group.next() ?? .exited(-1)
            if case .timedOut = first {
                kill(pid, SIGKILL)
                // Let the exit branch observe termination so pipes close.
                _ = await group.next()
            }
            group.cancelAll()
            return first
        }

        let stdout = String(data: await outData, encoding: .utf8) ?? ""
        let stderr = String(data: await errData, encoding: .utf8) ?? ""

        switch outcome {
        case .exited(let code):
            return ProcessResult(exitCode: code, stdout: stdout, stderr: stderr, timedOut: false)
        case .timedOut:
            return ProcessResult(exitCode: -1, stdout: stdout, stderr: stderr, timedOut: true)
        }
    }

    static func readAll(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let data = (try? handle.readToEnd()) ?? Data()
                continuation.resume(returning: data)
            }
        }
    }
}

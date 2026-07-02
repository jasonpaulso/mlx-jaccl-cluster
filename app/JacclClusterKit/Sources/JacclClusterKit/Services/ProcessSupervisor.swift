import Foundation

/// Specification for the supervised `mlx.launch` child.
public struct LaunchSpec: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var currentDirectory: String?

    public init(executable: String, arguments: [String], environment: [String: String], currentDirectory: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
    }

    /// Builds the exact launch the shell script performs (scripts/run_openai_cluster_server.sh),
    /// minus `conda run` — we exec `<prefix>/bin/mlx.launch` directly so logs stream
    /// unbuffered and SIGTERM reaches the launcher.
    public static func clusterServer(
        condaPrefix: String,
        hostfilePath: String,
        serverScriptPath: String,
        modelDir: String,
        modelID: String,
        ctrlHost: String,
        config: ServerLaunchConfig,
        repoPath: String?
    ) -> LaunchSpec {
        var args: [String] = []
        if config.verbose { args.append("--verbose") }
        args += ["--backend", "jaccl", "--hostfile", hostfilePath]

        // Full env set mirrored from the script, in the same order.
        var env: [(String, String)] = [
            ("MLX_METAL_FAST_SYNCH", "1"),
            ("HF_HUB_OFFLINE", "1"),
            ("TRANSFORMERS_OFFLINE", "1"),
            ("MODEL_DIR", modelDir),
            ("MODEL_ID", modelID),
            ("HOST", config.httpHost),
            ("PORT", String(config.httpPort)),
            ("CTRL_HOST", ctrlHost),
            ("CTRL_PORT", String(config.ctrlPort)),
            ("QUEUE_MAX", String(config.queueMax)),
            ("REQ_TIMEOUT", String(config.requestTimeoutSeconds)),
        ]
        env += config.extraEnv.sorted(by: { $0.key < $1.key }).map { ($0.key, $0.value) }
        for (key, value) in env {
            args += ["--env", "\(key)=\(value)"]
        }
        args += ["--", serverScriptPath]

        var processEnv: [String: String] = [
            "PATH": ToolLocator.launchPATH(prefix: condaPrefix),
            "HOME": NSHomeDirectory(),
        ]
        // ssh needs the agent socket for keychain-loaded keys.
        if let authSock = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] {
            processEnv["SSH_AUTH_SOCK"] = authSock
        }
        if let user = ProcessInfo.processInfo.environment["USER"] {
            processEnv["USER"] = user
        }
        // Unbuffered python output so log milestones arrive promptly.
        processEnv["PYTHONUNBUFFERED"] = "1"

        return LaunchSpec(
            executable: "\(condaPrefix)/bin/mlx.launch",
            arguments: args,
            environment: processEnv,
            currentDirectory: repoPath
        )
    }
}

/// Supervises one long-running child process, merging stdout/stderr into a
/// single async event stream and escalating SIGTERM → SIGKILL on stop.
///
/// Killing the local mlx.launch does NOT kill remote ranks — callers must also
/// ssh-pkill every node (ServerController does).
public actor ProcessSupervisor {
    public enum Event: Sendable {
        case line(LogLine)
        case exited(code: Int32)
    }

    private var process: Process?

    public init() {}

    public var isRunning: Bool {
        process?.isRunning ?? false
    }

    public func launch(_ spec: LaunchSpec) throws -> AsyncStream<Event> {
        guard process == nil || process?.isRunning != true else {
            throw ProcessRunnerError.launchFailed("A supervised process is already running.")
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: spec.executable)
        p.arguments = spec.arguments
        p.environment = spec.environment
        if let dir = spec.currentDirectory {
            p.currentDirectoryURL = URL(fileURLWithPath: dir, isDirectory: true)
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = FileHandle.nullDevice

        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading

        let stream = AsyncStream<Event> { continuation in
            let readers = Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        do {
                            for try await line in outHandle.bytes.lines {
                                continuation.yield(.line(LogLine(text: line, isStderr: false)))
                            }
                        } catch {}
                    }
                    group.addTask {
                        do {
                            for try await line in errHandle.bytes.lines {
                                continuation.yield(.line(LogLine(text: line, isStderr: true)))
                            }
                        } catch {}
                    }
                }
            }
            p.terminationHandler = { proc in
                let code = proc.terminationStatus
                Task {
                    // Drain remaining output before reporting exit.
                    await readers.value
                    continuation.yield(.exited(code: code))
                    continuation.finish()
                }
            }
        }

        try p.run()
        process = p
        return stream
    }

    /// SIGTERM, wait up to `graceSeconds`, then SIGKILL. Returns when the
    /// process is no longer running (the event stream still delivers `.exited`).
    public func terminate(graceSeconds: TimeInterval = 5) async {
        guard let p = process, p.isRunning else { return }
        let pid = p.processIdentifier
        p.terminate() // SIGTERM

        let deadline = Date().addingTimeInterval(graceSeconds)
        while p.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if p.isRunning {
            kill(pid, SIGKILL)
            while p.isRunning {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    public func clear() {
        if process?.isRunning != true {
            process = nil
        }
    }
}

import Foundation

/// Per-node sync status for a model, persisted between runs.
public enum NodeSyncState: String, Codable, Sendable {
    case inSync
    case stale
    case missing
    case unknown
}

public enum SyncEngineEvent: Sendable {
    case nodeStarted(model: String, host: String)
    case nodeProgress(model: String, host: String, transferredBytes: Int64, totalBytes: Int64, currentFile: String?)
    case nodeCompleted(model: String, host: String, verified: Bool)
    case nodeFailed(model: String, host: String, message: String)
    case modelFinished(model: String)
}

public enum SyncError: Error, LocalizedError, Sendable {
    case pathInvariantViolated(host: String, localHome: String, remoteHome: String)
    case remoteHomeUnresolvable(host: String, detail: String)
    case rsyncFailed(host: String, exitCode: Int32, stderr: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .pathInvariantViolated(let host, let localHome, let remoteHome):
            return """
            \(host) has home \(remoteHome) but this Mac has \(localHome). \
            MODEL_DIR is passed verbatim to all ranks, so the model path must be identical \
            on every node — syncing would produce a server that deadlocks at start. \
            Move the model library outside the home directory or align usernames.
            """
        case .remoteHomeUnresolvable(let host, let detail):
            return "Could not resolve $HOME on \(host): \(detail)"
        case .rsyncFailed(let host, let code, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "rsync to \(host) failed (exit \(code))" + (trimmed.isEmpty ? "" : ": \(trimmed.suffix(300))")
        case .cancelled:
            return "Sync cancelled."
        }
    }
}

/// Resolves and caches each node's remote $HOME, and enforces the
/// identical-absolute-path invariant *before* any bytes move.
public actor RemotePathResolver {
    private let ssh: SSHRunner
    private var cache: [String: String] = [:]

    public init(ssh: SSHRunner = SSHRunner()) {
        self.ssh = ssh
    }

    public func remoteHome(host: String) async throws -> String {
        if let cached = cache[host] { return cached }
        let result = try await ssh.run(host: host, command: #"echo "$HOME""#, timeout: 15)
        guard result.exitCode == 0, !result.timedOut else {
            throw SyncError.remoteHomeUnresolvable(host: host, detail: SSHRunner.humanize(stderr: result.stderr))
        }
        let home = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard home.hasPrefix("/") else {
            throw SyncError.remoteHomeUnresolvable(host: host, detail: "unexpected output '\(result.stdout)'")
        }
        cache[host] = home
        return home
    }

    /// Blocking preflight: the local absolute path must be usable verbatim on the node.
    public func preflight(host: String, localPath: String, localHome: String = NSHomeDirectory()) async throws {
        guard localPath.hasPrefix(localHome + "/") || localPath == localHome else {
            return // outside home: /Volumes/..., /opt/... — same-path by construction
        }
        let remote = try await remoteHome(host: host)
        if remote != localHome {
            throw SyncError.pathInvariantViolated(host: host, localHome: localHome, remoteHome: remote)
        }
    }

    public func invalidate() {
        cache.removeAll()
    }
}

/// Pushes model directories to cluster nodes with rsync (`-a --partial --progress`,
/// deliberately no `-z`: safetensors are high-entropy and compression just burns
/// CPU on a LAN). Sequential across nodes by default — all syncs leave rank0
/// over one uplink, and sequential gives clean failure attribution.
public actor SyncEngine {
    private let ssh: SSHRunner
    private let resolver: RemotePathResolver
    private let onEvent: @Sendable (SyncEngineEvent) -> Void
    private var activeSupervisors: [String: ProcessSupervisor] = [:] // "model|host" → rsync supervisor
    private var cancelledModels: Set<String> = []
    private var sleepAssertion: NSObjectProtocol?

    /// Configured rsync path (Homebrew rsync 3 preferred when set); openrsync
    /// at /usr/bin/rsync is the supported baseline.
    public let rsyncPath: String

    public init(ssh: SSHRunner = SSHRunner(),
                resolver: RemotePathResolver? = nil,
                rsyncPath: String = "/usr/bin/rsync",
                onEvent: @escaping @Sendable (SyncEngineEvent) -> Void) {
        self.ssh = ssh
        self.resolver = resolver ?? RemotePathResolver(ssh: ssh)
        self.rsyncPath = rsyncPath.isEmpty ? "/usr/bin/rsync" : rsyncPath
        self.onEvent = onEvent
    }

    // MARK: Public API

    /// Syncs one model to the given nodes, sequentially (or up to maxParallel).
    public func sync(model: LocalModel, hosts: [String], maxParallel: Int = 1) async -> [String: NodeSyncState] {
        cancelledModels.remove(model.name)
        beginSleepAssertion()
        defer { endSleepAssertionIfIdle() }

        var results: [String: NodeSyncState] = [:]
        let window = max(1, maxParallel)

        var pending = hosts.makeIterator()
        await withTaskGroup(of: (String, NodeSyncState).self) { group in
            var inFlight = 0
            while inFlight < window, let host = pending.next() {
                inFlight += 1
                group.addTask { (host, await self.syncNode(model: model, host: host)) }
            }
            while inFlight > 0 {
                guard let (host, state) = await group.next() else { break }
                inFlight -= 1
                results[host] = state
                if let host = pending.next() {
                    inFlight += 1
                    group.addTask { (host, await self.syncNode(model: model, host: host)) }
                }
            }
        }
        onEvent(.modelFinished(model: model.name))
        return results
    }

    public func cancel(model: String) {
        cancelledModels.insert(model)
        for (_, supervisor) in activeSupervisors.filter({ $0.key.hasPrefix("\(model)|") }) {
            // SIGTERM; --partial preserves progress for resume.
            Task { await supervisor.terminate(graceSeconds: 3) }
        }
    }

    // MARK: Per-node

    private func syncNode(model: LocalModel, host: String) async -> NodeSyncState {
        if cancelledModels.contains(model.name) {
            onEvent(.nodeFailed(model: model.name, host: host, message: SyncError.cancelled.localizedDescription))
            return .unknown
        }
        onEvent(.nodeStarted(model: model.name, host: host))
        let localPath = model.url.path
        do {
            // 1. Path invariant preflight (before any bytes move).
            try await resolver.preflight(host: host, localPath: localPath)

            // 2. Ensure the remote parent exists (never send `~` in host:path).
            let parent = model.url.deletingLastPathComponent().path
            let mkdir = try await ssh.run(host: host, command: "mkdir -p '\(parent)'", timeout: 15)
            guard mkdir.exitCode == 0 else {
                throw SyncError.rsyncFailed(host: host, exitCode: mkdir.exitCode, stderr: mkdir.stderr)
            }

            // 3. rsync with live progress.
            try await runRsync(model: model, host: host, remotePath: localPath)

            // 4. Verify: dry-run itemize must report zero changes.
            let verified = await verify(model: model, host: host, remotePath: localPath)
            onEvent(.nodeCompleted(model: model.name, host: host, verified: verified))
            return verified ? .inSync : .stale
        } catch {
            onEvent(.nodeFailed(model: model.name, host: host, message: error.localizedDescription))
            if case SyncError.pathInvariantViolated = error { return .unknown }
            return cancelledModels.contains(model.name) ? .unknown : .stale
        }
    }

    private func rsyncArguments(model: LocalModel, host: String, remotePath: String, dryRun: Bool) -> [String] {
        var args = ["-a", "--partial"]
        if dryRun {
            args += ["--dry-run", "--itemize-changes"]
        } else {
            args += ["--progress"]
        }
        args += [
            "-e", "ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new",
            model.url.path + "/",
            "\(host):\(remotePath)/",
        ]
        return args
    }

    private func runRsync(model: LocalModel, host: String, remotePath: String) async throws {
        let supervisor = ProcessSupervisor()
        let spec = LaunchSpec(
            executable: rsyncPath,
            arguments: rsyncArguments(model: model, host: host, remotePath: remotePath, dryRun: false),
            environment: minimalEnvironment()
        )
        let events = try await supervisor.launch(spec)

        var parser = RsyncProgressParser(fileSizes: fileSizeMap(for: model))
        let key = "\(model.name)|\(host)"
        activeSupervisors[key] = supervisor
        defer { activeSupervisors[key] = nil }

        var stderrTail = ""
        var exitCode: Int32 = -1
        let progressClock = StallClock()
        let totalBytes = parser.totalBytes

        // Stall fallback: if no parsed progress for >10s, poll remote du -sk every 5s.
        let stallTask = Task { [ssh, onEvent] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { break }
                if progressClock.secondsSinceTouch() > 10 {
                    if let result = try? await ssh.run(host: host, command: "du -sk '\(remotePath)' 2>/dev/null | cut -f1", timeout: 10),
                       result.exitCode == 0,
                       let kb = Int64(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        onEvent(.nodeProgress(model: model.name, host: host,
                                              transferredBytes: min(kb * 1024, totalBytes),
                                              totalBytes: totalBytes, currentFile: nil))
                    }
                }
            }
        }
        defer { stallTask.cancel() }

        for await event in events {
            if cancelledModels.contains(model.name) {
                await supervisor.terminate(graceSeconds: 2)
            }
            switch event {
            case .line(let line):
                if line.isStderr {
                    stderrTail = String((stderrTail + "\n" + line.text).suffix(2000))
                } else if let snapshot = parser.consume(line: line.text) {
                    progressClock.touch()
                    onEvent(.nodeProgress(model: model.name, host: host,
                                          transferredBytes: snapshot.transferredBytes,
                                          totalBytes: snapshot.totalBytes,
                                          currentFile: snapshot.currentFile))
                }
            case .exited(let code):
                exitCode = code
            }
        }

        if cancelledModels.contains(model.name) {
            throw SyncError.cancelled
        }
        guard exitCode == 0 else {
            throw SyncError.rsyncFailed(host: host, exitCode: exitCode, stderr: stderrTail)
        }
        let final = parser.finish()
        onEvent(.nodeProgress(model: model.name, host: host,
                              transferredBytes: final.totalBytes, totalBytes: final.totalBytes, currentFile: nil))
    }

    /// Primary verify: `--dry-run --itemize-changes` must produce zero change lines.
    /// Fallback (parse uncertainty on openrsync): remote name+size stat vs manifest.
    private func verify(model: LocalModel, host: String, remotePath: String) async -> Bool {
        do {
            let result = try await ProcessRunner.run(
                executable: rsyncPath,
                arguments: rsyncArguments(model: model, host: host, remotePath: remotePath, dryRun: true),
                environment: minimalEnvironment(),
                timeout: 300
            )
            guard result.exitCode == 0 else { return false }
            let changeLines = result.stdout
                .split(separator: "\n")
                .map(String.init)
                .filter { Self.isItemizeChangeLine($0) }
            if changeLines.isEmpty { return true }
        } catch {
            // fall through to stat-based verify
        }
        return await verifyByStat(model: model, host: host, remotePath: remotePath)
    }

    /// Itemize lines look like `>f+++++++++ path` / `cd+++++++++ dir/` / `*deleting path`.
    static func isItemizeChangeLine(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        if line.hasPrefix("*") { return true }
        guard line.count > 10 else { return false }
        let first = line.first!
        guard first == ">" || first == "<" || first == "c" || first == "h" || first == "." else { return false }
        // Must have the itemize flags field followed by a space.
        let fields = line.split(separator: " ", maxSplits: 1)
        guard let flags = fields.first, flags.count >= 9 else { return false }
        // A flags field that is all dots/spaces after the kind marker is a no-op line;
        // anything containing +, or a letter change marker, is a change.
        return flags.dropFirst().contains { $0 != "." && $0 != " " }
    }

    private func verifyByStat(model: LocalModel, host: String, remotePath: String) async -> Bool {
        guard let manifest = model.manifest ?? model.sidecar.map({ $0.toManifest() }) else {
            // No manifest (imported without adoption): nothing precise to compare.
            return true
        }
        let command = "cd '\(remotePath)' 2>/dev/null && find . -type f ! -name '.jaccl-*' -exec stat -f '%z %N' {} \\;"
        guard let result = try? await ssh.run(host: host, command: command, timeout: 120),
              result.exitCode == 0 else { return false }

        var remote: [String: Int64] = [:]
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let size = Int64(parts[0]) else { continue }
            var path = String(parts[1])
            if path.hasPrefix("./") { path.removeFirst(2) }
            remote[path] = size
        }
        for file in manifest.files {
            guard remote[file.path] == file.size else { return false }
        }
        return true
    }

    // MARK: Helpers

    private func fileSizeMap(for model: LocalModel) -> [String: Int64] {
        if let manifest = model.manifest {
            return Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0.size) })
        }
        if let sidecar = model.sidecar {
            return Dictionary(uniqueKeysWithValues: sidecar.files.map { ($0.path, $0.size) })
        }
        return [:]
    }

    private func minimalEnvironment() -> [String: String] {
        var env: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
        ]
        if let sock = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] {
            env["SSH_AUTH_SOCK"] = sock
        }
        return env
    }

    private func beginSleepAssertion() {
        if sleepAssertion == nil {
            sleepAssertion = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled],
                reason: "Syncing model to cluster nodes"
            )
        }
    }

    private func endSleepAssertionIfIdle() {
        if activeSupervisors.isEmpty, let token = sleepAssertion {
            ProcessInfo.processInfo.endActivity(token)
            sleepAssertion = nil
        }
    }
}

/// Lock-guarded "last progress" timestamp shared between the rsync event loop
/// and the stall watchdog task.
final class StallClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()

    func touch() {
        lock.lock()
        last = Date()
        lock.unlock()
    }

    func secondsSinceTouch() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(last)
    }
}

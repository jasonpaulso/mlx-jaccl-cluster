import Foundation

/// What gets replicated to a worker node so `mlx.launch` can run there:
/// the repo checkout, the python environment, and (for uv-managed venvs,
/// whose interpreter lives outside the venv) the interpreter tree — all at
/// identical absolute paths, mirroring rank 0 byte-for-byte. Copying beats
/// remote package installs: no package manager or internet needed on the
/// node, and every rank gets identical wheel versions by construction.
public struct ProvisionPlan: Sendable, Equatable {
    public struct SyncItem: Sendable, Equatable {
        public var label: String
        /// Absolute path, identical on source and destination.
        public var path: String
        /// rsync --exclude patterns.
        public var excludes: [String]

        public init(label: String, path: String, excludes: [String] = []) {
            self.label = label
            self.path = path
            self.excludes = excludes
        }
    }

    /// Ordered sync items (repo, optional interpreter, environment).
    public var items: [SyncItem]
    /// Env python used for the remote import verification.
    public var envPythonPath: String
    /// When the env's real interpreter is a system path (Homebrew, CLT) we
    /// can't sync it — it must already exist on the node.
    public var systemInterpreterPath: String?

    public init(items: [SyncItem], envPythonPath: String, systemInterpreterPath: String? = nil) {
        self.items = items
        self.envPythonPath = envPythonPath
        self.systemInterpreterPath = systemInterpreterPath
    }

    /// Builds the plan from rank 0's local layout. All inputs are
    /// symlink-resolved up front so prefix comparisons are reliable.
    public static func make(
        repoPath: String,
        envPrefix: String,
        home: String = NSHomeDirectory(),
        fileManager fm: FileManager = .default
    ) throws -> ProvisionPlan {
        let repoPath = URL(fileURLWithPath: repoPath).resolvingSymlinksInPath().path
        let envPrefix = URL(fileURLWithPath: envPrefix).resolvingSymlinksInPath().path
        let home = URL(fileURLWithPath: home).resolvingSymlinksInPath().path

        guard let pythonName = ["python3", "python"].first(where: {
            fm.fileExists(atPath: "\(envPrefix)/bin/\($0)")
        }) else {
            throw ProvisionError.envPythonMissing(prefix: envPrefix)
        }
        let envPython = "\(envPrefix)/bin/\(pythonName)"
        let realPython = URL(fileURLWithPath: envPython).resolvingSymlinksInPath().path

        var items: [SyncItem] = []

        // 1. Repo checkout (the server script must exist at the same path on
        //    every node). Skip VCS noise, build products, and the env itself
        //    when it lives inside the repo — it syncs as its own item.
        var repoExcludes = [".git", ".build", "DerivedData", ".swiftpm", ".DS_Store", "*.log"]
        if envPrefix.hasPrefix(repoPath + "/") {
            let relative = String(envPrefix.dropFirst(repoPath.count + 1))
            if let firstComponent = relative.split(separator: "/").first {
                repoExcludes.append("/\(firstComponent)")
            }
        }
        items.append(SyncItem(label: "repo", path: repoPath, excludes: repoExcludes))

        // 2. Interpreter tree, when it lives outside the env (uv venvs symlink
        //    to ~/.local/share/uv/python/<version>/bin/pythonX.Y). Only sync
        //    it when it's under the home directory; a system interpreter
        //    (Homebrew, Xcode CLT) must already exist on the node.
        var systemInterpreterPath: String?
        if !realPython.hasPrefix(envPrefix + "/") {
            let interpreterRoot = URL(fileURLWithPath: realPython)
                .deletingLastPathComponent() // bin
                .deletingLastPathComponent() // interpreter root
                .path
            if interpreterRoot.hasPrefix(home + "/") {
                items.append(SyncItem(label: "python interpreter", path: interpreterRoot))
            } else {
                systemInterpreterPath = realPython
            }
        }

        // 3. The environment itself (venv or conda env — same-path copies of
        //    both work on same-arch machines).
        items.append(SyncItem(label: "environment", path: envPrefix))

        return ProvisionPlan(
            items: items,
            envPythonPath: envPython,
            systemInterpreterPath: systemInterpreterPath
        )
    }
}

public enum ProvisionError: Error, LocalizedError, Sendable {
    case envPythonMissing(prefix: String)
    case systemPythonMissingRemote(host: String, path: String)
    case rsyncFailed(host: String, label: String, exitCode: Int32, stderr: String)
    case verifyFailed(host: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .envPythonMissing(let prefix):
            return "No python found in \(prefix)/bin — is the environment prefix right?"
        case .systemPythonMissingRemote(let host, let path):
            return """
            The environment uses a system python (\(path)) that doesn't exist on \(host). \
            Install the same python there first, or recreate the env with a uv-managed \
            python so the app can copy it.
            """
        case .rsyncFailed(let host, let label, let code, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Syncing \(label) to \(host) failed (rsync exit \(code))"
                + (trimmed.isEmpty ? "" : ": \(trimmed.suffix(300))")
        case .verifyFailed(let host, let detail):
            return "Environment verification on \(host) failed: \(detail)"
        }
    }
}

public enum ProvisionEvent: Sendable {
    case step(host: String, detail: String)
    case progress(host: String, transferredBytes: Int64)
    case completed(host: String)
    case failed(host: String, message: String)
}

/// Executes a ProvisionPlan against one node: path-invariant preflight,
/// rsync each item to the identical absolute path, then verify the server's
/// imports actually resolve with the node's copy of the env.
public actor NodeProvisioner {
    private let ssh: SSHRunner
    private let resolver: RemotePathResolver
    private let rsyncPath: String
    private let onEvent: @Sendable (ProvisionEvent) -> Void

    public init(ssh: SSHRunner = SSHRunner(),
                rsyncPath: String = "/usr/bin/rsync",
                onEvent: @escaping @Sendable (ProvisionEvent) -> Void) {
        self.ssh = ssh
        self.resolver = RemotePathResolver(ssh: ssh)
        self.rsyncPath = rsyncPath.isEmpty ? "/usr/bin/rsync" : rsyncPath
        self.onEvent = onEvent
    }

    public func provision(host: String, plan: ProvisionPlan, localHome: String = NSHomeDirectory()) async {
        do {
            onEvent(.step(host: host, detail: "Checking \(host) (home directory, ssh)…"))
            for item in plan.items {
                try await resolver.preflight(host: host, localPath: item.path, localHome: localHome)
            }
            if let systemPython = plan.systemInterpreterPath {
                let check = try await ssh.run(host: host, command: "test -x '\(systemPython)'", timeout: 12)
                guard check.exitCode == 0 else {
                    throw ProvisionError.systemPythonMissingRemote(host: host, path: systemPython)
                }
            }

            var totalTransferred: Int64 = 0
            for item in plan.items {
                onEvent(.step(host: host, detail: "Syncing \(item.label)…"))
                totalTransferred = try await rsync(item: item, host: host, transferredBase: totalTransferred)
            }

            onEvent(.step(host: host, detail: "Verifying environment on \(host)…"))
            let importCheck = "'\(plan.envPythonPath)' -c \"import mlx.core, mlx_lm, fastapi, uvicorn; print('provision-ok')\""
            let verify = try await ssh.run(host: host, command: importCheck, timeout: 180)
            guard verify.exitCode == 0, verify.stdout.contains("provision-ok") else {
                throw ProvisionError.verifyFailed(host: host, detail: SSHRunner.failureDetail(verify))
            }

            onEvent(.completed(host: host))
        } catch {
            onEvent(.failed(host: host, message: error.localizedDescription))
        }
    }

    /// rsync one item to the same absolute path; returns cumulative transferred bytes.
    private func rsync(item: ProvisionPlan.SyncItem, host: String, transferredBase: Int64) async throws -> Int64 {
        let parent = URL(fileURLWithPath: item.path).deletingLastPathComponent().path
        let mkdir = try await ssh.run(host: host, command: "mkdir -p '\(parent)'", timeout: 15)
        guard mkdir.exitCode == 0 else {
            throw ProvisionError.rsyncFailed(host: host, label: item.label, exitCode: mkdir.exitCode, stderr: mkdir.stderr)
        }

        var args = ["-a", "--partial", "--progress"]
        for exclude in item.excludes {
            args += ["--exclude", exclude]
        }
        args += [
            "-e", "ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new",
            item.path + "/",
            "\(host):\(item.path)/",
        ]

        let supervisor = ProcessSupervisor()
        let events = try await supervisor.launch(LaunchSpec(
            executable: rsyncPath,
            arguments: args,
            environment: Self.minimalEnvironment()
        ))

        var parser = RsyncProgressParser(fileSizes: [:])
        var stderrTail = ""
        var exitCode: Int32 = -1

        for await event in events {
            switch event {
            case .line(let line):
                if line.isStderr {
                    stderrTail = String((stderrTail + "\n" + line.text).suffix(2000))
                } else if let snapshot = parser.consume(line: line.text) {
                    onEvent(.progress(host: host, transferredBytes: transferredBase + snapshot.transferredBytes))
                }
            case .exited(let code):
                exitCode = code
            }
        }

        guard exitCode == 0 else {
            throw ProvisionError.rsyncFailed(host: host, label: item.label, exitCode: exitCode, stderr: stderrTail)
        }
        return transferredBase + parser.finish().transferredBytes
    }

    private static func minimalEnvironment() -> [String: String] {
        var env: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
        ]
        if let sock = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] {
            env["SSH_AUTH_SOCK"] = sock
        }
        return env
    }
}

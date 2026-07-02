import Foundation
import Observation

/// Single-writer server lifecycle state machine. All async inputs (process
/// events, log milestones, health events) and user intents funnel through
/// `handle(_:)` on the MainActor; transitions are computed by the pure
/// `ServerStateMachine.reduce` and side effects are performed here.
@MainActor
@Observable
public final class ServerController {
    public private(set) var state: ServerState = .stopped
    /// Milestone-derived progress note (accelerator only; /health 200 is authoritative).
    public private(set) var progressNote: String?
    /// Latest queue depth from /health, for the gauge.
    public private(set) var lastHealth: HealthStatus?
    /// Human-readable launch error (config problems, spawn failures).
    public private(set) var lastError: String?
    /// Per-node pkill outcomes from the most recent stop/cleanup, for surfacing.
    public private(set) var lastCleanupResults: [String: String] = [:]
    /// Model directory used for the current/last launch.
    public private(set) var currentModelDir: String?

    public let logBuffer: LogBuffer

    @ObservationIgnored private let supervisor = ProcessSupervisor()
    @ObservationIgnored private let poller = HealthPoller()
    @ObservationIgnored private let ssh = SSHRunner()
    @ObservationIgnored private weak var settings: SettingsStore?
    @ObservationIgnored private weak var hostfileStore: HostfileStore?

    @ObservationIgnored private var processTask: Task<Void, Never>?
    @ObservationIgnored private var healthTask: Task<Void, Never>?
    @ObservationIgnored private var expectedExit = false

    public init(settings: SettingsStore, hostfileStore: HostfileStore, logBuffer: LogBuffer = LogBuffer()) {
        self.settings = settings
        self.hostfileStore = hostfileStore
        self.logBuffer = logBuffer
    }

    // MARK: State machine

    public func handle(_ event: ServerEvent) {
        if case .healthSuccess(let h) = event {
            lastHealth = h
        }
        guard let next = ServerStateMachine.reduce(state: state, event: event, logTail: logBuffer.tail(50)) else {
            return
        }
        state = next
        switch next {
        case .stopped, .crashed:
            progressNote = nil
            healthTask?.cancel()
            Task { await poller.stop() }
        case .running:
            progressNote = nil
        default:
            break
        }
    }

    // MARK: Start

    public struct StartRequest: Sendable {
        public var modelDir: String
        public var modelID: String?

        public init(modelDir: String, modelID: String? = nil) {
            self.modelDir = modelDir
            self.modelID = modelID
        }
    }

    public func start(_ request: StartRequest) async {
        guard !state.isActive else { return }
        lastError = nil

        guard let settings else { return }
        let config = settings.config

        // --- Preflight: resolve everything the launch needs ---
        guard let hostfileURL = config.hostfileURL,
              FileManager.default.fileExists(atPath: hostfileURL.path) else {
            lastError = "Hostfile not found. Pick one in the Cluster tab (Settings → repo path must be set)."
            return
        }
        guard let serverScript = config.serverScriptURL,
              FileManager.default.fileExists(atPath: serverScript.path) else {
            lastError = "server/openai_cluster_server.py not found under the configured repo path."
            return
        }

        let document: HostfileDocument
        do {
            document = try HostfileDocument.load(from: hostfileURL)
        } catch {
            lastError = "Failed to parse hostfile: \(error.localizedDescription)"
            return
        }
        let issues = document.validate().filter { $0.severity == .error }
        if let first = issues.first {
            lastError = "Hostfile invalid: \(first.message)"
            return
        }
        guard let ctrlHost = document.hosts.first?.ips.first, !ctrlHost.isEmpty else {
            lastError = "Rank 0 must carry the coordinator LAN IP in ips[0]."
            return
        }

        // Stale-coordinator preflight: JACCL binds ips[0] on rank 0 and dies
        // with "Couldn't bind socket (error: 49)" when the address isn't
        // assigned there (classic after a network change). Catch it here.
        let rank0Host = document.hosts[0].ssh
        if LocalNetwork.hostRefersToThisMachine(rank0Host) {
            let interfaces = LocalNetwork.ipv4Interfaces()
            if !interfaces.isEmpty, !interfaces.contains(where: { $0.address == ctrlHost }) {
                let available = interfaces.map { "\($0.address) (\($0.name))" }.joined(separator: ", ")
                lastError = """
                Coordinator IP \(ctrlHost) isn't assigned to this Mac (rank 0). \
                Current addresses: \(available). Update ips[0] in the Cluster tab — \
                JACCL binds this address and fails otherwise.
                """
                return
            }
        } else if let probe = try? await ssh.run(
            host: rank0Host,
            command: #"ifconfig -a 2>/dev/null | awk '/inet /{print $2}'"#,
            timeout: 12
        ), probe.exitCode == 0 {
            let remoteIPs = probe.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            if !remoteIPs.isEmpty, !remoteIPs.contains(ctrlHost) {
                let available = remoteIPs.filter { $0 != "127.0.0.1" }.joined(separator: ", ")
                lastError = """
                Coordinator IP \(ctrlHost) isn't assigned to rank 0 (\(rank0Host)). \
                Its addresses: \(available). Update ips[0] in the Cluster tab.
                """
                return
            }
        }
        // (If the ssh probe fails we proceed — the preflight must not add a
        // new failure mode of its own.)

        // RDMA matrix preflight. Two failure classes JACCL reports cryptically:
        //  - a device name the node doesn't have → "Couldn't allocate protection domain"
        //  - a device whose port has no IPv6 link-local (Thunderbolt Bridge
        //    member → empty GID table) → "Changing queue pair to RTR failed with errno 96"
        for entry in document.hosts {
            let claimed = entry.rdma.compactMap { $0 }.filter { !$0.isEmpty }
            guard !claimed.isEmpty else { continue }
            guard let probe = try? await ssh.run(
                host: entry.ssh,
                command: #"for d in $(ibv_devices 2>/dev/null | grep -oE 'rdma_en[0-9]+'); do i="${d#rdma_}"; ll=$(ifconfig "$i" 2>/dev/null | awk '/inet6 fe80/{print "ll"; exit}'); echo "$d unknown ${ll:-noll}"; done"#,
                timeout: 12
            ), probe.exitCode == 0 else { continue }
            let parsed = VerifyService.parseDeviceStatus(probe.stdout)
            guard !parsed.devices.isEmpty else { continue }

            let missing = claimed.filter { !parsed.devices.contains($0) }
            if !missing.isEmpty {
                lastError = """
                \(entry.ssh) has no RDMA device named \(missing.joined(separator: ", ")). \
                It has: \(parsed.devices.sorted().joined(separator: ", ")). Fix that row in the \
                Cluster tab's matrix (Verify suggests devices with an active link) — \
                JACCL fails with 'Couldn't allocate protection domain' otherwise.
                """
                return
            }
            let bridged = claimed.filter { parsed.missingIPv6.contains($0) }
            if !bridged.isEmpty {
                lastError = """
                \(bridged.joined(separator: ", ")) on \(entry.ssh) has no IPv6 link-local, \
                so its RDMA GID table is empty and JACCL fails with 'Changing queue pair \
                to RTR failed with errno 96'. Usual cause: the port is a Thunderbolt Bridge \
                member. Fix on that Mac: System Settings → Network → Thunderbolt Bridge → ⋯ \
                → Manage Virtual Interfaces → remove the port (or delete the bridge), then \
                re-run Verify.
                """
                return
            }
        }

        let check = await settings.resolveAndTestCondaPrefix()
        guard check.ok else {
            lastError = check.detail
            return
        }

        let modelDir = NSString(string: request.modelDir).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: modelDir) else {
            lastError = "Model directory does not exist: \(modelDir)"
            return
        }

        // --- Begin ---
        handle(.startRequested)
        expectedExit = false
        currentModelDir = modelDir
        logBuffer.clear()
        progressNote = "Cleaning up old server processes on all nodes…"

        // Pre-pkill every node (mirrors the script): stale ranks deadlock the next start.
        let hosts = document.hosts.map(\.ssh)
        await pkillAll(hosts: hosts)

        let spec = LaunchSpec.clusterServer(
            condaPrefix: check.prefix,
            hostfilePath: hostfileURL.path,
            serverScriptPath: serverScript.path,
            modelDir: modelDir,
            modelID: request.modelID ?? URL(fileURLWithPath: modelDir).lastPathComponent,
            ctrlHost: ctrlHost,
            config: config.launch,
            repoPath: config.repoURL?.path
        )
        logBuffer.append(text: "$ \(spec.executable) \(spec.arguments.joined(separator: " "))", isStderr: false)

        let events: AsyncStream<ProcessSupervisor.Event>
        do {
            events = try await supervisor.launch(spec)
        } catch {
            lastError = "Failed to launch mlx.launch: \(error.localizedDescription)"
            handle(.processExited(code: -1, expected: false))
            return
        }

        handle(.processLaunched)
        progressNote = "Loading model on all ranks (no timeout — large models take a while)…"

        processTask?.cancel()
        processTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                switch event {
                case .line(let line):
                    self.logBuffer.append(line)
                    if let milestone = ServerLogMilestone.match(line: line.text) {
                        self.progressNote = milestone.progressNote
                        self.handle(.milestone(milestone))
                    }
                case .exited(let code):
                    self.logBuffer.flush()
                    self.handle(.processExited(code: code, expected: self.expectedExit))
                    if !self.expectedExit {
                        // Crash: make sure remote ranks don't linger.
                        let hosts = self.hostfileStore?.hosts ?? []
                        Task { await self.pkillAll(hosts: hosts) }
                    }
                }
            }
        }

        startHealthPolling(ctrlHost: ctrlHost, port: config.launch.httpPort)
    }

    private func startHealthPolling(ctrlHost: String, port: Int) {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.poller.start(host: ctrlHost, port: port)
            for await event in stream {
                switch event {
                case .healthy(let status):
                    self.handle(.healthSuccess(status))
                case .failuresExceededThreshold:
                    // Only meaningful while running: loading ignores failures,
                    // and a dead process is reported as .crashed by the exit path.
                    let processAlive = await self.supervisor.isRunning
                    if case .running = self.state, processAlive {
                        self.handle(.healthFailuresExceededThreshold)
                    }
                }
            }
        }
    }

    // MARK: Stop

    public func stop() async {
        guard state.isActive, state != .stopping else { return }
        expectedExit = true
        handle(.stopRequested)
        progressNote = "Stopping local launcher…"

        await supervisor.terminate(graceSeconds: 5)

        progressNote = "Stopping server on all nodes…"
        let hosts = hostfileStore?.hosts ?? []
        await pkillAll(hosts: hosts)

        await poller.stop()
        healthTask?.cancel()
        await supervisor.clear()
        handle(.stopCompleted)
        progressNote = nil
    }

    /// "Force cleanup" for stale/orphaned ranks (no local process required).
    public func forceCleanup() async {
        let hosts = hostfileStore?.hosts ?? []
        progressNote = "Force cleanup: pkill on all nodes…"
        await pkillAll(hosts: hosts)
        if !state.isActive {
            handle(.resetRequested)
        }
        progressNote = nil
    }

    public func dismissCrash() {
        if case .crashed = state {
            handle(.resetRequested)
        }
    }

    private func pkillAll(hosts: [String]) async {
        guard !hosts.isEmpty else { return }
        var results: [String: String] = [:]
        await withTaskGroup(of: (String, String).self) { group in
            for host in hosts {
                let ssh = self.ssh
                group.addTask {
                    switch await ssh.pkillServer(host: host) {
                    case .success: (host, "ok")
                    case .failure(let error): (host, error.localizedDescription)
                    }
                }
            }
            for await (host, outcome) in group {
                results[host] = outcome
            }
        }
        lastCleanupResults = results
        for (host, outcome) in results where outcome != "ok" {
            logBuffer.append(text: "[cleanup] \(host): \(outcome)", isStderr: true)
        }
    }
}

import Foundation

/// Decoded `GET /health` from `server/openai_cluster_server.py`.
public struct HealthStatus: Codable, Sendable, Equatable {
    public var ok: Bool
    public var worldSize: Int
    public var rank: Int
    public var model: String
    public var queueMax: Int
    public var queueSize: Int

    private enum CodingKeys: String, CodingKey {
        case ok
        case worldSize = "world_size"
        case rank
        case model
        case queueMax = "queue_max"
        case queueSize = "queue_size"
    }

    public init(ok: Bool, worldSize: Int, rank: Int, model: String, queueMax: Int, queueSize: Int) {
        self.ok = ok
        self.worldSize = worldSize
        self.rank = rank
        self.model = model
        self.queueMax = queueMax
        self.queueSize = queueSize
    }
}

/// Decoded `GET /queue`.
public struct QueueStatus: Codable, Sendable, Equatable {
    public var size: Int
    public var max: Int

    public init(size: Int, max: Int) {
        self.size = size
        self.max = max
    }
}

/// Lifecycle of the cluster server as observed from the app.
public enum ServerState: Sendable, Equatable {
    case stopped
    /// Pre-pkill + spawning mlx.launch.
    case launching
    /// Process alive, no successful /health yet. No timeout: huge models load for minutes.
    case loadingModel
    /// First /health 200 is the authoritative signal.
    case running(HealthStatus)
    /// Process alive but /health failing repeatedly.
    case degraded
    case stopping
    case crashed(exitCode: Int32, logTail: [String])

    public var isActive: Bool {
        switch self {
        case .launching, .loadingModel, .running, .degraded, .stopping: true
        case .stopped, .crashed: false
        }
    }

    public var label: String {
        switch self {
        case .stopped: "Stopped"
        case .launching: "Launching…"
        case .loadingModel: "Loading model…"
        case .running: "Running"
        case .degraded: "Degraded"
        case .stopping: "Stopping…"
        case .crashed(let code, _): "Crashed (exit \(code))"
        }
    }
}

/// Log milestones printed by this repo's server. Best-effort accelerators for
/// progress display only — the authoritative "running" signal is /health 200.
public enum ServerLogMilestone: String, Sendable, CaseIterable {
    case controlPlaneListening = "[rank0] control-plane listening on"
    case workersConnected = "[rank0] all workers connected"
    case httpStarted = "Application startup complete"
    case workersTimedOut = "Workers did not connect to control-plane in time"

    public static func match(line: String) -> ServerLogMilestone? {
        allCases.first { line.contains($0.rawValue) }
    }

    public var progressNote: String {
        switch self {
        case .controlPlaneListening: "Model loaded; control plane up, waiting for workers…"
        case .workersConnected: "All workers connected; starting HTTP…"
        case .httpStarted: "HTTP server started; waiting for first health check…"
        case .workersTimedOut: "Workers did not connect within 60s"
        }
    }
}

/// All inputs to the server state machine funnel through these events
/// (single-writer on the MainActor; unit-testable with scripted sequences).
public enum ServerEvent: Sendable, Equatable {
    case startRequested
    case processLaunched
    case processExited(code: Int32, expected: Bool)
    case milestone(ServerLogMilestone)
    case healthSuccess(HealthStatus)
    /// Emitted once when consecutive health failures cross the threshold while the process is alive.
    case healthFailuresExceededThreshold
    case stopRequested
    case stopCompleted
    case resetRequested
}

/// Pure transition function for `ServerState`; `ServerController` applies it and
/// performs side effects. Returns nil when the event does not change state.
public enum ServerStateMachine {
    public static func reduce(state: ServerState, event: ServerEvent, logTail: [String] = []) -> ServerState? {
        switch (state, event) {
        case (.stopped, .startRequested), (.crashed, .startRequested):
            return .launching
        case (.launching, .processLaunched):
            return .loadingModel
        case (.loadingModel, .healthSuccess(let h)),
             (.degraded, .healthSuccess(let h)):
            return .running(h)
        case (.running, .healthSuccess(let h)):
            return .running(h) // refresh payload (queue depth etc.)
        case (.running, .healthFailuresExceededThreshold):
            return .degraded
        case (_, .processExited(let code, let expected)):
            if expected {
                // Part of a user-initiated stop; remain in stopping until pkill completes.
                return state.isActive && state != .stopping ? .stopping : nil
            }
            return .crashed(exitCode: code, logTail: logTail)
        case (_, .stopRequested):
            guard state.isActive, state != .stopping else { return nil }
            return .stopping
        case (.stopping, .stopCompleted):
            return .stopped
        case (_, .resetRequested):
            return .stopped
        default:
            return nil
        }
    }
}

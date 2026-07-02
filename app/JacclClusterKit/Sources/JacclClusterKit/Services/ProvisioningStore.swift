import Foundation
import Observation

/// UI state for per-node environment provisioning ("Set up node" in the
/// Cluster tab).
@MainActor
@Observable
public final class ProvisioningStore {
    public enum NodeState: Equatable, Sendable {
        case idle
        case running(detail: String, transferredBytes: Int64)
        case succeeded
        case failed(String)
    }

    public private(set) var states: [String: NodeState] = [:]

    @ObservationIgnored private weak var settings: SettingsStore?

    public init(settings: SettingsStore) {
        self.settings = settings
    }

    public func state(for host: String) -> NodeState {
        states[host] ?? .idle
    }

    public func isRunning(host: String) -> Bool {
        if case .running = state(for: host) { return true }
        return false
    }

    public func provision(host: String) {
        guard let settings, !isRunning(host: host) else { return }
        states[host] = .running(detail: "Resolving local environment…", transferredBytes: 0)

        Task { [weak self] in
            guard let self, let settings = self.settings else { return }
            let check = await settings.resolveAndTestCondaPrefix()
            guard check.ok else {
                self.states[host] = .failed(check.detail)
                return
            }
            guard let repoPath = settings.config.repoURL?.path else {
                self.states[host] = .failed("Set the repo path in Settings first.")
                return
            }
            do {
                let plan = try ProvisionPlan.make(repoPath: repoPath, envPrefix: check.prefix)
                let provisioner = NodeProvisioner(rsyncPath: settings.config.rsyncPath) { [weak self] event in
                    Task { @MainActor [weak self] in
                        self?.handle(event)
                    }
                }
                await provisioner.provision(host: host, plan: plan)
            } catch {
                self.states[host] = .failed(error.localizedDescription)
            }
        }
    }

    private func handle(_ event: ProvisionEvent) {
        switch event {
        case .step(let host, let detail):
            let transferred: Int64
            if case .running(_, let bytes) = state(for: host) {
                transferred = bytes
            } else {
                transferred = 0
            }
            states[host] = .running(detail: detail, transferredBytes: transferred)
        case .progress(let host, let transferredBytes):
            if case .running(let detail, _) = state(for: host) {
                states[host] = .running(detail: detail, transferredBytes: transferredBytes)
            }
        case .completed(let host):
            states[host] = .succeeded
        case .failed(let host, let message):
            states[host] = .failed(message)
        }
    }
}

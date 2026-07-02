import Foundation

/// Polls rank0's `/health` (and `/queue`) every 2 seconds with a 2 second
/// per-request timeout. Failures are only *reported* once they cross the
/// consecutive-failure threshold; the consumer decides what they mean
/// (ignored while loading, degraded while running).
public actor HealthPoller {
    public enum Event: Sendable {
        case healthy(HealthStatus)
        case failuresExceededThreshold(consecutive: Int)
    }

    public let interval: TimeInterval
    public let requestTimeout: TimeInterval
    public let failureThreshold: Int

    private var pollTask: Task<Void, Never>?
    private let session: URLSession

    public init(interval: TimeInterval = 2, requestTimeout: TimeInterval = 2, failureThreshold: Int = 3) {
        self.interval = interval
        self.requestTimeout = requestTimeout
        self.failureThreshold = failureThreshold
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = requestTimeout * 2
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    /// Starts polling `http://host:port/health`. Cancels any previous poll.
    public func start(host: String, port: Int) -> AsyncStream<Event> {
        pollTask?.cancel()
        let session = self.session
        let interval = self.interval
        let threshold = self.failureThreshold

        guard let url = URL(string: "http://\(host):\(port)/health") else {
            return AsyncStream { $0.finish() }
        }

        let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
        let task = Task {
            var consecutiveFailures = 0
            var thresholdReported = false
            while !Task.isCancelled {
                do {
                    let (data, response) = try await session.data(from: url)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        throw URLError(.badServerResponse)
                    }
                    let status = try JSONDecoder().decode(HealthStatus.self, from: data)
                    consecutiveFailures = 0
                    thresholdReported = false
                    continuation.yield(.healthy(status))
                } catch {
                    if Task.isCancelled { break }
                    consecutiveFailures += 1
                    if consecutiveFailures >= threshold && !thresholdReported {
                        thresholdReported = true
                        continuation.yield(.failuresExceededThreshold(consecutive: consecutiveFailures))
                    }
                }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in
            task.cancel()
        }
        pollTask = task
        return stream
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }
}

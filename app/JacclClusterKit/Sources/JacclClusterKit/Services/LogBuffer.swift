import Foundation
import Observation

/// One line of child-process output.
public struct LogLine: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let text: String
    public let isStderr: Bool
    public let date: Date

    public init(text: String, isStderr: Bool, date: Date = Date()) {
        self.id = UUID()
        self.text = text
        self.isStderr = isStderr
        self.date = date
    }
}

/// Ring buffer for the log console. Appends are coalesced on a ~100ms tick so
/// `mlx.launch --verbose` bursts don't invalidate the view once per line.
@MainActor
@Observable
public final class LogBuffer {
    public private(set) var lines: [LogLine] = []
    public let capacity: Int

    @ObservationIgnored private var pending: [LogLine] = []
    @ObservationIgnored private var flushScheduled = false

    public init(capacity: Int = 5000) {
        self.capacity = capacity
    }

    public func append(_ line: LogLine) {
        pending.append(line)
        scheduleFlush()
    }

    public func append(text: String, isStderr: Bool) {
        append(LogLine(text: text, isStderr: isStderr))
    }

    public func clear() {
        pending.removeAll()
        lines.removeAll()
    }

    /// Last N lines, for crash sheets.
    public func tail(_ n: Int) -> [String] {
        let all = lines.map(\.text) + pending.map(\.text)
        return Array(all.suffix(n))
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            self?.flush()
        }
    }

    public func flush() {
        flushScheduled = false
        guard !pending.isEmpty else { return }
        lines.append(contentsOf: pending)
        pending.removeAll()
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
    }
}

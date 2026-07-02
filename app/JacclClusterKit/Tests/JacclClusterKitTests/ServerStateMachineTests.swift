import XCTest
@testable import JacclClusterKit

/// Scripted event-sequence tests over the pure reducer.
final class ServerStateMachineTests: XCTestCase {
    private let health = HealthStatus(ok: true, worldSize: 4, rank: 0, model: "Qwen3-4B", queueMax: 8, queueSize: 0)

    private func run(_ events: [ServerEvent], from initial: ServerState = .stopped) -> ServerState {
        var state = initial
        for event in events {
            if let next = ServerStateMachine.reduce(state: state, event: event) {
                state = next
            }
        }
        return state
    }

    func testHappyPath() {
        let state = run([
            .startRequested,
            .processLaunched,
            .milestone(.controlPlaneListening),
            .milestone(.httpStarted),
            .healthSuccess(health),
        ])
        XCTAssertEqual(state, .running(health))
    }

    func testMilestonesAloneNeverReachRunning() {
        // Milestones are accelerators only; /health 200 is authoritative.
        let state = run([
            .startRequested,
            .processLaunched,
            .milestone(.controlPlaneListening),
            .milestone(.workersConnected),
            .milestone(.httpStarted),
        ])
        XCTAssertEqual(state, .loadingModel)
    }

    func testHealthFailuresIgnoredWhileLoading() {
        let state = run([
            .startRequested,
            .processLaunched,
            .healthFailuresExceededThreshold, // model still loading — not degraded
        ])
        XCTAssertEqual(state, .loadingModel)
    }

    func testDegradedAndRecovery() {
        let degraded = run([
            .startRequested, .processLaunched, .healthSuccess(health),
            .healthFailuresExceededThreshold,
        ])
        XCTAssertEqual(degraded, .degraded)

        let recovered = run([.healthSuccess(health)], from: degraded)
        XCTAssertEqual(recovered, .running(health))
    }

    func testRunningRefreshesHealthPayload() {
        var updated = health
        updated.queueSize = 5
        let state = run([
            .startRequested, .processLaunched, .healthSuccess(health),
            .healthSuccess(updated),
        ])
        XCTAssertEqual(state, .running(updated))
    }

    func testUnexpectedExitIsCrash() {
        let state = run([
            .startRequested, .processLaunched, .healthSuccess(health),
            .processExited(code: 1, expected: false),
        ])
        guard case .crashed(let code, _) = state else {
            return XCTFail("expected crashed, got \(state)")
        }
        XCTAssertEqual(code, 1)
    }

    func testCrashWhileLoading() {
        let state = run([
            .startRequested, .processLaunched,
            .processExited(code: 137, expected: false),
        ])
        guard case .crashed(let code, _) = state else {
            return XCTFail("expected crashed, got \(state)")
        }
        XCTAssertEqual(code, 137)
    }

    func testCleanStopSequence() {
        let state = run([
            .startRequested, .processLaunched, .healthSuccess(health),
            .stopRequested,
            .processExited(code: 0, expected: true),
            .stopCompleted,
        ])
        XCTAssertEqual(state, .stopped)
    }

    func testStopFromLoadingModel() {
        let state = run([
            .startRequested, .processLaunched,
            .stopRequested,
            .processExited(code: 0, expected: true),
            .stopCompleted,
        ])
        XCTAssertEqual(state, .stopped)
    }

    func testRestartAfterCrash() {
        let crashed = run([
            .startRequested, .processLaunched,
            .processExited(code: 1, expected: false),
        ])
        let restarted = run([.startRequested], from: crashed)
        XCTAssertEqual(restarted, .launching)
    }

    func testStopIgnoredWhenStopped() {
        XCTAssertNil(ServerStateMachine.reduce(state: .stopped, event: .stopRequested))
        XCTAssertNil(ServerStateMachine.reduce(state: .stopped, event: .healthSuccess(health)))
    }

    func testStartIgnoredWhileActive() {
        XCTAssertNil(ServerStateMachine.reduce(state: .loadingModel, event: .startRequested))
        XCTAssertNil(ServerStateMachine.reduce(state: .running(health), event: .startRequested))
    }

    func testCrashCapturesLogTail() {
        let tail = ["line1", "line2"]
        let state = ServerStateMachine.reduce(
            state: .loadingModel,
            event: .processExited(code: 2, expected: false),
            logTail: tail
        )
        XCTAssertEqual(state, .crashed(exitCode: 2, logTail: tail))
    }

    func testMilestoneMatching() {
        XCTAssertEqual(
            ServerLogMilestone.match(line: "[rank0] control-plane listening on 0.0.0.0:18080"),
            .controlPlaneListening
        )
        XCTAssertEqual(
            ServerLogMilestone.match(line: "INFO:     Application startup complete."),
            .httpStarted
        )
        XCTAssertEqual(
            ServerLogMilestone.match(line: "RuntimeError: Workers did not connect to control-plane in time"),
            .workersTimedOut
        )
        XCTAssertNil(ServerLogMilestone.match(line: "[worker 1] connected to control-plane"))
    }
}

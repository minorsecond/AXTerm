//
//  ConnectStrategyRunner.swift
//  AXTerm
//
//  Walks a ConnectStrategyLadder rung by rung: explain, try, and either
//  stop (connected, refused, cancelled) or fall through to the next family.
//
//  Deliberately a sibling of ConnectAttemptRunner rather than a
//  generalization of it — that runner's contract ("rank within one mode,
//  stop on unavailable") is pinned by its own tests and still serves the
//  forced-mode buttons. The ladder's advance rules are different in kind:
//  see ConnectStrategyAdvancePolicy.
//

import Foundation

nonisolated final class ConnectStrategyRunner {

    enum Outcome: Equatable {
        /// A rung connected; `rung` is 1-based for operator-facing text.
        case connected(rung: Int)
        /// The station answered no — the ladder stops out of respect.
        case refused(String)
        /// Every rung was tried and none got through.
        case exhausted
        case cancelled
    }

    typealias SleepFunction = @Sendable (_ seconds: TimeInterval) async throws -> Void
    typealias ExplainHandler = (_ rung: Int, _ total: Int, _ step: ConnectStrategyStep) -> Void
    typealias ExecuteHandler = (_ step: ConnectStrategyStep) async -> ConnectAttemptStepResult
    typealias BackoffHandler = (_ seconds: TimeInterval) -> Void

    private let backoffSeconds: TimeInterval
    private let sleep: SleepFunction

    init(
        backoffSeconds: TimeInterval = ConnectStrategyPlanner.interRungBackoffSeconds,
        sleep: SleepFunction? = nil
    ) {
        self.backoffSeconds = backoffSeconds
        self.sleep = sleep ?? { seconds in
            let nanos = UInt64(max(0, seconds) * 1_000_000_000)
            try await Task.sleep(nanoseconds: nanos)
        }
    }

    @MainActor
    func run(
        ladder: ConnectStrategyLadder,
        onExplain: ExplainHandler,
        execute: ExecuteHandler,
        onBackoff: BackoffHandler? = nil
    ) async -> Outcome {
        guard !ladder.steps.isEmpty else { return .exhausted }
        let total = ladder.steps.count

        for (index, step) in ladder.steps.enumerated() {
            if Task.isCancelled { return .cancelled }
            let rung = index + 1
            onExplain(rung, total, step)

            let result = await execute(step)
            switch result {
            case .success:
                return .connected(rung: rung)
            case .cancelled:
                return .cancelled
            default:
                switch ConnectStrategyAdvancePolicy.verdict(after: result) {
                case .stopLadder(let detail):
                    return .refused(detail)
                case .fallThrough:
                    break
                }
            }

            if rung < total {
                onBackoff?(backoffSeconds)
                do {
                    try await sleep(backoffSeconds)
                } catch {
                    return .cancelled
                }
            }
        }
        return Task.isCancelled ? .cancelled : .exhausted
    }
}

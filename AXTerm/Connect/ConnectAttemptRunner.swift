import Foundation

nonisolated enum ConnectAttemptStepResult: Equatable {
    case success
    case failed
    case timeout
    case cancelled
    case unavailable(message: String)
}

nonisolated struct ConnectAttemptRunnerResult: Equatable {
    nonisolated enum Outcome: Equatable {
        case success
        case failed
        case cancelled
        case unavailable(message: String)
        case noPlan
    }

    let outcome: Outcome
    let attemptsExecuted: Int
}

nonisolated final class ConnectAttemptRunner {
    typealias SleepFunction = @Sendable (_ seconds: TimeInterval) async throws -> Void
    typealias StatusHandler = (_ attemptIndex: Int, _ totalAttempts: Int, _ step: ConnectAttemptStep) -> Void
    typealias ExecuteHandler = (_ step: ConnectAttemptStep, _ attemptIndex: Int, _ totalAttempts: Int) async -> ConnectAttemptStepResult
    typealias BackoffHandler = (_ seconds: TimeInterval, _ completedAttempt: Int, _ totalAttempts: Int) -> Void

    private let maxAttempts: Int
    private let backoffSeconds: TimeInterval
    private let sleep: SleepFunction

    init(
        maxAttempts: Int = 3,
        backoffSeconds: TimeInterval = 8,
        sleep: SleepFunction? = nil
    ) {
        self.maxAttempts = maxAttempts
        self.backoffSeconds = backoffSeconds
        self.sleep = sleep ?? { seconds in
            let nanos = UInt64(max(0, seconds) * 1_000_000_000)
            try await Task.sleep(nanoseconds: nanos)
        }
    }

    @MainActor
    func run(
        plan: ConnectAttemptPlan,
        onStatus: StatusHandler,
        execute: ExecuteHandler,
        onBackoff: BackoffHandler? = nil
    ) async -> ConnectAttemptRunnerResult {
        let steps = Array(plan.steps.prefix(maxAttempts))
        guard !steps.isEmpty else {
            return ConnectAttemptRunnerResult(outcome: .noPlan, attemptsExecuted: 0)
        }

        let totalAttempts = steps.count
        var executed = 0

        for (index, step) in steps.enumerated() {
            if Task.isCancelled {
                return ConnectAttemptRunnerResult(outcome: .cancelled, attemptsExecuted: executed)
            }

            let attemptIndex = index + 1
            executed = attemptIndex
            onStatus(attemptIndex, totalAttempts, step)
            let result = await execute(step, attemptIndex, totalAttempts)

            switch result {
            case .success:
                return ConnectAttemptRunnerResult(outcome: .success, attemptsExecuted: executed)
            case .cancelled:
                return ConnectAttemptRunnerResult(outcome: .cancelled, attemptsExecuted: executed)
            case .unavailable(let message):
                return ConnectAttemptRunnerResult(outcome: .unavailable(message: message), attemptsExecuted: executed)
            case .failed, .timeout:
                let isFinalAttempt = attemptIndex == totalAttempts
                if isFinalAttempt {
                    break
                }
                onBackoff?(backoffSeconds, attemptIndex, totalAttempts)
                do {
                    try await sleep(backoffSeconds)
                } catch {
                    return ConnectAttemptRunnerResult(outcome: .cancelled, attemptsExecuted: executed)
                }
            }
        }

        if Task.isCancelled {
            return ConnectAttemptRunnerResult(outcome: .cancelled, attemptsExecuted: executed)
        }
        return ConnectAttemptRunnerResult(outcome: .failed, attemptsExecuted: executed)
    }
}

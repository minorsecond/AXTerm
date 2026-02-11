import XCTest
@testable import AXTerm

@MainActor
final class ConnectAttemptRunnerTests: XCTestCase {
    func testPlanStopsAfterSuccess() async {
        let plan = ConnectAttemptPlan(steps: [
            .ax25ViaDigis(digis: ["A1AAA"]),
            .ax25ViaDigis(digis: ["B1BBB"]),
            .ax25ViaDigis(digis: ["C1CCC"])
        ])
        var executedSteps: [ConnectAttemptStep] = []
        let runner = ConnectAttemptRunner(maxAttempts: 3, backoffSeconds: 8, sleep: { _ in })

        let result = await runner.run(
            plan: plan,
            onStatus: { _, _, _ in },
            execute: { step, _, _ in
                executedSteps.append(step)
                return executedSteps.count == 2 ? .success : .failed
            }
        )

        XCTAssertEqual(result.outcome, .success)
        XCTAssertEqual(executedSteps.count, 2)
    }

    func testPlanRespectsCancellation() async {
        let plan = ConnectAttemptPlan(steps: [
            .ax25ViaDigis(digis: ["A1AAA"]),
            .ax25ViaDigis(digis: ["B1BBB"])
        ])
        let runner = ConnectAttemptRunner(maxAttempts: 3, backoffSeconds: 8, sleep: { _ in })

        let result = await runner.run(
            plan: plan,
            onStatus: { _, _, _ in },
            execute: { _, _, _ in
                .cancelled
            }
        )

        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertEqual(result.attemptsExecuted, 1)
    }

    func testPlanRequestsEightSecondBackoffBetweenAttempts() async {
        let plan = ConnectAttemptPlan(steps: [
            .ax25ViaDigis(digis: ["A1AAA"]),
            .ax25ViaDigis(digis: ["B1BBB"]),
            .ax25ViaDigis(digis: ["C1CCC"])
        ])
        var requestedBackoffs: [TimeInterval] = []
        let runner = ConnectAttemptRunner(
            maxAttempts: 3,
            backoffSeconds: 8,
            sleep: { _ in }
        )

        let result = await runner.run(
            plan: plan,
            onStatus: { _, _, _ in },
            execute: { _, _, _ in .failed },
            onBackoff: { seconds, _, _ in
                requestedBackoffs.append(seconds)
            }
        )

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(requestedBackoffs, [8, 8])
    }

    func testNetRomAutoFailsImmediatelyWhenTransportUnavailable() async {
        let plan = ConnectAttemptPlan(steps: [
            .netrom(nextHopOverride: nil),
            .netrom(nextHopOverride: "N1AAA"),
            .netrom(nextHopOverride: "N1BBB")
        ])
        var executedCount = 0
        let runner = ConnectAttemptRunner(maxAttempts: 3, backoffSeconds: 8, sleep: { _ in })

        let result = await runner.run(
            plan: plan,
            onStatus: { _, _, _ in },
            execute: { _, _, _ in
                executedCount += 1
                return .unavailable(message: "NET/ROM transport unavailable")
            }
        )

        XCTAssertEqual(result.outcome, .unavailable(message: "NET/ROM transport unavailable"))
        XCTAssertEqual(executedCount, 1)
    }
}

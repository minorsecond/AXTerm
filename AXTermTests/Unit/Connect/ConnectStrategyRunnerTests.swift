//
//  ConnectStrategyRunnerTests.swift
//  AXTermTests
//
//  Pins the ladder walk: fall through on path failures, stop on an answer,
//  back off between rungs. And the advance policy's whole verdict table,
//  because the difference between "no route" and "no" is the difference
//  between trying the next family and respecting a refusal.
//

import XCTest
@testable import AXTerm

@MainActor
final class ConnectStrategyRunnerTests: XCTestCase {

    private func step(_ kind: ConnectStrategyKind, score: Double = 1.0) -> ConnectStrategyStep {
        ConnectStrategyStep(
            kind: kind,
            score: score,
            provenance: .init(source: .heardDirect, evidenceAge: nil),
            reason: "test rung",
            budget: 10)
    }

    private func ladder(_ steps: [ConnectStrategyStep]) -> ConnectStrategyLadder {
        ConnectStrategyLadder(destination: "COSCO", steps: steps, skipped: [])
    }

    private func makeRunner() -> ConnectStrategyRunner {
        ConnectStrategyRunner(backoffSeconds: 5, sleep: { _ in })
    }

    // MARK: - Advance policy verdict table

    func testVerdictTable() {
        XCTAssertEqual(ConnectStrategyAdvancePolicy.verdict(after: .failed), .fallThrough)
        XCTAssertEqual(ConnectStrategyAdvancePolicy.verdict(after: .timeout), .fallThrough)
        XCTAssertEqual(ConnectStrategyAdvancePolicy.verdict(after: .unavailable(message: "no route")),
                       .fallThrough,
                       "one family's 'no route' says nothing about another family's chances")
        XCTAssertEqual(ConnectStrategyAdvancePolicy.verdict(after: .refused(detail: "COSCO refused")),
                       .stopLadder("COSCO refused"),
                       "the station answered; trying a different family is nagging")
    }

    // MARK: - Runner behavior

    func testFallsThroughFailuresAndConnectsOnALaterRung() async {
        let steps = [step(.directL2), step(.ax25ViaDigis(["DRLNOD"])), step(.nodePromptRelay(teller: "KB5YZB-7"))]
        var executed: [ConnectStrategyKind] = []
        var explained: [Int] = []

        let outcome = await makeRunner().run(
            ladder: ladder(steps),
            onExplain: { rung, _, _ in explained.append(rung) },
            execute: { step in
                executed.append(step.kind)
                return executed.count == 3 ? .success : (executed.count == 1 ? .timeout : .unavailable(message: "no path"))
            })

        XCTAssertEqual(outcome, .connected(rung: 3))
        XCTAssertEqual(executed.count, 3)
        XCTAssertEqual(explained, [1, 2, 3], "every rung explains itself before it keys anything")
    }

    func testARefusalStopsTheWholeLadder() async {
        let steps = [step(.directL2), step(.nodePromptRelay(teller: "KB5YZB-7"))]
        var executed = 0

        let outcome = await makeRunner().run(
            ladder: ladder(steps),
            onExplain: { _, _, _ in },
            execute: { _ in
                executed += 1
                return .refused(detail: "COSCO answered our SABM with DM")
            })

        XCTAssertEqual(outcome, .refused("COSCO answered our SABM with DM"))
        XCTAssertEqual(executed, 1, "the second rung must never run after an answer")
    }

    func testEveryRungFailingIsExhaustedNotRefused() async {
        let outcome = await makeRunner().run(
            ladder: ladder([step(.directL2), step(.ax25ViaDigis(["DRLNOD"]))]),
            onExplain: { _, _, _ in },
            execute: { _ in .failed })
        XCTAssertEqual(outcome, .exhausted)
    }

    func testBackoffRunsBetweenRungsButNotAfterTheLast() async {
        var backoffs: [TimeInterval] = []
        _ = await makeRunner().run(
            ladder: ladder([step(.directL2), step(.ax25ViaDigis(["DRLNOD"])), step(.nodePromptRelay(teller: nil))]),
            onExplain: { _, _, _ in },
            execute: { _ in .failed },
            onBackoff: { backoffs.append($0) })
        XCTAssertEqual(backoffs, [5, 5])
    }

    func testCancelledSleepEndsTheLadderQuietly() async {
        struct Interrupted: Error {}
        let runner = ConnectStrategyRunner(backoffSeconds: 5, sleep: { _ in throw Interrupted() })
        let outcome = await runner.run(
            ladder: ladder([step(.directL2), step(.ax25ViaDigis(["DRLNOD"]))]),
            onExplain: { _, _, _ in },
            execute: { _ in .failed })
        XCTAssertEqual(outcome, .cancelled)
    }

    func testAnEmptyLadderIsExhaustedWithoutExecuting() async {
        var executed = 0
        let outcome = await makeRunner().run(
            ladder: ladder([]),
            onExplain: { _, _, _ in },
            execute: { _ in executed += 1; return .success })
        XCTAssertEqual(outcome, .exhausted)
        XCTAssertEqual(executed, 0)
    }

    func testMidLadderCancellationOfTheExecutingStep() async {
        let outcome = await makeRunner().run(
            ladder: ladder([step(.directL2), step(.ax25ViaDigis(["DRLNOD"]))]),
            onExplain: { _, _, _ in },
            execute: { _ in .cancelled })
        XCTAssertEqual(outcome, .cancelled)
    }
}

/// The legacy single-family runner gained the `.refused` result; it stops
/// there the way it stops on `.unavailable`, surfacing the detail.
@MainActor
final class ConnectAttemptRunnerRefusedTests: XCTestCase {

    func testRefusedStopsTheLegacyRunnerWithTheDetail() async {
        let runner = ConnectAttemptRunner(maxAttempts: 3, backoffSeconds: 0, sleep: { _ in })
        let plan = ConnectAttemptPlan(steps: [
            .netrom(nextHopOverride: nil),
            .netrom(nextHopOverride: "KB5YZB-7")
        ])
        var executed = 0

        let result = await runner.run(
            plan: plan,
            onStatus: { _, _, _ in },
            execute: { _, _, _ in
                executed += 1
                return .refused(detail: "COSCO refused the connection")
            })

        XCTAssertEqual(result.outcome, .unavailable(message: "COSCO refused the connection"))
        XCTAssertEqual(executed, 1, "no retry after an answer")
    }
}

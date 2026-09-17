import XCTest
@testable import AXTerm

/// The rule behind DraftTextField's write-back.
///
/// Pinned because the bug it fixes is invisible from the code: on macOS a
/// button does not take focus from a text field, so a commit that waits for
/// focus loss never runs when the operator types an address and clicks the
/// button next to it. The field looked right, the value on disk was the old
/// one, and the error message complained about an address that was on
/// screen the whole time (2026-09-17).
final class DraftCommitRuleTests: XCTestCase {

    func testADraftMatchingTheBoundValueIsNotWorthWriting() async {
        XCTAssertFalse(DraftCommitRule.needsCommit(draft: "192.168.3.34", text: "192.168.3.34"))

        var slept = false
        let commit = await DraftCommitRule.awaitQuiet(
            draft: "192.168.3.34", text: "192.168.3.34",
            sleep: { _ in slept = true })
        XCTAssertFalse(commit)
        XCTAssertFalse(slept, "nothing to write, so nothing to wait for")
    }

    func testADifferentDraftCommitsOnceTypingStops() async {
        var waited: Duration?
        let commit = await DraftCommitRule.awaitQuiet(
            draft: "192.168.3.34", text: "",
            sleep: { waited = $0 })
        XCTAssertTrue(commit)
        XCTAssertEqual(waited, DraftCommitRule.quietPeriod)
    }

    /// Every keystroke restarts the wait, which SwiftUI does by cancelling
    /// the task. A cancelled wait must not write a half-typed address.
    func testAKeystrokeDuringTheWaitAbandonsTheWrite() async {
        let started = expectation(description: "sleeping")
        let task = Task {
            await DraftCommitRule.awaitQuiet(draft: "192.168.3.3", text: "",
                                             sleep: { _ in
                started.fulfill()
                try await Task.sleep(for: .seconds(10))
            })
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        let commit = await task.value
        XCTAssertFalse(commit, "a cancelled wait writes nothing")
    }

    /// The shipped delay has to clear a burst of typing without outlasting
    /// the reach for a button.
    func testTheQuietPeriodStaysInTheUsableBand() {
        XCTAssertGreaterThanOrEqual(DraftCommitRule.quietPeriod, .milliseconds(200))
        XCTAssertLessThanOrEqual(DraftCommitRule.quietPeriod, .milliseconds(800))
    }
}

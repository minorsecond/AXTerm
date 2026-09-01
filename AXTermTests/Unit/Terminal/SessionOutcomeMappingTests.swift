import XCTest
@testable import AXTerm

/// Turning the terminal's own status line into a recorded outcome.
///
/// Reusing those strings rather than inventing a second vocabulary: the
/// history should describe a session in the words the operator watched it
/// happen in, and two vocabularies eventually disagree about the same event.
final class SessionOutcomeMappingTests: XCTestCase {

    func testTheTerminalsWordsBecomeOutcomes() {
        XCTAssertEqual(TerminalSession.Outcome(statusText: "Disconnected"), .closed)
        XCTAssertEqual(TerminalSession.Outcome(statusText: "Refused"), .refused)
        XCTAssertEqual(TerminalSession.Outcome(statusText: "Busy"), .refused)
        XCTAssertEqual(TerminalSession.Outcome(statusText: "Timed out"), .timedOut)
        XCTAssertEqual(TerminalSession.Outcome(statusText: "Failed"), .lost)
    }

    func testCaseDoesNotMatter() {
        XCTAssertEqual(TerminalSession.Outcome(statusText: "DISCONNECTED"), .closed)
        XCTAssertEqual(TerminalSession.Outcome(statusText: "refused"), .refused)
    }

    /// Anything still in progress is not an ending, and must not close the
    /// record early. Most of what the strip shows is one of these.
    func testAnInProgressStateIsNotAnOutcome() {
        for live in ["Connecting", "Connected", "Sending", "Waiting", ""] {
            XCTAssertNil(TerminalSession.Outcome(statusText: live), live)
        }
    }

    /// A busy signal is the far end answering, so it proves the station heard
    /// us. Silence proves nothing at all, and the two must not be coloured or
    /// counted the same.
    func testRefusalAndSilenceAreDifferentEvidence() {
        XCTAssertTrue(TerminalSession.Outcome(statusText: "Busy")?
            .provesTheFarEndHeardUs ?? false)
        XCTAssertFalse(TerminalSession.Outcome(statusText: "Timed out")?
            .provesTheFarEndHeardUs ?? true)
    }

    /// Durations are read at a glance in a list, so they stay short and the
    /// units change with the magnitude.
    func testDurationsReadShort() {
        XCTAssertEqual(SessionHistoryRow.durationText(9), "9s")
        XCTAssertEqual(SessionHistoryRow.durationText(95), "1m 35s")
        XCTAssertEqual(SessionHistoryRow.durationText(3_725), "1h 2m")
    }
}

import XCTest
@testable import AXTerm

/// What a ping's result is allowed to claim, given how far it was sent.
///
/// A directed query sent **direct** carries no digipeater path, so an answer
/// is proof the station heard this one. Sent over the radio's APRS path it is
/// proof of nothing but reachability: the query may have been repeated twice
/// on the way out and the answer twice on the way back, and the two stations
/// may be nowhere near each other. The tracker has always recorded the reach;
/// the sentence shown to the operator ignored it and said "directly" either
/// way.
final class APRSPingReachTests: XCTestCase {

    private func ping(reach: APRSProbeReach, outcome: APRSPingTracker.Outcome,
                      heardUs: Bool = false, query: String = "?APRSP",
                      reply: APRSPingTracker.Reply = .none) -> APRSPingTracker.Ping {
        APRSPingTracker.Ping(callsign: "WQ8M-9", query: query, reach: reach,
                             sentAt: Date(), outcome: outcome, heardUs: heardUs,
                             reply: reply)
    }

    func testADirectAnswerMayClaimEarshot() {
        let line = APRSPingPresentation.line(
            ping(reach: .direct, outcome: .confirmed, query: "?VER", reply: .answeredQuery))
        XCTAssertTrue(line.contains("directly"), line)
    }

    /// The claim this test exists to prevent.
    func testADigipeatedAnswerMayNotClaimEarshot() {
        let line = APRSPingPresentation.line(
            ping(reach: .wide, outcome: .confirmed, query: "?VER", reply: .answeredQuery))
        XCTAssertFalse(line.contains("directly"),
                       "the query was digipeated; an answer proves reach, not earshot: \(line)")
        XCTAssertTrue(line.lowercased().contains("reachable"), line)
    }

    /// Silence means different things too: nobody in earshot, versus nobody
    /// within a digipeater hop.
    func testSilenceIsReadAgainstTheReachItWasSentAt() {
        let direct = APRSPingPresentation.line(ping(reach: .direct, outcome: .silent))
        let wide = APRSPingPresentation.line(ping(reach: .wide, outcome: .silent))
        XCTAssertNotEqual(direct, wide,
                          "silence after a digipeated ping rules out more than silence "
                          + "after a direct one, and must not be described the same way")
    }

    /// And while it is waiting, the operator should be able to see which
    /// question was actually asked.
    func testTheWaitingLineSaysHowFarItWent() {
        let wide = APRSPingPresentation.line(ping(reach: .wide, outcome: .waiting))
        XCTAssertTrue(wide.lowercased().contains("path"), wide)
        let direct = APRSPingPresentation.line(ping(reach: .direct, outcome: .waiting))
        XCTAssertFalse(direct.lowercased().contains("path"), direct)
    }
}

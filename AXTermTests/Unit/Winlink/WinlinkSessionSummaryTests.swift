import XCTest
@testable import AXTerm

/// Presenting a past exchange to the operator.
///
/// The numbers in the log are only useful once they answer the questions
/// actually asked afterwards: how long did that take, was it worth the
/// airtime, and why did it fail.
final class WinlinkSessionSummaryTests: XCTestCase {

    private func log(seconds: TimeInterval = 161,
                     result: String = "success",
                     error: String? = nil,
                     sent: Int = 0, received: Int = 1,
                     bytesOut: Int = 55, bytesIn: Int = 1691,
                     frequency: Int? = 145_050_000) -> WinlinkSessionLogRecord {
        let start = Date(timeIntervalSince1970: 1_788_000_000)
        return WinlinkSessionLogRecord(
            id: 1, startedAt: start, endedAt: start.addingTimeInterval(seconds),
            gatewayCallsign: "W0ARP-10", transport: "ax25", result: result,
            messagesSent: sent, messagesReceived: received,
            bytesSent: bytesOut, bytesReceived: bytesIn, errorText: error,
            frequencyHz: frequency, obsLatitude: nil, obsLongitude: nil,
            obsGrid: nil, obsSource: nil)
    }

    func testShortSessionsReadInSeconds() {
        XCTAssertEqual(WinlinkSessionSummary(log: log(seconds: 32)).durationText, "32s")
    }

    func testLongerSessionsReadInMinutesAndSeconds() {
        XCTAssertEqual(WinlinkSessionSummary(log: log(seconds: 161)).durationText, "2m 41s")
    }

    /// A session that failed on connect can be over in well under a second.
    /// "0s" is honest; a blank is not.
    func testAnInstantFailureStillHasADuration() {
        XCTAssertEqual(WinlinkSessionSummary(log: log(seconds: 0.4)).durationText, "0s")
    }

    /// The number that says whether the airtime bought anything. On a link
    /// this slow it is the difference between a useful session and one worth
    /// retrying from somewhere else.
    func testThroughputIsBytesOverTheWholeSession() {
        let summary = WinlinkSessionSummary(log: log(seconds: 100, bytesOut: 400, bytesIn: 600))
        XCTAssertEqual(summary.bytesPerSecond ?? 0, 10, accuracy: 0.001)
    }

    /// Dividing by a zero-length session is the obvious crash, and a
    /// throughput figure for one would be meaningless anyway.
    func testAZeroLengthSessionReportsNoThroughput() {
        XCTAssertNil(WinlinkSessionSummary(log: log(seconds: 0)).bytesPerSecond)
    }

    func testASuccessfulSessionSaysWhatItMoved() {
        let summary = WinlinkSessionSummary(log: log(sent: 2, received: 3))
        XCTAssertTrue(summary.succeeded)
        XCTAssertEqual(summary.trafficText, "2 sent · 3 received")
    }

    /// A session that connected and moved nothing is a real outcome, not an
    /// empty string — it is what an empty mailbox looks like.
    func testAnEmptyExchangeSaysNothingMoved() {
        let summary = WinlinkSessionSummary(log: log(sent: 0, received: 0))
        XCTAssertEqual(summary.trafficText, "nothing moved")
    }

    /// The failure text is the whole reason to look at a failed session, so
    /// it is the headline rather than a detail.
    func testAFailureLeadsWithWhy() {
        let summary = WinlinkSessionSummary(log: log(
            result: "the CMS refused the connection: Secure login failed",
            error: "the CMS refused the connection: Secure login failed"))
        XCTAssertFalse(summary.succeeded)
        XCTAssertEqual(summary.outcomeText, "the CMS refused the connection: Secure login failed")
    }

    func testASuccessSaysSoPlainly() {
        XCTAssertEqual(WinlinkSessionSummary(log: log()).outcomeText, "Succeeded")
    }

    /// A callsign alone does not identify a link — the same gateway answers
    /// on different frequencies and behaves nothing alike — so the frequency
    /// belongs in the label wherever it is known.
    func testTheLinkIsNamedByCallsignAndFrequency() {
        XCTAssertEqual(WinlinkSessionSummary(log: log()).linkText, "W0ARP-10 · 145.050 MHz")
    }

    func testATelnetSessionHasNoFrequencyToShow() {
        XCTAssertEqual(WinlinkSessionSummary(log: log(frequency: nil)).linkText, "W0ARP-10")
    }
}

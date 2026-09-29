import XCTest
@testable import AXTerm

final class WinlinkGatewayHoursTests: XCTestCase {

    /// A fixed UTC calendar keeps the hour buckets deterministic
    /// regardless of where the test machine thinks it is.
    private var utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func log(hour: Int,
                     callsign: String = "W0ARP-10",
                     bytes: Int = 5000,
                     result: String = "success",
                     transport: String = "ax25") -> WinlinkSessionLogRecord {
        // 2027-01-01 at the given UTC hour.
        let start = Date(timeIntervalSince1970: 1_798_761_600 + Double(hour) * 3600)
        return WinlinkSessionLogRecord(
            startedAt: start,
            endedAt: start.addingTimeInterval(120),
            gatewayCallsign: callsign,
            transport: transport,
            result: result,
            messagesSent: 0,
            messagesReceived: 0,
            bytesSent: 0,
            bytesReceived: bytes,
            errorText: nil,
            frequencyHz: 145_050_000,
            obsLatitude: nil, obsLongitude: nil, obsGrid: nil, obsSource: nil)
    }

    private func profile(_ logs: [WinlinkSessionLogRecord],
                         callsign: String = "") -> WinlinkGatewayHours {
        WinlinkGatewayHours.profile(logs: logs, callsign: callsign, calendar: utc)
    }

    // MARK: - Bucketing

    func testAlwaysReturnsTwentyFourHoursInOrder() {
        let result = profile([log(hour: 15)])
        XCTAssertEqual(result.hours.count, 24)
        XCTAssertEqual(result.hours.map(\.hour), Array(0..<24))
    }

    func testAttemptsAndAnswersLandInTheRightHour() {
        let result = profile([log(hour: 15), log(hour: 15), log(hour: 3)])
        XCTAssertEqual(result.hours[15].attempts, 2)
        XCTAssertEqual(result.hours[15].answered, 2)
        XCTAssertEqual(result.hours[3].attempts, 1)
        XCTAssertEqual(result.totalAttempts, 3)
    }

    /// "Never attempted" and "attempted and failed" are different facts
    /// and must not render alike.
    func testUntriedHoursHaveNoRateRatherThanZero() {
        let result = profile([log(hour: 15)])
        XCTAssertNil(result.hours[4].answerRate)
        XCTAssertEqual(result.hours[15].answerRate, 1.0)
    }

    // MARK: - What counts

    /// A connect failure that moved no bytes is silence — the gateway
    /// was not there.
    func testConnectFailureWithNoBytesCountsAsUnanswered() {
        let result = profile([log(hour: 9, bytes: 0, result: "connect failed: timeout")])
        XCTAssertEqual(result.hours[9].attempts, 1)
        XCTAssertEqual(result.hours[9].answered, 0)
    }

    /// A failure that is not a connect failure still proves the gateway
    /// answered.
    func testNonConnectFailureStillCountsAsAnswered() {
        let result = profile([log(hour: 9, bytes: 0, result: "the gateway closed the link")])
        XCTAssertEqual(result.hours[9].answered, 1)
    }

    /// Telnet reaches the CMS over the internet and says nothing about
    /// any RF gateway's hours.
    func testTelnetSessionsAreExcluded() {
        XCTAssertEqual(profile([log(hour: 9, transport: "telnet")]).totalAttempts, 0)
    }

    /// Blaming a gateway for our own busy session would make this
    /// measure AXTerm rather than the link.
    func testOurOwnFaultsAreExcluded() {
        let result = profile([log(hour: 9, result: "an exchange is already running")])
        XCTAssertEqual(result.totalAttempts, 0)
    }

    func testFilteringByCallsignIgnoresOtherGateways() {
        let logs = [log(hour: 9, callsign: "W0ARP-10"), log(hour: 9, callsign: "K0NTS-10")]
        XCTAssertEqual(profile(logs, callsign: "w0arp-10").totalAttempts, 1)
        XCTAssertEqual(profile(logs).totalAttempts, 2, "no filter means all gateways")
    }

    // MARK: - Reading the pattern

    /// Three sessions are not a schedule, and saying so is more useful
    /// than inventing one.
    func testThinHistorySaysSoRatherThanClaimingAPattern() {
        let result = profile([log(hour: 15), log(hour: 15)])
        XCTAssertTrue(result.isTooThin)
        XCTAssertTrue(result.headline.contains("not enough"), result.headline)
    }

    func testNoSessionsAtAllIsStatedPlainly() {
        XCTAssertTrue(profile([]).headline.contains("No sessions"), profile([]).headline)
    }

    func testHeadlineNamesTheBestHourOnceThereIsEnoughHistory() {
        var logs = (0..<6).map { _ in log(hour: 15) }
        logs += (0..<4).map { _ in log(hour: 4, bytes: 0, result: "connect failed: timeout") }
        let result = profile(logs)
        XCTAssertFalse(result.isTooThin)
        XCTAssertTrue(result.headline.contains("15:00"), result.headline)
    }

    /// Knowing when *not* to bother is more actionable than knowing the
    /// best hour.
    func testDeadHoursAreReportedWhenTriedRepeatedly() {
        var logs = (0..<6).map { _ in log(hour: 15) }
        logs += (0..<3).map { _ in log(hour: 4, bytes: 0, result: "connect failed: timeout") }
        let result = profile(logs)
        XCTAssertEqual(result.deadHours.map(\.hour), [4])
        XCTAssertTrue(result.headline.contains("Never answered at 04:00"), result.headline)
    }

    /// One failed attempt in an hour is not evidence that the hour is
    /// dead.
    func testASingleFailureDoesNotMakeAnHourDead() {
        var logs = (0..<8).map { _ in log(hour: 15) }
        logs.append(log(hour: 4, bytes: 0, result: "connect failed: timeout"))
        XCTAssertTrue(profile(logs).deadHours.isEmpty)
    }

    func testRankedHoursExcludeThinlyTriedHours() {
        var logs = (0..<8).map { _ in log(hour: 15) }
        logs.append(log(hour: 2))
        let ranked = profile(logs).rankedHours
        XCTAssertEqual(ranked.map(\.hour), [15], "hour 2 has only one attempt")
    }

    /// A station that has never been answered should not be told which
    /// hour is best.
    func testAllFailedHistoryReportsNoneAnswered() {
        let logs = (0..<10).map { _ in log(hour: 15, bytes: 0, result: "connect failed: timeout") }
        XCTAssertTrue(profile(logs).headline.contains("none answered"), profile(logs).headline)
    }
}

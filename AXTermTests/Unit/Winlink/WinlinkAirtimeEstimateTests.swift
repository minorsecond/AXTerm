import XCTest
@testable import AXTerm

/// Rates and sizes here are from the 2026-08-24 field capture unless a
/// test says otherwise.
final class WinlinkAirtimeEstimateTests: XCTestCase {

    /// `summarize` drops samples older than 90 days, so the fixture
    /// clock and the logs have to sit in the same window.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var recently: Date { now.addingTimeInterval(-3600) }

    private func summarize(_ logs: [WinlinkSessionLogRecord]) -> [String: WinlinkLinkQuality] {
        WinlinkLinkQuality.summarize(logs: logs, observer: here, now: now)
    }

    private func log(_ callsign: String,
                     frequencyHz: Int?,
                     seconds: Double,
                     bytes: Int,
                     startedAt: Date? = nil,
                     result: String = "success",
                     grid: String? = "DM79ab",
                     latitude: Double? = 39.7,
                     longitude: Double? = -105.0,
                     obsSource: String = "GPS") -> WinlinkSessionLogRecord {
        let startedAt = startedAt ?? recently
        return WinlinkSessionLogRecord(
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(seconds),
            gatewayCallsign: callsign,
            transport: "ax25",
            result: result,
            messagesSent: 0,
            messagesReceived: 1,
            bytesSent: 0,
            bytesReceived: bytes,
            errorText: nil,
            frequencyHz: frequencyHz,
            obsLatitude: latitude,
            obsLongitude: longitude,
            obsGrid: grid,
            obsSource: obsSource)
    }

    /// A GPS-sourced observer, so placement is decided by real distance
    /// rather than by grid-square imprecision — see
    /// `testGridSquareOnlyOperatorsNeverGetAMeasuredRate` for what
    /// happens when it is not.
    private let here = StationLocation(
        latitude: 39.7, longitude: -105.0, gridSquare: "DM79ab",
        source: .gps, timestamp: Date(timeIntervalSince1970: 1_800_000_000))

    // MARK: - The default

    func testAssumedEstimateUsesTheDocumentedConstants() {
        let estimate = WinlinkAirtimeEstimate.assumed
        XCTAssertFalse(estimate.isMeasured)
        XCTAssertEqual(estimate.compressedBytesPerSecond,
                       WinlinkAirtimeEstimate.defaultCompressedBytesPerSecond)
        // 90,000 bytes ÷ 3:1 ÷ 30 B/s = 1000 s.
        XCTAssertEqual(estimate.estimatedSeconds(bytes: 90_000), 1000, accuracy: 0.001)
    }

    func testAirtimeScalesWithSizeAndReadsInPlainUnits() {
        let estimate = WinlinkAirtimeEstimate.assumed
        XCTAssertEqual(estimate.airtimeText(bytes: 900), "10s")
        // 54,000 bytes = 600 s = a clean 10 minutes, so the assertion
        // does not depend on how the formatter rounds.
        XCTAssertTrue(estimate.airtimeText(bytes: 54_000).contains("10"),
                      estimate.airtimeText(bytes: 54_000))
    }

    /// A product too small to measure still has to say something.
    func testTinyProductRoundsUpToOneSecond() {
        XCTAssertEqual(WinlinkAirtimeEstimate.assumed.airtimeText(bytes: 1), "1s")
        XCTAssertEqual(WinlinkAirtimeEstimate.assumed.airtimeText(bytes: 0), "—")
    }

    func testTooltipShowsTheDerivationAndSaysItIsAnAssumption() {
        let text = WinlinkAirtimeEstimate.assumed.tooltip(bytes: 90_000)
        XCTAssertTrue(text.contains("30 B/s"), text)
        XCTAssertTrue(text.contains("3:1"), text)
        // The operator must be able to tell a default from a measurement.
        XCTAssertTrue(text.lowercased().contains("assum") || text.lowercased().contains("typical"),
                      text)
    }

    // MARK: - Measured throughput

    /// The session log records *compressed* bytes, which is the same
    /// quantity the estimate divides by — so a measured rate substitutes
    /// directly, with no unit conversion.
    func testMeasuredRateReplacesTheDefault() {
        let quality = summarize([log("K0NTS-10", frequencyHz: 145_030, seconds: 100, bytes: 6000)])
        let estimate = WinlinkAirtimeEstimate.forGateway(
            callsign: "K0NTS-10", frequencyHz: 145_030, quality: quality)

        XCTAssertTrue(estimate.isMeasured)
        XCTAssertEqual(estimate.compressedBytesPerSecond, 60, accuracy: 0.001)
        // Twice the default rate, so half the default time.
        XCTAssertEqual(estimate.estimatedSeconds(bytes: 90_000), 500, accuracy: 0.001)
        XCTAssertTrue(estimate.tooltip(bytes: 90_000).contains("K0NTS-10"),
                      estimate.tooltip(bytes: 90_000))
    }

    /// `WinlinkLinkQuality` refuses to let a sample taken elsewhere pass
    /// as a prediction, and the estimate must honour that rather than
    /// quietly using the number.
    func testSamplesFromElsewhereDoNotBecomeTheEstimate() {
        // Same gateway, but every sample was taken ~1500 km away.
        let quality = summarize([log("K0NTS-10", frequencyHz: 145_030, seconds: 100, bytes: 6000,
                       grid: "EM12ab", latitude: 32.7, longitude: -96.8)])
        let estimate = WinlinkAirtimeEstimate.forGateway(
            callsign: "K0NTS-10", frequencyHz: 145_030, quality: quality)

        XCTAssertFalse(estimate.isMeasured)
        XCTAssertEqual(estimate.compressedBytesPerSecond,
                       WinlinkAirtimeEstimate.defaultCompressedBytesPerSecond)
        // Shown as context, never as the basis.
        XCTAssertTrue(estimate.tooltip(bytes: 90_000).lowercased().contains("elsewhere"),
                      estimate.tooltip(bytes: 90_000))
    }

    /// Below `effectiveBytesPerSecond`'s evidence floor there is no
    /// measurement to use.
    func testTooLittleEvidenceFallsBackToTheDefault() {
        let quality = summarize([log("K0NTS-10", frequencyHz: 145_030, seconds: 2, bytes: 40)])
        let estimate = WinlinkAirtimeEstimate.forGateway(
            callsign: "K0NTS-10", frequencyHz: 145_030, quality: quality)
        XCTAssertFalse(estimate.isMeasured)
    }

    func testNoGatewaySelectedFallsBackToTheDefault() {
        let estimate = WinlinkAirtimeEstimate.forGateway(
            callsign: "", frequencyHz: nil, quality: [:])
        XCTAssertFalse(estimate.isMeasured)
        XCTAssertEqual(estimate.compressedBytesPerSecond,
                       WinlinkAirtimeEstimate.defaultCompressedBytesPerSecond)
    }

    /// 145.030 at 1200 bd and 441.075 at 9600 bd "behave nothing alike",
    /// so a rate measured on one must not be reported for the other.
    func testRatesAreNotBorrowedAcrossFrequencies() {
        let quality = summarize([log("W0ARP-10", frequencyHz: 441_075, seconds: 100, bytes: 60_000)])
        let estimate = WinlinkAirtimeEstimate.forGateway(
            callsign: "W0ARP-10", frequencyHz: 145_030, quality: quality)
        XCTAssertFalse(estimate.isMeasured)
        XCTAssertEqual(estimate.compressedBytesPerSecond,
                       WinlinkAirtimeEstimate.defaultCompressedBytesPerSecond)
    }

    /// With no frequency chosen, the best-evidenced link for that
    /// callsign is the honest pick.
    func testWithoutAFrequencyTheBestEvidencedLinkIsUsed() {
        let quality = summarize([
                log("W0ARP-10", frequencyHz: 145_030, seconds: 20, bytes: 200),
                log("W0ARP-10", frequencyHz: 441_075, seconds: 600, bytes: 60_000,
                    startedAt: now.addingTimeInterval(-1800)),
            ])
        let estimate = WinlinkAirtimeEstimate.forGateway(
            callsign: "W0ARP-10", frequencyHz: nil, quality: quality)
        XCTAssertTrue(estimate.isMeasured)
        XCTAssertEqual(estimate.compressedBytesPerSecond, 100, accuracy: 0.001)
    }

    /// A 2-degree grid square is 60 km of uncertainty, and
    /// `WinlinkLinkQuality` refuses to call that "here". So an operator
    /// who has only configured a 4-character grid never gets a measured
    /// rate — the estimate stays on the default and says why, rather
    /// than claiming a precision the position does not have.
    func testGridSquareOnlyOperatorsNeverGetAMeasuredRate() {
        let coarse = StationLocation(
            latitude: 39.7, longitude: -105.0, gridSquare: "DM79",
            source: .manualGrid, timestamp: now)
        let quality = WinlinkLinkQuality.summarize(
            logs: [log("K0NTS-10", frequencyHz: 145_030, seconds: 100, bytes: 6000,
                       grid: "DM79", obsSource: "Grid square")],
            observer: coarse,
            now: now)
        let estimate = WinlinkAirtimeEstimate.forGateway(
            callsign: "K0NTS-10", frequencyHz: 145_030, quality: quality)
        XCTAssertFalse(estimate.isMeasured)

        // The same sessions with a 6-character square do qualify.
        let fine = StationLocation(
            latitude: 39.7, longitude: -105.0, gridSquare: "DM79ab",
            source: .manualGrid, timestamp: now)
        let finer = WinlinkLinkQuality.summarize(
            logs: [log("K0NTS-10", frequencyHz: 145_030, seconds: 100, bytes: 6000,
                       grid: "DM79ab", obsSource: "Grid square")],
            observer: fine,
            now: now)
        XCTAssertTrue(WinlinkAirtimeEstimate.forGateway(
            callsign: "K0NTS-10", frequencyHz: 145_030, quality: finer).isMeasured)
    }

    // MARK: - Session cap

    /// W0ARP-10 disconnects at ~17 minutes, so a 45-minute request will
    /// be cut off twice no matter how good the path is.
    func testRequestLongerThanTheObservedCapNeedsSeveralSessions() {
        let quality = summarize([log("W0ARP-10", frequencyHz: 145_030, seconds: 1020, bytes: 30_600)])
        let estimate = WinlinkAirtimeEstimate.forGateway(
            callsign: "W0ARP-10", frequencyHz: 145_030, quality: quality)

        XCTAssertEqual(estimate.sessionCapSeconds, 1020)
        // 30 B/s measured, so 91,800 uncompressed bytes ≈ 1020 s = one full session.
        XCTAssertEqual(estimate.sessionsRequired(bytes: 91_800), 1)
        XCTAssertEqual(estimate.sessionsRequired(bytes: 91_801), 2)
        XCTAssertEqual(estimate.sessionsRequired(bytes: 275_400), 3)
    }

    func testNoObservedCapMeansNoSessionWarning() {
        let estimate = WinlinkAirtimeEstimate.assumed
        XCTAssertNil(estimate.sessionCapSeconds)
        XCTAssertEqual(estimate.sessionsRequired(bytes: 10_000_000), 1)
    }

    /// A cap is a property of the gateway's software, so it carries
    /// across that gateway's frequencies even though the rate does not.
    func testCapCarriesAcrossFrequenciesEvenThoughRateDoesNot() {
        let quality = summarize([log("W0ARP-10", frequencyHz: 441_075, seconds: 1020, bytes: 30_600)])
        let estimate = WinlinkAirtimeEstimate.forGateway(
            callsign: "W0ARP-10", frequencyHz: 145_030, quality: quality)
        XCTAssertFalse(estimate.isMeasured, "rate must not cross bands")
        XCTAssertEqual(estimate.sessionCapSeconds, 1020, "but the cap does")
    }

    /// A handful of short sessions is not evidence of a cap — every
    /// session is short when there is nothing to send.
    func testShortSessionsAreNotMistakenForACap() {
        let quality = summarize([log("K0NTS-10", frequencyHz: 145_030, seconds: 30, bytes: 900)])
        let estimate = WinlinkAirtimeEstimate.forGateway(
            callsign: "K0NTS-10", frequencyHz: 145_030, quality: quality)
        XCTAssertNil(estimate.sessionCapSeconds)
        XCTAssertEqual(estimate.sessionsRequired(bytes: 500_000), 1)
    }
}

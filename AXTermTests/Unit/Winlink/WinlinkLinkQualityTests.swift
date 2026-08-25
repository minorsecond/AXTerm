import XCTest
@testable import AXTerm

/// Empirical link quality: what AXTerm measured, qualified by where and
/// when it measured it.
final class WinlinkLinkQualityTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Denver-ish, and a point far enough away to be a different link.
    private let here = StationLocation(
        latitude: 39.7392, longitude: -104.9903,
        gridSquare: "DM79QL", source: .gps, timestamp: Date())
    private let farAway = StationLocation(
        latitude: 47.6062, longitude: -122.3321,
        gridSquare: "CN87UO", source: .gps, timestamp: Date())

    private func log(
        callsign: String = "W0ARP-10",
        frequencyHz: Int? = 145_050_000,
        transport: String = "ax25",
        result: String = "success",
        minutesAgo: Double = 60,
        durationSeconds: Double = 600,
        bytesSent: Int = 0,
        bytesReceived: Int = 0,
        at position: StationLocation? = nil
    ) -> WinlinkSessionLogRecord {
        let started = now.addingTimeInterval(-minutesAgo * 60)
        return WinlinkSessionLogRecord(
            id: nil,
            startedAt: started,
            endedAt: started.addingTimeInterval(durationSeconds),
            gatewayCallsign: callsign,
            transport: transport,
            result: result,
            messagesSent: 0,
            messagesReceived: 0,
            bytesSent: bytesSent,
            bytesReceived: bytesReceived,
            errorText: result == "success" ? nil : result,
            frequencyHz: frequencyHz,
            obsLatitude: position?.latitude,
            obsLongitude: position?.longitude,
            obsGrid: position?.gridSquare,
            obsSource: position?.source.rawValue)
    }

    private func summarize(
        _ logs: [WinlinkSessionLogRecord], observer: StationLocation?
    ) -> [String: WinlinkLinkQuality] {
        WinlinkLinkQuality.summarize(logs: logs, observer: observer, now: now)
    }

    private func only(_ result: [String: WinlinkLinkQuality]) -> WinlinkLinkQuality? {
        result.count == 1 ? result.values.first : nil
    }

    // MARK: - Link identity

    /// The same callsign on two frequencies is two links. W0ARP-10 runs
    /// 1200 bd on 145.050 and 9600 bd on 441.075; merging them would
    /// report the fast link's throughput on the slow one's row.
    func testFrequenciesAreSeparateLinks() {
        let result = summarize([
            log(frequencyHz: 145_050_000, bytesReceived: 6_000, at: here),
            log(frequencyHz: 441_075_000, bytesReceived: 60_000, at: here),
        ], observer: here)

        XCTAssertEqual(result.count, 2)
        let slow = result["W0ARP-10@145050000"]
        let fast = result["W0ARP-10@441075000"]
        XCTAssertEqual(slow?.effectiveBytesPerSecond ?? 0, 10, accuracy: 0.01)
        XCTAssertEqual(fast?.effectiveBytesPerSecond ?? 0, 100, accuracy: 0.01)
    }

    /// Telnet reaches the CMS over the internet. It proves nothing about
    /// any RF gateway and must never colour a station row.
    func testTelnetSessionsAreExcluded() {
        let result = summarize([
            log(transport: "telnet", bytesReceived: 500_000, at: here)
        ], observer: here)
        XCTAssertTrue(result.isEmpty)
    }

    /// "session busy — another session to W0ARP-10 is already active" is a
    /// fault on our side of the radio. Counting it against the gateway
    /// would make the column measure AXTerm rather than the link.
    func testLocalFaultsAreNotAttributedToTheGateway() {
        let result = summarize([
            log(result: "session busy — another session to W0ARP-10 is already active",
                durationSeconds: 1, at: here)
        ], observer: here)
        XCTAssertTrue(result.isEmpty, "a local fault is not evidence about the gateway")
    }

    func testLocalFaultsDoNotDiluteARealRecord() {
        let result = summarize([
            log(durationSeconds: 1_000, bytesReceived: 20_000, at: here),
            log(result: "session busy — another session to W0ARP-10 is already active",
                minutesAgo: 5, durationSeconds: 1, at: here),
        ], observer: here)

        let quality = only(result)
        XCTAssertEqual(quality?.attempts, 1, "only the real attempt counts")
        XCTAssertFalse(quality?.lastAttemptWasSilent ?? true,
                       "a local fault must not make a working gateway look silent")
    }

    /// A `.unknown` placement means we cannot prove where the samples came
    /// from — not that they came from somewhere else. It must not be
    /// rendered with the "elsewhere" treatment.
    func testUnknownPlacementIsNotPresentedAsElsewhere() {
        let quality = only(summarize(
            [log(durationSeconds: 1_000, bytesReceived: 20_000)], observer: here))
        let presentation = quality?.presentation(now: now)

        XCTAssertEqual(presentation?.tint, .neutral, "no colour-coded verdict without provenance")
        XCTAssertNotEqual(presentation?.systemImage, "location.slash",
                          "a location-slash icon claims the samples came from elsewhere")
        XCTAssertTrue(presentation?.text.contains("B/s") ?? false,
                      "the measurement is still reported: \(presentation?.text ?? "")")
        XCTAssertFalse(presentation?.text.contains("elsewhere") ?? true)
    }

    /// Legacy rows carry no frequency and are offered to every row for the
    /// callsign, so the tooltip has to admit which frequency it cannot
    /// distinguish.
    func testFrequencylessSamplesSayTheyCannotTellFrequenciesApart() {
        let quality = only(summarize(
            [log(frequencyHz: nil, durationSeconds: 1_000, bytesReceived: 20_000, at: here)],
            observer: here))
        let tooltip = quality?.presentation(now: now).tooltip ?? ""
        XCTAssertTrue(tooltip.contains("predate per-frequency logging"), tooltip)
    }

    // MARK: - Answered vs silent

    /// K0NTS-10 at 12:23 on 2026-08-23: called, nothing came back. That
    /// non-answer is the single most useful thing the column can say.
    func testConnectFailureCountsAsAttemptedButNotAnswered() {
        let result = summarize([
            log(callsign: "K0NTS-10", result: "connect failed: no response from K0NTS-10", durationSeconds: 90, at: here)
        ], observer: here)

        let quality = only(result)
        XCTAssertEqual(quality?.attempts, 1)
        XCTAssertEqual(quality?.answered, 0)
        XCTAssertEqual(quality?.answerRate ?? -1, 0, accuracy: 0.0001)
        XCTAssertTrue(quality?.lastAttemptWasSilent ?? false)
        XCTAssertEqual(quality?.presentation(now: now).tint, .bad)
        XCTAssertTrue(quality?.presentation(now: now).text.hasPrefix("No answer") ?? false)
    }

    /// A session that moved bytes answered, whatever the result string
    /// says about how it ended.
    func testFailureAfterBytesMovedStillCountsAsAnswered() {
        let result = summarize([
            log(result: "link lost", durationSeconds: 1_000, bytesReceived: 20_000, at: here)
        ], observer: here)

        let quality = only(result)
        XCTAssertEqual(quality?.answered, 1)
        XCTAssertEqual(quality?.completed, 0)
        XCTAssertFalse(quality?.lastAttemptWasSilent ?? true)
    }

    /// A gateway that answered before but not this time reads as silent —
    /// the newest evidence is the one that matters.
    func testMostRecentAttemptDecidesTheHeadline() {
        let result = summarize([
            log(minutesAgo: 300, durationSeconds: 1_000, bytesReceived: 30_000, at: here),
            log(result: "connect failed: no response", minutesAgo: 5, durationSeconds: 90, at: here),
        ], observer: here)

        let quality = only(result)
        XCTAssertEqual(quality?.attempts, 2)
        XCTAssertEqual(quality?.answered, 1)
        XCTAssertTrue(quality?.lastAttemptWasSilent ?? false)
    }

    // MARK: - Throughput

    func testGoodputIsPayloadOverConnectedTime() {
        let result = summarize([
            log(durationSeconds: 1_010, bytesSent: 300, bytesReceived: 27_000, at: here)
        ], observer: here)

        let quality = only(result)
        XCTAssertEqual(quality?.effectiveBytesPerSecond ?? 0, 27_300.0 / 1_010.0, accuracy: 0.01)
    }

    /// Sessions whose byte count was never captured (every pre-v8 failed
    /// session logged zero) must not divide into the ones that were, or a
    /// working gateway reads as 0 B/s forever.
    func testSessionsWithNoRecordedBytesDoNotDragTheRateDown() {
        let result = summarize([
            log(durationSeconds: 500, bytesReceived: 10_000, at: here),
            log(minutesAgo: 200, durationSeconds: 3_600, bytesReceived: 0, at: here),
        ], observer: here)

        let quality = only(result)
        XCTAssertEqual(quality?.answered, 2, "both sessions still answered")
        XCTAssertEqual(quality?.effectiveBytesPerSecond ?? 0, 20, accuracy: 0.01,
                       "goodput uses only the link time that produced the bytes")
    }

    /// A two-second session that moved forty bytes is not a 20 B/s link.
    func testTooLittleEvidenceReportsNoRate() {
        let result = summarize([
            log(durationSeconds: 2, bytesReceived: 40, at: here)
        ], observer: here)
        XCTAssertNil(only(result)?.effectiveBytesPerSecond)
    }

    /// Silent attempts contribute no connected time, so a gateway that
    /// answered once and failed ten times keeps its honest rate.
    func testSilentAttemptsDoNotDiluteTheRate() {
        var logs = [log(durationSeconds: 500, bytesReceived: 10_000, at: here)]
        for index in 0..<10 {
            logs.append(log(result: "connect failed: no response", minutesAgo: Double(index + 2), durationSeconds: 90, at: here))
        }
        let quality = only(summarize(logs, observer: here))
        XCTAssertEqual(quality?.effectiveBytesPerSecond ?? 0, 20, accuracy: 0.01)
        XCTAssertEqual(quality?.attempts, 11)
        XCTAssertEqual(quality?.answered, 1)
    }

    func testLongestSessionRecordsAnObservedGatewayCap() {
        let result = summarize([
            log(durationSeconds: 1_010, bytesReceived: 20_000, at: here),
            log(minutesAgo: 200, durationSeconds: 1_065, bytesReceived: 25_000, at: here),
        ], observer: here)
        XCTAssertEqual(only(result)?.longestSessionSeconds ?? 0, 1_065, accuracy: 0.5)
    }

    // MARK: - Geography

    func testSamplesTakenHereApplyHere() {
        let quality = only(summarize([log(bytesReceived: 20_000, at: here)], observer: here))
        XCTAssertEqual(quality?.placement, .here)
        XCTAssertTrue(quality?.appliesHere ?? false)
    }

    /// RF reach is a property of both endpoints. A measurement from
    /// Seattle says nothing about the same gateway from Denver.
    func testDistantSamplesAreReportedAsElsewhereAndNeverPredictive() {
        let quality = only(summarize(
            [log(bytesReceived: 20_000, at: farAway)], observer: here))

        guard case .elsewhere(let grid, let km)? = quality?.placement else {
            return XCTFail("expected .elsewhere, got \(String(describing: quality?.placement))")
        }
        XCTAssertEqual(grid, "CN87UO")
        XCTAssertGreaterThan(km, 1_500)
        XCTAssertFalse(quality?.appliesHere ?? true)

        let presentation = quality?.presentation(now: now)
        XCTAssertEqual(presentation?.tint, .neutral,
                       "a measurement from elsewhere must not be coloured as a verdict")
        XCTAssertTrue(presentation?.tooltip.contains("different link") ?? false)
    }

    /// If we have ever worked this gateway from here, that is the relevant
    /// evidence — a stray sample from a trip must not disqualify the row.
    func testNearestSampleDecidesPlacement() {
        let quality = only(summarize([
            log(bytesReceived: 20_000, at: farAway),
            log(minutesAgo: 30, bytesReceived: 20_000, at: here),
        ], observer: here))
        XCTAssertEqual(quality?.placement, .here)
    }

    /// A grid square is only as precise as the square. Claiming "here"
    /// from a 6-character locator would assert a path we cannot vouch for.
    func testGridDerivedPositionsCannotClaimFullPrecision() {
        let viaGrid = StationLocation(
            latitude: here.latitude, longitude: here.longitude,
            gridSquare: "DM79QL", source: .manualGrid, timestamp: now)
        let quality = only(summarize(
            [log(bytesReceived: 20_000, at: viaGrid)], observer: viaGrid))

        guard case .nearby(let km)? = quality?.placement else {
            return XCTFail("expected .nearby, got \(String(describing: quality?.placement))")
        }
        XCTAssertEqual(km, 3, accuracy: 0.01, "half a subsquare diagonal")
        XCTAssertTrue(quality?.appliesHere ?? false, "still usable, just not exact")
    }

    /// Logs written before migration v8 carry no position at all, and the
    /// column must say so rather than assume they were taken here.
    func testPositionlessSamplesAreUnknownNotAssumedLocal() {
        let quality = only(summarize([log(bytesReceived: 20_000)], observer: here))
        XCTAssertEqual(quality?.placement, .unknown)
        XCTAssertFalse(quality?.appliesHere ?? true)
        XCTAssertTrue(quality?.placementExplanation.contains("cannot tell") ?? false)
    }

    /// With no idea where we are, nothing can be claimed about relevance.
    func testNoObserverLeavesEverythingUnknown() {
        let quality = only(summarize(
            [log(bytesReceived: 20_000, at: here)], observer: nil))
        XCTAssertEqual(quality?.placement, .unknown)
    }

    // MARK: - Time

    func testSamplesBeyondTheHorizonAreDropped() {
        let result = WinlinkLinkQuality.summarize(
            logs: [log(minutesAgo: 200 * 24 * 60, bytesReceived: 20_000, at: here)],
            observer: here,
            horizon: 90 * 24 * 3600,
            now: now)
        XCTAssertTrue(result.isEmpty, "a year-old success is not evidence about today")
    }

    func testAgeIsAlwaysShown() {
        let quality = only(summarize(
            [log(minutesAgo: 120, durationSeconds: 600, bytesReceived: 20_000, at: here)],
            observer: here))
        XCTAssertTrue(quality?.presentation(now: now).text.contains("2h") ?? false,
                      quality?.presentation(now: now).text ?? "")
    }

    // MARK: - Tooltip

    /// CLAUDE.md §11: a metric must explain why it is what it is.
    func testTooltipShowsItsWorking() {
        let quality = only(summarize([
            log(durationSeconds: 1_010, bytesSent: 300, bytesReceived: 27_000, at: here),
            log(result: "connect failed: no response", minutesAgo: 200, durationSeconds: 90, at: here),
        ], observer: here))
        let tooltip = quality?.presentation(now: now).tooltip ?? ""

        XCTAssertTrue(tooltip.contains("W0ARP-10"), tooltip)
        XCTAssertTrue(tooltip.contains("145.050 MHz"), tooltip)
        XCTAssertTrue(tooltip.contains("Answered 1 of 2"), tooltip)
        XCTAssertTrue(tooltip.contains("B/s"), tooltip)
        XCTAssertTrue(tooltip.contains("Longest session"), tooltip)
        XCTAssertTrue(tooltip.contains("where you are now"), tooltip)
        XCTAssertTrue(tooltip.contains("not the CMS directory"), tooltip)
    }

    func testUnobservedLinkSaysSoPlainly() {
        let presentation = WinlinkLinkQuality.unobservedPresentation(
            callsign: "N0HI-10", frequencyHz: 145_050_000)
        XCTAssertEqual(presentation.text, "—")
        XCTAssertTrue(presentation.tooltip.contains("No exchange attempted"))
        XCTAssertTrue(presentation.tooltip.contains("N0HI-10"))
    }
}

//
//  CaptureCoverageTests.swift
//  AXTermTests
//
//  The coverage policy must be conservative: never claim we were listening
//  without evidence, and never blame the network for our own downtime.
//

import XCTest
@testable import AXTerm

final class CaptureCoverageTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func minutes(_ m: Double) -> Date { base.addingTimeInterval(m * 60) }

    // MARK: - Builder

    func testConnectDisconnectPairFormsInterval() {
        let coverage = CaptureCoverageBuilder.build(
            connectEvents: [minutes(0)],
            disconnectEvents: [minutes(30)],
            evidenceTimes: [],
            now: minutes(120),
            isCurrentlyConnected: false
        )
        XCTAssertEqual(coverage.intervals, [DateInterval(start: minutes(0), end: minutes(30))])
    }

    func testMissingDisconnectFallsBackToLastEvidence() {
        // The historical case: connects were logged, disconnects were not.
        let coverage = CaptureCoverageBuilder.build(
            connectEvents: [minutes(0), minutes(120)],
            disconnectEvents: [],
            evidenceTimes: [minutes(5), minutes(40), minutes(125)],
            now: minutes(200),
            isCurrentlyConnected: false
        )
        XCTAssertEqual(coverage.intervals.count, 2)
        XCTAssertEqual(coverage.intervals[0], DateInterval(start: minutes(0), end: minutes(40)),
                       "Interval ends at the last packet heard before the next connect")
        XCTAssertEqual(coverage.intervals[1], DateInterval(start: minutes(120), end: minutes(125)))
    }

    func testLiveSessionExtendsToNow() {
        let coverage = CaptureCoverageBuilder.build(
            connectEvents: [minutes(0)],
            disconnectEvents: [],
            evidenceTimes: [minutes(2)],
            now: minutes(90),
            isCurrentlyConnected: true
        )
        XCTAssertEqual(coverage.intervals, [DateInterval(start: minutes(0), end: minutes(90))],
                       "A live capture covers through now even if the channel is quiet")
    }

    func testConnectWithNoEvidenceProvesNothing() {
        // A connect followed by silence and no disconnect: we cannot show we
        // kept listening, so we claim nothing beyond the instant.
        let coverage = CaptureCoverageBuilder.build(
            connectEvents: [minutes(0), minutes(60)],
            disconnectEvents: [],
            evidenceTimes: [minutes(65)],
            now: minutes(200),
            isCurrentlyConnected: false
        )
        XCTAssertEqual(coverage.intervals, [DateInterval(start: minutes(60), end: minutes(65))])
    }

    func testPreEventEvidenceClustersIntoEstimatedSpans() {
        // History from before disconnect logging (or after event pruning):
        // packet clusters become estimated coverage; a 20-minute gap splits them.
        let coverage = CaptureCoverageBuilder.build(
            connectEvents: [],
            disconnectEvents: [],
            evidenceTimes: [minutes(0), minutes(5), minutes(10), minutes(30), minutes(33)],
            now: minutes(100),
            isCurrentlyConnected: false
        )
        XCTAssertEqual(coverage.intervals.count, 2)
        XCTAssertEqual(coverage.intervals[0], DateInterval(start: minutes(0), end: minutes(10)))
        XCTAssertEqual(coverage.intervals[1], DateInterval(start: minutes(30), end: minutes(33)))
    }

    // MARK: - Window math

    func testCoverageMathInWindow() {
        let coverage = CaptureCoverage(intervals: [
            DateInterval(start: minutes(0), end: minutes(30)),
            DateInterval(start: minutes(60), end: minutes(90))
        ])
        let window = DateInterval(start: minutes(15), end: minutes(75))

        XCTAssertEqual(coverage.coveredSeconds(in: window), 30 * 60, accuracy: 0.5)
        XCTAssertEqual(coverage.coverageFraction(in: window), 0.5, accuracy: 0.001)

        let gaps = coverage.uncoveredIntervals(in: window)
        XCTAssertEqual(gaps, [DateInterval(start: minutes(30), end: minutes(60))])
    }

    func testFullyUncoveredWindow() {
        let coverage = CaptureCoverage(intervals: [DateInterval(start: minutes(0), end: minutes(10))])
        let window = DateInterval(start: minutes(60), end: minutes(120))
        XCTAssertEqual(coverage.coverageFraction(in: window), 0)
        XCTAssertEqual(coverage.uncoveredIntervals(in: window), [window])
    }

    func testCoverageFractionByHour() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let dayStart = calendar.startOfDay(for: base)
        // Listening 09:00-09:30 only, over a 09:00-11:00 window.
        let coverage = CaptureCoverage(intervals: [
            DateInterval(start: dayStart.addingTimeInterval(9 * 3600), end: dayStart.addingTimeInterval(9 * 3600 + 1800))
        ])
        let window = DateInterval(
            start: dayStart.addingTimeInterval(9 * 3600),
            end: dayStart.addingTimeInterval(11 * 3600)
        )
        let byHour = coverage.coverageFractionByHour(in: window, calendar: calendar)
        XCTAssertEqual(byHour[9], 0.5, accuracy: 0.01)
        XCTAssertEqual(byHour[10], 0.0, accuracy: 0.01)
        XCTAssertEqual(byHour[8], 1.0, "Hours outside the window count as covered (nothing to miss)")
    }
}

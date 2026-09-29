import XCTest
@testable import AXTerm

/// Numbers shown to an operator are claims about evidence. These pin the
/// two that are easy to get wrong: a probe still in the air is not a
/// failure, and a round trip is reported as a median because the mean of a
/// long tail is a figure nothing measured.
final class PingStatisticsTests: XCTestCase {

    private let noon = Calendar.current.date(
        from: DateComponents(year: 2026, month: 9, day: 3, hour: 12))!

    private func attempt(_ call: String,
                         minutesAgo: Int,
                         outcome: PingProber.Attempt.Outcome,
                         rtt: TimeInterval? = nil,
                         kind: String? = nil,
                         escalated: Bool = false) -> PingProber.Attempt {
        let sent = noon.addingTimeInterval(TimeInterval(-minutesAgo * 60))
        return PingProber.Attempt(
            call: call, sentAt: sent,
            answeredAt: outcome == .answered ? sent.addingTimeInterval(rtt ?? 1) : nil,
            rtt: outcome == .answered ? (rtt ?? 1) : nil,
            answerKind: outcome == .answered ? (kind ?? "XID") : nil,
            escalated: escalated, manual: false, outcome: outcome)
    }

    // MARK: - Summary

    func testTheSummaryCountsWhatFinishedAndWhatAnswered() {
        let stats = PingStatistics.summary([
            attempt("AB0VZ-7", minutesAgo: 30, outcome: .answered, rtt: 1.2),
            attempt("AB0VZ-7", minutesAgo: 20, outcome: .silent),
            attempt("K0NTS-1", minutesAgo: 10, outcome: .answered, rtt: 3.0)])

        XCTAssertEqual(stats.completed, 3)
        XCTAssertEqual(stats.answered, 2)
        XCTAssertEqual(stats.silent, 1)
        XCTAssertEqual(stats.stations, 2)
        XCTAssertEqual(stats.answerRate ?? 0, 2.0 / 3.0, accuracy: 0.0001)
    }

    /// A probe on the air has not failed. Counting it as one makes the
    /// answer rate dip every time a probe goes out and recover when it
    /// lands — a rate that measures when you looked, not what happened.
    func testAProbeStillInTheAirIsNotASilence() {
        let stats = PingStatistics.summary([
            attempt("AB0VZ-7", minutesAgo: 10, outcome: .answered, rtt: 1),
            attempt("K0NTS-1", minutesAgo: 0, outcome: .waiting)])

        XCTAssertEqual(stats.waiting, 1)
        XCTAssertEqual(stats.completed, 1)
        XCTAssertEqual(stats.answerRate, 1.0, "one probe finished, and it answered")
    }

    /// "0%" claims every probe failed; nothing having finished claims
    /// nothing. They are different statements.
    func testNothingFinishedHasNoRateRatherThanZero() {
        let stats = PingStatistics.summary([
            attempt("K0NTS-1", minutesAgo: 0, outcome: .waiting)])
        XCTAssertNil(stats.answerRate)
        XCTAssertNil(stats.medianRTT)
    }

    func testAnswersThatNeededTheDISCFallbackAreCountedApart() {
        let stats = PingStatistics.summary([
            attempt("W0ARP-10", minutesAgo: 5, outcome: .answered, rtt: 2, kind: "DM",
                    escalated: true),
            attempt("AB0VZ-7", minutesAgo: 4, outcome: .answered, rtt: 1)])
        XCTAssertEqual(stats.escalatedAnswers, 1)
    }

    /// A busy channel adds seconds to one probe and says nothing about the
    /// path. The median ignores it; a mean would report 4 s for a link
    /// whose round trip is one.
    func testLatencyIsAMedianSoOneBusyChannelDoesNotSetIt() {
        let stats = PingStatistics.summary([
            attempt("AB0VZ-7", minutesAgo: 5, outcome: .answered, rtt: 1.0),
            attempt("AB0VZ-7", minutesAgo: 4, outcome: .answered, rtt: 1.1),
            attempt("AB0VZ-7", minutesAgo: 3, outcome: .answered, rtt: 11.0)])
        XCTAssertEqual(stats.medianRTT, 1.1)
        XCTAssertEqual(stats.fastestRTT, 1.0)
        XCTAssertEqual(stats.slowestRTT, 11.0)
    }

    func testTheLowerSampleIsTakenRatherThanAveragingTwo() {
        XCTAssertEqual(PingStatistics.median([1.0, 2.0]), 1.0,
                       "averaging invents a round trip nothing measured")
        XCTAssertNil(PingStatistics.median([]))
    }

    // MARK: - Per station

    func testStationRowsRollUpEachAddressNewestFirst() {
        let rows = PingStatistics.stations(
            attempts: [
                attempt("AB0VZ-7", minutesAgo: 60, outcome: .answered, rtt: 1.0),
                attempt("AB0VZ-7", minutesAgo: 30, outcome: .silent),
                attempt("K0NTS-1", minutesAgo: 5, outcome: .silent)],
            records: [:])

        XCTAssertEqual(rows.map(\.call), ["K0NTS-1", "AB0VZ-7"])
        let ab0vz = rows.first { $0.call == "AB0VZ-7" }
        XCTAssertEqual(ab0vz?.answered, 1)
        XCTAssertEqual(ab0vz?.silent, 1)
        XCTAssertEqual(ab0vz?.answerRate, 0.5)
        XCTAssertEqual(ab0vz?.medianRTT, 1.0)
    }

    /// The log is bounded; the running totals are not. A station probed
    /// for weeks has counts older than any attempt still stored, and the
    /// row must report every probe rather than only the surviving ones.
    func testTotalsComeFromTheRecordWhenTheLogHasAgedOut() {
        let record = PingProber.Record(
            call: "AB0VZ-7", lastProbed: noon.addingTimeInterval(-1800),
            lastAnswered: noon.addingTimeInterval(-1799), lastRTT: 0.8,
            lastAnswerKind: "XID", consecutiveSilences: 0, probes: 58, answers: 44)

        let rows = PingStatistics.stations(
            attempts: [attempt("AB0VZ-7", minutesAgo: 30, outcome: .answered, rtt: 0.8)],
            records: ["AB0VZ-7": record])

        let row = rows.first
        XCTAssertEqual(row?.probes, 58, "not the one attempt still in the log")
        XCTAssertEqual(row?.answered, 44)
        XCTAssertEqual(row?.lastRTT, 0.8)
    }

    /// A station whose probes have all aged out of the log was still
    /// asked, and what came of it is the point of the list.
    func testAStationWithNoSurvivingAttemptsStillAppears() {
        let record = PingProber.Record(
            call: "WH6ANH", lastProbed: noon.addingTimeInterval(-86_400),
            consecutiveSilences: 9, probes: 9, answers: 0)
        let rows = PingStatistics.stations(attempts: [], records: ["WH6ANH": record])

        XCTAssertEqual(rows.map(\.call), ["WH6ANH"])
        XCTAssertEqual(rows.first?.answerRate, 0.0)
        XCTAssertEqual(rows.first?.consecutiveSilences, 9)
    }

    // MARK: - Hourly shape

    /// The empty hours are as much of the shape as the busy ones: a gap
    /// says the prober held off, and dropping it would draw a solid wall.
    func testHourlyBucketsIncludeTheHoursWithNothingInThem() {
        let buckets = PingStatistics.hourly(
            [attempt("AB0VZ-7", minutesAgo: 90, outcome: .answered, rtt: 1),
             attempt("K0NTS-1", minutesAgo: 30, outcome: .silent)],
            now: noon, hours: 6)

        // Buckets run 07:00 through 12:00. Ninety minutes before noon is
        // 10:30 and lands in the 10:00 hour; thirty minutes before is
        // 11:30 and lands in the 11:00 one.
        XCTAssertEqual(buckets.count, 6)
        XCTAssertEqual(buckets.map(\.probes).reduce(0, +), 2)
        XCTAssertEqual(buckets[3].answered, 1)
        XCTAssertEqual(buckets[4].silent, 1)
        XCTAssertEqual(buckets.map(\.probes), [0, 0, 0, 1, 1, 0],
                       "the quiet hours are part of the shape")
    }

    func testProbesOlderThanTheWindowAreLeftOut() {
        let buckets = PingStatistics.hourly(
            [attempt("AB0VZ-7", minutesAgo: 60 * 40, outcome: .answered, rtt: 1)],
            now: noon, hours: 24)
        XCTAssertEqual(buckets.map(\.probes).reduce(0, +), 0)
    }
}

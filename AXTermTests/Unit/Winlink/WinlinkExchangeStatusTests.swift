//
//  WinlinkExchangeStatusTests.swift
//  AXTermTests
//

import XCTest
@testable import AXTerm

final class WinlinkExchangeStatusTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Terminal states

    func testFailureCarriesTheGatewaysOwnReason() {
        let status = WinlinkExchangeStatus.make(
            phase: .failed("the CMS refused the connection: Unknown client types are not allowed"),
            statusText: "", progress: nil, summary: nil)
        XCTAssertEqual(status.kind, .failed)
        // The reason is the whole value of the banner; paraphrasing it would
        // send the operator to the transcript to find the real words.
        XCTAssertEqual(status.detail,
                       "the CMS refused the connection: Unknown client types are not allowed")
    }

    func testCompletionWithNothingMovedSaysSoPlainly() {
        var summary = WinlinkExchangeSummary()
        summary.sentMIDs = []
        summary.receivedMIDs = []
        let status = WinlinkExchangeStatus.make(
            phase: .done, statusText: "", progress: nil, summary: summary)
        XCTAssertEqual(status.kind, .succeeded)
        // An empty exchange is the commonest success and the one most often
        // misread as a failure.
        XCTAssertEqual(status.detail, "Nothing queued either way — the mailbox is up to date.")
    }

    func testCompletionCountsAreSingularWhenOne() {
        var summary = WinlinkExchangeSummary()
        summary.sentMIDs = ["2QBFS5QVFFPM"]
        let status = WinlinkExchangeStatus.make(
            phase: .done, statusText: "", progress: nil, summary: summary)
        XCTAssertEqual(status.detail, "Sent 1 message")
    }

    func testCompletionReportsBothDirections() {
        var summary = WinlinkExchangeSummary()
        summary.sentMIDs = ["A", "B"]
        summary.receivedMIDs = ["C"]
        let status = WinlinkExchangeStatus.make(
            phase: .done, statusText: "", progress: nil, summary: summary)
        XCTAssertEqual(status.detail, "Sent 2 messages · Received 1 message")
    }

    func testIdleIsNotDressedUpAsWorking() {
        let status = WinlinkExchangeStatus.make(
            phase: .idle, statusText: "", progress: nil, summary: nil)
        XCTAssertEqual(status.kind, .idle)
        XCTAssertFalse(status.isWorking)
        XCTAssertNil(status.fraction)
    }

    // MARK: - Live phases

    func testConnectingWithoutProgressStillNamesThePhase() {
        let status = WinlinkExchangeStatus.make(
            phase: .connecting, statusText: "Calling W0ARP-10\u{2026}",
            progress: nil, summary: nil)
        XCTAssertEqual(status.kind, .working)
        XCTAssertEqual(status.title, "Connecting")
        XCTAssertEqual(status.detail, "Calling W0ARP-10\u{2026}")
    }

    func testProgressKindOverridesThePhaseTitle() {
        let progress = WinlinkExchangeProgress(
            kind: .receiving, bytesDone: 0, bytesTotal: 4096, startedAt: start)
        let status = WinlinkExchangeStatus.make(
            phase: .exchanging, statusText: "busy", progress: progress, summary: nil)
        // "Exchanging" is true but useless; the operator wants the direction.
        XCTAssertEqual(status.title, "Receiving")
    }

    func testSubjectBeatsGenericStatusTextAsDetail() {
        let progress = WinlinkExchangeProgress(
            kind: .sending, subject: "ICS-213 General Message",
            bytesDone: 100, bytesTotal: 1000, startedAt: start)
        let status = WinlinkExchangeStatus.make(
            phase: .exchanging, statusText: "Sending\u{2026}",
            progress: progress, summary: nil)
        XCTAssertEqual(status.detail, "ICS-213 General Message")
    }

    func testFractionIsReportedWhenTheSizeIsKnown() {
        let progress = WinlinkExchangeProgress(
            kind: .receiving, bytesDone: 512, bytesTotal: 1024, startedAt: start)
        let status = WinlinkExchangeStatus.make(
            phase: .exchanging, statusText: "", progress: progress, summary: nil)
        XCTAssertEqual(try XCTUnwrap(status.fraction), 0.5, accuracy: 0.001)
        XCTAssertEqual(status.byteSummary, "512 B of 1.0 KB")
    }

    func testIndeterminateTransferHasNoFractionButStillCounts() {
        let progress = WinlinkExchangeProgress(
            kind: .receiving, bytesDone: 300, bytesTotal: 0, startedAt: start)
        let status = WinlinkExchangeStatus.make(
            phase: .exchanging, statusText: "", progress: progress, summary: nil)
        XCTAssertNil(status.fraction)
        XCTAssertEqual(status.byteSummary, "300 B")
    }

    func testRateAndEstimateAppearOnceTheTransferHasRun() {
        let progress = WinlinkExchangeProgress(
            kind: .receiving, bytesDone: 1000, bytesTotal: 2000, startedAt: start)
        let status = WinlinkExchangeStatus.make(
            phase: .exchanging, statusText: "", progress: progress, summary: nil,
            now: start.addingTimeInterval(10))
        // 1000 bytes in 10s → 100 B/s, 1000 left → about 10s.
        XCTAssertEqual(status.rateSummary, "100 B/s · about 10s left")
    }

    func testResumedBytesDoNotInflateTheRate() {
        // Bytes carried in from an interrupted session never crossed the air
        // here, so charging them to this session's rate would overstate it.
        let progress = WinlinkExchangeProgress(
            kind: .receiving, bytesDone: 1100, bytesTotal: 2000,
            baselineBytes: 1000, startedAt: start)
        let status = WinlinkExchangeStatus.make(
            phase: .exchanging, statusText: "", progress: progress, summary: nil,
            now: start.addingTimeInterval(10))
        // 100 real bytes in 10s → 10 B/s; 900 left → 90s, which reads as "1m 30s".
        XCTAssertEqual(status.rateSummary, "10 B/s · about 1m 30s left")
    }

    func testNoRateBeforeAnyTimeHasPassed() {
        let progress = WinlinkExchangeProgress(
            kind: .receiving, bytesDone: 10, bytesTotal: 100, startedAt: start)
        let status = WinlinkExchangeStatus.make(
            phase: .exchanging, statusText: "", progress: progress, summary: nil,
            now: start)
        XCTAssertNil(status.rateSummary, "A rate from a zero-length window is noise")
    }

    // MARK: - Formatting helpers

    func testDurationsReadInHumanUnits() {
        XCTAssertEqual(WinlinkExchangeStatus.duration(45), "45s")
        XCTAssertEqual(WinlinkExchangeStatus.duration(60), "1m")
        XCTAssertEqual(WinlinkExchangeStatus.duration(95), "1m 35s")
        XCTAssertEqual(WinlinkExchangeStatus.duration(3600), "1h 0m")
    }

    func testByteSizesStayHonestAtPacketScale() {
        XCTAssertEqual(WinlinkExchangeStatus.compact(0), "0 B")
        XCTAssertEqual(WinlinkExchangeStatus.compact(999), "999 B")
        XCTAssertEqual(WinlinkExchangeStatus.compact(1024), "1.0 KB")
        XCTAssertEqual(WinlinkExchangeStatus.compact(2 * 1024 * 1024), "2.0 MB")
    }

    func testEachKindHasItsOwnSymbol() {
        let symbols = Set([
            WinlinkExchangeStatus(kind: .idle, title: "").symbol,
            WinlinkExchangeStatus(kind: .working, title: "").symbol,
            WinlinkExchangeStatus(kind: .succeeded, title: "").symbol,
            WinlinkExchangeStatus(kind: .failed, title: "").symbol,
        ])
        XCTAssertEqual(symbols.count, 4, "A glance must distinguish the four states")
    }
}

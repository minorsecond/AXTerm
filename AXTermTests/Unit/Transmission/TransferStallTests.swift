//
//  TransferStallTests.swift
//  AXTermTests
//
//  A receiver cannot be told that the sender paused: AXDP has no pause
//  message, and neither does YAPP. What it can see is that data stopped
//  arriving. These tests pin down when a quiet transfer counts as waiting
//  for the sender, and that the rate does not sink while nothing moves.
//  Bug 8 in Docs/LiveRFTest-2026-09-30.md.
//

import XCTest
@testable import AXTerm

final class TransferPaceTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Progress at `t0 + offsets[i]`.
    private func pace(_ offsets: [TimeInterval]) -> TransferPace {
        var pace = TransferPace()
        for offset in offsets { pace.noteProgress(at: t0.addingTimeInterval(offset)) }
        return pace
    }

    func testNothingReceivedYetIsNotWaiting() {
        XCTAssertNil(TransferPace().quietSeconds(now: t0.addingTimeInterval(600)))
    }

    func testSteadyChunksAreNotWaiting() {
        let p = pace(stride(from: 0, through: 20, by: 2).map { $0 })
        XCTAssertNil(p.quietSeconds(now: t0.addingTimeInterval(20 + 5)))
    }

    func testFastChunksGoQuietAfterTheFloor() {
        let p = pace(Array(0...10).map(TimeInterval.init))
        XCTAssertNil(p.quietSeconds(now: t0.addingTimeInterval(10 + 14)),
                     "a few seconds of silence is an ordinary exchange")
        let quiet = p.quietSeconds(now: t0.addingTimeInterval(10 + 16))
        XCTAssertNotNil(quiet, "past the 15 s floor the receiver is waiting")
        XCTAssertEqual(quiet ?? 0, 16, accuracy: 0.01)
    }

    func testSlowChunksGetALongerAllowance() {
        // A chunk every 10 s: 30 s without one is still a normal gap.
        let p = pace(stride(from: 0, through: 100, by: 10).map { $0 })
        XCTAssertNil(p.quietSeconds(now: t0.addingTimeInterval(100 + 30)))
        XCTAssertNotNil(p.quietSeconds(now: t0.addingTimeInterval(100 + 45)))
    }

    func testBurstsOfAWindowAtATimeAreNotWaiting() {
        // K=2: two frames back to back, then a wait for the RR.
        var offsets: [TimeInterval] = []
        for round in 0..<10 {
            let base = TimeInterval(round) * 6
            offsets.append(base)
            offsets.append(base + 0.2)
        }
        let p = pace(offsets)
        XCTAssertNil(p.quietSeconds(now: t0.addingTimeInterval(offsets.last! + 8)))
    }

    func testDataArrivingAgainEndsTheWait() {
        var p = pace(Array(0...10).map(TimeInterval.init))
        XCTAssertNotNil(p.quietSeconds(now: t0.addingTimeInterval(100)))
        p.noteProgress(at: t0.addingTimeInterval(100))
        XCTAssertNil(p.quietSeconds(now: t0.addingTimeInterval(101)))
    }

    func testAPauseIsSetAsideFromDataTime() {
        // One chunk a second, a two-minute pause, then one more chunk.
        var offsets = Array(0...10).map(TimeInterval.init)
        offsets.append(130)
        let p = pace(offsets)
        // The 120 s gap counts as one ordinary 1 s interval.
        XCTAssertEqual(p.stalledSeconds, 119, accuracy: 0.5)
    }

    func testOrdinaryGapsAreNotSetAside() {
        let p = pace(stride(from: 0, through: 20, by: 2).map { $0 })
        XCTAssertEqual(p.stalledSeconds, 0)
    }

    /// Smoke run 2026-10-03-1, issue 14: a 720-byte chunk takes about 27 s at
    /// 250 bps. Every gap was over the 15 s floor before any usual gap was
    /// known, so every gap was set aside as a stall, the data time came out
    /// near zero, and the row showed 212 Mbps and "0s remaining".
    func testSlowChunksAreTheirPaceNotStalls() {
        let p = pace(stride(from: 0, through: 270, by: 27).map { $0 })
        XCTAssertEqual(p.stalledSeconds, 0)
        XCTAssertNil(p.quietSeconds(now: t0.addingTimeInterval(270 + 30)),
                     "the next chunk is not late yet")
        XCTAssertNotNil(p.quietSeconds(now: t0.addingTimeInterval(270 + 120)))
    }

    /// A first gap far longer than any chunk takes is a pause, not a pace.
    func testAVeryLongFirstGapIsAStall() {
        let p = pace([0, 300, 302, 304, 306])
        XCTAssertEqual(p.stalledSeconds, 300, accuracy: 0.5)
        XCTAssertEqual(p.typicalInterval ?? 0, 2, accuracy: 0.01)
    }
}

final class BulkTransferStallTests: XCTestCase {
    private func receiving(bytes: Int = 1_000) -> BulkTransfer {
        var transfer = BulkTransfer(id: UUID(), fileName: "t20k_bin.bin", fileSize: 20_480,
                                    destination: "K0EPI-3", chunkSize: 128, direction: .inbound)
        transfer.status = .sending
        transfer.startedAt = Date(timeIntervalSinceNow: -10)
        transfer.bytesSent = bytes
        return transfer
    }

    func testAReceiverWithDataFlowingIsReceiving() {
        let transfer = receiving()
        XCTAssertNil(transfer.secondsWaitingForSender(now: Date().addingTimeInterval(5)))
        XCTAssertTrue(transfer.showsLiveRate(now: Date().addingTimeInterval(5)))
    }

    func testAReceiverThatHearsNothingIsWaitingForTheSender() {
        let transfer = receiving()
        let later = Date().addingTimeInterval(60)
        XCTAssertNotNil(transfer.secondsWaitingForSender(now: later))
        XCTAssertFalse(transfer.showsLiveRate(now: later), "no live rate while nothing arrives")
    }

    func testTheReceiverGoesBackToReceivingWhenDataFlows() {
        var transfer = receiving()
        let later = Date().addingTimeInterval(60)
        XCTAssertNotNil(transfer.secondsWaitingForSender(now: later))
        transfer.bytesSent += 128
        XCTAssertNil(transfer.secondsWaitingForSender(now: Date().addingTimeInterval(1)))
    }

    func testOnlyAReceiverWaitsForTheSender() {
        var transfer = BulkTransfer(id: UUID(), fileName: "a.bin", fileSize: 20_480,
                                    destination: "K0EPI-2", direction: .outbound)
        transfer.status = .sending
        transfer.startedAt = Date(timeIntervalSinceNow: -10)
        transfer.bytesSent = 1_000
        XCTAssertNil(transfer.secondsWaitingForSender(now: Date().addingTimeInterval(60)))
    }

    func testAPausedSenderShowsNoLiveRate() {
        var transfer = BulkTransfer(id: UUID(), fileName: "a.bin", fileSize: 20_480,
                                    destination: "K0EPI-2", direction: .outbound)
        transfer.status = .sending
        transfer.startedAt = Date(timeIntervalSinceNow: -10)
        transfer.bytesSent = 1_000
        transfer.status = .paused
        XCTAssertFalse(transfer.showsLiveRate(now: Date()))
    }

    func testTheRateHoldsStillWhileNothingArrives() {
        let transfer = receiving()
        let now = Date()
        let rate = transfer.throughputBytesPerSecond(now: now)
        XCTAssertEqual(rate, 100, accuracy: 5)
        XCTAssertEqual(transfer.throughputBytesPerSecond(now: now.addingTimeInterval(300)), rate,
                       accuracy: 0.5, "a pause must not drag the rate down")
    }

    func testTheRateLeavesAPauseOut() {
        // One 100-byte chunk a second for 10 s, a 120 s pause, one more chunk.
        let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var transfer = receiving(bytes: 1_100)
        transfer.startedAt = t0
        transfer.dataPhaseStartedAt = t0
        var pace = TransferPace()
        for second in 1...10 { pace.noteProgress(at: t0.addingTimeInterval(TimeInterval(second))) }
        pace.noteProgress(at: t0.addingTimeInterval(130))
        transfer.pace = pace
        // 1100 bytes over 11 s of data, not over 130 s.
        XCTAssertEqual(transfer.throughputBytesPerSecond(now: t0.addingTimeInterval(131)), 100, accuracy: 5)
    }

    func testTimeRemainingDoesNotGrowWhileNothingArrives() {
        let transfer = receiving()
        let now = Date()
        let eta = transfer.estimatedSecondsRemaining(now: now)
        XCTAssertNotNil(eta)
        XCTAssertEqual(transfer.estimatedSecondsRemaining(now: now.addingTimeInterval(600)) ?? 0,
                       eta ?? 0, accuracy: 1)
    }
}

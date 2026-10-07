//
//  FirstChunkRateTests.swift
//  AXTermTests
//
//  An inbound transfer's clock starts when its first chunk arrives, and
//  until a second one comes the last data is that same moment: the first
//  chunk's bytes over a few microseconds, shown as 206.61 Mbps on the
//  iPad (smoke run 2026-10-03-1, 13.4, issue 109). No rate is shown until
//  data has been measured over at least a second.
//

import XCTest
@testable import AXTerm

final class FirstChunkRateTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Bytes are set before the pace: setting them notes progress at the
    /// real time, which would sit far off this test's timeline.
    private func receiving(bytes: Int, progressAt offsets: [TimeInterval]) -> BulkTransfer {
        var transfer = BulkTransfer(id: UUID(), fileName: "t20k_bin.bin", fileSize: 20_480,
                                    destination: "K0EPI-2", chunkSize: 1024, direction: .inbound)
        transfer.status = .sending
        transfer.startedAt = t0
        transfer.dataPhaseStartedAt = t0
        transfer.bytesSent = bytes
        var pace = TransferPace()
        for offset in offsets { pace.noteProgress(at: t0.addingTimeInterval(offset)) }
        transfer.pace = pace
        return transfer
    }

    private func receivingFirstChunk() -> BulkTransfer {
        receiving(bytes: 1024, progressAt: [0.00004])
    }

    func testOneChunkShowsNoRate() {
        let transfer = receivingFirstChunk()
        XCTAssertEqual(transfer.throughputBytesPerSecond(now: t0.addingTimeInterval(1)), 0)
        XCTAssertNil(transfer.estimatedSecondsRemaining(now: t0.addingTimeInterval(1)))
    }

    func testTheSecondChunkGivesARate() {
        let transfer = receiving(bytes: 2048, progressAt: [0.00004, 8])
        XCTAssertEqual(transfer.throughputBytesPerSecond(now: t0.addingTimeInterval(9)), 256, accuracy: 1)
    }
}

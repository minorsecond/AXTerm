//
//  ActiveTransfersChipTests.swift
//  AXTermTests
//
//  What the always-visible transfer chip says. During a 20 KB transfer in
//  the smoke run (issue 91, 2026-10-06), neither station showed anything on
//  the Session tab or anywhere else; the progress bar lived only on the
//  Transfers tab, with no badge to say it was there.
//

import XCTest
@testable import AXTerm

final class ActiveTransfersChipTests: XCTestCase {

    private func transfer(_ name: String, size: Int = 20_000, to station: String = "K0EPI-3",
                          direction: TransferDirection = .outbound,
                          status: BulkTransferStatus, sent: Int = 0) -> BulkTransfer {
        var t = BulkTransfer(id: UUID(), fileName: name, fileSize: size, destination: station,
                             direction: direction)
        t.status = status
        t.bytesSent = sent
        return t
    }

    func testNothingActiveShowsNoChip() {
        XCTAssertNil(ActiveTransfersSummary.make([]))
        XCTAssertNil(ActiveTransfersSummary.make([transfer("a.bin", status: .completed, sent: 20_000),
                                                  transfer("b.bin", status: .cancelled),
                                                  transfer("c.bin", status: .failed(reason: "x"))]))
    }

    func testOneSendingTransferShowsItsFileStationAndProgress() throws {
        let summary = try XCTUnwrap(ActiveTransfersSummary.make([transfer("t20k_bin.bin", status: .sending, sent: 10_400)]))
        XCTAssertEqual(summary.count, 1)
        XCTAssertEqual(summary.title, "t20k_bin.bin")
        XCTAssertEqual(summary.direction, .outbound)
        XCTAssertEqual(summary.fraction ?? 0, 0.52, accuracy: 0.001)
        XCTAssertEqual(summary.label, "t20k_bin.bin 52%")
        XCTAssertEqual(summary.detail, "Sending t20k_bin.bin to K0EPI-3: 52%")
    }

    func testReceivingNamesWhereItComesFrom() throws {
        let summary = try XCTUnwrap(ActiveTransfersSummary.make([
            transfer("t20k_bin.bin", to: "K0EPI-2", direction: .inbound, status: .sending, sent: 5_000)]))
        XCTAssertEqual(summary.direction, .inbound)
        XCTAssertEqual(summary.detail, "Receiving t20k_bin.bin from K0EPI-2: 25%")
    }

    func testWaitingAndPausedSayWhatTheyAreWaitingOn() throws {
        let waiting = try XCTUnwrap(ActiveTransfersSummary.make([transfer("a.bin", status: .awaitingAcceptance)]))
        XCTAssertNil(waiting.fraction, "nothing has moved yet")
        XCTAssertEqual(waiting.label, "a.bin waiting")
        XCTAssertEqual(waiting.detail, "Waiting for K0EPI-3 to accept a.bin")

        let paused = try XCTUnwrap(ActiveTransfersSummary.make([transfer("a.bin", status: .paused, sent: 5_000)]))
        XCTAssertEqual(paused.label, "a.bin paused")
        XCTAssertEqual(paused.detail, "Sending a.bin to K0EPI-3: paused at 25%")

        let finishing = try XCTUnwrap(ActiveTransfersSummary.make([transfer("a.bin", status: .awaitingCompletion, sent: 20_000)]))
        XCTAssertEqual(finishing.detail, "Sending a.bin to K0EPI-3: all sent, waiting for K0EPI-3 to confirm")
    }

    func testSeveralAtOnceAreCountedWithTheirCombinedProgress() throws {
        let summary = try XCTUnwrap(ActiveTransfersSummary.make([
            transfer("a.bin", size: 10_000, status: .sending, sent: 10_000),
            transfer("b.bin", size: 30_000, status: .sending, sent: 0),
            transfer("done.bin", status: .completed, sent: 20_000)]))
        XCTAssertEqual(summary.count, 2)
        XCTAssertEqual(summary.title, "2 transfers")
        XCTAssertNil(summary.direction)
        XCTAssertEqual(summary.fraction ?? 0, 0.25, accuracy: 0.001)
        XCTAssertEqual(summary.label, "2 transfers 25%")
    }

    /// The iPhone and iPad card's second line (park rehearsal 2026-10-08:
    /// the chip's thin bar and percent were too small to read).
    func testTheCardSaysHowMuchAndHowLongIsLeft() {
        XCTAssertEqual(ActiveTransfersSummary.progressLine(moved: 12_288, total: 24_576, secondsLeft: 170),
                       "12 KB of 25 KB · about 3 min left")
        XCTAssertEqual(ActiveTransfersSummary.progressLine(moved: 12_288, total: 24_576, secondsLeft: nil),
                       "12 KB of 25 KB", "no estimate until there is a rate")
        XCTAssertEqual(ActiveTransfersSummary.progressLine(moved: 0, total: 24_576, secondsLeft: 40),
                       "0 bytes of 25 KB · under a minute left")
    }

    func testTimeLeftIsSaidTheSameWayEverywhere() {
        XCTAssertEqual(TimeLeftPhrase.text(seconds: 50), "under a minute left")
        XCTAssertEqual(TimeLeftPhrase.text(seconds: 170), "about 3 min left")
        XCTAssertEqual(TimeLeftPhrase.text(seconds: 6_647), "about 1 h 51 min left")
        XCTAssertEqual(TimeLeftPhrase.text(seconds: 7_200), "about 2 h left")
    }
}

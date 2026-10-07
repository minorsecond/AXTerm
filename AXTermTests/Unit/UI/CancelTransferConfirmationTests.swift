//
//  CancelTransferConfirmationTests.swift
//  AXTermTests
//
//  The red cancel button ended a running transfer on one tap, and a
//  canceled transfer cannot be resumed (smoke run 2026-10-03-1, 13.4,
//  issue 114). It asks first while data is moving; a transfer still
//  waiting or paused has nothing to lose and cancels at once.
//

import XCTest
@testable import AXTerm

final class CancelTransferConfirmationTests: XCTestCase {

    func testARunningTransferAsksFirst() {
        XCTAssertTrue(CancelTransferPrompt.isNeeded(for: .sending))
        XCTAssertTrue(CancelTransferPrompt.isNeeded(for: .awaitingCompletion))
    }

    func testAWaitingOrPausedTransferCancelsAtOnce() {
        XCTAssertFalse(CancelTransferPrompt.isNeeded(for: .pending))
        XCTAssertFalse(CancelTransferPrompt.isNeeded(for: .awaitingAcceptance))
        XCTAssertFalse(CancelTransferPrompt.isNeeded(for: .paused))
    }

    func testTheWordingFollowsTheDirection() {
        var receiving = BulkTransfer(id: UUID(), fileName: "t20k_bin.bin", fileSize: 20_480,
                                     destination: "K0EPI-2", direction: .inbound)
        receiving.status = .sending
        let inbound = CancelTransferPrompt(transfer: receiving)
        XCTAssertEqual(inbound.title, "Cancel receiving t20k_bin.bin?")
        XCTAssertEqual(inbound.keepLabel, "Keep Receiving")

        let sending = CancelTransferPrompt(transfer: BulkTransfer(id: UUID(), fileName: "a.txt", fileSize: 3,
                                                                  destination: "K0EPI-3"))
        XCTAssertEqual(sending.title, "Cancel sending a.txt?")
        XCTAssertEqual(sending.keepLabel, "Keep Sending")
        XCTAssertEqual(sending.cancelLabel, "Cancel Transfer")
    }
}

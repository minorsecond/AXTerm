//
//  DeclinedTransferTests.swift
//  AXTermTests
//
//  A declined offer is the other station's choice, not a fault. The sender
//  listed it as a red "Failed" row (smoke run 2026-10-03-1, test 13.3,
//  issue 107).
//

import XCTest
@testable import AXTerm

final class DeclinedTransferTests: XCTestCase {

    private func transfer(_ status: BulkTransferStatus) -> BulkTransfer {
        var t = BulkTransfer(id: UUID(), fileName: "t1k_bin.bin", fileSize: 1024,
                             destination: "K0EPI-3", direction: .outbound)
        t.status = status
        return t
    }

    func testARemoteDeclineReadsAsDeclined() {
        XCTAssertTrue(transfer(.failed(reason: BulkTransfer.declinedByRemoteReason)).wasDeclined)
        XCTAssertTrue(transfer(.failed(reason: "Declined: file too large")).wasDeclined,
                      "an offer refused by a rule says why after \"Declined:\"")
    }

    func testARealFailureIsStillAFailure() {
        XCTAssertFalse(transfer(.failed(reason: "Receiver failed to save file - transfer unsuccessful")).wasDeclined)
        XCTAssertFalse(transfer(.cancelled).wasDeclined)
        XCTAssertFalse(transfer(.completed).wasDeclined)
    }
}

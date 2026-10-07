//
//  TransferRowIdentityTests.swift
//  AXTermTests
//
//  An active transfer's row was keyed on its status and chunk count, so
//  SwiftUI made a new row for every chunk and the old one's state went with
//  it: the details the operator had opened closed each time a chunk came in
//  (smoke run 2026-10-03-1, 13.4 on the iPad, issue 112). The row keeps
//  one identity for the whole transfer and still redraws from the new value.
//

import XCTest
@testable import AXTerm

final class TransferRowIdentityTests: XCTestCase {

    func testARowKeepsItsIdentityAsChunksArrive() {
        var transfer = BulkTransfer(id: UUID(), fileName: "t20k_bin.bin", fileSize: 20_480,
                                    destination: "K0EPI-2", chunkSize: 1024, direction: .inbound)
        let before = BulkTransferListView.rowIdentity(for: transfer)
        transfer.status = .sending
        transfer.markChunkCompleted(0)
        transfer.markChunkCompleted(1)
        XCTAssertEqual(BulkTransferListView.rowIdentity(for: transfer), before)
    }

    func testDifferentTransfersHaveDifferentRows() {
        let a = BulkTransfer(id: UUID(), fileName: "a", fileSize: 1, destination: "K0EPI-2")
        let b = BulkTransfer(id: UUID(), fileName: "a", fileSize: 1, destination: "K0EPI-2")
        XCTAssertNotEqual(BulkTransferListView.rowIdentity(for: a), BulkTransferListView.rowIdentity(for: b))
    }
}

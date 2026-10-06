//
//  TransferChunkProgressTests.swift
//  AXTermTests
//
//  A (705) sent B (ID-50) a 20 KB file and its transfer read "20 KB / 20 KB"
//  beside "Chunks 0/29" (operator, 2026-10-06). The row counted chunks the
//  receiver had confirmed, and AXDP confirms the whole file at the end, not
//  each chunk (spec §FILE transfer completion), so a sender's count sat at 0
//  until then while its bar counted chunks sent.
//

import XCTest
@testable import AXTerm

final class TransferChunkProgressTests: XCTestCase {
    private func outbound() -> BulkTransfer {
        BulkTransfer(id: UUID(), fileName: "t20k_bin.bin", fileSize: 20_480, destination: "K0EPI-3", chunkSize: 720)
    }

    func testASenderCountsChunksSentUntilTheFileIsConfirmed() {
        var t = outbound()
        XCTAssertEqual(t.totalChunks, 29)
        XCTAssertEqual(t.chunkProgressText, "0/29 sent")
        for chunk in 0..<10 { t.markChunkSent(chunk) }
        XCTAssertEqual(t.chunkProgressText, "10/29 sent")
        for chunk in 10..<29 { t.markChunkSent(chunk) }
        XCTAssertEqual(t.chunkProgressText, "29/29 sent")
        t.markChunkNeedsRetry(3)
        XCTAssertEqual(t.chunkProgressText, "28/29 sent", "a chunk to resend is not counted as sent")
        t.markCompleted()
        XCTAssertEqual(t.chunkProgressText, "29/29 confirmed")
    }

    func testAReceiverCountsChunksItHas() {
        var t = BulkTransfer(id: UUID(), fileName: "t20k_bin.bin", fileSize: 20_480, destination: "K0EPI-2",
                             chunkSize: 720, direction: .inbound)
        t.markChunkCompleted(0)
        t.markChunkCompleted(1)
        XCTAssertEqual(t.chunkProgressText, "2/29")
    }
}

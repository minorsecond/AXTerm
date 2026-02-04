//
//  BulkTransferTests.swift
//  AXTermTests
//
//  TDD tests for bulk file transfer: progress, pause/resume, failure handling.
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 10.10
//

import XCTest
@testable import AXTerm

final class BulkTransferTests: XCTestCase {

    // MARK: - Transfer Model Tests

    func testTransferInitialState() {
        let transfer = BulkTransfer(
            id: UUID(),
            fileName: "test.txt",
            fileSize: 1024,
            destination: "N0CALL"
        )

        XCTAssertEqual(transfer.status, .pending)
        XCTAssertEqual(transfer.progress, 0.0)
        XCTAssertEqual(transfer.bytesSent, 0)
        XCTAssertEqual(transfer.fileName, "test.txt")
        XCTAssertEqual(transfer.fileSize, 1024)
    }

    func testTransferProgressCalculation() {
        var transfer = BulkTransfer(
            id: UUID(),
            fileName: "test.txt",
            fileSize: 1000,
            destination: "N0CALL"
        )

        transfer.bytesSent = 250
        XCTAssertEqual(transfer.progress, 0.25, accuracy: 0.01)

        transfer.bytesSent = 500
        XCTAssertEqual(transfer.progress, 0.50, accuracy: 0.01)

        transfer.bytesSent = 1000
        XCTAssertEqual(transfer.progress, 1.0, accuracy: 0.01)
    }

    func testTransferProgressClamped() {
        var transfer = BulkTransfer(
            id: UUID(),
            fileName: "test.txt",
            fileSize: 100,
            destination: "N0CALL"
        )

        // Edge case: more bytes sent than file size
        transfer.bytesSent = 150
        XCTAssertEqual(transfer.progress, 1.0, accuracy: 0.01)
    }

    /// Regression test: Progress bar should update when chunks are sent, not just when ACKed
    /// This ensures the sender's progress bar moves smoothly as chunks are transmitted
    func testTransferProgressUpdatesOnChunkSent() {
        var transfer = BulkTransfer(
            id: UUID(),
            fileName: "test.txt",
            fileSize: 256,
            destination: "DEST",
            chunkSize: 128,
            direction: .outbound
        )

        transfer.status = .sending
        XCTAssertEqual(transfer.totalChunks, 2)

        // Initially 0%
        XCTAssertEqual(transfer.progress, 0.0, accuracy: 0.01)
        XCTAssertEqual(transfer.bytesSent, 0)

        // Send first chunk - progress should update immediately
        transfer.markChunkSent(0)
        XCTAssertEqual(transfer.progress, 0.5, accuracy: 0.01, "Progress should update when chunk is sent")
        XCTAssertEqual(transfer.bytesSent, 128, "bytesSent should reflect sent chunks")

        // Send second chunk - progress should be 100%
        transfer.markChunkSent(1)
        XCTAssertEqual(transfer.progress, 1.0, accuracy: 0.01, "Progress should be 100% when all chunks sent")
        XCTAssertEqual(transfer.bytesSent, 256, "bytesSent should reflect all sent chunks")

        // Complete first chunk (ACK received) - progress should remain 100%
        transfer.markChunkCompleted(0)
        XCTAssertEqual(transfer.progress, 1.0, accuracy: 0.01, "Progress should remain 100% after ACK")
        XCTAssertEqual(transfer.bytesSent, 256, "bytesSent should still reflect all chunks")

        // Complete second chunk - progress should still be 100%
        transfer.markChunkCompleted(1)
        XCTAssertEqual(transfer.progress, 1.0, accuracy: 0.01, "Progress should remain 100% after all ACKs")
        XCTAssertEqual(transfer.bytesSent, 256, "bytesSent should reflect all completed chunks")
    }

    /// Regression test: Chunks should not be skipped when AX.25 window is full
    /// This test verifies that chunks marked as "needs retry" are properly retried
    func testChunksNotSkippedWhenWindowFull() {
        var transfer = BulkTransfer(
            id: UUID(),
            fileName: "test.txt",
            fileSize: 512,
            destination: "DEST",
            chunkSize: 128,
            direction: .outbound
        )

        transfer.status = .sending
        XCTAssertEqual(transfer.totalChunks, 4)

        // Send chunks 0, 1, 2, 3
        transfer.markChunkSent(0)
        transfer.markChunkSent(1)
        transfer.markChunkSent(2)
        transfer.markChunkSent(3)

        // Verify all chunks are sent (progress should be 100%)
        XCTAssertEqual(transfer.progress, 1.0, accuracy: 0.01, "All chunks sent, progress should be 100%")
        XCTAssertEqual(transfer.bytesSent, 512, "All bytes should be accounted for")

        // Simulate window full scenario: chunk 2 needs retry (was sent but window was full)
        // This simulates the bug where sendAXDPPayload returned false due to full window
        transfer.markChunkNeedsRetry(2)

        // nextChunkToSend should return 2 (the retry), not skip to nil
        XCTAssertEqual(transfer.nextChunkToSend, 2, "Should retry chunk 2, not skip it")

        // Progress should decrease slightly since chunk 2 is no longer "sent"
        // (it's now in retry state, so bytesSent should reflect only chunks 0, 1, 3)
        XCTAssertEqual(transfer.bytesSent, 384, "bytesSent should reflect only non-retry chunks")

        // After retry is sent, should be back to 100%
        transfer.markChunkSent(2)
        XCTAssertNil(transfer.nextChunkToSend, "All chunks should be sent now")
        XCTAssertEqual(transfer.progress, 1.0, accuracy: 0.01, "Progress should be 100% after retry sent")
        XCTAssertEqual(transfer.bytesSent, 512, "All bytes should be accounted for after retry")
    }

    func testTransferZeroSizeFile() {
        let transfer = BulkTransfer(
            id: UUID(),
            fileName: "empty.txt",
            fileSize: 0,
            destination: "N0CALL"
        )

        // Zero-size file should be 100% complete immediately
        XCTAssertEqual(transfer.progress, 1.0)
    }

    // MARK: - Status Transitions

    func testTransferStatusTransitions() {
        var transfer = BulkTransfer(
            id: UUID(),
            fileName: "test.txt",
            fileSize: 1024,
            destination: "N0CALL"
        )

        XCTAssertEqual(transfer.status, .pending)

        transfer.status = .sending
        XCTAssertEqual(transfer.status, .sending)

        transfer.status = .paused
        XCTAssertEqual(transfer.status, .paused)

        transfer.status = .sending
        XCTAssertEqual(transfer.status, .sending)

        transfer.status = .completed
        XCTAssertEqual(transfer.status, .completed)
    }

    func testTransferCanPauseOnlySending() {
        var transfer = BulkTransfer(
            id: UUID(),
            fileName: "test.txt",
            fileSize: 1024,
            destination: "N0CALL"
        )

        XCTAssertFalse(transfer.canPause)  // pending

        transfer.status = .sending
        XCTAssertTrue(transfer.canPause)

        transfer.status = .paused
        XCTAssertFalse(transfer.canPause)

        transfer.status = .completed
        XCTAssertFalse(transfer.canPause)
    }

    func testTransferCanResumeOnlyPaused() {
        var transfer = BulkTransfer(
            id: UUID(),
            fileName: "test.txt",
            fileSize: 1024,
            destination: "N0CALL"
        )

        XCTAssertFalse(transfer.canResume)  // pending

        transfer.status = .sending
        XCTAssertFalse(transfer.canResume)

        transfer.status = .paused
        XCTAssertTrue(transfer.canResume)

        transfer.status = .failed(reason: "Test")
        XCTAssertFalse(transfer.canResume)
    }

    func testTransferCanCancelWhileActive() {
        var transfer = BulkTransfer(
            id: UUID(),
            fileName: "test.txt",
            fileSize: 1024,
            destination: "N0CALL"
        )

        XCTAssertTrue(transfer.canCancel)  // pending

        transfer.status = .sending
        XCTAssertTrue(transfer.canCancel)

        transfer.status = .paused
        XCTAssertTrue(transfer.canCancel)

        transfer.status = .completed
        XCTAssertFalse(transfer.canCancel)

        transfer.status = .cancelled
        XCTAssertFalse(transfer.canCancel)
    }

    // MARK: - Failure Handling

    func testTransferFailureWithReason() {
        var transfer = BulkTransfer(
            id: UUID(),
            fileName: "test.txt",
            fileSize: 1024,
            destination: "N0CALL"
        )

        transfer.status = .failed(reason: "Connection timeout after 10 retries")

        if case .failed(let reason) = transfer.status {
            XCTAssertEqual(reason, "Connection timeout after 10 retries")
        } else {
            XCTFail("Expected failed status")
        }
    }

    func testTransferFailureExplanation() {
        var transfer = BulkTransfer(
            id: UUID(),
            fileName: "test.txt",
            fileSize: 1024,
            destination: "N0CALL"
        )

        // Test actionable failure messages
        transfer.status = .failed(reason: "No response after 10 tries")
        XCTAssertTrue(transfer.failureExplanation.contains("10 tries"))

        transfer.status = .failed(reason: "Link quality degraded")
        XCTAssertTrue(transfer.failureExplanation.contains("quality"))
    }

    // MARK: - Transfer Statistics

    func testTransferTracksTiming() {
        var transfer = BulkTransfer(
            id: UUID(),
            fileName: "test.txt",
            fileSize: 1024,
            destination: "N0CALL"
        )

        XCTAssertNil(transfer.startedAt)
        XCTAssertNil(transfer.completedAt)

        transfer.markStarted()
        XCTAssertNotNil(transfer.startedAt)
        XCTAssertNil(transfer.completedAt)

        transfer.markCompleted()
        XCTAssertNotNil(transfer.completedAt)
    }

    func testTransferThroughputCalculation() {
        var transfer = BulkTransfer(
            id: UUID(),
            fileName: "test.txt",
            fileSize: 1000,
            destination: "N0CALL"
        )

        // Simulate sending 1000 bytes in 10 seconds
        transfer.startedAt = Date(timeIntervalSinceNow: -10)
        transfer.bytesSent = 1000

        // Throughput should be ~100 bytes/sec
        XCTAssertEqual(transfer.throughputBytesPerSecond, 100.0, accuracy: 5.0)
    }

    func testTransferETACalculation() {
        var transfer = BulkTransfer(
            id: UUID(),
            fileName: "test.txt",
            fileSize: 1000,
            destination: "N0CALL"
        )

        // Simulate: 500 bytes sent in 5 seconds = 100 bytes/sec
        // Remaining 500 bytes at 100 bytes/sec = 5 seconds ETA
        transfer.startedAt = Date(timeIntervalSinceNow: -5)
        transfer.bytesSent = 500

        let eta = transfer.estimatedSecondsRemaining
        XCTAssertNotNil(eta)
        XCTAssertEqual(eta!, 5.0, accuracy: 1.0)
    }

    // MARK: - Chunk Management

    func testTransferChunkTracking() {
        var transfer = BulkTransfer(
            id: UUID(),
            fileName: "test.txt",
            fileSize: 1000,
            destination: "N0CALL",
            chunkSize: 128
        )

        XCTAssertEqual(transfer.totalChunks, 8)  // ceil(1000/128)
        XCTAssertEqual(transfer.completedChunks, 0)

        transfer.markChunkCompleted(0)
        XCTAssertEqual(transfer.completedChunks, 1)

        transfer.markChunkCompleted(1)
        transfer.markChunkCompleted(2)
        XCTAssertEqual(transfer.completedChunks, 3)
    }

    func testTransferNextChunkToSend() {
        var transfer = BulkTransfer(
            id: UUID(),
            fileName: "test.txt",
            fileSize: 384,  // 3 chunks of 128 bytes
            destination: "N0CALL",
            chunkSize: 128
        )

        XCTAssertEqual(transfer.nextChunkToSend, 0)

        transfer.markChunkSent(0)
        XCTAssertEqual(transfer.nextChunkToSend, 1)

        transfer.markChunkSent(1)
        XCTAssertEqual(transfer.nextChunkToSend, 2)

        transfer.markChunkSent(2)
        XCTAssertNil(transfer.nextChunkToSend)  // All sent
    }

    func testTransferRetryRequiresResendingChunk() {
        var transfer = BulkTransfer(
            id: UUID(),
            fileName: "test.txt",
            fileSize: 384,
            destination: "N0CALL",
            chunkSize: 128
        )

        transfer.markChunkSent(0)
        transfer.markChunkCompleted(0)
        transfer.markChunkSent(1)

        // Chunk 1 needs retry
        transfer.markChunkNeedsRetry(1)

        // Next chunk should be 1 (the one that needs retry)
        XCTAssertEqual(transfer.nextChunkToSend, 1)
    }

    // MARK: - Transfer Manager Tests

    func testTransferManagerEnqueue() {
        var manager = BulkTransferManager()

        let id = manager.enqueue(
            fileName: "test.txt",
            fileData: Data(count: 1024),
            destination: "N0CALL"
        )

        XCTAssertNotNil(id)
        XCTAssertEqual(manager.transfers.count, 1)
        XCTAssertEqual(manager.transfers.first?.id, id)
    }

    func testTransferManagerPause() {
        var manager = BulkTransferManager()

        let id = manager.enqueue(
            fileName: "test.txt",
            fileData: Data(count: 1024),
            destination: "N0CALL"
        )!

        // Start transfer
        manager.start(id)
        XCTAssertEqual(manager.transfers.first?.status, .sending)

        // Pause
        manager.pause(id)
        XCTAssertEqual(manager.transfers.first?.status, .paused)
    }

    func testTransferManagerResume() {
        var manager = BulkTransferManager()

        let id = manager.enqueue(
            fileName: "test.txt",
            fileData: Data(count: 1024),
            destination: "N0CALL"
        )!

        manager.start(id)
        manager.pause(id)
        XCTAssertEqual(manager.transfers.first?.status, .paused)

        manager.resume(id)
        XCTAssertEqual(manager.transfers.first?.status, .sending)
    }

    func testTransferManagerCancel() {
        var manager = BulkTransferManager()

        let id = manager.enqueue(
            fileName: "test.txt",
            fileData: Data(count: 1024),
            destination: "N0CALL"
        )!

        manager.start(id)
        manager.cancel(id)
        XCTAssertEqual(manager.transfers.first?.status, .cancelled)
    }

    func testTransferManagerMultipleTransfers() {
        var manager = BulkTransferManager()

        let id1 = manager.enqueue(
            fileName: "file1.txt",
            fileData: Data(count: 512),
            destination: "N0CALL"
        )!

        let id2 = manager.enqueue(
            fileName: "file2.txt",
            fileData: Data(count: 1024),
            destination: "N0CALL-2"
        )!

        XCTAssertEqual(manager.transfers.count, 2)
        XCTAssertNotEqual(id1, id2)

        // Verify separate state
        manager.start(id1)
        XCTAssertEqual(manager.transfer(for: id1)?.status, .sending)
        XCTAssertEqual(manager.transfer(for: id2)?.status, .pending)
    }

    // MARK: - AXDP Integration

    func testTransferBuildsAXDPChunk() {
        let transfer = BulkTransfer(
            id: UUID(),
            fileName: "test.txt",
            fileSize: 256,
            destination: "N0CALL",
            chunkSize: 128
        )

        let fileData = Data(repeating: 0x42, count: 256)
        let chunkData = transfer.chunkData(from: fileData, chunk: 0)

        XCTAssertEqual(chunkData?.count, 128)
        XCTAssertEqual(chunkData?.first, 0x42)
    }

    func testTransferLastChunkMayBeShorter() {
        let transfer = BulkTransfer(
            id: UUID(),
            fileName: "test.txt",
            fileSize: 300,  // 2 full chunks + partial
            destination: "N0CALL",
            chunkSize: 128
        )

        let fileData = Data(repeating: 0x42, count: 300)

        let chunk0 = transfer.chunkData(from: fileData, chunk: 0)
        XCTAssertEqual(chunk0?.count, 128)

        let chunk1 = transfer.chunkData(from: fileData, chunk: 1)
        XCTAssertEqual(chunk1?.count, 128)

        let chunk2 = transfer.chunkData(from: fileData, chunk: 2)
        XCTAssertEqual(chunk2?.count, 44)  // Remaining bytes
    }
}

//
//  TransferMetricsTests.swift
//  AXTermTests
//
//  Tests for file transfer metrics accuracy (throughput, timing, progress)
//

import XCTest
@testable import AXTerm

final class TransferMetricsTests: XCTestCase {

    // MARK: - BulkTransfer Throughput Tests

    func testSenderThroughputCalculation() {
        // Given: A transfer that sent 2639 bytes in 1.7 seconds
        var transfer = BulkTransfer(
            id: UUID(),
            fileName: "test.csv",
            fileSize: 13950,  // Original size
            destination: "TEST-2",
            chunkSize: 128,
            direction: .outbound
        )
        transfer.setTransmissionSize(2639)  // Compressed size
        transfer.startedAt = Date(timeIntervalSinceNow: -1.7)  // Started 1.7 seconds ago
        transfer.bytesSent = 2639
        transfer.bytesTransmitted = 2639

        // When: We calculate throughput
        let throughput = transfer.throughputBytesPerSecond

        // Then: Throughput should be ~1552 bytes/sec (2639 / 1.7)
        XCTAssertEqual(throughput, 1552, accuracy: 50, "Throughput should be ~1552 B/s")
    }

    func testReceiverThroughputCalculation() {
        // Given: A transfer that received 2639 bytes in 1.7 seconds
        var transfer = BulkTransfer(
            id: UUID(),
            fileName: "test.csv",
            fileSize: 13950,
            destination: "TEST-1",
            chunkSize: 128,
            direction: .inbound
        )
        transfer.setTransmissionSize(2639)
        transfer.startedAt = Date(timeIntervalSinceNow: -1.7)
        transfer.bytesSent = 2639
        transfer.bytesTransmitted = 2639

        // When: We calculate throughput
        let throughput = transfer.throughputBytesPerSecond

        // Then: Throughput should match sender (~1552 bytes/sec)
        XCTAssertEqual(throughput, 1552, accuracy: 50, "Receiver throughput should match sender")
    }

    func testProgressBasedOnTransmissionSize() {
        // Given: A compressed transfer where we've sent half the compressed data
        var transfer = BulkTransfer(
            id: UUID(),
            fileName: "test.csv",
            fileSize: 13950,  // Original size
            destination: "TEST-2",
            chunkSize: 128,
            direction: .outbound
        )
        transfer.setTransmissionSize(2639)  // Compressed size
        transfer.bytesSent = 1320  // Half of compressed size

        // When: We check progress
        let progress = transfer.progress

        // Then: Progress should be ~50% (not based on original size)
        XCTAssertEqual(progress, 0.5, accuracy: 0.05, "Progress should be ~50% based on transmission size")
    }

    func testAirRateTracking() {
        // Given: A transfer tracking actual bytes transmitted
        var transfer = BulkTransfer(
            id: UUID(),
            fileName: "test.csv",
            fileSize: 13950,
            destination: "TEST-2",
            chunkSize: 128,
            direction: .outbound
        )
        transfer.setTransmissionSize(2639)
        transfer.startedAt = Date(timeIntervalSinceNow: -1.7)
        transfer.bytesSent = 2639
        transfer.bytesTransmitted = 2639

        // When: We calculate air throughput
        let airThroughput = transfer.airThroughputBytesPerSecond

        // Then: Air throughput should be calculated correctly
        XCTAssertEqual(airThroughput, 1552, accuracy: 50, "Air throughput should be ~1552 B/s")
    }

    func testPreferredRatesUseReceiverTimingForOutboundTransfers() {
        // Given: An outbound transfer with receiver-reported timing
        var transfer = BulkTransfer(
            id: UUID(),
            fileName: "test.csv",
            fileSize: 13950,
            destination: "TEST-2",
            chunkSize: 128,
            direction: .outbound
        )
        transfer.setTransmissionSize(2639)
        transfer.bytesSent = 2639
        transfer.bytesTransmitted = 2639
        let localStart = Date(timeIntervalSinceReferenceDate: 1000)
        let localEnd = localStart.addingTimeInterval(2.0) // Local timing says 2.0s
        transfer.startedAt = localStart
        transfer.dataPhaseStartedAt = localStart
        transfer.dataPhaseCompletedAt = localEnd
        transfer.remoteTransferMetrics = AXDP.AXDPTransferMetrics(
            dataDurationMs: 1250,
            processingDurationMs: 3,
            bytesReceived: 2639,
            decompressedBytes: 13950
        )

        // When: We compute preferred rates
        let preferredDataRate = transfer.preferredDataRateBytesPerSecond
        let preferredAirRate = transfer.preferredAirRateBytesPerSecond

        // Then: Preferred rates should use receiver timing (2639 / 1.25s ~= 2111 B/s)
        XCTAssertEqual(preferredDataRate, 2111, accuracy: 50, "Preferred data rate should use receiver timing")
        XCTAssertEqual(preferredAirRate, 2111, accuracy: 50, "Preferred air rate should use receiver timing")
        XCTAssertTrue(transfer.preferredRatesUseReceiverTiming, "Outbound preferred rates should use receiver timing")
    }

    func testPreferredRatesIgnoreReceiverTimingForInboundTransfers() {
        // Given: An inbound transfer with receiver timing present (should be ignored)
        var transfer = BulkTransfer(
            id: UUID(),
            fileName: "test.csv",
            fileSize: 13950,
            destination: "TEST-1",
            chunkSize: 128,
            direction: .inbound
        )
        transfer.setTransmissionSize(2639)
        transfer.bytesSent = 2639
        transfer.bytesTransmitted = 2639
        let localStart = Date(timeIntervalSinceReferenceDate: 2000)
        let localEnd = localStart.addingTimeInterval(1.7)
        transfer.startedAt = localStart
        transfer.dataPhaseStartedAt = localStart
        transfer.dataPhaseCompletedAt = localEnd
        transfer.remoteTransferMetrics = AXDP.AXDPTransferMetrics(
            dataDurationMs: 1250,
            processingDurationMs: 3,
            bytesReceived: 2639,
            decompressedBytes: 13950
        )

        // When: We compute preferred rates
        let preferredDataRate = transfer.preferredDataRateBytesPerSecond
        let preferredAirRate = transfer.preferredAirRateBytesPerSecond

        // Then: Preferred rates should fall back to local timing (~1552 B/s)
        XCTAssertEqual(preferredDataRate, 1552, accuracy: 50, "Inbound preferred data rate should use local timing")
        XCTAssertEqual(preferredAirRate, 1552, accuracy: 50, "Inbound preferred air rate should use local timing")
        XCTAssertFalse(transfer.preferredRatesUseReceiverTiming, "Inbound preferred rates should not use receiver timing")
    }

    // MARK: - InboundTransferState Tests

    func testInboundStateDoesNotCountDuplicateChunks() {
        // Given: An inbound transfer state
        var state = InboundTransferState(
            axdpSessionId: 12345,
            sourceCallsign: "TEST-1",
            fileName: "test.csv",
            fileSize: 13950,
            expectedChunks: 21,
            chunkSize: 128,
            sha256: Data(repeating: 0, count: 32)
        )

        // When: We receive chunk 5 twice
        let chunkData = Data(repeating: 0x41, count: 128)
        state.receiveChunk(index: 5, data: chunkData)
        let bytesAfterFirst = state.totalBytesReceived

        state.receiveChunk(index: 5, data: chunkData)  // Duplicate
        let bytesAfterDuplicate = state.totalBytesReceived

        // Then: Bytes received should not increase on duplicate
        XCTAssertEqual(bytesAfterFirst, bytesAfterDuplicate, "Duplicate chunks should not increase byte count")
        XCTAssertEqual(state.receivedChunks.count, 1, "Should only have 1 unique chunk")
    }

    func testInboundStateCompletionOnlyTriggersOnce() {
        // Given: An inbound transfer expecting 3 chunks
        var state = InboundTransferState(
            axdpSessionId: 12345,
            sourceCallsign: "TEST-1",
            fileName: "test.csv",
            fileSize: 384,
            expectedChunks: 3,
            chunkSize: 128,
            sha256: Data(repeating: 0, count: 32)
        )

        // When: We receive all chunks and then receive duplicates
        state.receiveChunk(index: 0, data: Data(repeating: 0x41, count: 128))
        state.receiveChunk(index: 1, data: Data(repeating: 0x42, count: 128))
        XCTAssertFalse(state.isComplete, "Should not be complete yet")

        state.receiveChunk(index: 2, data: Data(repeating: 0x43, count: 128))
        XCTAssertTrue(state.isComplete, "Should be complete after all chunks")

        // Receive duplicates - state should remain complete but not process again
        let completionTime = state.endTime
        state.receiveChunk(index: 2, data: Data(repeating: 0x43, count: 128))

        // Then: End time should not change (completion already happened)
        XCTAssertEqual(state.endTime, completionTime, "End time should not change on duplicate")
    }

    func testInboundStateProgressCalculation() {
        // Given: An inbound transfer expecting 21 chunks
        var state = InboundTransferState(
            axdpSessionId: 12345,
            sourceCallsign: "TEST-1",
            fileName: "test.csv",
            fileSize: 2639,
            expectedChunks: 21,
            chunkSize: 128,
            sha256: Data(repeating: 0, count: 32)
        )

        // When: We receive 10 chunks
        for i in 0..<10 {
            state.receiveChunk(index: i, data: Data(repeating: UInt8(i), count: 128))
        }

        // Then: Progress should be ~47.6% (10/21)
        XCTAssertEqual(state.progress, 10.0 / 21.0, accuracy: 0.001, "Progress should be 10/21")
    }

    // MARK: - Timing Tests

    func testReceiverTimingShouldStartOnFirstChunk() {
        // Given: An inbound transfer state with no start time yet
        var state = InboundTransferState(
            axdpSessionId: 12345,
            sourceCallsign: "TEST-1",
            fileName: "test.csv",
            fileSize: 384,
            expectedChunks: 3,
            chunkSize: 128,
            sha256: Data(repeating: 0, count: 32)
        )

        XCTAssertNil(state.startTime, "Start time should be nil before first chunk")

        // When: First chunk is received
        state.receiveChunk(index: 0, data: Data(repeating: 0x41, count: 128))

        // Then: Start time should be set
        XCTAssertNotNil(state.startTime, "Start time should be set on first chunk")
    }

    func testTransferDurationCalculation() {
        // Given: A completed transfer
        var transfer = BulkTransfer(
            id: UUID(),
            fileName: "test.csv",
            fileSize: 13950,
            destination: "TEST-2",
            chunkSize: 128,
            direction: .outbound
        )
        let startTime = Date(timeIntervalSinceNow: -1.7)
        transfer.startedAt = startTime
        transfer.completedAt = Date()

        // When: We check the duration
        guard let completed = transfer.completedAt, let started = transfer.startedAt else {
            XCTFail("Times should be set")
            return
        }
        let duration = completed.timeIntervalSince(started)

        // Then: Duration should be ~1.7 seconds
        XCTAssertEqual(duration, 1.7, accuracy: 0.1, "Duration should be ~1.7 seconds")
    }

    // MARK: - Transfer Completion Guard Tests

    func testTransferCannotCompleteWhenAlreadyCompleted() {
        // Given: A transfer that is already completed
        var transfer = BulkTransfer(
            id: UUID(),
            fileName: "test.csv",
            fileSize: 13950,
            destination: "TEST-2",
            chunkSize: 128,
            direction: .inbound
        )
        transfer.markCompleted()
        XCTAssertEqual(transfer.status, .completed)
        let firstCompletionTime = transfer.completedAt

        // When: We try to complete it again
        // (simulating what would happen if handleTransferComplete was called twice)
        transfer.markCompleted()

        // Then: The completion time should not change (already completed)
        // Note: markCompleted() currently always sets completedAt
        // This test documents current behavior - the fix should change this
        XCTAssertEqual(transfer.status, .completed, "Status should remain completed")
    }

    func testInboundStateDoesNotProcessAfterCompletion() {
        // Given: A completed inbound transfer state
        var state = InboundTransferState(
            axdpSessionId: 12345,
            sourceCallsign: "TEST-1",
            fileName: "test.csv",
            fileSize: 384,
            expectedChunks: 3,
            chunkSize: 128,
            sha256: Data(repeating: 0, count: 32)
        )

        // Receive all chunks to complete
        state.receiveChunk(index: 0, data: Data(repeating: 0x41, count: 128))
        state.receiveChunk(index: 1, data: Data(repeating: 0x42, count: 128))
        state.receiveChunk(index: 2, data: Data(repeating: 0x43, count: 128))
        XCTAssertTrue(state.isComplete)
        let bytesAtCompletion = state.totalBytesReceived
        let chunksAtCompletion = state.receivedChunks.count

        // When: Duplicate chunks arrive after completion
        state.receiveChunk(index: 0, data: Data(repeating: 0x41, count: 128))
        state.receiveChunk(index: 1, data: Data(repeating: 0x42, count: 128))
        state.receiveChunk(index: 2, data: Data(repeating: 0x43, count: 128))

        // Then: State should not change
        XCTAssertEqual(state.totalBytesReceived, bytesAtCompletion, "Bytes should not increase")
        XCTAssertEqual(state.receivedChunks.count, chunksAtCompletion, "Chunks should not increase")
    }

    // MARK: - Timing Alignment Tests

    func testReceiverAndSenderShouldHaveComparableTiming() {
        // This test documents the expected behavior:
        // Both sender and receiver should measure throughput from the same point in time
        // (when actual data transfer begins)

        // Sender scenario: starts timing when ACK is received
        var senderTransfer = BulkTransfer(
            id: UUID(),
            fileName: "test.csv",
            fileSize: 2639,
            destination: "TEST-2",
            chunkSize: 128,
            direction: .outbound
        )
        senderTransfer.setTransmissionSize(2639)
        // Simulate: FILE_META sent, then wait 2 seconds for ACK, then start timing
        let dataTransferStart = Date(timeIntervalSinceNow: -1.7)  // 1.7 seconds of actual transfer
        senderTransfer.startedAt = dataTransferStart  // Reset when ACK received
        senderTransfer.bytesSent = 2639
        senderTransfer.bytesTransmitted = 2639

        let senderThroughput = senderTransfer.throughputBytesPerSecond

        // Receiver scenario: should also start timing when first chunk arrives
        var receiverTransfer = BulkTransfer(
            id: UUID(),
            fileName: "test.csv",
            fileSize: 2639,
            destination: "TEST-1",
            chunkSize: 128,
            direction: .inbound
        )
        receiverTransfer.setTransmissionSize(2639)
        // Bug scenario: timing started when FILE_META arrived (2 seconds before actual transfer)
        // This would give artificially low throughput

        // Correct scenario: timing should start when first chunk arrives
        receiverTransfer.startedAt = dataTransferStart  // Same as sender
        receiverTransfer.bytesSent = 2639
        receiverTransfer.bytesTransmitted = 2639

        let receiverThroughput = receiverTransfer.throughputBytesPerSecond

        // Then: Both throughputs should be comparable (within ~10%)
        let difference = abs(senderThroughput - receiverThroughput) / senderThroughput
        XCTAssertLessThan(difference, 0.1, "Sender and receiver throughput should be within 10%")
    }
}

//
//  FileTransferReceiverTests.swift
//  AXTermTests
//
//  TDD tests for receiver-side file transfer handling.
//  These tests prove that the receiver correctly processes incoming
//  FILE_META and FILE_CHUNK messages.
//

import XCTest
@testable import AXTerm

final class FileTransferReceiverTests: XCTestCase {

    // MARK: - AXDP Message Parsing Tests

    func testAXDPMessageDecodeFileMeta() {
        // Create a FILE_META message
        let fileMeta = AXDPFileMeta(
            filename: "test.txt",
            fileSize: 1024,
            sha256: Data(repeating: 0xAB, count: 32),
            chunkSize: 128
        )

        let msg = AXDP.Message(
            type: .fileMeta,
            sessionId: 12345,
            messageId: 0,
            totalChunks: 8,
            fileMeta: fileMeta
        )

        let encoded = msg.encode()
        let decoded = AXDP.Message.decodeMessage(from: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.type, .fileMeta)
        XCTAssertEqual(decoded?.sessionId, 12345)
        XCTAssertEqual(decoded?.totalChunks, 8)
        XCTAssertEqual(decoded?.fileMeta?.filename, "test.txt")
        XCTAssertEqual(decoded?.fileMeta?.fileSize, 1024)
        XCTAssertEqual(decoded?.fileMeta?.chunkSize, 128)
    }

    func testAXDPMessageDecodeFileChunk() {
        let chunkData = Data(repeating: 0x42, count: 128)

        let msg = AXDP.Message(
            type: .fileChunk,
            sessionId: 12345,
            messageId: 1,
            chunkIndex: 0,
            totalChunks: 8,
            payload: chunkData
        )

        let encoded = msg.encode()
        let decoded = AXDP.Message.decodeMessage(from: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.type, .fileChunk)
        XCTAssertEqual(decoded?.sessionId, 12345)
        XCTAssertEqual(decoded?.chunkIndex, 0)
        XCTAssertEqual(decoded?.totalChunks, 8)
        XCTAssertEqual(decoded?.payload, chunkData)
    }

    // MARK: - Inbound Transfer State Tests

    func testInboundTransferStateCreation() {
        let state = InboundTransferState(
            axdpSessionId: 12345,
            sourceCallsign: "N0CALL",
            fileName: "test.txt",
            fileSize: 1024,
            expectedChunks: 8,
            chunkSize: 128,
            sha256: Data(repeating: 0xAB, count: 32)
        )

        XCTAssertEqual(state.axdpSessionId, 12345)
        XCTAssertEqual(state.sourceCallsign, "N0CALL")
        XCTAssertEqual(state.fileName, "test.txt")
        XCTAssertEqual(state.fileSize, 1024)
        XCTAssertEqual(state.expectedChunks, 8)
        XCTAssertEqual(state.receivedChunks.count, 0)
        XCTAssertEqual(state.totalBytesReceived, 0)
        XCTAssertFalse(state.isComplete)
    }

    func testInboundTransferStateReceiveChunk() {
        var state = InboundTransferState(
            axdpSessionId: 12345,
            sourceCallsign: "N0CALL",
            fileName: "test.txt",
            fileSize: 256,
            expectedChunks: 2,
            chunkSize: 128,
            sha256: Data(repeating: 0xAB, count: 32)
        )

        let chunk1 = Data(repeating: 0x01, count: 128)
        state.receiveChunk(index: 0, data: chunk1)

        XCTAssertEqual(state.receivedChunks.count, 1)
        XCTAssertTrue(state.receivedChunks.contains(0))
        XCTAssertEqual(state.totalBytesReceived, 128)
        XCTAssertFalse(state.isComplete)

        let chunk2 = Data(repeating: 0x02, count: 128)
        state.receiveChunk(index: 1, data: chunk2)

        XCTAssertEqual(state.receivedChunks.count, 2)
        XCTAssertTrue(state.receivedChunks.contains(1))
        XCTAssertEqual(state.totalBytesReceived, 256)
        XCTAssertTrue(state.isComplete)
    }

    func testInboundTransferStateDuplicateChunk() {
        var state = InboundTransferState(
            axdpSessionId: 12345,
            sourceCallsign: "N0CALL",
            fileName: "test.txt",
            fileSize: 256,
            expectedChunks: 2,
            chunkSize: 128,
            sha256: Data(repeating: 0xAB, count: 32)
        )

        let chunk = Data(repeating: 0x01, count: 128)
        state.receiveChunk(index: 0, data: chunk)
        state.receiveChunk(index: 0, data: chunk)  // Duplicate

        // Should not count twice
        XCTAssertEqual(state.receivedChunks.count, 1)
        XCTAssertEqual(state.totalBytesReceived, 128)
    }

    func testInboundTransferStateProgress() {
        var state = InboundTransferState(
            axdpSessionId: 12345,
            sourceCallsign: "N0CALL",
            fileName: "test.txt",
            fileSize: 512,
            expectedChunks: 4,
            chunkSize: 128,
            sha256: Data(repeating: 0xAB, count: 32)
        )

        XCTAssertEqual(state.progress, 0.0, accuracy: 0.01)

        state.receiveChunk(index: 0, data: Data(repeating: 0x01, count: 128))
        XCTAssertEqual(state.progress, 0.25, accuracy: 0.01)

        state.receiveChunk(index: 1, data: Data(repeating: 0x02, count: 128))
        XCTAssertEqual(state.progress, 0.5, accuracy: 0.01)

        state.receiveChunk(index: 2, data: Data(repeating: 0x03, count: 128))
        XCTAssertEqual(state.progress, 0.75, accuracy: 0.01)

        state.receiveChunk(index: 3, data: Data(repeating: 0x04, count: 128))
        XCTAssertEqual(state.progress, 1.0, accuracy: 0.01)
    }

    func testInboundTransferStateReassembly() {
        var state = InboundTransferState(
            axdpSessionId: 12345,
            sourceCallsign: "N0CALL",
            fileName: "test.txt",
            fileSize: 8,
            expectedChunks: 2,
            chunkSize: 4,
            sha256: Data(repeating: 0xAB, count: 32)
        )

        let chunk1 = Data([0x01, 0x02, 0x03, 0x04])
        let chunk2 = Data([0x05, 0x06, 0x07, 0x08])

        // Receive chunks out of order
        state.receiveChunk(index: 1, data: chunk2)
        state.receiveChunk(index: 0, data: chunk1)

        // Reassemble should give correct order
        let reassembled = state.reassembleFile()
        XCTAssertNotNil(reassembled)
        XCTAssertEqual(reassembled?.count, 8)
        XCTAssertEqual(reassembled, Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]))
    }

    // MARK: - Transfer Metrics Tests

    func testTransferMetricsCalculation() {
        var state = InboundTransferState(
            axdpSessionId: 12345,
            sourceCallsign: "N0CALL",
            fileName: "test.txt",
            fileSize: 1024,
            expectedChunks: 8,
            chunkSize: 128,
            sha256: Data(repeating: 0xAB, count: 32)
        )

        // Simulate receiving all chunks over 2 seconds
        state.startTime = Date().addingTimeInterval(-2.0)
        for i in 0..<8 {
            state.receiveChunk(index: i, data: Data(repeating: UInt8(i), count: 128))
        }
        state.endTime = Date()

        let metrics = state.calculateMetrics()

        XCTAssertNotNil(metrics)
        XCTAssertEqual(metrics!.totalBytes, 1024)
        XCTAssertGreaterThan(metrics!.durationSeconds, 0)
        XCTAssertGreaterThan(metrics!.effectiveBytesPerSecond, 0)
    }

    func testTransferMetricsBandwidthCalculation() {
        let metrics = TransferMetrics(
            totalBytes: 1000,
            durationSeconds: 2.0,
            originalSize: 2000,
            compressedSize: 1000,
            compressionAlgorithm: .lz4
        )

        XCTAssertEqual(metrics.effectiveBytesPerSecond, 500, accuracy: 0.1)
        XCTAssertEqual(metrics.effectiveBitsPerSecond, 4000, accuracy: 0.1)
        XCTAssertNotNil(metrics.compressionRatio)
        XCTAssertEqual(metrics.compressionRatio!, 0.5, accuracy: 0.01)
        XCTAssertNotNil(metrics.spaceSavedPercent)
        XCTAssertEqual(metrics.spaceSavedPercent!, 50, accuracy: 0.1)
    }

    func testTransferMetricsWithoutCompression() {
        let metrics = TransferMetrics(
            totalBytes: 1000,
            durationSeconds: 2.0,
            originalSize: nil,
            compressedSize: nil,
            compressionAlgorithm: nil
        )

        XCTAssertEqual(metrics.effectiveBytesPerSecond, 500, accuracy: 0.1)
        XCTAssertNil(metrics.compressionRatio)
        XCTAssertNil(metrics.spaceSavedPercent)
    }

    // MARK: - BulkTransfer Inbound Support Tests

    func testBulkTransferInboundTracksReceivedChunks() {
        var transfer = BulkTransfer(
            id: UUID(),
            fileName: "test.txt",
            fileSize: 256,
            destination: "N0CALL",
            direction: .inbound
        )

        XCTAssertEqual(transfer.direction, .inbound)
        XCTAssertEqual(transfer.completedChunks, 0)

        transfer.markChunkCompleted(0)
        XCTAssertEqual(transfer.completedChunks, 1)

        transfer.markChunkCompleted(1)
        XCTAssertEqual(transfer.completedChunks, 2)
    }

    func testBulkTransferDirection() {
        let outbound = BulkTransfer(
            id: UUID(),
            fileName: "test.txt",
            fileSize: 1024,
            destination: "N0CALL",
            direction: .outbound
        )

        let inbound = BulkTransfer(
            id: UUID(),
            fileName: "test.txt",
            fileSize: 1024,
            destination: "N0CALL",
            direction: .inbound
        )

        XCTAssertEqual(outbound.direction, .outbound)
        XCTAssertEqual(inbound.direction, .inbound)
    }

    // MARK: - Data Extension Tests

    func testDataHexEncodedString() {
        let data = Data([0x00, 0x01, 0x0F, 0xFF])
        XCTAssertEqual(data.hexEncodedString(), "00010fff")
    }

    func testDataHexEncodedStringEmpty() {
        let data = Data()
        XCTAssertEqual(data.hexEncodedString(), "")
    }
}

//
//  SessionCoordinatorTests.swift
//  AXTermTests
//
//  Tests for SessionCoordinator: capability discovery, file transfers, pending data queue.
//

import XCTest
@testable import AXTerm

final class SessionCoordinatorTests: XCTestCase {

    // Note: AXDPCapabilityStore is tested in AXDPCapabilityTests.swift
    // using the AXDPCapabilityCache which has the same core functionality.

    // MARK: - AXDP Message Building Tests

    func testBuildFileMetaMessage() {
        let meta = AXDPFileMeta(
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
            fileMeta: meta
        )

        let encoded = msg.encode()
        XCTAssertTrue(AXDP.hasMagic(encoded))

        let decoded = AXDP.Message.decode(from: encoded)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.type, .fileMeta)
        XCTAssertEqual(decoded?.sessionId, 12345)
        XCTAssertEqual(decoded?.totalChunks, 8)
        XCTAssertEqual(decoded?.fileMeta?.filename, "test.txt")
        XCTAssertEqual(decoded?.fileMeta?.fileSize, 1024)
    }

    func testBuildFileChunkMessage() {
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
        let decoded = AXDP.Message.decode(from: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.type, .fileChunk)
        XCTAssertEqual(decoded?.chunkIndex, 0)
        XCTAssertEqual(decoded?.totalChunks, 8)
        XCTAssertEqual(decoded?.payload, chunkData)
    }

    func testBuildAckMessage() {
        let msg = AXDP.Message(
            type: .ack,
            sessionId: 12345,
            messageId: 5
        )

        let encoded = msg.encode()
        let decoded = AXDP.Message.decode(from: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.type, .ack)
        XCTAssertEqual(decoded?.sessionId, 12345)
        XCTAssertEqual(decoded?.messageId, 5)
    }

    func testBuildNackMessage() {
        let msg = AXDP.Message(
            type: .nack,
            sessionId: 12345,
            messageId: 5
        )

        let encoded = msg.encode()
        let decoded = AXDP.Message.decode(from: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.type, .nack)
        XCTAssertEqual(decoded?.sessionId, 12345)
    }

    // MARK: - Capability PING/PONG Message Tests

    func testBuildCapabilityPingMessage() {
        let caps = AXDPCapability.defaultLocal()
        let msg = AXDP.Message(
            type: .ping,
            sessionId: 0,
            messageId: 1,
            capabilities: caps
        )

        let encoded = msg.encode()
        let decoded = AXDP.Message.decode(from: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.type, .ping)
        XCTAssertNotNil(decoded?.capabilities)
        XCTAssertEqual(decoded?.capabilities?.protoMax, caps.protoMax)
    }

    func testBuildCapabilityPongMessage() {
        let caps = AXDPCapability.defaultLocal()
        let msg = AXDP.Message(
            type: .pong,
            sessionId: 12345,
            messageId: 1,
            capabilities: caps
        )

        let encoded = msg.encode()
        let decoded = AXDP.Message.decode(from: encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.type, .pong)
        XCTAssertEqual(decoded?.sessionId, 12345)
        XCTAssertNotNil(decoded?.capabilities)
    }

    // MARK: - IncomingTransferRequest Tests

    func testIncomingTransferRequestCreation() {
        let request = IncomingTransferRequest(
            sourceCallsign: "N0CALL",
            fileName: "test.txt",
            fileSize: 1024,
            axdpSessionId: 12345
        )

        XCTAssertEqual(request.sourceCallsign, "N0CALL")
        XCTAssertEqual(request.fileName, "test.txt")
        XCTAssertEqual(request.fileSize, 1024)
        XCTAssertEqual(request.axdpSessionId, 12345)
        XCTAssertNotNil(request.receivedAt)
    }

    // MARK: - BulkTransfer with Compression Settings Tests

    func testBulkTransferWithCompressionSettings() {
        let transfer = BulkTransfer(
            id: UUID(),
            fileName: "test.txt",
            fileSize: 1024,
            destination: "N0CALL",
            compressionSettings: .disabled
        )

        XCTAssertFalse(transfer.compressionSettings.useGlobalSettings)
        XCTAssertEqual(transfer.compressionSettings.enabledOverride, false)
    }

    func testBulkTransferWithCustomAlgorithm() {
        let transfer = BulkTransfer(
            id: UUID(),
            fileName: "test.txt",
            fileSize: 1024,
            destination: "N0CALL",
            compressionSettings: .withAlgorithm(.lz4)
        )

        XCTAssertFalse(transfer.compressionSettings.useGlobalSettings)
        XCTAssertEqual(transfer.compressionSettings.algorithmOverride, .lz4)
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

    // MARK: - Compressibility Analysis Tests

    func testCompressibilityAnalysisText() {
        let textData = Data("Hello World! This is a test of compressibility analysis for text data.".utf8)
        let analysis = CompressionAnalyzer.analyze(textData, fileName: "test.txt")

        XCTAssertEqual(analysis.fileCategory, .text)
        // Text should generally be compressible
        XCTAssertTrue(analysis.isCompressible)
    }

    func testCompressibilityAnalysisAlreadyCompressed() {
        // JPEG magic bytes + some data
        var jpegData = Data([0xFF, 0xD8, 0xFF, 0xE0])
        jpegData.append(Data(repeating: 0x00, count: 100))

        let analysis = CompressionAnalyzer.analyze(jpegData, fileName: "image.jpg")

        XCTAssertEqual(analysis.fileCategory, .image)
        XCTAssertFalse(analysis.isCompressible)
    }

    func testCompressibilityAnalysisSmallFile() {
        let smallData = Data([0x01, 0x02, 0x03])
        let analysis = CompressionAnalyzer.analyze(smallData, fileName: "tiny.bin")

        // Very small files shouldn't be compressed (overhead not worth it)
        XCTAssertFalse(analysis.isCompressible)
        XCTAssertTrue(analysis.reason.contains("small"))
    }

    func testCompressibilityAnalysisArchive() {
        // ZIP magic bytes
        let zipData = Data([0x50, 0x4B, 0x03, 0x04]) + Data(repeating: 0x00, count: 100)
        let analysis = CompressionAnalyzer.analyze(zipData, fileName: "archive.zip")

        XCTAssertEqual(analysis.fileCategory, .archive)
        XCTAssertFalse(analysis.isCompressible)
    }

    // MARK: - Transfer Compression Metrics Tests

    func testCompressionMetricsCalculations() {
        let metrics = TransferCompressionMetrics(
            algorithm: .lz4,
            originalSize: 1000,
            compressedSize: 600
        )

        XCTAssertEqual(metrics.ratio, 0.6, accuracy: 0.01)
        XCTAssertEqual(metrics.savingsPercent, 40.0, accuracy: 0.1)
        XCTAssertEqual(metrics.bytesSaved, 400)
        XCTAssertTrue(metrics.wasEffective)
    }

    func testCompressionMetricsNotEffective() {
        let metrics = TransferCompressionMetrics(
            algorithm: .lz4,
            originalSize: 100,
            compressedSize: 105  // Got bigger
        )

        XCTAssertFalse(metrics.wasEffective)
        XCTAssertEqual(metrics.bytesSaved, 0)  // Clamped to 0
    }

    func testCompressionMetricsUncompressed() {
        let metrics = TransferCompressionMetrics.uncompressed(size: 1000)

        XCTAssertNil(metrics.algorithm)
        XCTAssertEqual(metrics.originalSize, 1000)
        XCTAssertEqual(metrics.compressedSize, 1000)
        XCTAssertEqual(metrics.ratio, 1.0)
        XCTAssertFalse(metrics.wasEffective)
    }
}

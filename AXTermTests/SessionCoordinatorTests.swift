//
//  SessionCoordinatorTests.swift
//  AXTermTests
//
//  Tests for SessionCoordinator: capability discovery, file transfers, pending data queue.
//

import XCTest
@testable import AXTerm

@MainActor
final class SessionCoordinatorTests: XCTestCase {

    override func setUp() {
        super.setUp()
        #if DEBUG
        SessionCoordinator.disableCompletionNackSackRetransmitForTests = true
        #endif
    }

    override func tearDown() {
        #if DEBUG
        SessionCoordinator.disableCompletionNackSackRetransmitForTests = false
        #endif
        super.tearDown()
    }

    // Note: AXDPCapabilityStore is tested in AXDPCapabilityTests.swift
    // using the AXDPCapabilityCache which has the same core functionality.

    // MARK: - AXDP Capability Negotiation (PING/PONG)

    func testAutoNegotiateSendsPingWhenInitiatorAndExtensionsEnabled() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }

        // Enable AXDP extensions + auto-negotiation
        coordinator.globalAdaptiveSettings.axdpExtensionsEnabled = true
        coordinator.globalAdaptiveSettings.autoNegotiateCapabilities = true

        // Simulate a connected session where we are the initiator
        let session = AX25Session(
            localAddress: AX25Address(call: "LOCAL"),
            remoteAddress: AX25Address(call: "PEER"),
            path: DigiPath(),
            channel: 0,
            config: AX25SessionConfig(),
            isInitiator: true
        )

        // Manually trigger the onSessionStateChanged callback
        coordinator.sessionManager.onSessionStateChanged?(session, .connecting, .connected)

        // We don't have a full packet engine here, but we can at least assert
        // that discovery has started by checking that capability is no longer
        // "unknown" once discovery has started.
        let status = coordinator.capabilityStatus(for: "PEER")
        XCTAssertEqual(status, .pending, "Expected AXDP discovery to be pending after initiator connect with auto-negotiation enabled.")
    }

    func testEnablingAutoNegotiateWhileConnectedTriggersDiscovery() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }

        // Disable auto-negotiate initially
        coordinator.globalAdaptiveSettings.axdpExtensionsEnabled = true
        coordinator.globalAdaptiveSettings.autoNegotiateCapabilities = false

        // Simulate we already have a connected initiator session
        coordinator.sessionManager.localCallsign = AX25Address(call: "LOCAL", ssid: 1)
        let peer = AX25Address(call: "PEER", ssid: 1)
        let session = coordinator.sessionManager.session(for: peer)
        // Force session to connected state
        session.stateMachine.handle(event: .connectRequest)
        session.stateMachine.handle(event: .receivedUA)

        XCTAssertEqual(session.state, .connected)

        // At this point capability should be unknown
        XCTAssertEqual(coordinator.capabilityStatus(for: "PEER"), .unknown)

        // Turn on auto-negotiation and trigger discovery for connected sessions
        coordinator.globalAdaptiveSettings.autoNegotiateCapabilities = true
        coordinator.triggerCapabilityDiscoveryForConnectedInitiators()

        // Now discovery should be pending
        XCTAssertEqual(coordinator.capabilityStatus(for: "PEER"), .pending)
    }

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

    // MARK: - Transfer Completion ACK Handling

    /// Sender should mark transfer as completed when a completion ACK is received
    /// and the transfer is currently awaitingCompletion.
    func testHandleCompletionACKWhenAwaitingCompletion() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }

        // Set up an outbound transfer that has finished sending all chunks
        let transferId = UUID()
        let transfer = BulkTransfer(
            id: transferId,
            fileName: "test.txt",
            fileSize: 1024,
            destination: "TEST-2",
            direction: .outbound
        )

        coordinator.transfers = [transfer]
        coordinator.transfers[0].status = .awaitingCompletion

        // Map AXDP session ID to this transfer
        let axdpSessionId: UInt32 = 0x1234_5678
        coordinator.storeAXDPSessionId(axdpSessionId, for: transferId)

        // Build completion ACK from receiver
        let completionAck = AXDP.Message(
            type: .ack,
            sessionId: axdpSessionId,
            messageId: SessionCoordinator.transferCompleteMessageId
        )

        // Handle ACK
        let from = AX25Address(call: "TEST-2")
        coordinator.handleAckMessage(completionAck, from: from)

        // Transfer should now be marked completed
        XCTAssertEqual(coordinator.transfers[0].status, .completed)
        XCTAssertNotNil(coordinator.transfers[0].completedAt)
    }

    /// Even if the UI never transitioned to .awaitingCompletion (e.g. due to a race
    /// or chunk-count mismatch), a completion ACK from the receiver MUST still cause
    /// the sender to mark the transfer as completed.
    func testHandleCompletionACKCompletesTransferEvenIfNotAwaitingCompletion() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }

        // Simulate an outbound transfer that is still in .sending state
        let transferId = UUID()
        var transfer = BulkTransfer(
            id: transferId,
            fileName: "test.txt",
            fileSize: 1024,
            destination: "TEST-2",
            direction: .outbound
        )
        transfer.status = .sending

        coordinator.transfers = [transfer]

        // Map AXDP session ID to this transfer
        let axdpSessionId: UInt32 = 0xCAFEBABE
        coordinator.storeAXDPSessionId(axdpSessionId, for: transferId)

        // Build completion ACK from receiver
        let completionAck = AXDP.Message(
            type: .ack,
            sessionId: axdpSessionId,
            messageId: SessionCoordinator.transferCompleteMessageId
        )

        // Handle ACK
        let from = AX25Address(call: "TEST-2")
        coordinator.handleAckMessage(completionAck, from: from)

        // Transfer should still be marked completed even though it wasn't in
        // .awaitingCompletion at the time the ACK arrived.
        XCTAssertEqual(coordinator.transfers[0].status, .completed)
        XCTAssertNotNil(coordinator.transfers[0].completedAt)
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

    // MARK: - Receiver Completion Detection Tests

    /// Test that InboundTransferState correctly detects completion when all chunks received
    func testInboundTransferStateDetectsCompletion() {
        // Test with 21 chunks (indices 0-20) to match the bug scenario
        var state = InboundTransferState(
            axdpSessionId: 1491564977,
            sourceCallsign: "TEST-1",
            fileName: "test.csv",
            fileSize: 2688,  // 21 chunks of 128 bytes
            expectedChunks: 21,
            chunkSize: 128,
            sha256: Data(repeating: 0xAB, count: 32),
            compressionAlgorithm: .none
        )

        // Receive chunks 0-19 (20 chunks)
        for i in 0..<20 {
            state.receiveChunk(index: i, data: Data(repeating: UInt8(i), count: 128))
            XCTAssertFalse(state.isComplete, "Should not be complete after \(i+1) chunks")
        }
        XCTAssertEqual(state.receivedChunks.count, 20)

        // Receive final chunk (index 20) - should complete
        state.receiveChunk(index: 20, data: Data(repeating: 0x14, count: 128))
        XCTAssertTrue(state.isComplete, "Should be complete after receiving all 21 chunks (indices 0-20)")
        XCTAssertEqual(state.receivedChunks.count, 21, "Should have received all 21 chunks")
        XCTAssertNotNil(state.endTime, "endTime should be set when complete")
    }

    /// Test that sender shows awaitingAcceptance status correctly
    func testSenderShowsAwaitingAcceptanceStatus() {
        var transfer = BulkTransfer(
            id: UUID(),
            fileName: "test.txt",
            fileSize: 1024,
            destination: "TEST-2",
            direction: .outbound
        )

        transfer.status = .awaitingAcceptance
        XCTAssertEqual(transfer.status, .awaitingAcceptance)
        XCTAssertTrue(transfer.canCancel, "Should be able to cancel while awaiting acceptance")
        XCTAssertFalse(transfer.canPause, "Cannot pause while awaiting acceptance")
    }

    // MARK: - Completion Request / NACK SACK Bitmap (Robust File Transfer)

    /// Completion request and completion ACK message ID constants
    func testCompletionRequestAndTransferCompleteMessageIdConstants() {
        XCTAssertEqual(SessionCoordinator.transferCompleteMessageId, 0xFFFFFFFF)
        XCTAssertEqual(SessionCoordinator.completionRequestMessageId, 0xFFFFFFFE)
    }

    /// NACK with SACK bitmap (missing chunks) must not mark transfer as failed; transfer stays awaitingCompletion
    func testNackWithSackBitmapDoesNotFailTransfer() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }

        let transferId = UUID()
        var transfer = BulkTransfer(
            id: transferId,
            fileName: "test.txt",
            fileSize: 512,
            destination: "TEST-2",
            direction: .outbound
        )
        transfer.status = .awaitingCompletion
        coordinator.transfers = [transfer]

        let axdpSessionId: UInt32 = 0x1234_5678
        coordinator.storeAXDPSessionId(axdpSessionId, for: transferId)

        // SACK bitmap: receiver has chunks 0,1,3 (missing 2) out of 4
        var sack = AXDPSACKBitmap(baseChunk: 0, windowSize: 4)
        sack.markReceived(chunk: 0)
        sack.markReceived(chunk: 1)
        sack.markReceived(chunk: 3)

        let sackData = sack.encode()
        XCTAssertFalse(sackData.isEmpty, "SACK bitmap should not be empty")

        let nack = AXDP.Message(
            type: .nack,
            sessionId: axdpSessionId,
            messageId: SessionCoordinator.transferCompleteMessageId,
            chunkIndex: nil,
            totalChunks: nil,
            payload: nil,
            payloadCRC32: nil,
            sackBitmap: sackData
        )
        XCTAssertNotNil(nack.sackBitmap, "NACK must carry SACK bitmap for this test")
        XCTAssertEqual(nack.messageId, SessionCoordinator.transferCompleteMessageId)

        let from = AX25Address(call: "TEST-2")
        coordinator.handleNackMessage(nack, from: from)

        XCTAssertEqual(coordinator.transfers.count, 1, "Transfer should still be in list")
        let status = coordinator.transfers[0].status
        XCTAssertEqual(status, .awaitingCompletion, "NACK with SACK bitmap must not mark transfer as failed; got \(status)")
    }

    /// NACK with SACK bitmap but no transfer in transferSessionIds (e.g. unknown session) must not touch transfers
    func testNackWithSackBitmapNoFileDataDoesNotFailTransfer() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }

        let transferId = UUID()
        var transfer = BulkTransfer(
            id: transferId,
            fileName: "test.txt",
            fileSize: 512,
            destination: "TEST-2",
            direction: .outbound
        )
        transfer.status = .awaitingCompletion
        coordinator.transfers = [transfer]

        let axdpSessionId: UInt32 = 0xCAFE_BABE
        // Do NOT call storeAXDPSessionId - so NACK is "completion with SACK" but no matching transfer;
        // handler must return without marking any transfer as failed
        var sack = AXDPSACKBitmap(baseChunk: 0, windowSize: 4)
        sack.markReceived(chunk: 0)

        let sackData = sack.encode()
        let nack = AXDP.Message(
            type: .nack,
            sessionId: axdpSessionId,
            messageId: SessionCoordinator.transferCompleteMessageId,
            chunkIndex: nil,
            totalChunks: nil,
            payload: nil,
            payloadCRC32: nil,
            sackBitmap: sackData
        )
        XCTAssertNotNil(nack.sackBitmap)

        let from = AX25Address(call: "TEST-2")
        coordinator.handleNackMessage(nack, from: from)

        XCTAssertEqual(coordinator.transfers.count, 1)
        XCTAssertEqual(coordinator.transfers[0].status, .awaitingCompletion, "NACK with SACK must not mark transfer failed when no session mapping")
    }
}

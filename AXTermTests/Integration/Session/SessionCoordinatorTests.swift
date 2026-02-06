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
        XCTAssertEqual(coordinator.capabilityStatus(for: peer.display), .unknown)

        // Turn on auto-negotiation and trigger discovery for connected sessions
        coordinator.globalAdaptiveSettings.autoNegotiateCapabilities = true
        coordinator.triggerCapabilityDiscoveryForConnectedInitiators()

        // Now discovery should be pending
        XCTAssertEqual(coordinator.capabilityStatus(for: peer.display), .pending)
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

        let decoded = AXDP.Message.decodeMessage(from: encoded)
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
        let decoded = AXDP.Message.decodeMessage(from: encoded)

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
        let decoded = AXDP.Message.decodeMessage(from: encoded)

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
        let decoded = AXDP.Message.decodeMessage(from: encoded)

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
        let decoded = AXDP.Message.decodeMessage(from: encoded)

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
        let decoded = AXDP.Message.decodeMessage(from: encoded)

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

    // MARK: - Adaptive transmission: enable/disable, clear, per-station reset

    func testClearAllLearnedResetsSettingsAndOverrides() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }

        coordinator.adaptiveTransmissionEnabled = true
        coordinator.globalAdaptiveSettings.windowSize.currentAdaptive = 1
        coordinator.globalAdaptiveSettings.paclen.currentAdaptive = 64
        coordinator.useDefaultConfigForDestinations.insert("N0CALL-1")

        coordinator.clearAllLearned()

        XCTAssertEqual(coordinator.globalAdaptiveSettings.windowSize.currentAdaptive, 2)
        XCTAssertEqual(coordinator.globalAdaptiveSettings.paclen.currentAdaptive, 128)
        XCTAssertTrue(coordinator.useDefaultConfigForDestinations.isEmpty)
    }

    func testResetStationToDefaultAddsToOverrideSet() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }

        coordinator.adaptiveTransmissionEnabled = true
        coordinator.resetStationToDefault(callsign: " N0CALL-2 ")

        XCTAssertTrue(coordinator.useDefaultConfigForDestinations.contains("N0CALL-2"))
    }

    func testUseGlobalAdaptiveForStationRemovesOverride() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }

        coordinator.useDefaultConfigForDestinations.insert("N0CALL-3")
        coordinator.useGlobalAdaptiveForStation(callsign: "n0call-3")

        XCTAssertFalse(coordinator.useDefaultConfigForDestinations.contains("N0CALL-3"))
    }

    func testApplyLinkQualitySampleWhenDisabledDoesNotUpdateSettings() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }

        coordinator.adaptiveTransmissionEnabled = false
        coordinator.globalAdaptiveSettings.windowSize.currentAdaptive = 2
        coordinator.globalAdaptiveSettings.paclen.currentAdaptive = 128

        coordinator.applyLinkQualitySample(lossRate: 0.5, etx: 3.0, srtt: 2.0, source: "session")

        // Should remain at defaults (no learning when disabled)
        XCTAssertEqual(coordinator.globalAdaptiveSettings.windowSize.currentAdaptive, 2)
        XCTAssertEqual(coordinator.globalAdaptiveSettings.paclen.currentAdaptive, 128)
    }

    func testApplyLinkQualitySampleWhenEnabledUpdatesSettings() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }

        coordinator.adaptiveTransmissionEnabled = true
        coordinator.applyLinkQualitySample(lossRate: 0.25, etx: 2.5, srtt: 1.0, source: "session")

        XCTAssertEqual(coordinator.globalAdaptiveSettings.windowSize.currentAdaptive, 1)
        XCTAssertEqual(coordinator.globalAdaptiveSettings.paclen.currentAdaptive, 64)
    }

    func testGetConfigForDestinationUsesDefaultWhenStationInOverrideSet() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }

        coordinator.adaptiveTransmissionEnabled = true
        coordinator.globalAdaptiveSettings.windowSize.currentAdaptive = 1
        coordinator.globalAdaptiveSettings.windowSize.mode = .auto
        coordinator.syncSessionManagerConfigFromAdaptive()
        coordinator.useDefaultConfigForDestinations.insert("PEER-1")

        let configForPeer = coordinator.sessionManager.getConfigForDestination?("PEER-1", "") ?? AX25SessionConfig()
        let configForOther = coordinator.sessionManager.getConfigForDestination?("OTHER-0", "") ?? AX25SessionConfig()

        XCTAssertEqual(configForPeer.windowSize, 4, "Overridden station should get default config (window 4)")
        XCTAssertEqual(configForOther.windowSize, 1, "Other should get learned config")
    }

    // MARK: - Per-route adaptive cache and multi-connection stabilization

    func testApplyLinkQualitySampleWithRouteKeyUpdatesPerRouteCache() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }

        coordinator.adaptiveTransmissionEnabled = true
        let routeKey = RouteAdaptiveKey(destination: "PEER-0", pathSignature: "VIA,WIDE1-1")
        coordinator.applyLinkQualitySample(lossRate: 0.35, etx: 3.0, srtt: nil, source: "session", routeKey: routeKey)

        let config = coordinator.sessionManager.getConfigForDestination?("PEER-0", "VIA,WIDE1-1") ?? AX25SessionConfig()
        XCTAssertEqual(config.windowSize, 1, "Per-route high loss should yield window 1")
        XCTAssertEqual(config.maxRetries, 10)
    }

    func testApplyLinkQualitySampleWithoutRouteKeyUpdatesGlobalOnly() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }

        coordinator.adaptiveTransmissionEnabled = true
        coordinator.applyLinkQualitySample(lossRate: 0.25, etx: 2.5, srtt: 1.0, source: "network")

        let config = coordinator.sessionManager.getConfigForDestination?("ANY-0", "") ?? AX25SessionConfig()
        XCTAssertEqual(config.windowSize, 1, "Global sample should drive global adaptive (high loss -> window 1)")
    }

    func testGetConfigForDestinationWithMultipleSessionsUsesMergedConfig() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }

        coordinator.adaptiveTransmissionEnabled = true
        coordinator.localCallsign = "LOCAL-0"
        let peer = AX25Address(call: "PEER", ssid: 0)

        coordinator.applyLinkQualitySample(lossRate: 0.4, etx: 4.0, srtt: nil, source: "session", routeKey: RouteAdaptiveKey(destination: "PEER-0", pathSignature: ""))
        coordinator.applyLinkQualitySample(lossRate: 0.05, etx: 1.1, srtt: nil, source: "session", routeKey: RouteAdaptiveKey(destination: "PEER-0", pathSignature: "DIGI-1"))
        coordinator.globalAdaptiveSettings.windowSize.currentAdaptive = 2

        _ = coordinator.sessionManager.session(for: peer, path: DigiPath())
        _ = coordinator.sessionManager.session(for: peer, path: DigiPath.from(["DIGI-1"]))

        let mergedConfig = coordinator.sessionManager.getConfigForDestination?("PEER-0", "other") ?? AX25SessionConfig()
        XCTAssertEqual(mergedConfig.windowSize, 1, "Merged config should use min(window) when multiple sessions to same destination")
        XCTAssertGreaterThanOrEqual(mergedConfig.rtoMin ?? 0, 1.0)
        XCTAssertGreaterThanOrEqual(mergedConfig.maxRetries, 10)
    }

    func testClearAllLearnedClearsPerRouteCache() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }

        coordinator.adaptiveTransmissionEnabled = true
        coordinator.applyLinkQualitySample(lossRate: 0.3, etx: 2.5, srtt: nil, source: "session", routeKey: RouteAdaptiveKey(destination: "PEER-0", pathSignature: "VIA"))

        coordinator.clearAllLearned()

        let config = coordinator.sessionManager.getConfigForDestination?("PEER-0", "VIA") ?? AX25SessionConfig()
        XCTAssertEqual(config.windowSize, 2, "After clear, should fall back to global defaults (window 2)")
        XCTAssertEqual(coordinator.globalAdaptiveSettings.windowSize.currentAdaptive, 2)
    }

    func testAdaptiveDisabledReturnsDefaultConfig() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }

        coordinator.adaptiveTransmissionEnabled = false
        coordinator.globalAdaptiveSettings.windowSize.currentAdaptive = 1

        let config = coordinator.sessionManager.getConfigForDestination?("PEER-0", "") ?? AX25SessionConfig()
        XCTAssertEqual(config.windowSize, 4, "When adaptive disabled, should get default session config")
    }

    func testConfigFixedAtSessionCreation() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }

        coordinator.adaptiveTransmissionEnabled = true
        coordinator.globalAdaptiveSettings.windowSize.currentAdaptive = 2
        coordinator.syncSessionManagerConfigFromAdaptive()
        coordinator.localCallsign = "LOCAL-0"
        let peer = AX25Address(call: "PEER", ssid: 0)

        let session = coordinator.sessionManager.session(for: peer, path: DigiPath())
        let configAtCreation = session.stateMachine.config
        XCTAssertEqual(configAtCreation.windowSize, 2)

        coordinator.globalAdaptiveSettings.windowSize.currentAdaptive = 1
        coordinator.applyLinkQualitySample(lossRate: 0.4, etx: 3.0, srtt: nil, source: "session")

        let sameSession = coordinator.sessionManager.existingSession(for: peer, path: DigiPath())
        XCTAssertNotNil(sameSession)
        XCTAssertEqual(sameSession!.stateMachine.config.windowSize, configAtCreation.windowSize, "Session config must not change mid-session")
    }

    func testPerRouteVsDirectUseSeparateCacheEntries() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }

        coordinator.adaptiveTransmissionEnabled = true
        coordinator.applyLinkQualitySample(lossRate: 0.05, etx: 1.1, srtt: nil, source: "session", routeKey: RouteAdaptiveKey(destination: "PEER-0", pathSignature: ""))
        coordinator.applyLinkQualitySample(lossRate: 0.35, etx: 3.5, srtt: nil, source: "session", routeKey: RouteAdaptiveKey(destination: "PEER-0", pathSignature: "DIGI-1"))

        let configDirect = coordinator.sessionManager.getConfigForDestination?("PEER-0", "") ?? AX25SessionConfig()
        let configVia = coordinator.sessionManager.getConfigForDestination?("PEER-0", "DIGI-1") ?? AX25SessionConfig()

        XCTAssertEqual(configDirect.windowSize, 3, "Direct route good link -> larger window")
        XCTAssertEqual(configVia.windowSize, 1, "Via route high loss -> window 1")
    }

    func testRouteAdaptiveKeyNormalizesDestinationInLookup() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }

        coordinator.adaptiveTransmissionEnabled = true
        coordinator.applyLinkQualitySample(lossRate: 0.3, etx: 2.5, srtt: nil, source: "session", routeKey: RouteAdaptiveKey(destination: "PEER-0", pathSignature: ""))

        let configLower = coordinator.sessionManager.getConfigForDestination?("peer-0", "") ?? AX25SessionConfig()
        let configUpper = coordinator.sessionManager.getConfigForDestination?("PEER-0", "") ?? AX25SessionConfig()
        XCTAssertEqual(configLower.windowSize, configUpper.windowSize, "Lookup should normalize destination for cache hit")
    }

    // MARK: - Duplicate Subscription Prevention (KB5YZB-7 bug)

    /// Proves that calling subscribeToPackets twice does NOT produce duplicate processing.
    /// Before the fix, each call added another Combine subscriber, causing every inbound
    /// I-frame to be processed N times — generating N RR frames per packet.
    func testSubscribeToPacketsTwiceDoesNotDuplicateProcessing() async throws {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        defaults.set(false, forKey: AppSettingsStore.persistKey)
        let settings = AppSettingsStore(defaults: defaults)
        settings.myCallsign = "LOCAL-7"

        let client = PacketEngine(maxPackets: 100, maxConsoleLines: 100, maxRawChunks: 100, settings: settings)
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }
        coordinator.localCallsign = "LOCAL-7"

        // Simulate SwiftUI calling ContentView.init() twice — calls subscribeToPackets twice
        coordinator.subscribeToPackets(from: client)
        coordinator.subscribeToPackets(from: client)

        // Set up a connected session
        let peer = AX25Address(call: "PEER", ssid: 7)
        _ = coordinator.sessionManager.connect(to: peer, path: DigiPath(), channel: 0)
        coordinator.sessionManager.handleInboundUA(from: peer, path: DigiPath(), channel: 0)

        // Count data deliveries to detect duplicate processing
        var dataDeliveryCount = 0
        coordinator.sessionManager.onDataReceived = { _, _ in
            dataDeliveryCount += 1
        }

        // Inject an I-frame packet addressed to us
        let iFramePacket = Packet(
            timestamp: Date(),
            from: peer,
            to: AX25Address(call: "LOCAL", ssid: 7),
            via: [],
            frameType: .i,
            control: 0x00, // ns=0, nr=0, P=0
            controlByte1: nil,
            pid: 0xF0,
            info: Data("Hello from peer".utf8),
            rawAx25: Data()
        )

        client.handleIncomingPacket(iFramePacket)

        // Yield to allow Combine's receive(on: DispatchQueue.main) to deliver
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms

        // With the fix, data should be delivered exactly once.
        // Before the fix, it was delivered twice (once per subscriber).
        XCTAssertEqual(dataDeliveryCount, 1,
            "I-frame data must be delivered exactly once; duplicate subscriptions must not cause double processing")
    }

    /// Proves that after multiple subscribeToPackets calls, the session state machine
    /// receives each I-frame exactly once — preventing duplicate RR generation.
    func testSubscribeToPacketsReplacesNotAccumulatesSubscriptions() async throws {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        defaults.set(false, forKey: AppSettingsStore.persistKey)
        let settings = AppSettingsStore(defaults: defaults)
        settings.myCallsign = "LOCAL-7"

        let client = PacketEngine(maxPackets: 100, maxConsoleLines: 100, maxRawChunks: 100, settings: settings)
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }
        coordinator.localCallsign = "LOCAL-7"

        // Subscribe three times (simulating aggressive SwiftUI re-init)
        coordinator.subscribeToPackets(from: client)
        coordinator.subscribeToPackets(from: client)
        coordinator.subscribeToPackets(from: client)

        // Set up connected session
        let peer = AX25Address(call: "PEER", ssid: 7)
        _ = coordinator.sessionManager.connect(to: peer, path: DigiPath(), channel: 0)
        coordinator.sessionManager.handleInboundUA(from: peer, path: DigiPath(), channel: 0)

        var deliveryCount = 0
        coordinator.sessionManager.onDataReceived = { _, _ in
            deliveryCount += 1
        }

        // Send two sequential I-frames
        for ns in 0..<2 {
            let control = UInt8(ns << 1) // N(S) in bits 1-3, N(R)=0
            let packet = Packet(
                timestamp: Date(),
                from: peer,
                to: AX25Address(call: "LOCAL", ssid: 7),
                via: [],
                frameType: .i,
                control: control,
                controlByte1: nil,
                pid: 0xF0,
                info: Data("Frame \(ns)".utf8),
                rawAx25: Data()
            )
            client.handleIncomingPacket(packet)
        }

        // Yield to allow Combine delivery
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms

        XCTAssertEqual(deliveryCount, 2,
            "Two I-frames must produce exactly two data deliveries, not 2×N from accumulated subscriptions")
    }
}

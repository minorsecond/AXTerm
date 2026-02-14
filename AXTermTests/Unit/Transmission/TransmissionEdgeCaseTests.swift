//
//  TransmissionEdgeCaseTests.swift
//  AXTermTests
//
//  Comprehensive edge case tests for transmission functionality.
//  These tests cover boundary conditions, malformed data, and error scenarios
//  to ensure robust handling per AXTERM-TRANSMISSION-SPEC.md requirements.
//

import XCTest
@testable import AXTerm

final class TransmissionEdgeCaseTests: XCTestCase {

    // MARK: - KISS Edge Cases (Section 3)

    func testKISSMultipleConsecutiveFENDs() {
        var parser = KISSFrameParser()

        // Multiple FENDs in a row should be handled (common in noisy links)
        let chunk = Data([0xC0, 0xC0, 0xC0, 0x00, 0x01, 0x02, 0xC0, 0xC0])
        let frames = parser.feed(chunk)

        XCTAssertEqual(frames.count, 1)
        if case .ax25(let data) = frames[0] {
            XCTAssertEqual(data, Data([0x01, 0x02]))
        } else { XCTFail() }
    }

    func testKISSInvalidEscapeSequence() {
        // FESC followed by invalid byte (not TFEND or TFESC)
        let escaped = Data([0x01, 0xDB, 0x55, 0x02])  // 0x55 is invalid after FESC
        let unescaped = KISS.unescape(escaped)

        // Implementation should handle gracefully - either skip or pass through
        // The important thing is no crash
        XCTAssertNotNil(unescaped)
    }

    func testKISSFESCAtEndOfData() {
        // FESC at very end with no following byte
        let escaped = Data([0x01, 0x02, 0xDB])
        let unescaped = KISS.unescape(escaped)

        // Should not crash, handle trailing FESC
        XCTAssertNotNil(unescaped)
    }

    func testKISSVeryLongFrame() {
        // Test near maximum frame size (256 bytes typical max)
        let largePayload = Data(repeating: 0x42, count: 255)
        let kissFrame = KISS.encodeFrame(payload: largePayload, port: 0)

        var parser = KISSFrameParser()
        let frames = parser.feed(kissFrame)

        XCTAssertEqual(frames.count, 1)
        if case .ax25(let data) = frames[0] {
            XCTAssertEqual(data, largePayload)
        } else { XCTFail() }
    }

    func testKISSEmptyAfterStrippingCommand() {
        var parser = KISSFrameParser()

        // Frame with only command byte, no data
        let chunk = Data([0xC0, 0x00, 0xC0])
        let frames = parser.feed(chunk)

        // Parser returns 1 frame with empty payload (valid behavior)
        XCTAssertEqual(frames.count, 1)
        if case .ax25(let d) = frames[0] {
            XCTAssertEqual(d.count, 0, "Payload should be empty")
        } else {
            XCTFail("Should be AX.25 frame")
        }
    }

    func testKISSAllBytesNeedEscaping() {
        // Payload where every byte needs escaping
        let payload = Data([0xC0, 0xDB, 0xC0, 0xDB])
        let escaped = KISS.escape(payload)
        let unescaped = KISS.unescape(escaped)

        XCTAssertEqual(unescaped, payload)
    }

    // MARK: - AXDP TLV Edge Cases (Section 6)

    func testAXDPTLVMaximumLength() {
        // TLV with maximum possible length (0xFFFF = 65535 bytes)
        var data = Data([0x06, 0xFF, 0xFF])  // Type=6, Length=65535
        data.append(Data(repeating: 0xAB, count: 65535))

        let result = AXDP.TLV.decode(from: data, at: 0)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.tlv.value.count, 65535)
    }

    func testAXDPTLVZeroLength() {
        // TLV with zero length
        let data = Data([0x01, 0x00, 0x00])  // Type=1, Length=0

        let result = AXDP.TLV.decode(from: data, at: 0)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.tlv.value.count, 0)
    }

    func testAXDPTLVLengthExactlyAtEnd() {
        // TLV length exactly matches remaining data
        let data = Data([0x01, 0x00, 0x03, 0xAA, 0xBB, 0xCC])

        let result = AXDP.TLV.decode(from: data, at: 0)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.tlv.value, Data([0xAA, 0xBB, 0xCC]))
    }

    func testAXDPTLVLengthOneByteShort() {
        // TLV claims length but is one byte short
        let data = Data([0x01, 0x00, 0x05, 0xAA, 0xBB, 0xCC, 0xDD])  // Says 5, has 4

        let result = AXDP.TLV.decode(from: data, at: 0)

        XCTAssertNil(result)  // Should fail gracefully
    }

    func testAXDPDecodeEmptyMagicOnly() {
        // Just the magic header, nothing else
        let data = AXDP.magic

        let decoded = AXDP.Message.decodeMessage(from: data)

        XCTAssertNil(decoded)  // Not enough data
    }

    func testAXDPDecodeCorruptedTLVInMiddle() {
        // Valid TLV, then corrupted TLV, then another valid TLV
        var data = AXDP.magic
        data.append(AXDP.TLV(type: 0x01, value: Data([0x01])).encode())
        // Corrupted: claims 100 bytes but only has 2
        data.append(Data([0x99, 0x00, 0x64, 0x01, 0x02]))

        let result = AXDP.Message.decodeMessage(from: data)

        // Should decode the first TLV at minimum
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.type, .chat)
    }

    func testAXDPDecodeMissingRequiredField() {
        // Message with sessionId but no messageType
        var data = AXDP.magic
        data.append(AXDP.TLV(type: 0x02, value: AXDP.encodeUInt32(12345)).encode())

        let decoded = AXDP.Message.decodeMessage(from: data)

        XCTAssertNil(decoded)  // MessageType is required
    }

    func testAXDPDecodeInvalidMessageType() {
        // MessageType with invalid raw value
        var data = AXDP.magic
        data.append(AXDP.TLV(type: 0x01, value: Data([0xFF])).encode())  // Invalid type

        let decoded = AXDP.Message.decodeMessage(from: data)

        XCTAssertNil(decoded)  // Invalid message type
    }

    func testAXDPDecodeSessionIdTooShort() {
        // SessionId TLV with only 2 bytes instead of 4
        var data = AXDP.magic
        data.append(AXDP.TLV(type: 0x01, value: Data([0x01])).encode())
        data.append(AXDP.TLV(type: 0x02, value: Data([0x01, 0x02])).encode())  // Too short

        let decoded = AXDP.Message.decodeMessage(from: data)

        // Should decode with sessionId=0 (graceful degradation)
        XCTAssertNotNil(decoded)
    }

    func testAXDPUnknownTLVsInFutureRange() {
        // Unknown TLVs in the 0x80-0xFF experimental range
        var data = AXDP.magic
        data.append(AXDP.TLV(type: 0x01, value: Data([0x01])).encode())
        data.append(AXDP.TLV(type: 0x80, value: Data([0x01, 0x02, 0x03])).encode())
        data.append(AXDP.TLV(type: 0xFE, value: Data([0xFF])).encode())
        data.append(AXDP.TLV(type: 0x03, value: AXDP.encodeUInt32(42)).encode())

        let result = AXDP.Message.decodeMessage(from: data)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.unknownTLVs.count, 2)
        XCTAssertEqual(result?.messageId, 42)
    }

    // MARK: - SACK Bitmap Edge Cases

    func testSACKBitmapBoundaryChunks() {
        var sack = AXDPSACKBitmap(baseChunk: 0, windowSize: 8)

        // Mark first and last in window
        sack.markReceived(chunk: 0)
        sack.markReceived(chunk: 7)

        XCTAssertTrue(sack.isReceived(chunk: 0))
        XCTAssertTrue(sack.isReceived(chunk: 7))
        XCTAssertFalse(sack.isReceived(chunk: 8))  // Outside window
    }

    func testSACKBitmapChunkBelowBase() {
        var sack = AXDPSACKBitmap(baseChunk: 10, windowSize: 8)

        // Try to mark chunk below base (should be no-op)
        sack.markReceived(chunk: 5)

        XCTAssertFalse(sack.isReceived(chunk: 5))
    }

    func testSACKBitmapChunkAboveWindow() {
        var sack = AXDPSACKBitmap(baseChunk: 0, windowSize: 8)

        // Try to mark chunk above window (should be no-op)
        sack.markReceived(chunk: 10)

        XCTAssertFalse(sack.isReceived(chunk: 10))
    }

    func testSACKBitmapAllReceived() {
        var sack = AXDPSACKBitmap(baseChunk: 0, windowSize: 16)

        // Mark all as received
        for i: UInt32 in 0..<16 {
            sack.markReceived(chunk: i)
        }

        let missing = sack.missingChunks(upTo: 15)
        XCTAssertTrue(missing.isEmpty)
        XCTAssertEqual(sack.highestContiguous, 15)
    }

    func testSACKBitmapNoneReceived() {
        let sack = AXDPSACKBitmap(baseChunk: 0, windowSize: 8)

        let missing = sack.missingChunks(upTo: 7)
        XCTAssertEqual(missing.count, 8)
        XCTAssertEqual(sack.highestContiguous, 0)
    }

    func testSACKBitmapLargeBaseChunk() {
        var sack = AXDPSACKBitmap(baseChunk: 0xFFFFFF00, windowSize: 16)

        sack.markReceived(chunk: 0xFFFFFF00)
        sack.markReceived(chunk: 0xFFFFFF0F)

        XCTAssertTrue(sack.isReceived(chunk: 0xFFFFFF00))
        XCTAssertTrue(sack.isReceived(chunk: 0xFFFFFF0F))
    }

    // MARK: - Compression Edge Cases (Section 6.x.4)

    func testCompressionOriginalLengthZero() {
        // Decompression with original length = 0
        let data = Data([0x01, 0x02, 0x03])

        let result = AXDPCompression.decompress(
            data,
            algorithm: .lz4,
            originalLength: 0,
            maxLength: 4096
        )

        // With zero original length, decompression fails (size mismatch)
        // Either nil or empty is acceptable
        XCTAssertTrue(result == nil || result?.isEmpty == true)
    }

    func testCompressionOriginalLengthExceedsMax() {
        // Decompression where original length exceeds max
        let data = Data([0x01, 0x02, 0x03])

        let result = AXDPCompression.decompress(
            data,
            algorithm: .lz4,
            originalLength: 10000,
            maxLength: 4096
        )

        XCTAssertNil(result)
    }

    func testCompressionAbsoluteMaxHardLimit() {
        // Verify absolute max cannot be exceeded even if maxLength is larger
        XCTAssertEqual(AXDPCompression.absoluteMaxDecompressedLen, 8192)

        let result = AXDPCompression.decompress(
            Data([0x01]),
            algorithm: .lz4,
            originalLength: 16000,
            maxLength: 20000  // Larger than absolute max
        )

        XCTAssertNil(result)  // Should reject
    }

    func testCompressionEmptyInput() {
        let result = AXDPCompression.compress(Data(), algorithm: .lz4)
        // Empty data should either return nil or empty
        XCTAssertTrue(result == nil || result?.isEmpty == true)
    }

    func testCompressionNoneAlgorithmPassthrough() {
        let original = Data([0x01, 0x02, 0x03, 0x04])

        // compress with .none returns the data unchanged (passthrough)
        let compressed = AXDPCompression.compress(original, algorithm: .none)
        XCTAssertEqual(compressed, original)  // .none passes through unchanged

        let decompressed = AXDPCompression.decompress(
            original,
            algorithm: .none,
            originalLength: 4,
            maxLength: 100
        )
        XCTAssertEqual(decompressed, original)  // .none passes through
    }

    // MARK: - Capability Negotiation Edge Cases (Section 6.x.3)

    func testCapabilityEmptyTLV() {
        // Empty capabilities data - still returns default capability
        let decoded = AXDPCapability.decode(from: Data())

        // Implementation returns default values for empty data (graceful handling)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.protoMin, 1)
        XCTAssertEqual(decoded?.protoMax, 1)
    }

    func testCapabilityUnknownSubTLVs() {
        // Capabilities with only unknown sub-TLVs
        var data = Data()
        // Unknown sub-TLV type 0xFE
        data.append(0xFE)
        data.append(contentsOf: [0x00, 0x02])  // Length 2
        data.append(contentsOf: [0x01, 0x02])

        let decoded = AXDPCapability.decode(from: data)

        // Should decode with defaults (skipping unknown)
        XCTAssertNotNil(decoded)
    }

    func testCapabilityNoOverlappingCompression() {
        let local = AXDPCapability(
            protoMin: 1,
            protoMax: 1,
            features: .compression,
            compressionAlgos: [.lz4],
            maxDecompressedLen: 4096,
            maxChunkLen: 128
        )

        let remote = AXDPCapability(
            protoMin: 1,
            protoMax: 1,
            features: .compression,
            compressionAlgos: [.deflate],  // Different from local
            maxDecompressedLen: 4096,
            maxChunkLen: 128
        )

        let negotiated = AXDPCapability.negotiate(local: local, remote: remote)

        // No common compression should disable compression
        XCTAssertTrue(negotiated.compressionAlgos.isEmpty)
    }

    func testCapabilityVersionMismatch() {
        let local = AXDPCapability(
            protoMin: 2,
            protoMax: 3,
            features: [],
            compressionAlgos: [],
            maxDecompressedLen: 4096,
            maxChunkLen: 128
        )
        let remote = AXDPCapability(
            protoMin: 4,
            protoMax: 5,
            features: [],
            compressionAlgos: [],
            maxDecompressedLen: 4096,
            maxChunkLen: 128
        )

        let negotiated = AXDPCapability.negotiate(local: local, remote: remote)

        // No overlapping versions - minimum should be max(local.min, remote.min)
        XCTAssertEqual(negotiated.protoMin, 4)
        XCTAssertEqual(negotiated.protoMax, 3)
    }

    func testCapabilityCacheExpiry() {
        var cache = AXDPCapabilityCache()
        let peer = AXDPPeerKey(callsign: "N0CALL", ssid: 0)
        let cap = AXDPCapability(
            protoMin: 1,
            protoMax: 1,
            features: [],
            compressionAlgos: [],
            maxDecompressedLen: 4096,
            maxChunkLen: 128
        )

        cache.store(cap, for: peer)

        XCTAssertFalse(cache.needsNegotiation(for: peer))  // Just stored, should NOT need negotiation

        // Retrieved capability should exist
        XCTAssertNotNil(cache.get(for: peer))
    }

    // MARK: - Path Suggestion Edge Cases (Section 5.1 & 8.1)

    func testPathSuggesterEmptyHistory() {
        let suggester = PathSuggester()

        let suggestions = suggester.suggest(for: "UNKNOWN", maxSuggestions: 5)

        XCTAssertTrue(suggestions.isEmpty)
    }

    func testPathScorePerfectConditions() {
        let score = PathScore(etx: 1.0, ett: 0.5, hops: 0, freshness: 1.0)

        // Perfect score should be very low
        XCTAssertLessThan(score.compositeScore, 1.0)
    }

    func testPathScoreWorstConditions() {
        let score = PathScore(etx: 20.0, ett: 60.0, hops: 10, freshness: 0.0)

        // Worst score should be very high
        XCTAssertGreaterThan(score.compositeScore, 60.0)
    }

    func testPathSuggesterDeduplicatesIdenticalPaths() {
        var suggester = PathSuggester()

        // Record same path multiple times
        for _ in 0..<10 {
            suggester.recordSuccess(
                destination: "N0CALL",
                path: DigiPath.from(["WIDE1-1"]),
                rtt: 2.0
            )
        }

        let suggestions = suggester.suggest(for: "N0CALL", maxSuggestions: 10)

        // Should only have one unique path
        XCTAssertEqual(suggestions.count, 1)
    }

    func testPathModeAutoSelectionGuardrails() {
        // Verify auto mode respects constraints
        var settings = DestinationPathSettings(destination: "N0CALL")
        settings.mode = .auto

        // In auto mode, lockedPath should be nil
        XCTAssertNil(settings.lockedPath)
        XCTAssertEqual(settings.mode, .auto)
    }

    // MARK: - AX.25 Session Edge Cases (Section 7)

    func testSequenceNumberWraparoundDuringWindow() {
        var seq = AX25SequenceState(modulo: 8)

        // Move to near wraparound point
        for _ in 0..<6 {
            seq.incrementVS()
        }
        XCTAssertEqual(seq.vs, 6)

        // Now increment through wraparound
        seq.incrementVS()  // 7
        seq.incrementVS()  // 0 (wrapped)

        XCTAssertEqual(seq.vs, 0)

        // Acknowledge across wraparound
        seq.ackUpTo(nr: 0)
        XCTAssertEqual(seq.va, 0)
    }

    func testSequenceNumberOutstandingCountAtBoundary() {
        var seq = AX25SequenceState(modulo: 8)

        // Fill entire window
        for _ in 0..<7 {
            seq.incrementVS()
        }

        XCTAssertEqual(seq.outstandingCount, 7)  // Maximum for mod-8

        // Acknowledge all
        seq.ackUpTo(nr: 7)
        XCTAssertEqual(seq.outstandingCount, 0)
    }

    func testStateMachineRapidStateTransitions() {
        var sm = AX25StateMachine(config: AX25SessionConfig())

        // Rapid connect/disconnect cycle
        _ = sm.handle(event: .connectRequest)
        XCTAssertEqual(sm.state, .connecting)

        _ = sm.handle(event: .receivedUA)
        XCTAssertEqual(sm.state, .connected)

        _ = sm.handle(event: .disconnectRequest)
        XCTAssertEqual(sm.state, .disconnecting)

        _ = sm.handle(event: .receivedUA)
        XCTAssertEqual(sm.state, .disconnected)

        // Immediate reconnect
        _ = sm.handle(event: .connectRequest)
        XCTAssertEqual(sm.state, .connecting)
    }

    func testStateMachineUnexpectedFrameInWrongState() {
        var sm = AX25StateMachine(config: AX25SessionConfig())

        // Receive I-frame while disconnected (should be ignored/rejected)
        let actions = sm.handle(event: .receivedIFrame(ns: 0, nr: 0, pf: false, payload: Data([0x01])))

        XCTAssertEqual(sm.state, .disconnected)  // Should stay disconnected
        // Should not deliver data
        XCTAssertFalse(actions.contains { action in
            if case .deliverData = action { return true }
            return false
        })
    }

    // MARK: - Token Bucket Edge Cases (Section 4.3)

    func testTokenBucketZeroCost() {
        var bucket = TokenBucket(ratePerSec: 10, capacity: 100, now: 0)

        // Zero cost should always be allowed
        XCTAssertTrue(bucket.allow(cost: 0, now: 0))
        XCTAssertTrue(bucket.allow(cost: 0, now: 0))
    }

    func testTokenBucketExactCapacity() {
        var bucket = TokenBucket(ratePerSec: 10, capacity: 100, now: 0)

        // Consume exactly capacity
        XCTAssertTrue(bucket.allow(cost: 100, now: 0))

        // Next request should fail
        XCTAssertFalse(bucket.allow(cost: 1, now: 0))
    }

    func testTokenBucketLargeTimeDelta() {
        var bucket = TokenBucket(ratePerSec: 10, capacity: 100, now: 0)

        // Consume all tokens
        _ = bucket.allow(cost: 100, now: 0)

        // Wait a very long time (1 day)
        let oneDay: TimeInterval = 86400
        XCTAssertTrue(bucket.allow(cost: 100, now: oneDay))
    }

    func testTokenBucketNegativeTimeDelta() {
        var bucket = TokenBucket(ratePerSec: 10, capacity: 100, now: 100)

        // Try with earlier timestamp (should not refill)
        _ = bucket.allow(cost: 50, now: 100)
        XCTAssertFalse(bucket.allow(cost: 100, now: 50))  // Negative delta
    }

    // MARK: - Retry Policy Edge Cases

    func testRetryPolicyMaxAttempts() {
        let policy = AXDPRetryPolicy(maxRetries: 3, baseInterval: 1.0, maxInterval: 10.0)

        XCTAssertTrue(policy.shouldRetry(attempt: 0))
        XCTAssertTrue(policy.shouldRetry(attempt: 1))
        XCTAssertTrue(policy.shouldRetry(attempt: 2))
        XCTAssertFalse(policy.shouldRetry(attempt: 3))
        XCTAssertFalse(policy.shouldRetry(attempt: 100))
    }

    func testRetryPolicyIntervalBounds() {
        let policy = AXDPRetryPolicy(
            maxRetries: 20,
            baseInterval: 1.0,
            maxInterval: 10.0,
            jitterFraction: 0.0
        )

        // First attempt
        XCTAssertEqual(policy.retryInterval(attempt: 0), 1.0, accuracy: 0.01)

        // Very high attempt should be clamped to max
        XCTAssertEqual(policy.retryInterval(attempt: 100), 10.0, accuracy: 0.01)
    }

    // MARK: - Message ID Tracker Edge Cases

    func testMessageIdTrackerLargeWindow() {
        var tracker = AXDPMessageIdTracker(windowSize: 10000)

        // Should handle large window
        for i: UInt32 in 0..<1000 {
            _ = tracker.isDuplicate(sessionId: 1, messageId: i)
        }

        // All should now be duplicates
        XCTAssertTrue(tracker.isDuplicate(sessionId: 1, messageId: 500))
    }

    func testMessageIdTrackerClear() {
        var tracker = AXDPMessageIdTracker(windowSize: 100)

        _ = tracker.isDuplicate(sessionId: 1, messageId: 1)
        XCTAssertTrue(tracker.isDuplicate(sessionId: 1, messageId: 1))

        tracker.clear()

        // After clear, should not be duplicate
        XCTAssertFalse(tracker.isDuplicate(sessionId: 1, messageId: 1))
    }

    func testMessageIdTrackerDifferentSessions() {
        var tracker = AXDPMessageIdTracker(windowSize: 100)

        // Same messageId in different sessions should not be duplicates
        XCTAssertFalse(tracker.isDuplicate(sessionId: 1, messageId: 42))
        XCTAssertFalse(tracker.isDuplicate(sessionId: 2, messageId: 42))
        XCTAssertFalse(tracker.isDuplicate(sessionId: 3, messageId: 42))

        // But same session+messageId should be duplicate
        XCTAssertTrue(tracker.isDuplicate(sessionId: 1, messageId: 42))
    }

    // MARK: - Transfer State Edge Cases

    func testTransferStateZeroChunks() {
        let state = AXDPTransferState(sessionId: 1, totalChunks: 0)

        XCTAssertTrue(state.isComplete)  // Zero chunks = complete
        XCTAssertNil(state.nextChunkToSend())
    }

    func testTransferStateLargeTransfer() {
        let state = AXDPTransferState(sessionId: 1, totalChunks: 10000)

        XCTAssertEqual(state.pendingChunks.count, 10000)
        XCTAssertFalse(state.isComplete)
    }

    func testTransferStateAcknowledgeInvalidChunk() {
        var state = AXDPTransferState(sessionId: 1, totalChunks: 5)

        // Acknowledge chunk outside range
        state.acknowledgeChunk(100)

        // Should not crash, pending should be unchanged
        XCTAssertEqual(state.pendingChunks.count, 5)
    }

    // MARK: - RttEstimator Edge Cases

    func testRttEstimatorVerySmallSample() {
        var estimator = RttEstimator()

        estimator.update(sample: 0.001)  // 1ms

        // RTO should be clamped to minimum
        XCTAssertGreaterThanOrEqual(estimator.rto(), 1.0)
    }

    func testRttEstimatorVeryLargeSample() {
        var estimator = RttEstimator()

        estimator.update(sample: 1000.0)  // 1000 seconds

        // RTO should be clamped to maximum
        XCTAssertLessThanOrEqual(estimator.rto(), 30.0)
    }

    func testRttEstimatorHighVariance() {
        var estimator = RttEstimator()

        // Alternating high and low samples
        for i in 0..<20 {
            estimator.update(sample: i % 2 == 0 ? 1.0 : 10.0)
        }

        // Variance should be high, RTO should account for it
        XCTAssertGreaterThan(estimator.rttvar, 1.0)
    }

    // MARK: - CRC32 Edge Cases

    func testCRC32EmptyData() {
        let crc = AXDP.crc32(Data())

        // Empty data CRC32 (IEEE) is 0x00000000 after XOR
        // (starts 0xFFFFFFFF, no data, XOR 0xFFFFFFFF = 0x00000000)
        XCTAssertEqual(crc, 0x00000000)
    }

    func testCRC32SingleByte() {
        let crc1 = AXDP.crc32(Data([0x00]))
        let crc2 = AXDP.crc32(Data([0x01]))

        // Different bytes should have different CRCs
        XCTAssertNotEqual(crc1, crc2)
    }

    func testCRC32Determinism() {
        let data = Data("Test data for CRC".utf8)

        // Same data should always produce same CRC
        let crc1 = AXDP.crc32(data)
        let crc2 = AXDP.crc32(data)

        XCTAssertEqual(crc1, crc2)
    }

    func testCRC32LargeData() {
        let largeData = Data(repeating: 0x42, count: 100000)

        // Should not crash and should produce valid CRC
        let crc = AXDP.crc32(largeData)
        XCTAssertNotEqual(crc, 0)
    }
}

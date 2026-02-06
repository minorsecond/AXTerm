//
//  AX25TransmissionTests.swift
//  AXTermTests
//
//  Tests for AX.25 transmission logic: acknowledgeUpTo, retransmit, send/receive flow.
//  Ensures sender does not over-send and RR handling is correct for sequence wrap.
//

import XCTest
@testable import AXTerm

@MainActor
final class AX25TransmissionTests: XCTestCase {

    // MARK: - acknowledgeUpTo(from:to:) Tests

    /// RR(N(R)=4) means "I expect 4 next" = receiver has received 0,1,2,3. Remove 0,1,2,3; keep 4,5,6,7.
    func testAcknowledgeUpToRemovesAllAckedByNr() {
        let manager = AX25SessionManager()
        let dest = AX25Address(call: "TEST", ssid: 2)
        let src = AX25Address(call: "TEST", ssid: 1)
        _ = manager.connect(to: dest, path: DigiPath(), channel: 0)
        manager.handleInboundUA(from: dest, path: DigiPath(), channel: 0)
        let session = manager.session(for: dest, path: DigiPath(), channel: 0)

        let payload = Data([0x41, 0x58, 0x54, 0x31])
        for ns in 0..<8 {
            session.sendBuffer[ns] = OutboundFrame(
                destination: dest,
                source: src,
                payload: payload,
                frameType: "i",
                pid: 0xF0,
                ns: ns,
                nr: 0
            )
        }

        session.acknowledgeUpTo(from: 0, to: 4)

        let remaining = Set(session.sendBuffer.keys)
        let expected = Set([4, 5, 6, 7])
        XCTAssertEqual(remaining, expected, "RR(4) with va=0 acks 0,1,2,3; keep 4,5,6,7")
    }

    /// When VA has wrapped and NR=7, only VA..NR-1 are acked (6 only); wrapped frames 0,1 remain.
    func testAcknowledgeUpToWrappedVaDoesNotClearEarlierWrappedFrames() {
        let manager = AX25SessionManager()
        let dest = AX25Address(call: "TEST", ssid: 2)
        let src = AX25Address(call: "TEST", ssid: 1)
        _ = manager.connect(to: dest, path: DigiPath(), channel: 0)
        manager.handleInboundUA(from: dest, path: DigiPath(), channel: 0)
        let session = manager.session(for: dest, path: DigiPath(), channel: 0)

        let payload = Data([0x41])
        for ns in [6, 7, 0, 1] {
            session.sendBuffer[ns] = OutboundFrame(
                destination: dest,
                source: src,
                payload: payload,
                frameType: "i",
                pid: 0xF0,
                ns: ns,
                nr: 0
            )
        }

        session.acknowledgeUpTo(from: 6, to: 7)

        let remaining = Set(session.sendBuffer.keys)
        XCTAssertEqual(remaining, Set([7, 0, 1]), "RR(7) with VA=6 should only ack 6; wrapped 0,1 must remain")
    }

    /// When VA has wrapped and NR=2, ack spans 6,7,0,1. Remaining should be only 2.. (here 2,3).
    func testAcknowledgeUpToWrapAcrossZeroRemovesWrappedAckRange() {
        let manager = AX25SessionManager()
        let dest = AX25Address(call: "TEST", ssid: 2)
        let src = AX25Address(call: "TEST", ssid: 1)
        _ = manager.connect(to: dest, path: DigiPath(), channel: 0)
        manager.handleInboundUA(from: dest, path: DigiPath(), channel: 0)
        let session = manager.session(for: dest, path: DigiPath(), channel: 0)

        let payload = Data([0x41])
        for ns in [6, 7, 0, 1, 2, 3] {
            session.sendBuffer[ns] = OutboundFrame(
                destination: dest,
                source: src,
                payload: payload,
                frameType: "i",
                pid: 0xF0,
                ns: ns,
                nr: 0
            )
        }

        session.acknowledgeUpTo(from: 6, to: 2)

        let remaining = Set(session.sendBuffer.keys)
        XCTAssertEqual(remaining, Set([2, 3]), "RR(2) with VA=6 should ack 6,7,0,1; keep 2,3")
    }

    /// RR(0) means "I expect 0 next" = receiver has received through 7.
    /// With va=4, only frames 4,5,6,7 remain (0-3 already acked). RR(0) clears them all.
    func testAcknowledgeUpToWrapCaseNr0RemovesAll() {
        let manager = AX25SessionManager()
        let dest = AX25Address(call: "TEST", ssid: 2)
        let src = AX25Address(call: "TEST", ssid: 1)
        _ = manager.connect(to: dest, path: DigiPath(), channel: 0)
        manager.handleInboundUA(from: dest, path: DigiPath(), channel: 0)
        let session = manager.session(for: dest, path: DigiPath(), channel: 0)

        let payload = Data([0x41, 0x58, 0x54, 0x31])
        // Only frames 4-7 remain; 0-3 were already acked (va=4)
        for ns in [4, 5, 6, 7] {
            session.sendBuffer[ns] = OutboundFrame(
                destination: dest,
                source: src,
                payload: payload,
                frameType: "i",
                pid: 0xF0,
                ns: ns,
                nr: 0
            )
        }

        session.acknowledgeUpTo(from: 4, to: 0)

        let remaining = Set(session.sendBuffer.keys)
        XCTAssertTrue(remaining.isEmpty, "RR(0) with va=4 acks 4,5,6,7; sendBuffer should be empty")
    }

    /// When va=0, nr=3: remove 0,1,2; keep 3,4,5,6,7.
    func testAcknowledgeUpToSimpleRange() {
        let manager = AX25SessionManager()
        let dest = AX25Address(call: "TEST", ssid: 2)
        let src = AX25Address(call: "TEST", ssid: 1)
        _ = manager.connect(to: dest, path: DigiPath(), channel: 0)
        manager.handleInboundUA(from: dest, path: DigiPath(), channel: 0)
        let session = manager.session(for: dest, path: DigiPath(), channel: 0)

        let payload = Data([0x41])
        for ns in 0..<8 {
            session.sendBuffer[ns] = OutboundFrame(
                destination: dest,
                source: src,
                payload: payload,
                frameType: "i",
                ns: ns,
                nr: 0
            )
        }

        session.acknowledgeUpTo(from: 0, to: 3)

        let remaining = Set(session.sendBuffer.keys)
        XCTAssertEqual(remaining, Set([3, 4, 5, 6, 7]))
    }

    /// framesToRetransmit(from:) returns frames from nr onwards in sendBuffer.
    func testFramesToRetransmitReturnsCorrectFrames() {
        let manager = AX25SessionManager()
        let dest = AX25Address(call: "TEST", ssid: 2)
        let src = AX25Address(call: "TEST", ssid: 1)
        _ = manager.connect(to: dest, path: DigiPath(), channel: 0)
        manager.handleInboundUA(from: dest, path: DigiPath(), channel: 0)
        let session = manager.session(for: dest, path: DigiPath(), channel: 0)

        let payload = Data([0x41])
        session.sendBuffer[2] = OutboundFrame(destination: dest, source: src, payload: payload, frameType: "i", ns: 2, nr: 0)
        session.sendBuffer[3] = OutboundFrame(destination: dest, source: src, payload: payload, frameType: "i", ns: 3, nr: 0)
        session.sendBuffer[4] = OutboundFrame(destination: dest, source: src, payload: payload, frameType: "i", ns: 4, nr: 0)
        session.stateMachine.sequenceState.va = 2
        session.stateMachine.sequenceState.vs = 5  // outstandingCount = 3

        let retransmit = session.framesToRetransmit(from: 2)
        let nsValues = retransmit.compactMap { $0.ns }.sorted()
        XCTAssertEqual(nsValues, [2, 3, 4])
    }

    // MARK: - AXDP Chat Deduplication Tests

    /// Same chat message (from, messageId, sessionId) delivered twice invokes onAXDPChatReceived only once.
    /// Uses UI frames so no AX.25 session is required; deduplication key is (from, messageId, sessionId).
    func testAXDPChatDeduplicationSkipsDuplicateMessage() async throws {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        defaults.set(false, forKey: AppSettingsStore.persistKey)
        let settings = AppSettingsStore(defaults: defaults)
        settings.myCallsign = "TEST-2"

        let client = PacketEngine(maxPackets: 100, maxConsoleLines: 100, maxRawChunks: 100, settings: settings)
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }
        coordinator.packetEngine = client
        coordinator.localCallsign = "TEST-2"
        coordinator.subscribeToPackets(from: client)

        var receiveCount = 0
        coordinator.onAXDPChatReceived = { _, _ in receiveCount += 1 }

        let messageId: UInt32 = 12345
        let axdpPayload = AXDP.Message(
            type: .chat,
            sessionId: 0,
            messageId: messageId,
            payload: Data("Hello".utf8)
        ).encode()

        let from = AX25Address(call: "TEST", ssid: 1)

        // First delivery (UI frame - no session required)
        let packet1 = Packet(
            timestamp: Date(),
            from: from,
            to: AX25Address(call: "TEST", ssid: 2),
            via: [],
            frameType: .ui,
            control: 0x03,
            controlByte1: nil,
            pid: 0xF0,
            info: axdpPayload,
            rawAx25: Data(),
            kissEndpoint: nil,
            infoText: nil
        )
        client.handleIncomingPacket(packet1)

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(receiveCount, 1, "First message should be delivered")

        // Second delivery (same messageId - retransmission/duplicate)
        let packet2 = Packet(
            timestamp: Date(),
            from: from,
            to: AX25Address(call: "TEST", ssid: 2),
            via: [],
            frameType: .ui,
            control: 0x03,
            controlByte1: nil,
            pid: 0xF0,
            info: axdpPayload,
            rawAx25: Data(),
            kissEndpoint: nil,
            infoText: nil
        )
        client.handleIncomingPacket(packet2)

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(receiveCount, 1, "Duplicate message should be skipped")
    }

    // MARK: - AXDP Encode/Decode Round-Trip Tests

    /// Long chat message (> paclen) encodes and decodes correctly.
    func testLongChatMessageEncodeDecodeRoundTrip() {
        let longText = String(repeating: "Contrary to popular belief, Lorem Ipsum is not simply random text. ", count: 20)
        let payload = Data(longText.utf8)
        let msg = AXDP.Message(
            type: .chat,
            sessionId: 0,
            messageId: 3419766896,
            payload: payload
        )
        let encoded = msg.encode()
        let decoded = AXDP.Message.decodeMessage(from: encoded)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.type, .chat)
        XCTAssertEqual(decoded?.sessionId, 0)
        XCTAssertEqual(decoded?.messageId, 3419766896)
        XCTAssertEqual(decoded?.payload, payload)
    }

    /// Fragmented AXDP chunks reassemble to complete message.
    func testFragmentedChatReassembly() {
        let longText = String(repeating: "Lorem ipsum ", count: 100)  // ~1200 bytes
        let payload = Data(longText.utf8)
        let msg = AXDP.Message(type: .chat, sessionId: 0, messageId: 1, payload: payload)
        let fullEncoded = msg.encode()

        var chunks: [Data] = []
        let paclen = 128
        var offset = 0
        while offset < fullEncoded.count {
            let end = min(offset + paclen, fullEncoded.count)
            chunks.append(fullEncoded.subdata(in: offset..<end))
            offset = end
        }

        var reassembled = Data()
        for chunk in chunks {
            reassembled.append(chunk)
        }
        let decoded = AXDP.Message.decodeMessage(from: reassembled)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.payload?.count, payload.count)
        XCTAssertEqual(decoded?.payload, payload)
    }

    // MARK: - Sequence State Wrap Tests

    /// OutstandingCount correct when vs wraps past va.
    func testOutstandingCountWrap() {
        var seq = AX25SequenceState(modulo: 8)
        seq.va = 4
        seq.vs = 2  // wrapped: sent 4,5,6,7,0,1 -> vs=2
        // Outstanding: 4,5,6,7,0,1 = 6 frames
        XCTAssertEqual(seq.outstandingCount, 6)
    }

    // MARK: - Exact Log Scenario (recipient dupes, sender freeze)

    /// Exact scenario from logs: sendBuffer has 0..7, RR(4) arrives. Must remove 0,1,2,3;
    /// remaining {4,5,6,7} and outstandingCount == 4 so sender does not retransmit 0,1,2.
    func testExactLogScenarioRR4ClearsZeroThroughThreeAndOutstandingIsFour() {
        let manager = AX25SessionManager()
        let dest = AX25Address(call: "TEST", ssid: 2)
        let src = AX25Address(call: "TEST", ssid: 1)
        _ = manager.connect(to: dest, path: DigiPath(), channel: 0)
        manager.handleInboundUA(from: dest, path: DigiPath(), channel: 0)
        let session = manager.session(for: dest, path: DigiPath(), channel: 0)

        let payload = Data([0x41])
        for ns in 0..<8 {
            session.sendBuffer[ns] = OutboundFrame(
                destination: dest,
                source: src,
                payload: payload,
                frameType: "i",
                pid: 0xF0,
                ns: ns,
                nr: 0
            )
        }

        session.acknowledgeUpTo(from: 0, to: 4)

        let remaining = Set(session.sendBuffer.keys)
        XCTAssertEqual(remaining, Set([4, 5, 6, 7]), "RR(4) must clear 0,1,2,3 so sender does not retransmit them")
        XCTAssertEqual(session.outstandingCount, 4, "outstandingCount must match sendBuffer.count so UI and T1 are correct")
    }

    /// After RR(4) then RR(5), RR(6), RR(7), RR(0): sendBuffer empty, outstandingCount 0 so "sending" clears.
    func testExactLogScenarioSequenceOfRRsClearsBufferAndOutstandingZero() {
        let manager = AX25SessionManager()
        let dest = AX25Address(call: "TEST", ssid: 2)
        let src = AX25Address(call: "TEST", ssid: 1)
        _ = manager.connect(to: dest, path: DigiPath(), channel: 0)
        manager.handleInboundUA(from: dest, path: DigiPath(), channel: 0)
        let session = manager.session(for: dest, path: DigiPath(), channel: 0)

        let payload = Data([0x41])
        for ns in 0..<8 {
            session.sendBuffer[ns] = OutboundFrame(
                destination: dest,
                source: src,
                payload: payload,
                frameType: "i",
                pid: 0xF0,
                ns: ns,
                nr: 0
            )
        }

        session.acknowledgeUpTo(from: 0, to: 4)
        XCTAssertEqual(session.sendBuffer.count, 4)
        session.acknowledgeUpTo(from: 4, to: 5)
        session.acknowledgeUpTo(from: 5, to: 6)
        session.acknowledgeUpTo(from: 6, to: 7)
        session.acknowledgeUpTo(from: 7, to: 0)

        XCTAssertTrue(session.sendBuffer.isEmpty, "After RR(4)..RR(0) buffer must be empty")
        XCTAssertEqual(session.outstandingCount, 0, "outstandingCount must be 0 so sender leaves 'sending' state")
    }

    /// T1 retransmit: with sendBuffer {4,5,6,7} only, framesToRetransmit(from: 4) returns exactly 4 frames (not 7).
    func testT1RetransmitOnlyUnackedFramesNotOldAcked() {
        let manager = AX25SessionManager()
        let dest = AX25Address(call: "TEST", ssid: 2)
        let src = AX25Address(call: "TEST", ssid: 1)
        _ = manager.connect(to: dest, path: DigiPath(), channel: 0)
        manager.handleInboundUA(from: dest, path: DigiPath(), channel: 0)
        let session = manager.session(for: dest, path: DigiPath(), channel: 0)

        let payload = Data([0x41])
        for ns in [4, 5, 6, 7] {
            session.sendBuffer[ns] = OutboundFrame(
                destination: dest,
                source: src,
                payload: payload,
                frameType: "i",
                pid: 0xF0,
                ns: ns,
                nr: 0
            )
        }

        let retransmit = session.framesToRetransmit(from: 4)
        let nsValues = retransmit.compactMap { $0.ns }.sorted()
        XCTAssertEqual(nsValues, [4, 5, 6, 7], "Must retransmit only 4,5,6,7 not 0,1,2,4,5,6,7")
        XCTAssertEqual(retransmit.count, 4)
    }

    /// outstandingCount always equals sendBuffer.count: empty -> 0.
    func testOutstandingCountEqualsSendBufferCountEmpty() {
        let manager = AX25SessionManager()
        let dest = AX25Address(call: "TEST", ssid: 2)
        _ = manager.connect(to: dest, path: DigiPath(), channel: 0)
        manager.handleInboundUA(from: dest, path: DigiPath(), channel: 0)
        let session = manager.session(for: dest, path: DigiPath(), channel: 0)

        session.sendBuffer.removeAll()
        XCTAssertEqual(session.outstandingCount, 0)
        XCTAssertEqual(session.outstandingCount, session.sendBuffer.count)
    }

    /// outstandingCount equals sendBuffer.count after RR(4) with 8 frames -> 4.
    func testOutstandingCountEqualsSendBufferCountAfterRR4() {
        let manager = AX25SessionManager()
        let dest = AX25Address(call: "TEST", ssid: 2)
        let src = AX25Address(call: "TEST", ssid: 1)
        _ = manager.connect(to: dest, path: DigiPath(), channel: 0)
        manager.handleInboundUA(from: dest, path: DigiPath(), channel: 0)
        let session = manager.session(for: dest, path: DigiPath(), channel: 0)

        let payload = Data([0x41])
        for ns in 0..<8 {
            session.sendBuffer[ns] = OutboundFrame(
                destination: dest,
                source: src,
                payload: payload,
                frameType: "i",
                ns: ns,
                nr: 0
            )
        }
        session.acknowledgeUpTo(from: 0, to: 4)

        XCTAssertEqual(session.outstandingCount, session.sendBuffer.count)
        XCTAssertEqual(session.outstandingCount, 4)
    }

    // MARK: - Edge Cases

    /// RR(1), RR(2), RR(3): sequential RRs clear 0; then 0,1; then 0,1,2.
    func testEdgeSequentialRRsClearCorrectly() {
        let manager = AX25SessionManager()
        let dest = AX25Address(call: "TEST", ssid: 2)
        let src = AX25Address(call: "TEST", ssid: 1)
        _ = manager.connect(to: dest, path: DigiPath(), channel: 0)
        manager.handleInboundUA(from: dest, path: DigiPath(), channel: 0)
        let session = manager.session(for: dest, path: DigiPath(), channel: 0)

        let payload = Data([0x41])
        for ns in 0..<8 {
            session.sendBuffer[ns] = OutboundFrame(
                destination: dest,
                source: src,
                payload: payload,
                frameType: "i",
                ns: ns,
                nr: 0
            )
        }

        session.acknowledgeUpTo(from: 0, to: 1)
        XCTAssertEqual(Set(session.sendBuffer.keys), Set([1, 2, 3, 4, 5, 6, 7]))
        session.acknowledgeUpTo(from: 1, to: 2)
        XCTAssertEqual(Set(session.sendBuffer.keys), Set([2, 3, 4, 5, 6, 7]))
        session.acknowledgeUpTo(from: 2, to: 3)
        XCTAssertEqual(Set(session.sendBuffer.keys), Set([3, 4, 5, 6, 7]))
    }

    /// sendBuffer only 0,1,2,3; receive RR(4): all cleared, empty.
    func testEdgeRR4WithOnlyZeroThroughThreeClearsAll() {
        let manager = AX25SessionManager()
        let dest = AX25Address(call: "TEST", ssid: 2)
        let src = AX25Address(call: "TEST", ssid: 1)
        _ = manager.connect(to: dest, path: DigiPath(), channel: 0)
        manager.handleInboundUA(from: dest, path: DigiPath(), channel: 0)
        let session = manager.session(for: dest, path: DigiPath(), channel: 0)

        let payload = Data([0x41])
        for ns in 0..<4 {
            session.sendBuffer[ns] = OutboundFrame(
                destination: dest,
                source: src,
                payload: payload,
                frameType: "i",
                ns: ns,
                nr: 0
            )
        }

        session.acknowledgeUpTo(from: 0, to: 4)

        XCTAssertTrue(session.sendBuffer.isEmpty)
        XCTAssertEqual(session.outstandingCount, 0)
    }

    /// sendBuffer 4,5,6,7 only; RR(0) clears all (wrap).
    func testEdgeRR0WithOnlyFourThroughSevenClearsAll() {
        let manager = AX25SessionManager()
        let dest = AX25Address(call: "TEST", ssid: 2)
        let src = AX25Address(call: "TEST", ssid: 1)
        _ = manager.connect(to: dest, path: DigiPath(), channel: 0)
        manager.handleInboundUA(from: dest, path: DigiPath(), channel: 0)
        let session = manager.session(for: dest, path: DigiPath(), channel: 0)

        let payload = Data([0x41])
        for ns in [4, 5, 6, 7] {
            session.sendBuffer[ns] = OutboundFrame(
                destination: dest,
                source: src,
                payload: payload,
                frameType: "i",
                ns: ns,
                nr: 0
            )
        }

        session.acknowledgeUpTo(from: 4, to: 0)

        XCTAssertTrue(session.sendBuffer.isEmpty)
        XCTAssertEqual(session.outstandingCount, 0)
    }

    /// RR(nr) with nr out of range (e.g. nr=8 mod 8): treat as RR(0) per mod; we only call with 0..<8 in practice.
    /// Here we only test nr=0 and nr=4; nr=8 would be invalid. Skip invalid-nr test.
    /// Three identical chat messages (same messageId) via UI: only first displayed.
    func testEdgeThreeIdenticalChatMessagesOnlyOneDisplayed() async throws {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        defaults.set(false, forKey: AppSettingsStore.persistKey)
        let settings = AppSettingsStore(defaults: defaults)
        settings.myCallsign = "TEST-2"

        let client = PacketEngine(maxPackets: 100, maxConsoleLines: 100, maxRawChunks: 100, settings: settings)
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }
        coordinator.packetEngine = client
        coordinator.localCallsign = "TEST-2"
        coordinator.subscribeToPackets(from: client)

        var receiveCount = 0
        coordinator.onAXDPChatReceived = { _, _ in receiveCount += 1 }

        let messageId: UInt32 = 999
        let axdpPayload = AXDP.Message(
            type: .chat,
            sessionId: 0,
            messageId: messageId,
            payload: Data("Same".utf8)
        ).encode()

        let from = AX25Address(call: "TEST", ssid: 1)
        let to = AX25Address(call: "TEST", ssid: 2)

        for _ in 0..<3 {
            let packet = Packet(
                timestamp: Date(),
                from: from,
                to: to,
                via: [],
                frameType: .ui,
                control: 0x03,
                controlByte1: nil,
                pid: 0xF0,
                info: axdpPayload,
                rawAx25: Data(),
                kissEndpoint: nil,
                infoText: nil
            )
            client.handleIncomingPacket(packet)
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(receiveCount, 1, "Three identical messages must result in single display")
    }
}

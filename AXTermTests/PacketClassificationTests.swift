//
//  PacketClassificationTests.swift
//  AXTermTests
//
//  Tests for AX.25 packet classification based on decoded control fields.
//  Written TDD-style: these tests must fail initially until production code is implemented.
//

import XCTest
@testable import AXTerm

final class PacketClassificationTests: XCTestCase {
    private let baseTimestamp = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - I-Frame Classification

    /// I-frames with payload should be classified as dataProgress
    func testIFrameWithPayloadIsDataProgress() {
        // I-frame with N(S)=3, N(R)=2, P/F=0, and payload
        let packet = makePacket(
            frameType: .i,
            control: 0x06,  // N(S)=3
            controlByte1: 0x40,  // N(R)=2, P/F=0
            pid: 0xF0,
            info: Data([0x48, 0x65, 0x6C, 0x6C, 0x6F])  // "Hello"
        )

        let classification = PacketClassifier.classify(packet: packet)
        XCTAssertEqual(classification, .dataProgress)
    }

    /// I-frames without payload should still be dataProgress (sequence progress)
    func testIFrameWithoutPayloadIsDataProgress() {
        // I-frame with empty info field
        let packet = makePacket(
            frameType: .i,
            control: 0x04,
            controlByte1: 0x60,
            pid: 0xF0,
            info: Data()
        )

        let classification = PacketClassifier.classify(packet: packet)
        XCTAssertEqual(classification, .dataProgress)
    }

    // MARK: - S-Frame Classification

    /// RR frames (Receive Ready) should be classified as ackOnly
    func testRRFrameIsAckOnly() {
        // S-frame RR with N(R)=5, P/F=0
        // ctl0: 0xA1 (N(R)=5 in bits 5-7, P/F=0, RR=0b00, S-frame=0b01)
        let packet = makePacket(
            frameType: .s,
            control: 0xA1,
            pid: nil,
            info: Data()
        )

        let classification = PacketClassifier.classify(packet: packet)
        XCTAssertEqual(classification, .ackOnly)
    }

    /// RNR frames (Receive Not Ready) should be classified as ackOnly
    func testRNRFrameIsAckOnly() {
        // S-frame RNR with N(R)=3, P/F=1
        // ctl0: 0x75 (N(R)=3 in bits 5-7, P/F=1, RNR=0b01 in bits 2-3, S-frame=0b01)
        let packet = makePacket(
            frameType: .s,
            control: 0x75,
            pid: nil,
            info: Data()
        )

        let classification = PacketClassifier.classify(packet: packet)
        XCTAssertEqual(classification, .ackOnly)
    }

    /// REJ frames (Reject) should be classified as retryOrDuplicate
    func testREJFrameIsRetryOrDuplicate() {
        // S-frame REJ - indicates retry request
        // ctl0: 0x09 (N(R)=0, P/F=0, REJ=0b10, S-frame=0b01)
        let packet = makePacket(
            frameType: .s,
            control: 0x09,
            pid: nil,
            info: Data()
        )

        let classification = PacketClassifier.classify(packet: packet)
        XCTAssertEqual(classification, .retryOrDuplicate)
    }

    /// SREJ frames (Selective Reject) should be classified as retryOrDuplicate
    func testSREJFrameIsRetryOrDuplicate() {
        // S-frame SREJ
        // ctl0: 0x0D (N(R)=0, P/F=0, SREJ=0b11, S-frame=0b01)
        let packet = makePacket(
            frameType: .s,
            control: 0x0D,
            pid: nil,
            info: Data()
        )

        let classification = PacketClassifier.classify(packet: packet)
        XCTAssertEqual(classification, .retryOrDuplicate)
    }

    // MARK: - U-Frame Classification

    /// UI frames with non-beacon payload should be uiBeacon by default
    func testUIFrameIsUIBeacon() {
        // U-frame UI with P/F=0
        let packet = makePacket(
            frameType: .ui,
            control: 0x03,
            pid: 0xF0,
            info: Data([0x41, 0x42, 0x43])  // "ABC"
        )

        let classification = PacketClassifier.classify(packet: packet)
        XCTAssertEqual(classification, .uiBeacon)
    }

    /// UI frames to BEACON destination should be uiBeacon
    func testUIFrameToBeaconIsUIBeacon() {
        let packet = makePacket(
            frameType: .ui,
            control: 0x03,
            pid: 0xF0,
            info: Data([0x42, 0x45, 0x41, 0x43, 0x4F, 0x4E]),  // "BEACON"
            toCall: "BEACON"
        )

        let classification = PacketClassifier.classify(packet: packet)
        XCTAssertEqual(classification, .uiBeacon)
    }

    /// SABM frames should be classified as sessionControl
    func testSABMIsSessionControl() {
        // U-frame SABM with P/F=1
        // ctl0: 0x3F (SABM=0x2F | P/F=0x10)
        let packet = makePacket(
            frameType: .u,
            control: 0x3F,
            pid: nil,
            info: Data()
        )

        let classification = PacketClassifier.classify(packet: packet)
        XCTAssertEqual(classification, .sessionControl)
    }

    /// UA frames should be classified as sessionControl
    func testUAIsSessionControl() {
        // U-frame UA with P/F=1
        // ctl0: 0x73 (UA=0x63 | P/F=0x10)
        let packet = makePacket(
            frameType: .u,
            control: 0x73,
            pid: nil,
            info: Data()
        )

        let classification = PacketClassifier.classify(packet: packet)
        XCTAssertEqual(classification, .sessionControl)
    }

    /// DISC frames should be classified as sessionControl
    func testDISCIsSessionControl() {
        // U-frame DISC
        // ctl0: 0x53 (DISC=0x43 | P/F=0x10)
        let packet = makePacket(
            frameType: .u,
            control: 0x53,
            pid: nil,
            info: Data()
        )

        let classification = PacketClassifier.classify(packet: packet)
        XCTAssertEqual(classification, .sessionControl)
    }

    /// DM frames should be classified as sessionControl
    func testDMIsSessionControl() {
        // U-frame DM
        // ctl0: 0x1F (DM=0x0F | P/F=0x10)
        let packet = makePacket(
            frameType: .u,
            control: 0x1F,
            pid: nil,
            info: Data()
        )

        let classification = PacketClassifier.classify(packet: packet)
        XCTAssertEqual(classification, .sessionControl)
    }

    /// FRMR frames should be classified as sessionControl
    func testFRMRIsSessionControl() {
        // U-frame FRMR
        // ctl0: 0x87
        let packet = makePacket(
            frameType: .u,
            control: 0x87,
            pid: nil,
            info: Data()
        )

        let classification = PacketClassifier.classify(packet: packet)
        XCTAssertEqual(classification, .sessionControl)
    }

    // MARK: - Display Mapping Tests

    func testBadgeMapping() {
        XCTAssertEqual(PacketClassification.dataProgress.badge, "DATA")
        XCTAssertEqual(PacketClassification.ackOnly.badge, "ACK")
        XCTAssertEqual(PacketClassification.retryOrDuplicate.badge, "RETRY")
        XCTAssertEqual(PacketClassification.uiBeacon.badge, "BEACON")
        XCTAssertEqual(PacketClassification.routingBroadcast.badge, "ROUTE")
        XCTAssertEqual(PacketClassification.sessionControl.badge, "CTRL")
        XCTAssertEqual(PacketClassification.unknown.badge, "—")
    }

    func testTooltipMapping() {
        XCTAssertEqual(PacketClassification.ackOnly.tooltip, "ACK — An acknowledgement frame confirming reception. Does not carry new data.")
        XCTAssertTrue(PacketClassification.dataProgress.tooltip.hasPrefix("DATA —"))
        XCTAssertTrue(PacketClassification.uiBeacon.tooltip.hasPrefix("BEACON —"))
    }

    // MARK: - NET/ROM Broadcast Classification

    /// NET/ROM routing broadcasts should be classified as routingBroadcast
    func testNetRomBroadcastIsRoutingBroadcast() {
        // UI frame with PID=0xCF to NODES
        let packet = makePacket(
            frameType: .ui,
            control: 0x03,
            pid: 0xCF,  // NET/ROM PID
            info: makeNetRomBroadcastData(),
            toCall: "NODES"
        )

        let classification = PacketClassifier.classify(packet: packet)
        XCTAssertEqual(classification, .routingBroadcast)
    }

    /// NET/ROM broadcast with data should be routingBroadcast (not dataProgress)
    func testNetRomBroadcastOverridesUIBeacon() {
        // Even though it has payload, NET/ROM broadcasts are routing
        let packet = makePacket(
            frameType: .ui,
            control: 0x03,
            pid: 0xCF,
            info: makeNetRomBroadcastData(),
            toCall: "NODES"
        )

        let classification = PacketClassifier.classify(packet: packet)
        XCTAssertEqual(classification, .routingBroadcast)
        XCTAssertNotEqual(classification, .uiBeacon)
    }

    // MARK: - Unknown Classification

    /// Unknown frame types should be classified as unknown
    func testUnknownFrameIsUnknown() {
        let packet = makePacket(
            frameType: .unknown,
            control: 0xFF,
            pid: nil,
            info: Data()
        )

        let classification = PacketClassifier.classify(packet: packet)
        XCTAssertEqual(classification, .unknown)
    }

    // MARK: - Retry/Duplicate Detection

    /// Reused N(S) with same payload should be retryOrDuplicate
    func testReusedNSWithSamePayloadIsRetry() {
        let payload = Data([0x48, 0x65, 0x6C, 0x6C, 0x6F])  // "Hello"

        let packet1 = makePacket(
            frameType: .i,
            control: 0x02,  // N(S)=1
            controlByte1: 0x20,
            pid: 0xF0,
            info: payload,
            fromCall: "W1ABC",
            toCall: "W2DEF"
        )

        // First packet establishes baseline
        let class1 = PacketClassifier.classify(packet: packet1)
        XCTAssertEqual(class1, .dataProgress)

        // Same N(S), same payload, same src/dst = retry
        let packet2 = makePacket(
            frameType: .i,
            control: 0x02,  // Same N(S)=1
            controlByte1: 0x20,
            pid: 0xF0,
            info: payload,  // Same payload
            fromCall: "W1ABC",
            toCall: "W2DEF"
        )

        let class2 = PacketClassifier.classify(packet: packet2, previousPackets: [packet1])
        XCTAssertEqual(class2, .retryOrDuplicate)
    }

    /// Different N(S) with same payload is NOT a retry (just repeated data)
    func testDifferentNSWithSamePayloadIsNotRetry() {
        let payload = Data([0x48, 0x65, 0x6C, 0x6C, 0x6F])

        let packet1 = makePacket(
            frameType: .i,
            control: 0x02,  // N(S)=1
            controlByte1: 0x20,
            pid: 0xF0,
            info: payload,
            fromCall: "W1ABC",
            toCall: "W2DEF"
        )

        let packet2 = makePacket(
            frameType: .i,
            control: 0x04,  // Different N(S)=2
            controlByte1: 0x20,
            pid: 0xF0,
            info: payload,  // Same payload
            fromCall: "W1ABC",
            toCall: "W2DEF"
        )

        let class2 = PacketClassifier.classify(packet: packet2, previousPackets: [packet1])
        XCTAssertEqual(class2, .dataProgress)
    }

    // MARK: - Classification Order Tests

    /// I-frame classification should check for NET/ROM first
    func testIFrameWithNetRomPIDIsStillDataProgress() {
        // I-frame (not UI) even with PID 0xCF is dataProgress, not routingBroadcast
        // NET/ROM broadcasts are always UI frames
        let packet = makePacket(
            frameType: .i,
            control: 0x00,
            controlByte1: 0x00,
            pid: 0xCF,
            info: Data([0x01, 0x02, 0x03]),
            toCall: "NODES"
        )

        let classification = PacketClassifier.classify(packet: packet)
        XCTAssertEqual(classification, .dataProgress)
    }

    // MARK: - Test Helpers

    private func makePacket(
        frameType: FrameType,
        control: UInt8,
        controlByte1: UInt8? = nil,
        pid: UInt8?,
        info: Data,
        fromCall: String = "TEST1",
        toCall: String = "TEST2",
        timestamp: Date? = nil
    ) -> Packet {
        let packetTimestamp = timestamp ?? baseTimestamp
        return Packet(
            timestamp: packetTimestamp,
            from: AX25Address(call: fromCall),
            to: AX25Address(call: toCall),
            via: [],
            frameType: frameType,
            control: control,
            controlByte1: controlByte1,
            pid: pid,
            info: info,
            rawAx25: Data()
        )
    }

    /// Create minimal NET/ROM broadcast data (signature + one entry)
    private func makeNetRomBroadcastData() -> Data {
        var data = Data()
        // Signature byte
        data.append(0xFF)
        // Minimal entry (21 bytes for standard format)
        // Destination callsign (shifted): "TEST1 " = 0xA8,0xAA,0xA6,0xA8,0x62,0x40 + SSID byte
        data.append(contentsOf: [0xA8, 0xAA, 0xA6, 0xA8, 0x62, 0x40, 0x60])
        // Alias: "ALIAS1"
        data.append(contentsOf: [0x41, 0x4C, 0x49, 0x41, 0x53, 0x31])
        // Neighbor callsign (shifted): "W1ABC " = shifted bytes + SSID
        data.append(contentsOf: [0xAE, 0x62, 0x82, 0x84, 0x86, 0x40, 0x60])
        // Quality byte
        data.append(200)
        return data
    }
}

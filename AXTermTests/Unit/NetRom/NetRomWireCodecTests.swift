import XCTest
@testable import AXTerm

/// Byte-exact tests of the NET/ROM L3/L4 codec against the layouts in
/// the Linux AF_NETROM reference (nr_write_internal, __nr_transmit_reply,
/// nr_rx_frame — net/netrom, v6.6).
///
/// The shifted-callsign literals below were cross-checked against live
/// AX.25 captures from this station: K0EPI-7 on the air is
/// 96 60 8A A0 92 40 6E and KB5YZB-7 is 96 84 6A B2 B4 84 6E.
final class NetRomWireCodecTests: XCTestCase {

    // MARK: Shifted-callsign literals (E-bit variants)

    private let k0epi7_e0: [UInt8] = [0x96, 0x60, 0x8A, 0xA0, 0x92, 0x40, 0x6E]
    private let k0epi7_e1: [UInt8] = [0x96, 0x60, 0x8A, 0xA0, 0x92, 0x40, 0x6F]
    private let kb5yzb7_e0: [UInt8] = [0x96, 0x84, 0x6A, 0xB2, 0xB4, 0x84, 0x6E]
    private let kb5yzb7_e1: [UInt8] = [0x96, 0x84, 0x6A, 0xB2, 0xB4, 0x84, 0x6F]
    private let k0epi_e0: [UInt8] = [0x96, 0x60, 0x8A, 0xA0, 0x92, 0x40, 0x60]

    private let k0epi = AX25Address(call: "K0EPI", ssid: 0)
    private let k0epi7 = AX25Address(call: "K0EPI", ssid: 7)
    private let kb5yzb7 = AX25Address(call: "KB5YZB", ssid: 7)

    // MARK: - Callsign field codec

    func testCallsignEncodeMatchesOnAirCapture() {
        XCTAssertEqual(NetRomTransportWire.encodeCallsignField(k0epi7, lastBit: false), k0epi7_e0)
        XCTAssertEqual(NetRomTransportWire.encodeCallsignField(kb5yzb7, lastBit: true), kb5yzb7_e1)
        XCTAssertEqual(NetRomTransportWire.encodeCallsignField(k0epi, lastBit: false), k0epi_e0)
    }

    func testCallsignDecodeIgnoresCAndEAndSpareBits() {
        // Same address with C-bit set, spare bits cleared, E flipped —
        // receivers mask everything but the SSID (kernel behavior).
        var noisy = k0epi7_e0
        noisy[6] = 0x8E  // C-bit set, spares cleared, E clear, ssid 7
        XCTAssertEqual(NetRomTransportWire.decodeCallsignField(noisy[...]), k0epi7)
        noisy[6] = 0x0F  // E set, ssid 7
        XCTAssertEqual(NetRomTransportWire.decodeCallsignField(noisy[...]), k0epi7)
    }

    func testCallsignDecodeRejectsJunk() {
        // Lowercase / punctuation cannot appear in a shifted callsign.
        XCTAssertNil(NetRomTransportWire.decodeCallsignField([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00][...]))
        XCTAssertNil(NetRomTransportWire.decodeCallsignField([0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x60][...]))  // all spaces
        // Character after the terminating space: not a callsign.
        XCTAssertNil(NetRomTransportWire.decodeCallsignField([0x96, 0x40, 0x8A, 0xA0, 0x92, 0x40, 0x6E][...]))
        // Wrong length.
        XCTAssertNil(NetRomTransportWire.decodeCallsignField([0x96, 0x60][...]))
    }

    // MARK: - Golden vectors

    func testConnectRequestGoldenVector() {
        let datagram = NetRomDatagram(
            origin: k0epi7, destination: kb5yzb7, ttl: 25,
            transport: .connectRequest(
                myIndex: 0x01, myId: 0x01,
                proposedWindow: 4,
                user: k0epi, originNode: k0epi7,
                t1Seconds: 120
            )
        )
        var expected = k0epi7_e0 + kb5yzb7_e1 + [0x19]
        expected += [0x01, 0x01, 0x00, 0x00, 0x01]        // hdr: idx, id, 0, 0, CONREQ
        expected += [0x04] + k0epi_e0 + k0epi7_e0          // window, user, node
        expected += [0x78, 0x00]                           // 120 s, little-endian
        XCTAssertEqual([UInt8](NetRomTransportWire.encode(datagram)), expected)
    }

    func testClassicConnectRequestOmitsTimeout() {
        let frame = NetRomL4Frame.connectRequest(
            myIndex: 0x01, myId: 0x02,
            proposedWindow: 4, user: k0epi, originNode: k0epi7,
            t1Seconds: nil
        )
        XCTAssertEqual(NetRomTransportWire.encodeTransport(frame).count, 5 + 15)
    }

    func testConnectAckGoldenVector() {
        let frame = NetRomL4Frame.connectAck(
            yourIndex: 0x01, yourId: 0x01,
            myIndex: 0x1A, myId: 0x2B,
            acceptedWindow: 3, ttl: nil, refused: false
        )
        XCTAssertEqual(NetRomTransportWire.encodeTransport(frame),
                       [0x01, 0x01, 0x1A, 0x2B, 0x02, 0x03])
    }

    func testConnectAckWithBPQTTLByte() {
        let frame = NetRomL4Frame.connectAck(
            yourIndex: 0x01, yourId: 0x01,
            myIndex: 0x1A, myId: 0x2B,
            acceptedWindow: 3, ttl: 25, refused: false
        )
        XCTAssertEqual(NetRomTransportWire.encodeTransport(frame),
                       [0x01, 0x01, 0x1A, 0x2B, 0x02, 0x03, 0x19])
    }

    func testRefusalGoldenVector() {
        // nr_transmit_refusal: standard CONACK order, requester's handle
        // in 15/16, zeros in 17/18, choke set, one zero data byte.
        let frame = NetRomL4Frame.connectAck(
            yourIndex: 0x01, yourId: 0x01,
            myIndex: 0, myId: 0,
            acceptedWindow: 0, ttl: nil, refused: true
        )
        XCTAssertEqual(NetRomTransportWire.encodeTransport(frame),
                       [0x01, 0x01, 0x00, 0x00, 0x82, 0x00])
    }

    func testInformationGoldenVector() {
        let frame = NetRomL4Frame.information(
            yourIndex: 0x1A, yourId: 0x2B,
            txSeq: 5, rxSeq: 3,
            choke: false, nak: false, moreFollows: true,
            payload: Data([0xDE, 0xAD])
        )
        XCTAssertEqual(NetRomTransportWire.encodeTransport(frame),
                       [0x1A, 0x2B, 0x05, 0x03, 0x25, 0xDE, 0xAD])
    }

    func testInformationAckGoldenVectors() {
        XCTAssertEqual(
            NetRomTransportWire.encodeTransport(.informationAck(
                yourIndex: 0x1A, yourId: 0x2B, rxSeq: 7, choke: false, nak: false)),
            [0x1A, 0x2B, 0x00, 0x07, 0x06])
        XCTAssertEqual(
            NetRomTransportWire.encodeTransport(.informationAck(
                yourIndex: 0x1A, yourId: 0x2B, rxSeq: 7, choke: false, nak: true)),
            [0x1A, 0x2B, 0x00, 0x07, 0x46])
        XCTAssertEqual(
            NetRomTransportWire.encodeTransport(.informationAck(
                yourIndex: 0x1A, yourId: 0x2B, rxSeq: 7, choke: true, nak: false)),
            [0x1A, 0x2B, 0x00, 0x07, 0x86])
    }

    func testDisconnectGoldenVectors() {
        XCTAssertEqual(
            NetRomTransportWire.encodeTransport(.disconnectRequest(yourIndex: 0x1A, yourId: 0x2B)),
            [0x1A, 0x2B, 0x00, 0x00, 0x03])
        XCTAssertEqual(
            NetRomTransportWire.encodeTransport(.disconnectAck(yourIndex: 0x1A, yourId: 0x2B)),
            [0x1A, 0x2B, 0x00, 0x00, 0x04])
    }

    // MARK: - Round trips

    private func roundTrip(_ transport: NetRomL4Frame,
                           origin: AX25Address? = nil,
                           destination: AX25Address? = nil,
                           ttl: UInt8 = 25,
                           file: StaticString = #filePath, line: UInt = #line) {
        let datagram = NetRomDatagram(
            origin: origin ?? k0epi7,
            destination: destination ?? kb5yzb7,
            ttl: ttl,
            transport: transport
        )
        let encoded = NetRomTransportWire.encode(datagram)
        let parsed = NetRomTransportWire.parse(encoded)
        XCTAssertEqual(parsed, datagram, file: file, line: line)
    }

    func testRoundTripEveryOpcode() {
        roundTrip(.connectRequest(myIndex: 9, myId: 200, proposedWindow: 127,
                                  user: k0epi, originNode: k0epi7, t1Seconds: 300))
        roundTrip(.connectRequest(myIndex: 9, myId: 200, proposedWindow: 4,
                                  user: k0epi, originNode: k0epi7, t1Seconds: nil))
        roundTrip(.connectAck(yourIndex: 9, yourId: 200, myIndex: 3, myId: 4,
                              acceptedWindow: 4, ttl: nil, refused: false))
        roundTrip(.connectAck(yourIndex: 9, yourId: 200, myIndex: 3, myId: 4,
                              acceptedWindow: 4, ttl: 16, refused: false))
        roundTrip(.disconnectRequest(yourIndex: 1, yourId: 255))
        roundTrip(.disconnectAck(yourIndex: 255, yourId: 1))
        roundTrip(.information(yourIndex: 7, yourId: 7, txSeq: 255, rxSeq: 0,
                               choke: true, nak: false, moreFollows: true,
                               payload: Data(repeating: 0x55, count: 236)))
        roundTrip(.information(yourIndex: 7, yourId: 7, txSeq: 0, rxSeq: 255,
                               choke: false, nak: true, moreFollows: false,
                               payload: Data()))
        roundTrip(.informationAck(yourIndex: 12, yourId: 34, rxSeq: 128,
                                  choke: true, nak: true))
        roundTrip(.reset(yourIndex: 5, yourId: 6))
    }

    func testRoundTripSSIDRange() {
        for ssid in 0...15 {
            roundTrip(.disconnectRequest(yourIndex: 1, yourId: 1),
                      origin: AX25Address(call: "W0ARP", ssid: ssid),
                      destination: AX25Address(call: "N0XYZ", ssid: 15 - ssid))
        }
    }

    // MARK: - Refusal normalization (exotic zero-index shape)

    func testExoticRefusalShapeNormalizes() {
        // __nr_transmit_reply(mine: 1): [0, 0, idx, id], CONACK|CHOKE.
        var bytes = kb5yzb7_e0 + k0epi7_e1 + [0x19]
        bytes += [0x00, 0x00, 0x07, 0x2A, 0x82, 0x00]
        guard let parsed = NetRomTransportWire.parse(Data(bytes)) else {
            return XCTFail("exotic refusal should parse")
        }
        guard case let .connectAck(yourIndex, yourId, myIndex, myId, _, _, refused) = parsed.transport else {
            return XCTFail("expected connectAck, got \(parsed.transport)")
        }
        XCTAssertTrue(refused)
        XCTAssertEqual(yourIndex, 0x07, "the addressed handle surfaces in yourIndex")
        XCTAssertEqual(yourId, 0x2A)
        XCTAssertEqual(myIndex, 0)
        XCTAssertEqual(myId, 0)
    }

    func testStandardRefusalParsesRefused() {
        var bytes = kb5yzb7_e0 + k0epi7_e1 + [0x19]
        bytes += [0x07, 0x2A, 0x00, 0x00, 0x82, 0x00]
        guard case let .connectAck(yourIndex, yourId, _, _, _, _, refused)? =
                NetRomTransportWire.parse(Data(bytes))?.transport else {
            return XCTFail("standard refusal should parse as connectAck")
        }
        XCTAssertTrue(refused)
        XCTAssertEqual(yourIndex, 0x07)
        XCTAssertEqual(yourId, 0x2A)
    }

    // MARK: - Malformed input

    func testEveryTruncationParsesToNilWithoutCrashing() {
        let full = NetRomTransportWire.encode(NetRomDatagram(
            origin: k0epi7, destination: kb5yzb7, ttl: 25,
            transport: .connectRequest(myIndex: 1, myId: 1, proposedWindow: 4,
                                       user: k0epi, originNode: k0epi7, t1Seconds: 120)
        ))
        let classicLength = NetRomWire.headerLength + 15
        for length in 0..<full.count {
            let truncated = Data(full.prefix(length))
            if length == classicLength {
                // Cutting the two timeout bytes off an extended CONREQ
                // leaves a valid *classic* CONREQ — that ambiguity is the
                // extension's own design (detection is by length).
                guard case .connectRequest(_, _, _, _, _, t1Seconds: nil)? =
                        NetRomTransportWire.parse(truncated)?.transport else {
                    return XCTFail("35-byte prefix should parse as a classic CONREQ")
                }
            } else {
                XCTAssertNil(NetRomTransportWire.parse(truncated),
                             "truncation to \(length) bytes must not parse")
            }
        }
    }

    func testZeroTTLIsMalformed() {
        var bytes = [UInt8](NetRomTransportWire.encode(NetRomDatagram(
            origin: k0epi7, destination: kb5yzb7, ttl: 25,
            transport: .disconnectRequest(yourIndex: 1, yourId: 1))))
        bytes[14] = 0
        XCTAssertNil(NetRomTransportWire.parse(Data(bytes)))
    }

    func testUndefinedOpcodeNibblesAreMalformed() {
        for opcode: UInt8 in 0x08...0x0F {
            var bytes = kb5yzb7_e0 + k0epi7_e1 + [0x19]
            bytes += [0x01, 0x01, 0x00, 0x00, opcode]
            XCTAssertNil(NetRomTransportWire.parse(Data(bytes)),
                         "opcode nibble \(opcode) has no definition")
        }
    }

    func testConnectRequestWithWrongDataLengthIsMalformed() {
        for extra in [1, 2, 14, 16, 18, 30] {
            var bytes = k0epi7_e0 + kb5yzb7_e1 + [0x19]
            bytes += [0x01, 0x01, 0x00, 0x00, 0x01]
            bytes += [UInt8](repeating: 0x41, count: extra)
            XCTAssertNil(NetRomTransportWire.parse(Data(bytes)),
                         "CONREQ data must be exactly 15 or 17 bytes, not \(extra)")
        }
    }

    func testOversizedInfoPayloadIsMalformed() {
        var bytes = k0epi7_e0 + kb5yzb7_e1 + [0x19]
        bytes += [0x01, 0x01, 0x00, 0x00, 0x05]
        bytes += [UInt8](repeating: 0x00, count: NetRomWire.maxInfoPayload + 1)
        XCTAssertNil(NetRomTransportWire.parse(Data(bytes)))
    }

    // MARK: - Protocol extension passthrough

    func testProtocolExtensionIsOpaqueAndRoundTrips() {
        // IP-over-NET/ROM marker: opcode 0 with index == id == 0x0C.
        var bytes = k0epi7_e0 + kb5yzb7_e1 + [0x19]
        bytes += [0x0C, 0x0C, 0x00, 0x00, 0x00, 0x45, 0x00, 0x01]
        guard let parsed = NetRomTransportWire.parse(Data(bytes)) else {
            return XCTFail("protocol-extension frame should parse")
        }
        guard case let .protocolExtension(raw) = parsed.transport else {
            return XCTFail("expected protocolExtension, got \(parsed.transport)")
        }
        XCTAssertEqual([UInt8](raw), [0x0C, 0x0C, 0x00, 0x00, 0x00, 0x45, 0x00, 0x01],
                       "bytes 15+ carried verbatim — no invented semantics")
        XCTAssertEqual([UInt8](NetRomTransportWire.encode(parsed)), bytes,
                       "and re-encode reproduces the wire bytes exactly")
    }
}

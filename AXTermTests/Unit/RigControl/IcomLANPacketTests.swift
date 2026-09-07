import XCTest
@testable import AXTerm

/// The Icom LAN wire format, pinned. The golden vectors are real datagrams
/// captured from an IC-705 (see the sound-modem work), so a change that
/// breaks the handshake breaks a test rather than the radio.
final class IcomLANPacketTests: XCTestCase {

    private func bytes(_ hex: String) -> Data {
        let chars = Array(hex)
        var out = [UInt8]()
        var i = 0
        while i + 1 < chars.count {
            if let b = UInt8(String(chars[i...(i + 1)]), radix: 16) { out.append(b) }
            i += 2
        }
        return Data(out)
    }

    // MARK: - Header

    func testHeaderRoundTrips() {
        let h = IcomLAN.Header(length: 16, type: 3, sequence: 0x1234, senderID: 0xAABBCCDD, receiverID: 0x11223344)
        let parsed = IcomLAN.Header.parse(Data(h.bytes))
        XCTAssertEqual(parsed, h)
        // Length and type are little-endian, the two IDs are kept as-is.
        XCTAssertEqual(h.bytes[0], 16)
        XCTAssertEqual(h.bytes[4], 3)
        XCTAssertEqual([UInt8](h.bytes[8..<12]), [0xAA, 0xBB, 0xCC, 0xDD])
    }

    func testControlAndPingShapes() {
        let idle = IcomLAN.control(.idle, local: 1, remote: 2)
        XCTAssertEqual(idle.count, 16)
        XCTAssertTrue(IcomLAN.isIdle(idle))

        let ping = IcomLAN.ping(sequence: 9, local: 1, remote: 2, reply: false, id: [0xAA, 0x04, 0x83, 0x06])
        XCTAssertEqual(ping.count, 21)
        XCTAssertTrue(IcomLAN.isPing(ping))
        XCTAssertFalse(IcomLAN.pingIsReply(ping))
        XCTAssertEqual(IcomLAN.pingID(ping), [0xAA, 0x04, 0x83, 0x06])
        let reply = IcomLAN.ping(sequence: 9, local: 1, remote: 2, reply: true, id: [0xAA, 0x04, 0x83, 0x06])
        XCTAssertTrue(IcomLAN.pingIsReply(reply))
    }

    // MARK: - Passcode (the reference's obfuscation table)

    func testPasscodeIsSixteenBytesAndDeterministic() {
        let a = IcomPasscode.encode("rwardrup")
        XCTAssertEqual(a.count, 16)
        XCTAssertEqual(a, IcomPasscode.encode("rwardrup"))
        XCTAssertNotEqual(a, IcomPasscode.encode("someoneelse"))
        // Position matters: the same letter encodes differently by index.
        let doubled = IcomPasscode.encode("aa")
        XCTAssertNotEqual(doubled[0], doubled[1])
        // 'a' is 0x61 = 97; at index 0, table[97-32=65] = 0x4a per the reference.
        XCTAssertEqual(IcomPasscode.encode("a")[0], 0x38)
    }

    // MARK: - Login / token / connection request layout

    func testLoginLayout() {
        let d = IcomLAN.login(local: 0xAABBCCDD, remote: 0x11223344, innerSequence: 5,
                              tokenRequest: (0x12, 0x34), username: "user", password: "pass", program: "AXTerm")
        XCTAssertEqual(d.count, 128)
        let b = [UInt8](d)
        XCTAssertEqual(b[0], 0x80)
        XCTAssertEqual(b[19], 0x70)
        XCTAssertEqual(b[20], 0x01)
        XCTAssertEqual(b[26], 0x12); XCTAssertEqual(b[27], 0x34)
        XCTAssertEqual(Array(b[64..<80]), IcomPasscode.encode("user"))
        XCTAssertEqual(Array(b[80..<96]), IcomPasscode.encode("pass"))
        XCTAssertEqual(IcomLAN.cString(b, from: 96, max: 16), "AXTerm")
    }

    func testConnectionRequestNamesTheCodecPortsAndRate() {
        var r = IcomLAN.ConnectionRequest(radioName: "IC-705", username: "user")
        r.sampleRate = 48_000; r.serialPort = 50_002; r.audioPort = 50_003; r.txBufferMs = 300
        let d = IcomLAN.connectionRequest(r, local: 1, remote: 2, innerSequence: 7, authID: [1, 2, 3, 4, 5, 6], replyID: Array(0..<16).map(UInt8.init))
        XCTAssertEqual(d.count, 144)
        let b = [UInt8](d)
        XCTAssertEqual(b[0], 0x90)
        XCTAssertEqual(Array(b[26..<32]), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(Array(b[32..<48]), Array(0..<16).map(UInt8.init))
        XCTAssertEqual(IcomLAN.cString(b, from: 64, max: 32), "IC-705")
        XCTAssertEqual(b[112], 0x01); XCTAssertEqual(b[113], 0x01)
        XCTAssertEqual(b[114], 0x04)                       // LPCM codec
        XCTAssertEqual(UInt16(b[118]) << 8 | UInt16(b[119]), 48_000)   // rate, big-endian
        XCTAssertEqual(UInt16(b[126]) << 8 | UInt16(b[127]), 50_002)   // CI-V port
        XCTAssertEqual(UInt16(b[130]) << 8 | UInt16(b[131]), 50_003)   // audio port
        XCTAssertEqual(UInt16(b[134]) << 8 | UInt16(b[135]), 300)      // tx buffer ms
    }

    // MARK: - CI-V and audio framing

    func testSerialFramingRoundTrips() {
        let civ = Data([0xFE, 0xFE, 0xA4, 0xE0, 0x19, 0x00, 0xFD])
        let packet = IcomLAN.serialData(civ, sendSequence: 0x0102, local: 1, remote: 2)
        XCTAssertEqual(packet.count, 21 + civ.count)
        XCTAssertEqual(packet[16], 0xC1)
        XCTAssertEqual(Int(packet[17]), civ.count)
        XCTAssertEqual(IcomLAN.serialPayload(packet), civ)
        // A plain control packet has no CI-V payload.
        XCTAssertNil(IcomLAN.serialPayload(IcomLAN.control(.idle, local: 1, remote: 2)))
    }

    func testAudioFramingRoundTrips() {
        let pcm = Data((0..<640).map { UInt8($0 & 0xFF) })
        let packet = IcomLAN.audioData(pcm, sendSequence: 7, local: 1, remote: 2)
        XCTAssertEqual(packet.count, 24 + pcm.count)
        XCTAssertEqual(IcomLAN.audioPayload(packet), pcm)
    }

    // MARK: - Golden vectors: real IC-705 datagrams

    func testParsesARealLoginReply() {
        let d = bytes("60000000000002000b4bd82cdd17905000000050020000000000e665710c3fdb00000000000000000000000000000000000000000000000000000000000000004654544800000000000000000000000001000000000000000000000000000000")
        let reply = IcomLAN.parseLoginReply(d)
        XCTAssertEqual(reply?.accepted, true)
    }

    func testParsesRealCapabilities() {
        let d = bytes("a8000000000003000b4bd82cdd17905000000098020200010000e665710c3fdb00000000000000000000000000000000000000000000000000000000000000000001000000000000001080000090c7155d0d49432d373035000000000000000000000000000000000000000000000000000049434f4d5f56415544494f0000000000000000000000000000000000000000000707a4018b018b01010100004b000150009001000000")
        let caps = IcomLAN.parseCapabilities(d)
        XCTAssertEqual(caps?.radioName, "IC-705")
        XCTAssertEqual(caps?.replyID.count, 16)
    }

    func testParsesRealConnectionReplyAsAccepted() {
        let d = bytes("90000000000004000b4bd82cdd179050000000800300000000000e665710c3fdb0")   // truncated on purpose below
        // Use the full 144-byte capture:
        let full = bytes("90000000000004000b4bd82cdd179050000000800300000000" + "00e665710c3fdb000000000000001080000090c7155d0d0000000000000000000000000000000049432d3730350000000000000000000000000000000000000000000000000000010000006950616400000000000000000000000000000000000000000000000000000000c0a803050000000000000000")
        XCTAssertNil(IcomLAN.parseConnectionReply(d), "a short packet is not a reply")
        let reply = IcomLAN.parseConnectionReply(full)
        XCTAssertEqual(reply?.accepted, true)
        XCTAssertEqual(reply?.deviceName, "IC-705")
    }

    func testStatusFlagsAuthFailedAndRadioDisconnect() {
        var authFailed = [UInt8](repeating: 0, count: 80)
        authFailed[0] = 0x50
        authFailed[48] = 0xFF; authFailed[49] = 0xFF; authFailed[50] = 0xFF; authFailed[51] = 0xFD
        XCTAssertEqual(IcomLAN.parseStatus(Data(authFailed)), .authFailed)

        var disconnected = [UInt8](repeating: 0, count: 80)
        disconnected[0] = 0x50
        disconnected[64] = 0x01
        XCTAssertEqual(IcomLAN.parseStatus(Data(disconnected)), .radioDisconnected)

        var benign = [UInt8](repeating: 0, count: 80)
        benign[0] = 0x50; benign[48] = 0x10
        XCTAssertEqual(IcomLAN.parseStatus(Data(benign)), .other)
    }

    func testAnAudioDatagramFromTheRadioYieldsItsPCM() {
        // A real 664-byte audio datagram header, padded to length with zeros.
        var d = bytes("9802000000000100b774b8d96c4f3a9b8101b9b0000002800000")
        d.append(Data(repeating: 0, count: 664 - d.count))
        let pcm = IcomLAN.audioPayload(d)
        XCTAssertEqual(pcm?.count, 640, "24-byte header stripped, 640 bytes of PCM")
    }
}

import XCTest
import Network
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

    func testLocalIDEncodesTheSourceIPInItsTopBits() {
        // A real IC-705 refuses the audio/CI-V connection unless the top 16
        // bits of the session ID are the third and fourth octets of our
        // source IPv4 address. Routed to loopback, the source is 127.0.0.1,
        // so those octets are 0 and 1. routedSource supplies only that base;
        // the low 16 bits (the source UDP port) are filled in at .ready.
        let src = IcomLANStream.routedSource(toward: "127.0.0.1", port: 50001)
        XCTAssertEqual(src?.ip, "127.0.0.1")
        XCTAssertEqual((src?.base ?? 0) >> 16, 0x0001, "top 16 bits must be source-IP octets 3 and 4")
        XCTAssertEqual((src?.base ?? 0) & 0xFFFF, 0, "base carries no port; the port is added at .ready")
    }

    func testLocalIDLowBitsAreTheSourceUDPPort() {
        // The other half of the rule: the radio validates the connection
        // request against the low 16 bits being the actual source port. A
        // random low 16 gets login/token/caps accepted but the audio+CI-V
        // request silently refused, so the port must be read from the
        // socket's own bound endpoint, not invented.
        let ep = NWEndpoint.hostPort(host: "192.168.3.14", port: 55563)
        XCTAssertEqual(IcomLANStream.baseFromEndpoint(ep), 0x030E_0000, "IP octets 3,4 → top 16 bits")
        XCTAssertEqual(IcomLANStream.portFromEndpoint(ep), 55563, "low 16 bits are the source port")
        XCTAssertNil(IcomLANStream.portFromEndpoint(nil))
    }

    func testLoginReplyRejectedWhenSlotIsBusy() {
        // The radio marks a refused login (wrong password, or — much more
        // often in practice — a stale session still holding its single
        // client slot) with FF FF FF FE at offset 48. The two cases are
        // byte-for-byte identical, which is why IcomLANSession retries a
        // rejected login rather than failing a good password outright.
        var b = bytes("60000000000002000b4bd82cdd17905000000050020000000000e665710c3fdb00000000000000000000000000000000000000000000000000000000000000004654544800000000000000000000000001000000000000000000000000000000")
        b.replaceSubrange(48..<52, with: [0xFF, 0xFF, 0xFF, 0xFE])
        XCTAssertEqual(IcomLAN.parseLoginReply(b)?.accepted, false)
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

    // MARK: - Which packets answer a login

    func testAnAuthFailedStatusAnswersALoginAndRefusesIt() {
        // The refusal that costs an operator their evening: the radio is
        // still holding its single network-control slot from an unclean
        // exit and says so out-of-band, not in a login reply. Treating it
        // as an answer is what lets the login ladder retry until the slot
        // times out instead of failing on the first attempt.
        var authFailed = [UInt8](repeating: 0, count: 80)
        authFailed[0] = 0x50
        authFailed[48] = 0xFF; authFailed[49] = 0xFF; authFailed[50] = 0xFF; authFailed[51] = 0xFD
        XCTAssertTrue(IcomLAN.isLoginAnswer(Data(authFailed)))
        XCTAssertTrue(IcomLAN.isLoginRefusal(Data(authFailed)))
    }

    func testARejectedLoginReplyAnswersAndRefuses() {
        var b = bytes("60000000000002000b4bd82cdd17905000000050020000000000e665710c3fdb00000000000000000000000000000000000000000000000000000000000000004654544800000000000000000000000001000000000000000000000000000000")
        b.replaceSubrange(48..<52, with: [0xFF, 0xFF, 0xFF, 0xFE])
        XCTAssertTrue(IcomLAN.isLoginAnswer(b))
        XCTAssertTrue(IcomLAN.isLoginRefusal(b))
    }

    func testAnAcceptedLoginReplyAnswersWithoutRefusing() {
        let d = bytes("60000000000002000b4bd82cdd17905000000050020000000000e665710c3fdb00000000000000000000000000000000000000000000000000000000000000004654544800000000000000000000000001000000000000000000000000000000")
        XCTAssertEqual(IcomLAN.parseLoginReply(d)?.accepted, true, "fixture should be an accepted login")
        XCTAssertTrue(IcomLAN.isLoginAnswer(d))
        XCTAssertFalse(IcomLAN.isLoginRefusal(d))
    }

    func testRoutineStatusPacketsDoNotAnswerALogin() {
        // The radio emits status periodically. If those counted as answers
        // the ladder would wake on the first one and read it as a refusal,
        // burning all five attempts against a radio that never said no.
        var benign = [UInt8](repeating: 0, count: 80)
        benign[0] = 0x50; benign[48] = 0x10
        XCTAssertEqual(IcomLAN.parseStatus(Data(benign)), .other)
        XCTAssertFalse(IcomLAN.isLoginAnswer(Data(benign)))
        XCTAssertFalse(IcomLAN.isLoginRefusal(Data(benign)))

        var disconnected = [UInt8](repeating: 0, count: 80)
        disconnected[0] = 0x50
        disconnected[64] = 0x01
        XCTAssertFalse(IcomLAN.isLoginAnswer(Data(disconnected)))
    }

    func testAnAudioDatagramFromTheRadioYieldsItsPCM() {
        // A real 664-byte audio datagram header, padded to length with zeros.
        var d = bytes("9802000000000100b774b8d96c4f3a9b8101b9b0000002800000")
        d.append(Data(repeating: 0, count: 664 - d.count))
        let pcm = IcomLAN.audioPayload(d)
        XCTAssertEqual(pcm?.count, 640, "24-byte header stripped, 640 bytes of PCM")
    }
}

/// The three faults that between them made CI-V over the radio's WLAN
/// impossible, pinned against bytes captured from an IC-705 on 2026-09-13.
///
/// Each one on its own produces the same symptom — a radio that works on a
/// cable and answers nothing over Wi-Fi — which is why fixing any one of them
/// alone looked like no progress at all.
final class IcomLANWiFiRegressionTests: XCTestCase {

    /// A scope waveform packet as the radio actually sends it: 518 bytes on
    /// the wire, 497 of payload, `F1 01` in the length field. Read as one
    /// byte that is 241, the packet is rejected — and because these packets
    /// share the CI-V stream's sequence numbering, rejecting them stalls the
    /// reorder buffer and every genuine reply behind it.
    func testTheRadiosLongPacketsParse() {
        let payload = [UInt8](repeating: 0xAA, count: 497)
        var packet = IcomLAN.Header(length: 518, type: 0, sequence: 0x9300,
                                    senderID: 0x94A50D62, receiverID: 0x030ECA1F).bytes
        packet += [0xC1, 0xF1, 0x01, 0x00, 0x93]
        packet += payload
        XCTAssertEqual(packet.count, 518)
        XCTAssertEqual(IcomLAN.serialPayload(Data(packet))?.count, 497, "497 is F1 01, not F1")
    }

    func testShortFramesStillRoundTrip() {
        let frame = CIVCommand.setScopeDataOutput(false).encoded()
        let packet = IcomLAN.serialData(frame, sendSequence: 1, local: 0x030ECA1F, remote: 0x94A50D62)
        XCTAssertEqual([UInt8](packet)[16...20], [0xC1, 0x08, 0x00, 0x00, 0x01])
        XCTAssertEqual(IcomLAN.serialPayload(packet), frame)
    }

    func testLengthsAcrossTheByteBoundary() {
        for n in [1, 80, 254, 255, 256, 497, 1000] {
            let payload = Data((0..<n).map { UInt8($0 & 0xFF) })
            let packet = IcomLAN.serialData(payload, sendSequence: 7, local: 3, remote: 4)
            XCTAssertEqual(IcomLAN.serialPayload(packet), payload, "\(n) bytes must survive")
        }
    }

    /// The link does not get to pick the controller address.
    ///
    /// An override forcing 0xE1 over the network link shipped on
    /// 2026-09-17 and stopped CI-V dead: every command went out from E1,
    /// the radio echoed each one and answered none, PTT timed out, and the
    /// station could not key at all. The address is the operator's setting
    /// and nothing may quietly substitute another.
    func testTheLinkDoesNotSubstituteAControllerAddress() {
        for link in [ModemRigLink.lan, .usb] {
            var config = ModemLinkConfig()
            config.rigLink = link
            XCTAssertEqual(config.effectiveCIVControllerAddress, 0xE0,
                           "\(link) must not rewrite the default")

            config.civControllerAddress = 0xE4
            XCTAssertEqual(config.effectiveCIVControllerAddress, 0xE4,
                           "\(link) must not rewrite an explicit choice either")
        }
    }

    /// `1F` and `23` take a subcommand; without them in the table their
    /// replies match no request and six working commands read as missing.
    func testTheSubcommandTableCoversTheDVAndGPSCommands() {
        for command: UInt8 in [0x1F, 0x20, 0x22, 0x23, 0x24, 0x28] {
            XCTAssertEqual(CIVCommand.subcommandLength(command), 1,
                           String(format: "%02X takes a subcommand", command))
        }
        // And the table still has to say no. Returning 1 for everything
        // passes the loop above while folding a byte of data into the
        // subcommand of every reply that never had one.
        for command: UInt8 in [0x03, 0x04, 0x05, 0x06, 0x18] {
            XCTAssertEqual(CIVCommand.subcommandLength(command), 0,
                           String(format: "%02X takes no subcommand", command))
        }

        // The radio's real answer to `1F 00`: MY call sign, K0EPI.
        let bytes: [UInt8] = [0xFE, 0xFE, 0xE1, 0xA4, 0x1F, 0x00,
                              0x4B, 0x30, 0x45, 0x50, 0x49, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0xFD]
        let frame = CIVFrame.parse(bytes)
        XCTAssertEqual(frame?.subcommand, 0x00, "without this the reply matches no request")
        XCTAssertEqual(String(decoding: frame?.data ?? [], as: UTF8.self)
            .trimmingCharacters(in: .whitespaces), "K0EPI")
    }

    /// DATA MOD over the WLAN is 03. 02 is MIC and USB — a dead input.
    func testWLANModulationIsThree() {
        XCTAssertEqual(CIVClient.DataModSource.wlan.rawValue, 0x03)
        XCTAssertEqual(CIVClient.DataModSource.micAndUSB.rawValue, 0x02)
    }
}

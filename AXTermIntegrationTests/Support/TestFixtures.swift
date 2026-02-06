//
//  TestFixtures.swift
//  AXTermIntegrationTests
//
//  Pre-built AX.25 and AXDP test frames for integration testing.
//

import Foundation

// MARK: - AX.25 Address

/// Simple AX.25 address for test frame building
struct TestAX25Address {
    let callsign: String
    let ssid: UInt8

    init(_ callsign: String, ssid: UInt8 = 0) {
        self.callsign = callsign.uppercased()
        self.ssid = ssid
    }

    /// Encode address for AX.25 frame (7 bytes: 6 callsign + 1 SSID)
    func encode(isLast: Bool = false, hasBeenRepeated: Bool = false) -> Data {
        var data = Data()

        // Pad callsign to 6 characters, shift left by 1
        var padded = callsign.padding(toLength: 6, withPad: " ", startingAt: 0)
        for char in padded.utf8 {
            data.append(char << 1)
        }

        // SSID byte: C R R SSID 0 (bit 0 = extension bit, 1 = last address)
        var ssidByte: UInt8 = 0x60  // C=1, R=1 for command/response
        ssidByte |= (ssid & 0x0F) << 1
        if hasBeenRepeated {
            ssidByte |= 0x80  // H bit
        }
        if isLast {
            ssidByte |= 0x01  // Extension bit
        }
        data.append(ssidByte)

        return data
    }
}

// MARK: - Test Frame Builder

/// Builder for constructing AX.25 test frames
struct TestFrameBuilder {

    // MARK: - UI Frame Building

    /// Build a UI (Unnumbered Information) frame
    static func buildUIFrame(
        from source: TestAX25Address,
        to destination: TestAX25Address,
        via: [TestAX25Address] = [],
        payload: Data,
        pid: UInt8 = 0xF0
    ) -> Data {
        var frame = Data()

        // Destination address
        frame.append(destination.encode(isLast: via.isEmpty && true == false))

        // Source address
        let sourceIsLast = via.isEmpty
        frame.append(source.encode(isLast: sourceIsLast))

        // Via path (digipeaters)
        for (index, digi) in via.enumerated() {
            let isLast = index == via.count - 1
            frame.append(digi.encode(isLast: isLast))
        }

        // Control field: UI frame = 0x03
        frame.append(0x03)

        // PID (Protocol ID)
        frame.append(pid)

        // Payload
        frame.append(payload)

        return frame
    }

    /// Build a UI frame with text payload
    static func buildUIFrame(
        from source: String,
        to destination: String,
        text: String
    ) -> Data {
        buildUIFrame(
            from: TestAX25Address(source),
            to: TestAX25Address(destination),
            payload: Data(text.utf8)
        )
    }

    /// Build a UI frame with AXDP payload
    static func buildAXDPFrame(
        from source: String,
        to destination: String,
        message: String
    ) -> Data {
        let axdpPayload = TestAXDPBuilder.buildChatMessage(text: message)
        return buildUIFrame(
            from: TestAX25Address(source),
            to: TestAX25Address(destination),
            payload: axdpPayload
        )
    }
}

// MARK: - AXDP Builder

/// Builder for AXDP test payloads
struct TestAXDPBuilder {
    // AXDP magic header
    static let magic = Data("AXT1".utf8)

    // TLV types
    static let TLV_MESSAGE_TYPE: UInt8 = 0x01
    static let TLV_SESSION_ID: UInt8 = 0x02
    static let TLV_MESSAGE_ID: UInt8 = 0x03
    static let TLV_PAYLOAD: UInt8 = 0x06

    // Message types
    static let MSG_CHAT: UInt8 = 1
    static let MSG_PING: UInt8 = 6
    static let MSG_PONG: UInt8 = 7

    /// Build an AXDP chat message
    static func buildChatMessage(text: String, sessionId: UInt16 = 0, messageId: UInt32? = nil) -> Data {
        var data = Data()

        // Magic header
        data.append(magic)

        // Message type TLV
        data.append(TLV_MESSAGE_TYPE)
        data.append(contentsOf: UInt16(1).bigEndianBytes)  // length
        data.append(MSG_CHAT)

        // Session ID TLV
        data.append(TLV_SESSION_ID)
        data.append(contentsOf: UInt16(2).bigEndianBytes)  // length
        data.append(contentsOf: sessionId.bigEndianBytes)

        // Message ID TLV
        let msgId = messageId ?? UInt32.random(in: 1...UInt32.max)
        data.append(TLV_MESSAGE_ID)
        data.append(contentsOf: UInt16(4).bigEndianBytes)  // length
        data.append(contentsOf: msgId.bigEndianBytes)

        // Payload TLV
        let textData = Data(text.utf8)
        data.append(TLV_PAYLOAD)
        data.append(contentsOf: UInt16(textData.count).bigEndianBytes)
        data.append(textData)

        return data
    }

    /// Build an AXDP PING message
    static func buildPing(sessionId: UInt16 = 0) -> Data {
        var data = Data()

        // Magic header
        data.append(magic)

        // Message type TLV
        data.append(TLV_MESSAGE_TYPE)
        data.append(contentsOf: UInt16(1).bigEndianBytes)
        data.append(MSG_PING)

        // Session ID TLV
        data.append(TLV_SESSION_ID)
        data.append(contentsOf: UInt16(2).bigEndianBytes)
        data.append(contentsOf: sessionId.bigEndianBytes)

        return data
    }

    /// Check if data has AXDP magic header
    static func hasAXDPMagic(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return data.prefix(4) == magic
    }
}

// MARK: - Helpers

extension UInt16 {
    var bigEndianBytes: [UInt8] {
        [UInt8((self >> 8) & 0xFF), UInt8(self & 0xFF)]
    }
}

extension UInt32 {
    var bigEndianBytes: [UInt8] {
        [
            UInt8((self >> 24) & 0xFF),
            UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF),
            UInt8(self & 0xFF)
        ]
    }
}

// MARK: - Connected Mode Frame Builder

/// Builder for connected-mode AX.25 frames (SABM, UA, I-frames, RR, etc.)
struct TestConnectedFrameBuilder {

    // MARK: - Control Byte Constants

    /// SABM control byte (with P=1)
    static let sabmControl: UInt8 = 0x3F  // 0x2F | 0x10 (P bit)

    /// UA control byte (with F=1)
    static let uaControl: UInt8 = 0x73    // 0x63 | 0x10 (F bit)

    /// DM control byte (with F=1)
    static let dmControl: UInt8 = 0x1F    // 0x0F | 0x10 (F bit)

    /// DISC control byte (with P=1)
    static let discControl: UInt8 = 0x53  // 0x43 | 0x10 (P bit)

    // MARK: - U-Frame Building

    /// Build a SABM (connection request) frame
    static func buildSABM(
        from source: TestAX25Address,
        to destination: TestAX25Address,
        via: [TestAX25Address] = []
    ) -> Data {
        return buildUFrame(from: source, to: destination, via: via, control: sabmControl)
    }

    /// Build a UA (unnumbered acknowledge) frame
    static func buildUA(
        from source: TestAX25Address,
        to destination: TestAX25Address,
        via: [TestAX25Address] = []
    ) -> Data {
        return buildUFrame(from: source, to: destination, via: via, control: uaControl)
    }

    /// Build a DM (disconnected mode) frame
    static func buildDM(
        from source: TestAX25Address,
        to destination: TestAX25Address,
        via: [TestAX25Address] = []
    ) -> Data {
        return buildUFrame(from: source, to: destination, via: via, control: dmControl)
    }

    /// Build a DISC (disconnect) frame
    static func buildDISC(
        from source: TestAX25Address,
        to destination: TestAX25Address,
        via: [TestAX25Address] = []
    ) -> Data {
        return buildUFrame(from: source, to: destination, via: via, control: discControl)
    }

    /// Build a generic U-frame with given control byte
    private static func buildUFrame(
        from source: TestAX25Address,
        to destination: TestAX25Address,
        via: [TestAX25Address],
        control: UInt8
    ) -> Data {
        var frame = Data()

        // Destination address
        frame.append(destination.encode(isLast: false))

        // Source address
        let sourceIsLast = via.isEmpty
        frame.append(source.encode(isLast: sourceIsLast))

        // Via path
        for (index, digi) in via.enumerated() {
            frame.append(digi.encode(isLast: index == via.count - 1))
        }

        // Control field
        frame.append(control)

        return frame
    }

    // MARK: - I-Frame Building

    /// Build an I-frame (information frame) with sequence numbers
    /// Format: NNNPSSS0 where NNN=N(R), P=P/F, SSS=N(S), 0=I-frame indicator
    static func buildIFrame(
        from source: TestAX25Address,
        to destination: TestAX25Address,
        via: [TestAX25Address] = [],
        ns: Int,
        nr: Int,
        pf: Bool = false,
        pid: UInt8 = 0xF0,
        payload: Data
    ) -> Data {
        var frame = Data()

        // Destination address
        frame.append(destination.encode(isLast: false))

        // Source address
        let sourceIsLast = via.isEmpty
        frame.append(source.encode(isLast: sourceIsLast))

        // Via path
        for (index, digi) in via.enumerated() {
            frame.append(digi.encode(isLast: index == via.count - 1))
        }

        // Control field: NNNPSSS0
        var control: UInt8 = 0x00  // bit 0 = 0 for I-frame
        control |= UInt8((ns & 0x07) << 1)  // N(S) in bits 1-3
        if pf { control |= 0x10 }            // P/F in bit 4
        control |= UInt8((nr & 0x07) << 5)  // N(R) in bits 5-7
        frame.append(control)

        // PID
        frame.append(pid)

        // Payload
        frame.append(payload)

        return frame
    }

    /// Build an I-frame with text payload
    static func buildIFrame(
        from source: String,
        to destination: String,
        ns: Int,
        nr: Int,
        text: String
    ) -> Data {
        buildIFrame(
            from: TestAX25Address(source),
            to: TestAX25Address(destination),
            ns: ns,
            nr: nr,
            payload: Data(text.utf8)
        )
    }

    // MARK: - S-Frame Building

    /// Build an RR (Receive Ready) frame
    /// Format: NNN P 0001 where NNN=N(R), P=P/F bit
    static func buildRR(
        from source: TestAX25Address,
        to destination: TestAX25Address,
        via: [TestAX25Address] = [],
        nr: Int,
        pf: Bool = false
    ) -> Data {
        return buildSFrame(from: source, to: destination, via: via, sType: 0x01, nr: nr, pf: pf)
    }

    /// Build a REJ (Reject) frame
    static func buildREJ(
        from source: TestAX25Address,
        to destination: TestAX25Address,
        via: [TestAX25Address] = [],
        nr: Int,
        pf: Bool = false
    ) -> Data {
        return buildSFrame(from: source, to: destination, via: via, sType: 0x09, nr: nr, pf: pf)
    }

    /// Build a generic S-frame
    private static func buildSFrame(
        from source: TestAX25Address,
        to destination: TestAX25Address,
        via: [TestAX25Address],
        sType: UInt8,
        nr: Int,
        pf: Bool
    ) -> Data {
        var frame = Data()

        // Destination address
        frame.append(destination.encode(isLast: false))

        // Source address
        let sourceIsLast = via.isEmpty
        frame.append(source.encode(isLast: sourceIsLast))

        // Via path
        for (index, digi) in via.enumerated() {
            frame.append(digi.encode(isLast: index == via.count - 1))
        }

        // Control field: NNN P SS 01
        var control = sType
        if pf { control |= 0x10 }
        control |= UInt8((nr & 0x07) << 5)
        frame.append(control)

        return frame
    }

    // MARK: - Parsing Helpers

    /// Extract control byte from an AX.25 frame
    static func extractControlByte(from frame: Data) -> UInt8? {
        // Find the end of address field (byte with bit 0 = 1)
        var offset = 0
        while offset < frame.count {
            if frame[offset] & 0x01 != 0 {
                // Found last address byte
                let controlOffset = offset + 1
                if controlOffset < frame.count {
                    return frame[controlOffset]
                }
                return nil
            }
            offset += 1
        }
        return nil
    }

    /// Extract N(R) from a control byte (I-frame or S-frame)
    static func extractNR(from control: UInt8) -> Int {
        return Int((control >> 5) & 0x07)
    }

    /// Extract N(S) from an I-frame control byte
    static func extractNS(from control: UInt8) -> Int {
        return Int((control >> 1) & 0x07)
    }

    /// Check if control byte is an I-frame
    static func isIFrame(_ control: UInt8) -> Bool {
        return (control & 0x01) == 0
    }

    /// Check if control byte is an S-frame
    static func isSFrame(_ control: UInt8) -> Bool {
        return (control & 0x03) == 0x01
    }

    /// Check if control byte is RR
    static func isRR(_ control: UInt8) -> Bool {
        return isSFrame(control) && ((control >> 2) & 0x03) == 0x00
    }
}

// MARK: - Pre-built Test Frames

/// Common test frames for integration tests
enum TestFrames {

    /// Plain text UI frame: TEST-1 -> TEST-2 "Hello World"
    static var plainTextHello: Data {
        TestFrameBuilder.buildUIFrame(
            from: "TEST-1",
            to: "TEST-2",
            text: "Hello World"
        )
    }

    /// Plain text UI frame: TEST-2 -> TEST-1 "Hello Back"
    static var plainTextReply: Data {
        TestFrameBuilder.buildUIFrame(
            from: "TEST-2",
            to: "TEST-1",
            text: "Hello Back"
        )
    }

    /// AXDP chat frame: TEST-1 -> TEST-2
    static var axdpChatHello: Data {
        TestFrameBuilder.buildAXDPFrame(
            from: "TEST-1",
            to: "TEST-2",
            message: "AXDP Test Message"
        )
    }

    /// Broadcast frame: TEST-1 -> CQ
    static var broadcast: Data {
        TestFrameBuilder.buildUIFrame(
            from: "TEST-1",
            to: "CQ",
            text: "CQ CQ CQ de TEST-1"
        )
    }

    /// Frame with digipeater path
    static var viaPath: Data {
        TestFrameBuilder.buildUIFrame(
            from: TestAX25Address("TEST-1"),
            to: TestAX25Address("TEST-2"),
            via: [TestAX25Address("WIDE1", ssid: 1)],
            payload: Data("Via path test".utf8)
        )
    }
}

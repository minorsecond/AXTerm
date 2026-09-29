//
//  NetRomTransportWire.swift
//  AXTerm
//
//  NET/ROM Level 3 (network) and Level 4 (transport) wire codec.
//
//  The byte layout here is not designed — it is transcribed. NET/ROM's
//  canonical description is the ARRL 7th Computer Networking Conference
//  paper, and the interop-proven rendering of it is the Linux kernel's
//  AF_NETROM stack (net/netrom/, removed after v6.6 but field-tested for
//  three decades against BPQ, TheNet, and Xrouter). Field meanings below
//  cite that source. Where AXTerm deviates, the deviation is called out
//  inline and in Docs/NetRomTransport.md.
//
//  A NET/ROM datagram rides the info field of an AX.25 I-frame (or UI
//  frame) with PID 0xCF:
//
//      bytes 0..6    origin callsign   (AX.25-shifted, E=0)
//      bytes 7..13   destination callsign (AX.25-shifted, E=1)
//      byte  14      TTL, decremented per hop
//      byte  15      circuit index  ─┐
//      byte  16      circuit id      │  meaning depends
//      byte  17      tx sequence     │  on the opcode
//      byte  18      rx sequence    ─┘
//      byte  19      opcode (low nibble) | flags (high nibble)
//      bytes 20..    opcode-specific data
//

import Foundation

// MARK: - Constants

nonisolated enum NetRomWire {
    /// AX.25 PID marking a NET/ROM layer-3 payload.
    static let pid: UInt8 = 0xCF

    /// L3 header: two 7-byte callsigns + TTL. (NR_NETWORK_LEN)
    static let networkHeaderLength = 15

    /// L4 header: index, id, txSeq, rxSeq, opcode. (NR_TRANSPORT_LEN)
    static let transportHeaderLength = 5

    static let headerLength = networkHeaderLength + transportHeaderLength

    /// Largest INFO payload per frame. (NR_MAX_PACKET_SIZE)
    static let maxInfoPayload = 236

    /// Sequence-number modulus. (NR_MODULUS)
    static let modulus = 256

    /// Largest negotiable window. (NR_MAX_WINDOW_SIZE)
    static let maxWindow = 127

    /// Marker for IP-over-NET/ROM: opcode 0 with index == id == NR_PROTO_IP.
    static let ipProtocolMarker: UInt8 = 0x0C
}

/// L4 opcode, the low nibble of byte 19.
nonisolated enum NetRomOpcode: UInt8, Sendable, CaseIterable {
    case protocolExtension = 0x00   // INP3, L3RTT, IP-over-NET/ROM — opaque to us
    case connectRequest    = 0x01
    case connectAck        = 0x02
    case disconnectRequest = 0x03
    case disconnectAck     = 0x04
    case information       = 0x05
    case informationAck    = 0x06
    /// Xrouter extension (NR_RESET). Parsed so a peer that speaks it is
    /// understood; never emitted — the kernel source records that
    /// unsolicited CONACK|CHOKE "resets" kill BPQ boxes, and opcode-7
    /// resets are only safe between consenting Xrouters.
    case reset             = 0x07
}

/// L4 flag bits, the high nibble of byte 19.
nonisolated struct NetRomL4Flags: OptionSet, Sendable, Hashable {
    let rawValue: UInt8
    static let choke       = NetRomL4Flags(rawValue: 0x80)  // NR_CHOKE_FLAG
    static let nak         = NetRomL4Flags(rawValue: 0x40)  // NR_NAK_FLAG
    static let moreFollows = NetRomL4Flags(rawValue: 0x20)  // NR_MORE_FLAG
    static let reserved    = NetRomL4Flags(rawValue: 0x10)
}

// MARK: - L4 frame model

/// One parsed NET/ROM transport frame — the five header bytes plus data,
/// with the opcode-dependent field meanings made explicit.
nonisolated enum NetRomL4Frame: Equatable, Sendable {
    /// CONREQ. `myIndex`/`myId` are the *initiator's* handle for the new
    /// circuit; data carries the proposed window, the connecting user's
    /// callsign, the originating node's callsign, and (BPQ extension,
    /// detected by length) the initiator's T1 in seconds.
    case connectRequest(
        myIndex: UInt8, myId: UInt8,
        proposedWindow: UInt8,
        user: AX25Address, originNode: AX25Address,
        t1Seconds: UInt16?
    )

    /// CONACK. `yourIndex`/`yourId` echo the initiator's handle;
    /// `myIndex`/`myId` are the acceptor's. `refused` is the choke flag.
    /// A standard refusal keeps this field order with the acceptor's
    /// handle zeroed; the exotic [0,0,idx,id] unknown-circuit shape is
    /// normalized by the parser back into this one.
    /// `ttl` is the BPQ-extension trailing byte, present when the peer
    /// detected our extended CONREQ.
    case connectAck(
        yourIndex: UInt8, yourId: UInt8,
        myIndex: UInt8, myId: UInt8,
        acceptedWindow: UInt8?,
        ttl: UInt8?,
        refused: Bool
    )

    case disconnectRequest(yourIndex: UInt8, yourId: UInt8)

    case disconnectAck(yourIndex: UInt8, yourId: UInt8)

    /// INFO. `txSeq` numbers this frame; `rxSeq` piggybacks an ack of
    /// everything below it. `moreFollows` marks a fragment of a larger
    /// record; `choke` piggybacks the sender's own-busy condition.
    case information(
        yourIndex: UInt8, yourId: UInt8,
        txSeq: UInt8, rxSeq: UInt8,
        choke: Bool, nak: Bool, moreFollows: Bool,
        payload: Data
    )

    /// INFOACK. `rxSeq` acks everything below it. `nak` asks for a
    /// retransmission starting at `rxSeq`; `choke` = stop sending.
    case informationAck(
        yourIndex: UInt8, yourId: UInt8,
        rxSeq: UInt8,
        choke: Bool, nak: Bool
    )

    /// Opcode 0 — INP3/L3RTT/IP traffic. Carried opaque (the five header
    /// bytes plus data, verbatim) so nothing downstream invents semantics.
    case protocolExtension(raw: Data)

    /// Xrouter opcode 7. Parsed, never emitted.
    case reset(yourIndex: UInt8, yourId: UInt8)
}

// MARK: - Datagram

/// One NET/ROM L3 datagram: routing envelope plus transport frame.
nonisolated struct NetRomDatagram: Equatable, Sendable {
    var origin: AX25Address
    var destination: AX25Address
    var ttl: UInt8
    var transport: NetRomL4Frame
}

// MARK: - Codec

nonisolated enum NetRomTransportWire {

    // MARK: Callsign field codec

    /// Encode a callsign into NET/ROM's embedded 7-byte form.
    /// Kernel convention (`nr_write_internal`): C-bit clear, spare bits
    /// set (0x60), E-bit clear on the origin field and set on the
    /// destination field of the L3 header; clear on callsigns embedded
    /// in CONREQ data.
    static func encodeCallsignField(_ address: AX25Address, lastBit: Bool) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(7)
        let padded = address.call.padding(toLength: 6, withPad: " ", startingAt: 0).prefix(6)
        for char in padded {
            bytes.append(UInt8(char.asciiValue ?? 0x20) << 1)
        }
        var ssidByte: UInt8 = 0x60  // AX25_SSSID_SPARE
        ssidByte |= UInt8(address.ssid & 0x0F) << 1
        if lastBit { ssidByte |= 0x01 }
        bytes.append(ssidByte)
        return bytes
    }

    /// Decode a 7-byte callsign field. Tolerant of C/E/spare bit noise
    /// (only bits 1–4 of the SSID byte are meaningful on receive — the
    /// kernel masks the rest, and so do we). Returns nil for byte
    /// patterns that cannot be a callsign, which is the codec's main
    /// defense against treating line noise as a datagram.
    static func decodeCallsignField(_ bytes: ArraySlice<UInt8>) -> AX25Address? {
        guard bytes.count == 7 else { return nil }
        let b = Array(bytes)
        var call = ""
        for i in 0..<6 {
            // Low bit is address-extension noise in this context; the
            // character lives in the top 7 bits.
            let ch = b[i] >> 1
            if ch == 0x20 { break }  // space: end of callsign
            let isUpper = ch >= 0x41 && ch <= 0x5A
            let isDigit = ch >= 0x30 && ch <= 0x39
            guard isUpper || isDigit else { return nil }
            call.append(Character(UnicodeScalar(ch)))
        }
        guard !call.isEmpty else { return nil }
        // Everything after the first space must also be space padding.
        var seenEnd = false
        for i in 0..<6 {
            let ch = b[i] >> 1
            if seenEnd && ch != 0x20 { return nil }
            if ch == 0x20 { seenEnd = true }
        }
        let ssid = Int((b[6] >> 1) & 0x0F)
        return AX25Address(call: call, ssid: ssid)
    }

    // MARK: Parse

    /// Parse one L3 datagram. Total: any input yields a value or nil,
    /// never a trap.
    static func parse(_ data: Data) -> NetRomDatagram? {
        let bytes = [UInt8](data)
        guard bytes.count >= NetRomWire.headerLength else { return nil }

        guard let origin = decodeCallsignField(bytes[0..<7]),
              let destination = decodeCallsignField(bytes[7..<14])
        else { return nil }
        let ttl = bytes[14]
        // A TTL of zero should have been discarded by the previous hop;
        // treat it as malformed rather than inventing a meaning.
        guard ttl > 0 else { return nil }

        guard let transport = parseTransport(bytes: bytes) else { return nil }
        return NetRomDatagram(origin: origin, destination: destination, ttl: ttl, transport: transport)
    }

    private static func parseTransport(bytes: [UInt8]) -> NetRomL4Frame? {
        let b15 = bytes[15]
        let b16 = bytes[16]
        let b17 = bytes[17]
        let b18 = bytes[18]
        let opcodeRaw = bytes[19] & 0x0F
        let flags = NetRomL4Flags(rawValue: bytes[19] & 0xF0)
        let payload = bytes.count > 20 ? Data(bytes[20...]) : Data()

        guard let opcode = NetRomOpcode(rawValue: opcodeRaw) else {
            // Low nibble 0x8–0xF: nothing defines these. Malformed.
            return nil
        }

        switch opcode {
        case .protocolExtension:
            // Opaque: header bytes 15–19 plus data, verbatim.
            return .protocolExtension(raw: Data(bytes[15...]))

        case .connectRequest:
            // Data: window(1) user(7) node(7) [t1 lo, t1 hi]
            guard payload.count == 15 || payload.count == 17 else { return nil }
            let p = [UInt8](payload)
            guard let user = decodeCallsignField(p[1..<8]),
                  let node = decodeCallsignField(p[8..<15])
            else { return nil }
            var t1: UInt16?
            if p.count == 17 {
                t1 = UInt16(p[15]) | (UInt16(p[16]) << 8)  // little-endian seconds
            }
            return .connectRequest(
                myIndex: b15, myId: b16,
                proposedWindow: p[0],
                user: user, originNode: node,
                t1Seconds: t1
            )

        case .connectAck:
            // Data: window(1) [ttl(1) if BPQ extension]. A kernel-style
            // refusal carries exactly one data byte; be liberal and
            // accept zero data bytes too (window nil).
            guard payload.count <= 2 else { return nil }
            let p = [UInt8](payload)
            let refused = flags.contains(.choke)
            if refused && b15 == 0 && b16 == 0 {
                // Exotic refusal/reset shape: handle rides bytes 17/18
                // with 15/16 zeroed (`__nr_transmit_reply(mine: 1)` —
                // the unknown-circuit reply). The standard refusal keeps
                // CONACK field order and is handled below.
                // Normalize: yourIndex/yourId = the addressed handle.
                return .connectAck(
                    yourIndex: b17, yourId: b18,
                    myIndex: 0, myId: 0,
                    acceptedWindow: p.first, ttl: nil,
                    refused: true
                )
            }
            return .connectAck(
                yourIndex: b15, yourId: b16,
                myIndex: b17, myId: b18,
                acceptedWindow: p.first,
                ttl: p.count == 2 ? p[1] : nil,
                refused: refused
            )

        case .disconnectRequest:
            guard payload.isEmpty else { return nil }
            return .disconnectRequest(yourIndex: b15, yourId: b16)

        case .disconnectAck:
            guard payload.isEmpty else { return nil }
            return .disconnectAck(yourIndex: b15, yourId: b16)

        case .information:
            guard payload.count <= NetRomWire.maxInfoPayload else { return nil }
            return .information(
                yourIndex: b15, yourId: b16,
                txSeq: b17, rxSeq: b18,
                choke: flags.contains(.choke),
                nak: flags.contains(.nak),
                moreFollows: flags.contains(.moreFollows),
                payload: payload
            )

        case .informationAck:
            // Kernel emits no data; tolerate stray trailing bytes from
            // other implementations by ignoring them? No — a bounded
            // protocol should bound: refuse more than 2 stray bytes.
            guard payload.count <= 2 else { return nil }
            return .informationAck(
                yourIndex: b15, yourId: b16,
                rxSeq: b18,
                choke: flags.contains(.choke),
                nak: flags.contains(.nak)
            )

        case .reset:
            return .reset(yourIndex: b15, yourId: b16)
        }
    }

    // MARK: Encode

    /// Encode a datagram to wire bytes, byte-compatible with
    /// `nr_write_internal` / `__nr_transmit_reply`.
    static func encode(_ datagram: NetRomDatagram) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(NetRomWire.headerLength + 32)
        bytes += encodeCallsignField(datagram.origin, lastBit: false)
        bytes += encodeCallsignField(datagram.destination, lastBit: true)
        bytes.append(datagram.ttl)
        bytes += encodeTransport(datagram.transport)
        return Data(bytes)
    }

    static func encodeTransport(_ frame: NetRomL4Frame) -> [UInt8] {
        switch frame {
        case let .connectRequest(myIndex, myId, proposedWindow, user, originNode, t1Seconds):
            var bytes: [UInt8] = [myIndex, myId, 0, 0, NetRomOpcode.connectRequest.rawValue]
            bytes.append(proposedWindow)
            bytes += encodeCallsignField(user, lastBit: false)
            bytes += encodeCallsignField(originNode, lastBit: false)
            if let t1 = t1Seconds {
                bytes.append(UInt8(t1 & 0xFF))
                bytes.append(UInt8(t1 >> 8))
            }
            return bytes

        case let .connectAck(yourIndex, yourId, myIndex, myId, acceptedWindow, ttl, refused):
            // A refusal keeps the standard CONACK field order — the
            // requester's handle in bytes 15/16 with our (nonexistent)
            // handle zeroed (`nr_transmit_refusal` → `__nr_transmit_reply`
            // with mine=0). The inverted [0,0,idx,id] shape is the
            // unknown-circuit reset, which we parse but never emit.
            let opcode = NetRomOpcode.connectAck.rawValue | (refused ? NetRomL4Flags.choke.rawValue : 0)
            var bytes: [UInt8] = [yourIndex, yourId, myIndex, myId, opcode]
            if let w = acceptedWindow { bytes.append(w) }
            if let t = ttl { bytes.append(t) }
            return bytes

        case let .disconnectRequest(yourIndex, yourId):
            return [yourIndex, yourId, 0, 0, NetRomOpcode.disconnectRequest.rawValue]

        case let .disconnectAck(yourIndex, yourId):
            return [yourIndex, yourId, 0, 0, NetRomOpcode.disconnectAck.rawValue]

        case let .information(yourIndex, yourId, txSeq, rxSeq, choke, nak, moreFollows, payload):
            var flags: UInt8 = 0
            if choke { flags |= NetRomL4Flags.choke.rawValue }
            if nak { flags |= NetRomL4Flags.nak.rawValue }
            if moreFollows { flags |= NetRomL4Flags.moreFollows.rawValue }
            var bytes: [UInt8] = [yourIndex, yourId, txSeq, rxSeq, NetRomOpcode.information.rawValue | flags]
            bytes += [UInt8](payload)
            return bytes

        case let .informationAck(yourIndex, yourId, rxSeq, choke, nak):
            var flags: UInt8 = 0
            if choke { flags |= NetRomL4Flags.choke.rawValue }
            if nak { flags |= NetRomL4Flags.nak.rawValue }
            return [yourIndex, yourId, 0, rxSeq, NetRomOpcode.informationAck.rawValue | flags]

        case let .protocolExtension(raw):
            return [UInt8](raw)

        case let .reset(yourIndex, yourId):
            return [yourIndex, yourId, 0, 0, NetRomOpcode.reset.rawValue]
        }
    }
}

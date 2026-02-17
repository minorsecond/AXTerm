//
//  KISSAX25Decoder.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import Foundation

// MARK: - KISS Protocol

/// KISS protocol constants and utilities
nonisolated enum KISS {
    // KISS framing bytes
    static let FEND: UInt8 = 0xC0
    static let FESC: UInt8 = 0xDB
    static let TFEND: UInt8 = 0xDC
    static let TFESC: UInt8 = 0xDD

    // KISS command types (only supporting data frame on port 0)
    static let CMD_DATA: UInt8 = 0x00

    /// Unescape KISS-escaped data
    /// Converts FESC+TFEND -> FEND and FESC+TFESC -> FESC
    static func unescape(_ data: Data) -> Data {
        var result = Data()
        result.reserveCapacity(data.count)

        var i = 0
        while i < data.count {
            let byte = data[i]
            if byte == FESC && i + 1 < data.count {
                let next = data[i + 1]
                if next == TFEND {
                    result.append(FEND)
                    i += 2
                    continue
                } else if next == TFESC {
                    result.append(FESC)
                    i += 2
                    continue
                }
            }
            result.append(byte)
            i += 1
        }
        return result
    }

    // MARK: - TX Encoding

    /// Escape data for KISS transmission
    /// Converts FEND -> FESC+TFEND and FESC -> FESC+TFESC
    static func escape(_ data: Data) -> Data {
        var result = Data()
        // Worst case: every byte needs escaping (doubles size)
        result.reserveCapacity(data.count * 2)

        for byte in data {
            if byte == FEND {
                result.append(FESC)
                result.append(TFEND)
            } else if byte == FESC {
                result.append(FESC)
                result.append(TFESC)
            } else {
                result.append(byte)
            }
        }
        return result
    }

    /// Build a complete KISS frame from an AX.25 payload
    /// Format: FEND + command byte + escaped payload + FEND
    /// - Parameters:
    ///   - payload: The raw AX.25 frame bytes to transmit
    ///   - port: The KISS port number (0-15, default 0)
    /// - Returns: Complete KISS frame ready for TCP transmission
    static func encodeFrame(payload: Data, port: UInt8 = 0) -> Data {
        var frame = Data()
        // Reserve capacity: FEND + cmd + escaped payload (worst case 2x) + FEND
        frame.reserveCapacity(2 + payload.count * 2)

        // Start delimiter
        frame.append(FEND)

        // Command byte: high nibble = port, low nibble = command (0 = data)
        let command = (port << 4) | CMD_DATA
        frame.append(command)

        // Escaped AX.25 payload
        frame.append(escape(payload))

        // End delimiter
        frame.append(FEND)

        return frame
    }
}

// MARK: - KISS Frame Parser

/// Output from the KISS frame parser
nonisolated enum KISSFrameOutput {
    case ax25(Data)
    case mobilinkdTelemetry(Data) // Raw hardware frame payload
    case unknown(command: UInt8, payload: Data)
}

/// Stateful parser for extracting KISS frames from a TCP byte stream.
/// Handles arbitrary chunk boundaries and frame splitting.
nonisolated struct KISSFrameParser {
    private var buffer = Data()
    private var inFrame = false

    init() {}

    /// Feed a chunk of data from TCP. Returns zero or more processed KISS frames.
    mutating func feed(_ chunk: Data) -> [KISSFrameOutput] {
        var frames: [KISSFrameOutput] = []

        for byte in chunk {
            if byte == KISS.FEND {
                if inFrame && !buffer.isEmpty {
                    // End of frame - process it
                    if let result = processKISSFrame(buffer) {
                        frames.append(result)
                    }
                }
                // Start fresh for next frame
                buffer.removeAll(keepingCapacity: true)
                inFrame = true
            } else if inFrame {
                buffer.append(byte)
            }
            // Bytes before first FEND are discarded
        }

        return frames
    }

    /// Reset parser state (e.g., on disconnect)
    mutating func reset() {
        buffer.removeAll()
        inFrame = false
    }

    /// Process a complete KISS frame buffer.
    /// Returns nil for malformed or unrecognized frames (logged, not passed downstream).
    private func processKISSFrame(_ data: Data) -> KISSFrameOutput? {
        guard !data.isEmpty else { return nil }

        // First byte is KISS command byte
        let command = data[0]

        // Command byte format: high nibble = port, low nibble = command type
        let cmdType = command & 0x0F

        let escapedPayload = data.count > 1 ? data.subdata(in: 1..<data.count) : Data()
        let payload = KISS.unescape(escapedPayload)

        TxLog.debug(.kiss, "KISS frame received", [
            "command": String(format: "0x%02X", command),
            "cmdType": String(format: "0x%02X", cmdType),
            "port": String(format: "0x%02X", (command >> 4) & 0x0F),
            "payloadLen": payload.count
        ])

        // Handle Data Frame (any port — some multi-port TNCs or firmware variants use ports other than 0)
        if cmdType == KISS.CMD_DATA {
            // A valid AX.25 frame requires at minimum 15 bytes (src + dst + control).
            // An empty payload means we got a bare command byte with no data — discard it.
            guard !payload.isEmpty else {
                TxLog.debug(.kiss, "Discarding DATA frame with empty payload")
                return nil
            }
            return .ax25(payload)
        }

        // Handle Mobilinkd Hardware Command (0x06)
        // This is used for battery levels and other telemetry
        if cmdType == 0x06 {
            // Reconstruct full frame: parseBatteryLevel expects [CMD, SUB, DATA...]
            var fullFrame = Data([command])
            fullFrame.append(payload)
            return .mobilinkdTelemetry(fullFrame)
        }

        // Unrecognized command type — log and discard.
        // This catches noise bytes between valid frames and non-standard TNC commands.
        // Per CLAUDE.md: "Malformed frames MUST be logged, not dropped silently."
        TxLog.debug(.kiss, "Discarding unrecognized KISS command", [
            "command": String(format: "0x%02X", command),
            "cmdType": String(format: "0x%02X", cmdType),
            "payloadLen": payload.count
        ])
        return nil
    }
}

// MARK: - AX.25 Decoding

/// AX.25 frame encoding/decoding utilities (pure functions)
nonisolated enum AX25 {

    // MARK: - TX Frame Types for Control Field Encoding

    /// Frame types for encoding control fields
    enum TxFrameType {
        case ui           // Unnumbered Information
        case i            // Information frame
        case rr           // Receive Ready
        case rnr          // Receive Not Ready
        case rej          // Reject
        case srej         // Selective Reject
        case sabm         // Set Asynchronous Balanced Mode
        case sabme        // SABM Extended
        case disc         // Disconnect
        case ua           // Unnumbered Acknowledge
        case dm           // Disconnected Mode
        case frmr         // Frame Reject
    }

    // MARK: - Decoding Types

    /// Result of decoding an AX.25 address field
    struct AddressDecodeResult {
        let address: AX25Address
        let nextOffset: Int
        let isLast: Bool
    }

    /// Result of decoding an AX.25 frame
    struct FrameDecodeResult {
        let from: AX25Address?
        let to: AX25Address?
        let via: [AX25Address]
        let control: UInt8
        /// Second control byte (for I-frames in modulo-8 mode)
        let controlByte1: UInt8?
        let pid: UInt8?
        let info: Data
        let frameType: FrameType
    }

    /// Decode a single AX.25 address from data at given offset
    /// Each address is 7 bytes: 6 callsign chars (shifted left 1) + 1 SSID byte
    static func decodeAddress(data: Data, offset: Int) -> AddressDecodeResult? {
        guard offset + 7 <= data.count else { return nil }

        // Extract and unshift the 6 callsign characters
        var callChars: [Character] = []
        for i in 0..<6 {
            let shifted = data[offset + i]
            let char = shifted >> 1
            if char >= 0x20 && char < 0x7F {
                let c = Character(UnicodeScalar(char))
                if c != " " {
                    callChars.append(c)
                }
            }
        }

        let callsign = String(callChars)
        guard !callsign.isEmpty else { return nil }

        let ssidByte = data[offset + 6]
        let ssid = Int((ssidByte >> 1) & 0x0F)
        let isLast = (ssidByte & 0x01) != 0
        let repeated = (ssidByte & 0x80) != 0

        let address = AX25Address(call: callsign, ssid: ssid, repeated: repeated)
        return AddressDecodeResult(address: address, nextOffset: offset + 7, isLast: isLast)
    }

    /// Decode an AX.25 frame from raw data
    static func decodeFrame(ax25 data: Data) -> FrameDecodeResult? {
        // Minimum: destination (7) + source (7) + control (1) = 15 bytes
        guard data.count >= 15 else { return nil }

        // Decode destination address
        guard let destResult = decodeAddress(data: data, offset: 0) else { return nil }
        let to = destResult.address

        // Decode source address
        guard let srcResult = decodeAddress(data: data, offset: 7) else { return nil }
        let from = srcResult.address

        // Decode via addresses (digipeaters)
        var via: [AX25Address] = []
        var offset = 14
        var lastAddress = srcResult.isLast

        while !lastAddress && offset + 7 <= data.count && via.count < 8 {
            guard let viaResult = decodeAddress(data: data, offset: offset) else { break }
            via.append(viaResult.address)
            offset = viaResult.nextOffset
            lastAddress = viaResult.isLast
        }

        // Control field
        guard offset < data.count else {
            return FrameDecodeResult(
                from: from, to: to, via: via,
                control: 0, controlByte1: nil, pid: nil, info: Data(),
                frameType: .unknown
            )
        }

        let control = data[offset]
        offset += 1

        // Determine frame type from control byte
        let frameType = classifyFrameType(control: control)

        // Note: Standard AX.25 (modulo-8) uses a single control byte for all frame types.
        // Extended mode (modulo-128) uses two control bytes, but we don't support that yet.
        // controlByte1 is reserved for future modulo-128 support.
        let controlByte1: UInt8? = nil

        // PID field (only present in I and UI frames)
        var pid: UInt8? = nil
        if frameType == .ui || frameType == .i {
            if offset < data.count {
                pid = data[offset]
                offset += 1
            }
        }

        // Info field (remaining data)
        let info: Data
        if offset < data.count {
            info = data.subdata(in: offset..<data.count)
        } else {
            info = Data()
        }

        return FrameDecodeResult(
            from: from, to: to, via: via,
            control: control, controlByte1: controlByte1, pid: pid, info: info,
            frameType: frameType
        )
    }

    /// Classify frame type from control byte
    static func classifyFrameType(control: UInt8) -> FrameType {
        // I-frame: bit 0 = 0
        if (control & 0x01) == 0 {
            return .i
        }

        // S-frame: bits 0-1 = 01
        if (control & 0x03) == 0x01 {
            return .s
        }

        // U-frame: bits 0-1 = 11
        if (control & 0x03) == 0x03 {
            // UI frame: control = 0x03 (or 0x13, etc. with P/F bit variations)
            if (control & 0xEF) == 0x03 {
                return .ui
            }
            return .u
        }

        return .unknown
    }

    // MARK: - TX Encoding

    /// Encode an AX.25 address to bytes
    /// - Parameters:
    ///   - address: The address to encode
    ///   - isLast: Whether this is the last address in the header
    /// - Returns: 7 bytes representing the encoded address
    static func encodeAddress(_ address: AX25Address, isLast: Bool) -> Data {
        var result = Data()
        result.reserveCapacity(7)

        // Callsign: 6 characters, right-padded with spaces, each shifted left 1 bit
        let callsign = address.call.uppercased()
        let paddedCall = callsign.padding(toLength: 6, withPad: " ", startingAt: 0)

        for char in paddedCall.prefix(6) {
            let ascii = char.asciiValue ?? 0x20
            result.append(ascii << 1)
        }

        // SSID byte: bits 1-4 = SSID, bit 0 = extension bit (0 if more addresses follow)
        // Bits 5-6 are reserved and should be set to 1 (0b01100000 = 0x60)
        var ssidByte: UInt8 = 0x60  // Reserved bits set
        ssidByte |= UInt8(address.ssid & 0x0F) << 1
        if isLast {
            ssidByte |= 0x01  // Extension bit = 1 means last address
        }
        result.append(ssidByte)

        return result
    }

    /// Encode a UI (Unnumbered Information) frame
    /// - Parameters:
    ///   - from: Source address
    ///   - to: Destination address
    ///   - via: Digipeater path (max 8)
    ///   - pid: Protocol ID (default 0xF0 = no layer 3)
    ///   - info: Information field payload
    /// - Returns: Complete AX.25 frame bytes
    static func encodeUIFrame(
        from: AX25Address,
        to: AX25Address,
        via: [AX25Address],
        pid: UInt8 = 0xF0,
        info: Data
    ) -> Data {
        var frame = Data()

        // Destination address (never last if there's a source)
        frame.append(encodeAddress(to, isLast: false))

        // Source address (last if no digipeaters)
        let hasVia = !via.isEmpty
        frame.append(encodeAddress(from, isLast: !hasVia))

        // Digipeater addresses
        let limitedVia = Array(via.prefix(8))
        for (index, digi) in limitedVia.enumerated() {
            let isLastDigi = index == limitedVia.count - 1
            frame.append(encodeAddress(digi, isLast: isLastDigi))
        }

        // Control field: UI = 0x03
        frame.append(0x03)

        // PID field
        frame.append(pid)

        // Info field
        frame.append(info)

        return frame
    }

    /// Encode control field bytes for a given frame type
    /// - Parameters:
    ///   - frameType: The type of frame to encode
    ///   - ns: Send sequence number (for I-frames, modulo 8)
    ///   - nr: Receive sequence number (for I/S-frames, modulo 8)
    ///   - pf: Poll/Final bit
    /// - Returns: Control field bytes (1 byte for modulo-8)
    static func encodeControlField(
        frameType: TxFrameType,
        ns: Int = 0,
        nr: Int = 0,
        pf: Bool = false
    ) -> [UInt8] {
        let pfBit: UInt8 = pf ? 0x10 : 0x00

        switch frameType {
        // U-frames (modulo-8 encoding)
        case .ui:
            // UI: 000P0011
            return [0x03 | pfBit]

        case .sabm:
            // SABM: 001P1111
            return [0x2F | pfBit]

        case .sabme:
            // SABME: 011P1111
            return [0x6F | pfBit]

        case .disc:
            // DISC: 010P0011
            return [0x43 | pfBit]

        case .ua:
            // UA: 011F0011
            return [0x63 | pfBit]

        case .dm:
            // DM: 000F1111
            return [0x0F | pfBit]

        case .frmr:
            // FRMR: 100F0111
            return [0x87 | pfBit]

        // S-frames (modulo-8 encoding)
        case .rr:
            // RR: NNN P 0001
            let nrBits = UInt8(nr & 0x07) << 5
            return [nrBits | pfBit | 0x01]

        case .rnr:
            // RNR: NNN P 0101
            let nrBits = UInt8(nr & 0x07) << 5
            return [nrBits | pfBit | 0x05]

        case .rej:
            // REJ: NNN P 1001
            let nrBits = UInt8(nr & 0x07) << 5
            return [nrBits | pfBit | 0x09]

        case .srej:
            // SREJ: NNN P 1101
            let nrBits = UInt8(nr & 0x07) << 5
            return [nrBits | pfBit | 0x0D]

        // I-frame (modulo-8 encoding)
        case .i:
            // I-frame: NNN P SSS 0
            // Where NNN = N(R), SSS = N(S)
            let nrBits = UInt8(nr & 0x07) << 5
            let nsBits = UInt8(ns & 0x07) << 1
            return [nrBits | pfBit | nsBits]
        }
    }

    /// Encode an I-frame (Information frame)
    /// - Parameters:
    ///   - from: Source address
    ///   - to: Destination address
    ///   - via: Digipeater path
    ///   - ns: Send sequence number (modulo 8)
    ///   - nr: Receive sequence number (modulo 8)
    ///   - pf: Poll/Final bit
    ///   - pid: Protocol ID
    ///   - info: Information field payload
    /// - Returns: Complete AX.25 I-frame bytes
    static func encodeIFrame(
        from: AX25Address,
        to: AX25Address,
        via: [AX25Address] = [],
        ns: Int,
        nr: Int,
        pf: Bool = false,
        pid: UInt8 = 0xF0,
        info: Data
    ) -> Data {
        var frame = Data()

        // Addresses
        frame.append(encodeAddress(to, isLast: false))
        let hasVia = !via.isEmpty
        frame.append(encodeAddress(from, isLast: !hasVia))

        let limitedVia = Array(via.prefix(8))
        for (index, digi) in limitedVia.enumerated() {
            frame.append(encodeAddress(digi, isLast: index == limitedVia.count - 1))
        }

        // Control field
        let control = encodeControlField(frameType: .i, ns: ns, nr: nr, pf: pf)
        frame.append(contentsOf: control)

        // PID
        frame.append(pid)

        // Info
        frame.append(info)

        return frame
    }

    /// Encode an S-frame (Supervisory frame)
    /// - Parameters:
    ///   - from: Source address
    ///   - to: Destination address
    ///   - via: Digipeater path
    ///   - type: S-frame type (rr, rnr, rej, srej)
    ///   - nr: Receive sequence number
    ///   - pf: Poll/Final bit
    /// - Returns: Complete AX.25 S-frame bytes
    static func encodeSFrame(
        from: AX25Address,
        to: AX25Address,
        via: [AX25Address] = [],
        type: TxFrameType,
        nr: Int,
        pf: Bool = false
    ) -> Data {
        var frame = Data()

        // Addresses
        frame.append(encodeAddress(to, isLast: false))
        let hasVia = !via.isEmpty
        frame.append(encodeAddress(from, isLast: !hasVia))

        let limitedVia = Array(via.prefix(8))
        for (index, digi) in limitedVia.enumerated() {
            frame.append(encodeAddress(digi, isLast: index == limitedVia.count - 1))
        }

        // Control field
        let control = encodeControlField(frameType: type, nr: nr, pf: pf)
        frame.append(contentsOf: control)

        return frame
    }

    /// Encode a U-frame (Unnumbered frame) for session control
    /// - Parameters:
    ///   - from: Source address
    ///   - to: Destination address
    ///   - via: Digipeater path
    ///   - type: U-frame type (sabm, disc, ua, dm, frmr)
    ///   - pf: Poll/Final bit
    /// - Returns: Complete AX.25 U-frame bytes
    static func encodeUFrame(
        from: AX25Address,
        to: AX25Address,
        via: [AX25Address] = [],
        type: TxFrameType,
        pf: Bool = false
    ) -> Data {
        var frame = Data()

        // Addresses
        frame.append(encodeAddress(to, isLast: false))
        let hasVia = !via.isEmpty
        frame.append(encodeAddress(from, isLast: !hasVia))

        let limitedVia = Array(via.prefix(8))
        for (index, digi) in limitedVia.enumerated() {
            frame.append(encodeAddress(digi, isLast: index == limitedVia.count - 1))
        }

        // Control field
        let control = encodeControlField(frameType: type, pf: pf)
        frame.append(contentsOf: control)

        return frame
    }
}

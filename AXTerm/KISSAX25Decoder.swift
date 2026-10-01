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

        // Indexed from startIndex so a Data slice (a frame body cut out of
        // a larger buffer) unescapes like a fresh copy.
        var i = data.startIndex
        while i < data.endIndex {
            let byte = data[i]
            if byte == FESC && i + 1 < data.endIndex {
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

    /// How many FESC bytes in `data` do not start a valid escape: a FESC
    /// followed by anything but TFEND or TFESC, or a FESC that ends the
    /// frame. No correct KISS sender produces either, so a nonzero count
    /// means the frame was corrupted on the host link. `unescape` keeps
    /// such bytes as they are (the KISS spec says "no action is taken");
    /// this lets the parser log the frame instead of passing it on silently.
    static func invalidEscapeCount(_ data: Data) -> Int {
        var count = 0
        var i = data.startIndex
        while i < data.endIndex {
            if data[i] == FESC {
                let next = data.index(after: i)
                if next < data.endIndex, data[next] == TFEND || data[next] == TFESC {
                    i = data.index(after: next)
                    continue
                }
                count += 1
            }
            i = data.index(after: i)
        }
        return count
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

        // Command byte: high nibble = port, low nibble = command (0 = data).
        // It is escaped like the payload: port 12's data command is 0xC0,
        // the FEND value, and sent raw it would end the frame right there.
        // Direwolf escapes the whole frame, command byte included.
        let command = (port << 4) | CMD_DATA
        frame.append(escape(Data([command])))

        // Escaped AX.25 payload
        frame.append(escape(payload))

        // End delimiter
        frame.append(FEND)

        return frame
    }
}

// MARK: - KISS Frame Parser

/// Output from the KISS frame parser
nonisolated enum KISSFrameOutput: Equatable {
    case ax25(Data)
    case mobilinkdTelemetry(Data) // Raw hardware frame payload
    case unknown(command: UInt8, payload: Data)
}

/// One deframed KISS frame together with the port it arrived on.
///
/// The command byte's high nibble is the TNC port. Direwolf numbers its
/// channels this way, so a multi-port TNC is several radios behind one byte
/// stream. For years this parser read the nibble for a log line and then
/// returned the payload alone, which folded every port into one.
/// `feedFrames` keeps the port; `feed` is the older, port-less view kept for
/// the callers (and the many tests) that only want the bytes.
nonisolated struct KISSParsedFrame: Equatable {
    let port: UInt8
    let output: KISSFrameOutput
}

/// Stateful parser for extracting KISS frames from a TCP byte stream.
/// Handles arbitrary chunk boundaries and frame splitting.
nonisolated struct KISSFrameParser {
    private var buffer = Data()
    private var inFrame = false

    init() {}

    /// Feed a chunk of data from TCP. Returns zero or more processed KISS frames.
    mutating func feed(_ chunk: Data) -> [KISSFrameOutput] {
        feedFrames(chunk).map(\.output)
    }

    /// Like `feed`, but every frame carries the KISS port it arrived on.
    mutating func feedFrames(_ chunk: Data) -> [KISSParsedFrame] {
        var frames: [KISSParsedFrame] = []

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
    private func processKISSFrame(_ data: Data) -> KISSParsedFrame? {
        guard !data.isEmpty else { return nil }

        // The escapes cover the whole frame, command byte included: port
        // 12's data command is 0xC0 and arrives as FESC TFEND. Reading the
        // raw first byte took that for command 0xDB and dropped the frame.
        let unescaped = KISS.unescape(data)
        guard let command = unescaped.first else { return nil }

        // Command byte format: high nibble = port, low nibble = command type
        let cmdType = command & 0x0F
        let port = (command >> 4) & 0x0F

        // A fresh Data, so downstream code can index it from zero.
        let payload = Data(unescaped.dropFirst())

        // A broken escape is a malformed frame, which must be logged rather
        // than passed on silently (CLAUDE.md §4). The bytes still go
        // downstream unchanged; the AX.25 decoder judges the frame.
        let invalidEscapes = KISS.invalidEscapeCount(data)
        if invalidEscapes > 0 {
            TxLog.warning(.kiss, "KISS frame has invalid escape sequences", [
                "command": String(format: "0x%02X", command),
                "invalidEscapes": invalidEscapes,
                "payloadLen": payload.count
            ])
        }

        TxLog.debug(.kiss, "KISS frame received", [
            "command": String(format: "0x%02X", command),
            "cmdType": String(format: "0x%02X", cmdType),
            "port": String(format: "0x%02X", port),
            "payloadLen": payload.count
        ])

        // Handle Data Frame (any port — some multi-port TNCs or firmware variants use ports other than 0)
        if cmdType == KISS.CMD_DATA {
            // A valid AX.25 frame requires at minimum 15 bytes (src + dst + control).
            // An empty payload means we got a bare command byte with no data — discard it.
            guard !payload.isEmpty else {
                // Malformed frames MUST be logged, not dropped silently
                // (CLAUDE.md §4). Warning level so the crumb survives flood
                // control and reaches Sentry attached to any later event.
                TxLog.warning(.kiss, "Discarding DATA frame with empty payload")
                return nil
            }
            return KISSParsedFrame(port: port, output: .ax25(payload))
        }

        // Handle Mobilinkd Hardware Command (0x06)
        // This is used for battery levels and other telemetry
        if cmdType == 0x06 {
            // Reconstruct full frame: parseBatteryLevel expects [CMD, SUB, DATA...]
            var fullFrame = Data([command])
            fullFrame.append(payload)
            return KISSParsedFrame(port: port, output: .mobilinkdTelemetry(fullFrame))
        }

        // Unrecognized command type — log and discard.
        // This catches noise bytes between valid frames and non-standard TNC commands.
        // Per CLAUDE.md: "Malformed frames MUST be logged, not dropped silently."
        // Warning level so the crumb survives flood control and reaches Sentry.
        TxLog.warning(.kiss, "Discarding unrecognized KISS command", [
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

    /// Why one 7-byte address field was refused.
    enum AddressFault: Error, Equatable, Sendable {
        /// Fewer than 7 bytes left where an address should be.
        case truncated
        /// Bit 0 of callsign byte `position` (0-based) is set.
        case extensionBitInCallsign(position: Int)
        /// Callsign byte `position` unshifts to something other than A–Z,
        /// 0–9 or space. `value` is the unshifted character.
        case invalidCharacter(position: Int, value: UInt8)
        /// A space before a letter or digit, leading or in the middle.
        /// `position` is the space. Padding may only trail.
        case embeddedSpace(position: Int)
        /// All six characters are spaces.
        case emptyCallsign

        /// Stable wording with no byte values, for keying event throttles.
        var summary: String {
            switch self {
            case .truncated: return "truncated"
            case .extensionBitInCallsign: return "extension bit set in callsign"
            case .invalidCharacter: return "invalid character"
            case .embeddedSpace: return "space inside callsign"
            case .emptyCallsign: return "empty callsign"
            }
        }

        /// The summary plus where and what, for logs.
        var detail: String {
            switch self {
            case .truncated:
                return summary
            case .extensionBitInCallsign(let position):
                return "\(summary) at position \(position + 1)"
            case .invalidCharacter(let position, let value):
                return String(format: "invalid character 0x%02X at position %d", value, position + 1)
            case .embeddedSpace(let position):
                return "\(summary) at position \(position + 1)"
            case .emptyCallsign:
                return summary
            }
        }
    }

    /// Which address in the header a fault belongs to.
    enum AddressRole: Equatable, Sendable {
        case destination
        case source
        /// 1-based position in the digipeater list.
        case digipeater(Int)

        var label: String {
            switch self {
            case .destination: return "destination address"
            case .source: return "source address"
            case .digipeater(let n): return "digipeater \(n) address"
            }
        }
    }

    /// Why decodeFrame refused a frame. Every case is a frame that is not
    /// AX.25 as the spec defines it, so it must not become a packet.
    enum FrameFault: Error, Equatable, Sendable {
        case tooShort(count: Int)
        case badAddress(AddressRole, AddressFault)
        /// The destination's SSID byte has the extension bit set, which ends
        /// the address field before the source.
        case endsAfterDestination
        /// The bytes ran out before any address set the extension bit.
        case unterminatedAddressField(addresses: Int)
        /// No extension bit within dest + source + 8 digipeaters.
        case tooManyDigipeaters
        /// The address field is the whole frame: there is no control byte.
        case missingControlField

        /// Stable text with no byte values or positions. Keys the Sentry
        /// throttle, so a noisy channel produces a handful of distinct
        /// events rather than one per byte value.
        var summary: String {
            switch self {
            case .tooShort: return "frame shorter than 15-byte minimum"
            case .badAddress(let role, let fault):
                // Digipeaters share one key whatever their position.
                let label: String
                switch role {
                case .digipeater: label = "digipeater address"
                default: label = role.label
                }
                return "\(label): \(fault.summary)"
            case .endsAfterDestination: return "address field ends after destination"
            case .unterminatedAddressField: return "address field never ends"
            case .tooManyDigipeaters: return "more than 8 digipeaters"
            case .missingControlField: return "no control field"
            }
        }

        /// Human-readable reason naming the address and the byte at fault.
        var reason: String {
            switch self {
            case .tooShort(let count):
                return "frame shorter than 15-byte minimum (\(count) bytes)"
            case .badAddress(let role, let fault):
                return "\(role.label): \(fault.detail)"
            case .endsAfterDestination:
                return "address field ends after destination (extension bit set in its SSID byte)"
            case .unterminatedAddressField(let addresses):
                return "address field never ends (no extension bit in \(addresses) addresses before the frame ran out)"
            case .tooManyDigipeaters:
                return "more than 8 digipeaters (no extension bit by the 10th address)"
            case .missingControlField:
                return "no control field after the address field"
            }
        }
    }

    /// Decode a single AX.25 address from data at given offset.
    /// Each address is 7 bytes: 6 callsign chars (shifted left 1) + 1 SSID byte.
    /// Returns nil for anything `checkAddress` refuses.
    static func decodeAddress(data: Data, offset: Int) -> AddressDecodeResult? {
        try? checkAddress(data: data, offset: offset).get()
    }

    /// Decode one 7-byte address field, refusing anything AX.25 2.2 §3.12
    /// does not allow in a callsign. These are the rules that keep a burst
    /// of noise that happened to pass the TNC's FCS from turning into a
    /// heard station:
    ///
    /// - Bit 0 of each of the six callsign bytes must be clear. It is the
    ///   HDLC address-extension bit, and the spec only ever sets it in the
    ///   SSID byte of the last address. A callsign byte is an ASCII
    ///   character shifted left one bit, so bit 0 is always 0 from any
    ///   encoder. Direwolf finds the end of the address field by the first
    ///   byte with bit 0 set, so a frame that breaks this rule is unreadable
    ///   to it as well.
    /// - Each unshifted character must be A–Z, 0–9 or space. The spec
    ///   allows upper-case letters and digits only. APRS tocalls, WIDEn-N,
    ///   RELAY, TRACE, RFONLY, NOGATE, TCPIP, BEACON, ID, CQ, QST, MAIL,
    ///   NODES and Mic-E destinations (0–9, A–L, P–Z) all fit. Lower case
    ///   is refused: TNC firmware, the Linux ax25 tools and BPQ upper-case
    ///   the callsign when they encode it, and Direwolf rejects a received
    ///   address with lower case in it. The old decoder upper-cased what it
    ///   read, which is how `q` in the noise became `Q`.
    /// - Spaces are padding, so they may only trail. A leading or embedded
    ///   space, or six spaces, is not a callsign.
    ///
    /// The SSID byte is read but not judged. Bits 5–6 are reserved and
    /// normally 1, but some software sends 0; bit 7 is the C or H bit and
    /// any value is legal. Its bit 0 is the extension bit, which the frame
    /// decoder interprets.
    static func checkAddress(data: Data, offset: Int) -> Result<AddressDecodeResult, AddressFault> {
        guard offset >= 0, offset + 7 <= data.count else { return .failure(.truncated) }
        let base = data.startIndex + offset

        var callsign = ""
        var sawPadding = false
        for position in 0..<6 {
            let byte = data[base + position]
            if byte & 0x01 != 0 {
                return .failure(.extensionBitInCallsign(position: position))
            }
            let char = byte >> 1
            let isUpper = char >= 0x41 && char <= 0x5A
            let isDigit = char >= 0x30 && char <= 0x39
            if char == 0x20 {
                sawPadding = true
                continue
            }
            guard isUpper || isDigit else {
                return .failure(.invalidCharacter(position: position, value: char))
            }
            if sawPadding {
                // A letter or digit after a space. Report the space itself.
                // An all-space prefix counts too: " ABC" has a leading space.
                return .failure(.embeddedSpace(position: callsign.count))
            }
            callsign.append(Character(UnicodeScalar(char)))
        }
        guard !callsign.isEmpty else { return .failure(.emptyCallsign) }

        let ssidByte = data[base + 6]
        let ssid = Int((ssidByte >> 1) & 0x0F)
        let isLast = (ssidByte & 0x01) != 0
        let repeated = (ssidByte & 0x80) != 0

        let address = AX25Address(call: callsign, ssid: ssid, repeated: repeated)
        return .success(AddressDecodeResult(address: address, nextOffset: offset + 7, isLast: isLast))
    }

    /// Explain why decodeFrame returned nil for the given bytes, naming the
    /// address and the byte at fault (for example "source address: invalid
    /// character 0x7D at position 2").
    static func decodeFailureReason(ax25 data: Data) -> String {
        if case .failure(let fault) = checkFrame(ax25: data) { return fault.reason }
        return "no fault found (the frame decodes)"
    }

    /// Decode an AX.25 frame from raw data. Nil for any frame `checkFrame`
    /// refuses.
    static func decodeFrame(ax25 data: Data) -> FrameDecodeResult? {
        try? checkFrame(ax25: data).get()
    }

    /// Decode an AX.25 frame, or say why it is not one.
    ///
    /// The address field is dest, source and up to 8 digipeaters, and it
    /// ends at the first SSID byte with the extension bit set (AX.25 2.2
    /// §3.12). Anything else is malformed and refused whole: a digipeater
    /// address that fails `checkAddress`, an extension bit on the
    /// destination, no extension bit by the 10th address or before the
    /// bytes run out, or no control byte after the addresses. The old
    /// decoder stopped at the first bad digipeater and read its bytes as
    /// the control field, and read a frame whose address field never ended
    /// as if the leftover bytes were control and info.
    static func checkFrame(ax25 data: Data) -> Result<FrameDecodeResult, FrameFault> {
        // Minimum: destination (7) + source (7) + control (1) = 15 bytes
        guard data.count >= 15 else { return .failure(.tooShort(count: data.count)) }

        let destResult: AddressDecodeResult
        switch checkAddress(data: data, offset: 0) {
        case .success(let result): destResult = result
        case .failure(let fault): return .failure(.badAddress(.destination, fault))
        }
        let srcResult: AddressDecodeResult
        switch checkAddress(data: data, offset: 7) {
        case .success(let result): srcResult = result
        case .failure(let fault): return .failure(.badAddress(.source, fault))
        }
        // Checked after the source so a frame that is noise throughout is
        // reported by its characters, which say more than this bit does.
        if destResult.isLast { return .failure(.endsAfterDestination) }
        let to = destResult.address
        let from = srcResult.address

        // Decode via addresses (digipeaters)
        var via: [AX25Address] = []
        var offset = 14
        var lastAddress = srcResult.isLast

        while !lastAddress {
            guard via.count < 8 else { return .failure(.tooManyDigipeaters) }
            guard offset + 7 <= data.count else {
                return .failure(.unterminatedAddressField(addresses: 2 + via.count))
            }
            switch checkAddress(data: data, offset: offset) {
            case .success(let viaResult):
                via.append(viaResult.address)
                offset = viaResult.nextOffset
                lastAddress = viaResult.isLast
            case .failure(let fault):
                return .failure(.badAddress(.digipeater(via.count + 1), fault))
            }
        }

        // Control field
        guard offset < data.count else { return .failure(.missingControlField) }

        let base = data.startIndex
        let control = data[base + offset]
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
                pid = data[base + offset]
                offset += 1
            }
        }

        // Info field (remaining data)
        let info: Data
        if offset < data.count {
            info = data.subdata(in: (base + offset)..<data.endIndex)
        } else {
            info = Data()
        }

        return .success(FrameDecodeResult(
            from: from, to: to, via: via,
            control: control, controlByte1: controlByte1, pid: pid, info: info,
            frameType: frameType
        ))
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

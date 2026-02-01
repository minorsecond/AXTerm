//
//  KISSAX25Decoder.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import Foundation

// MARK: - KISS Protocol

/// KISS protocol constants and utilities
enum KISS {
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
}

// MARK: - KISS Frame Parser

/// Stateful parser for extracting KISS frames from a TCP byte stream.
/// Handles arbitrary chunk boundaries and frame splitting.
struct KISSFrameParser {
    private var buffer = Data()
    private var inFrame = false

    init() {}

    /// Feed a chunk of data from TCP. Returns zero or more complete AX.25 frame payloads.
    /// Each returned Data is an unescaped AX.25 frame (KISS command byte stripped).
    mutating func feed(_ chunk: Data) -> [Data] {
        var frames: [Data] = []

        for byte in chunk {
            if byte == KISS.FEND {
                if inFrame && !buffer.isEmpty {
                    // End of frame - process it
                    if let payload = processKISSFrame(buffer) {
                        frames.append(payload)
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

    /// Process a complete KISS frame buffer, returning the AX.25 payload if valid
    private func processKISSFrame(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }

        // First byte is KISS command byte
        let command = data[0]

        // Only handle data frames on port 0 for now
        // Command byte format: high nibble = port, low nibble = command type
        let port = (command >> 4) & 0x0F
        let cmdType = command & 0x0F

        guard port == 0 && cmdType == 0 else { return nil }

        // Rest is the AX.25 frame (escaped)
        guard data.count > 1 else { return nil }
        let escapedPayload = data.subdata(in: 1..<data.count)

        // Unescape and return
        return KISS.unescape(escapedPayload)
    }
}

// MARK: - AX.25 Decoding

/// AX.25 frame decoding utilities (pure functions)
enum AX25 {

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

        // For I-frames, extract the second control byte (modulo-8 mode)
        var controlByte1: UInt8? = nil
        if frameType == .i && offset < data.count {
            controlByte1 = data[offset]
            offset += 1
        }

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
}

//
//  Ax25Address.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import Foundation

// MARK: - Callsign Normalization (Single Source of Truth)

/// Centralized callsign parsing and matching. Use this everywhere to avoid
/// SSID/callsign inconsistencies (e.g. "TEST-1" vs "TEST1", "TEST" vs "TEST-0").
enum CallsignNormalizer {
    /// Parse "CALL-SSID" or "CALL" into (baseCall, ssid). SSID 0 if omitted.
    /// - "TEST-1" -> ("TEST", 1)
    /// - "TEST" -> ("TEST", 0)
    /// - "TEST2" (no hyphen) -> ("TEST2", 0) — ambiguous; caller may need to try "TEST-2"
    static func parse(_ input: String) -> (call: String, ssid: Int) {
        let upper = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let parts = upper.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let call = String(parts.first ?? "").trimmingCharacters(in: .whitespaces)
        let ssid = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        return (call, max(0, min(15, ssid)))
    }

    /// Canonical display form: "CALL" for SSID 0, "CALL-N" for SSID > 0.
    static func display(call: String, ssid: Int) -> String {
        ssid > 0 ? "\(call)-\(ssid)" : call
    }

    /// Whether two addresses refer to the same station (call + SSID match).
    static func addressesMatch(_ a: AX25Address, _ b: AX25Address) -> Bool {
        a.call.uppercased() == b.call.uppercased() && a.ssid == b.ssid
    }

    /// Whether an address matches a display string (e.g. "TEST-1" or "TEST").
    static func addressMatchesDisplay(_ address: AX25Address, _ display: String) -> Bool {
        let (call, ssid) = parse(display)
        guard !call.isEmpty else { return false }
        return address.call.uppercased() == call.uppercased() && address.ssid == ssid
    }

    /// Create AX25Address from "CALL-SSID" or "CALL" string.
    static func toAddress(_ input: String) -> AX25Address {
        let (call, ssid) = parse(input)
        return AX25Address(call: call.isEmpty ? "NOCALL" : call, ssid: ssid)
    }
}

// MARK: - AX25Address

/// Represents an AX.25 address (callsign + SSID)
struct AX25Address: Hashable, Codable, Identifiable, Sendable {
    let call: String
    let ssid: Int
    let repeated: Bool

    var id: String { display }

    var display: String {
        ssid > 0 ? "\(call)-\(ssid)" : call
    }

    init(call: String, ssid: Int = 0, repeated: Bool = false) {
        // Normalize: trim whitespace and uppercase
        self.call = call.trimmingCharacters(in: .whitespaces).uppercased()
        self.ssid = max(0, min(15, ssid))
        self.repeated = repeated
    }

    /// Encode address as 7 bytes for AX.25 frame
    /// - Parameters:
    ///   - isLast: Whether this is the last address in the path (sets HDLC address extension bit)
    ///   - isDestination: Whether this is the destination address (affects C/R bit)
    ///   - isCommand: Whether the frame is a Command (affects C/R bit). If nil, defaults to V1.x (C=0).
    /// - Returns: 7-byte encoded address
    func encodeForAX25(isLast: Bool, isDestination: Bool = false, isCommand: Bool? = nil) -> Data {
        var data = Data()

        // Callsign: 6 bytes, left-justified, space-padded, each byte shifted left by 1
        let paddedCall = call.padding(toLength: 6, withPad: " ", startingAt: 0).prefix(6)
        for char in paddedCall {
            let ascii = UInt8(char.asciiValue ?? 0x20)
            data.append(ascii << 1)
        }

        // SSID byte:
        // Bits 1-4: SSID
        // Bit 0: HDLC extension (0=more, 1=last)
        // Bit 5-6: Reserved (usually 11 for "local significance" or 00, we use 11/0x60 base)
        // Bit 7: C/R bit or H bit
        
        // Base: 01100000 (0x60) - Reserved bits set
        var ssidByte: UInt8 = 0x60
        
        // Add SSID (bits 1-4)
        ssidByte |= UInt8(ssid & 0x0F) << 1
        
        // HDLC Extension (bit 0)
        if isLast {
            ssidByte |= 0x01
        }
        
        if repeated {
            // Repeater/Digipeater logic: Bit 7 is H-bit (Has-been-repeated)
            ssidByte |= 0x80
        } else if let isCommand = isCommand {
            // Source/Destination logic: Bit 7 is C/R bit (AX.25 v2.0)
            // Command: Dest=1, Src=0
            // Response: Dest=0, Src=1
            
            if isCommand {
                if isDestination {
                    ssidByte |= 0x80 // Command + Dest = 1
                } else {
                    ssidByte &= ~0x80 // Command + Src = 0
                }
            } else {
                // Response
                if isDestination {
                    ssidByte &= ~0x80 // Response + Dest = 0
                } else {
                    ssidByte |= 0x80 // Response + Src = 1
                }
            }
        }
        
        data.append(ssidByte)

        return data
    }
}

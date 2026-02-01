//
//  Ax25Address.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import Foundation

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
    /// - Parameter isLast: Whether this is the last address in the path (sets HDLC address extension bit)
    /// - Returns: 7-byte encoded address
    func encodeForAX25(isLast: Bool) -> Data {
        var data = Data()

        // Callsign: 6 bytes, left-justified, space-padded, each byte shifted left by 1
        let paddedCall = call.padding(toLength: 6, withPad: " ", startingAt: 0).prefix(6)
        for char in paddedCall {
            let ascii = UInt8(char.asciiValue ?? 0x20)
            data.append(ascii << 1)
        }

        // SSID byte: bits 7-5 = reserved (110), bit 4 = command/response, bits 3-1 = SSID, bit 0 = HDLC extension
        // For simplicity: 0b01100000 | (ssid << 1) | (isLast ? 1 : 0)
        var ssidByte: UInt8 = 0b01100000
        ssidByte |= UInt8(ssid & 0x0F) << 1
        if isLast {
            ssidByte |= 0x01  // HDLC address extension bit
        }
        if repeated {
            ssidByte |= 0x80  // H-bit (has been repeated)
        }
        data.append(ssidByte)

        return data
    }
}

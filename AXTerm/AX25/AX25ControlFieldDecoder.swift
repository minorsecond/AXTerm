//
//  AX25ControlFieldDecoder.swift
//  AXTerm
//
//  Decoder for AX.25 control field bytes.
//

import Foundation

/// Decoder for AX.25 control field bytes
enum AX25ControlFieldDecoder {

    // MARK: - U-Frame Control Byte Patterns (with P/F bit masked out)

    /// UI (Unnumbered Information) - 0x03
    private static let uiPattern: UInt8 = 0x03

    /// SABM (Set Asynchronous Balanced Mode) - 0x2F
    private static let sabmPattern: UInt8 = 0x2F

    /// SABME (Set Asynchronous Balanced Mode Extended) - 0x6F
    private static let sabmePattern: UInt8 = 0x6F

    /// DISC (Disconnect) - 0x43
    private static let discPattern: UInt8 = 0x43

    /// UA (Unnumbered Acknowledge) - 0x63
    private static let uaPattern: UInt8 = 0x63

    /// DM (Disconnected Mode) - 0x0F
    private static let dmPattern: UInt8 = 0x0F

    /// FRMR (Frame Reject) - 0x87
    private static let frmrPattern: UInt8 = 0x87

    // MARK: - Decode Function

    /// Decode control field bytes into structured information.
    ///
    /// - Parameter controlBytes: Raw control field bytes (1 or 2 bytes depending on frame type)
    /// - Returns: Decoded control field information
    ///
    /// Rules (AX.25 v2.2):
    /// - I-frame: (ctl0 & 0x01) == 0, uses 2 control bytes in modulo-8 mode
    /// - S-frame: (ctl0 & 0x03) == 0x01, uses 1 control byte in modulo-8 mode
    /// - U-frame: (ctl0 & 0x03) == 0x03, uses 1 control byte
    static func decode(controlBytes: [UInt8]) -> AX25ControlFieldDecoded {
        guard !controlBytes.isEmpty else {
            return .unknown
        }

        let ctl0 = controlBytes[0]
        let ctl1: UInt8? = controlBytes.count > 1 ? controlBytes[1] : nil

        // Determine frame class from bits 0-1 of ctl0
        let frameClass = determineFrameClass(ctl0: ctl0)

        switch frameClass {
        case .I:
            return decodeIFrame(ctl0: ctl0, ctl1: ctl1)
        case .S:
            return decodeSFrame(ctl0: ctl0)
        case .U:
            return decodeUFrame(ctl0: ctl0)
        case .unknown:
            return AX25ControlFieldDecoded(
                frameClass: .unknown,
                sType: nil,
                uType: nil,
                ns: nil,
                nr: nil,
                pf: nil,
                ctl0: ctl0,
                ctl1: ctl1,
                isExtended: false
            )
        }
    }

    /// Decode from a single control byte (for existing code compatibility)
    static func decode(control: UInt8) -> AX25ControlFieldDecoded {
        decode(controlBytes: [control])
    }

    /// Decode from control byte and optional second byte
    static func decode(control: UInt8, controlByte1: UInt8?) -> AX25ControlFieldDecoded {
        if let ctl1 = controlByte1 {
            return decode(controlBytes: [control, ctl1])
        } else {
            return decode(controlBytes: [control])
        }
    }

    // MARK: - Private Helpers

    /// Determine frame class from the first control byte
    private static func determineFrameClass(ctl0: UInt8) -> AX25FrameClass {
        // I-frame: bit 0 = 0
        if (ctl0 & 0x01) == 0 {
            return .I
        }

        // S-frame: bits 0-1 = 01
        if (ctl0 & 0x03) == 0x01 {
            return .S
        }

        // U-frame: bits 0-1 = 11
        if (ctl0 & 0x03) == 0x03 {
            return .U
        }

        return .unknown
    }

    /// Decode an I-frame (Information frame)
    ///
    /// Modulo-8 I-frame (2 bytes):
    /// - ctl0 bit 0 = 0
    /// - N(S) = (ctl0 >> 1) & 0x07 (bits 1-3)
    /// - ctl1 bit 4 = P/F
    /// - N(R) = (ctl1 >> 5) & 0x07 (bits 5-7)
    private static func decodeIFrame(ctl0: UInt8, ctl1: UInt8?) -> AX25ControlFieldDecoded {
        // I-frames require 2 control bytes in modulo-8 mode
        // If ctl1 is missing, we can't fully decode
        guard let ctl1 = ctl1 else {
            return AX25ControlFieldDecoded(
                frameClass: .unknown,
                sType: nil,
                uType: nil,
                ns: nil,
                nr: nil,
                pf: nil,
                ctl0: ctl0,
                ctl1: nil,
                isExtended: false
            )
        }

        let ns = Int((ctl0 >> 1) & 0x07)
        let pf = Int((ctl1 >> 4) & 0x01)
        let nr = Int((ctl1 >> 5) & 0x07)

        return AX25ControlFieldDecoded(
            frameClass: .I,
            sType: nil,
            uType: nil,
            ns: ns,
            nr: nr,
            pf: pf,
            ctl0: ctl0,
            ctl1: ctl1,
            isExtended: false
        )
    }

    /// Decode an S-frame (Supervisory frame)
    ///
    /// Modulo-8 S-frame (1 byte):
    /// - bits 0-1 = 01 (S-frame indicator)
    /// - bits 2-3 = subtype (RR=00, RNR=01, REJ=10, SREJ=11)
    /// - bit 4 = P/F
    /// - bits 5-7 = N(R)
    private static func decodeSFrame(ctl0: UInt8) -> AX25ControlFieldDecoded {
        let subtypeBits = (ctl0 >> 2) & 0x03
        let sType: AX25SType

        switch subtypeBits {
        case 0b00:
            sType = .RR
        case 0b01:
            sType = .RNR
        case 0b10:
            sType = .REJ
        case 0b11:
            sType = .SREJ
        default:
            sType = .RR // Should never happen, but default to RR
        }

        let pf = Int((ctl0 >> 4) & 0x01)
        let nr = Int((ctl0 >> 5) & 0x07)

        return AX25ControlFieldDecoded(
            frameClass: .S,
            sType: sType,
            uType: nil,
            ns: nil,
            nr: nr,
            pf: pf,
            ctl0: ctl0,
            ctl1: nil,
            isExtended: false
        )
    }

    /// Decode a U-frame (Unnumbered frame)
    ///
    /// U-frame (1 byte):
    /// - bits 0-1 = 11 (U-frame indicator)
    /// - bit 4 = P/F
    /// - Subtype determined by pattern matching with P/F bit masked out
    private static func decodeUFrame(ctl0: UInt8) -> AX25ControlFieldDecoded {
        let pf = Int((ctl0 >> 4) & 0x01)

        // Mask out P/F bit (bit 4) to get the pattern
        let pattern = ctl0 & 0xEF

        let uType: AX25UType
        switch pattern {
        case uiPattern:
            uType = .UI
        case sabmPattern:
            uType = .SABM
        case sabmePattern:
            uType = .SABME
        case discPattern:
            uType = .DISC
        case uaPattern:
            uType = .UA
        case dmPattern:
            uType = .DM
        case frmrPattern:
            uType = .FRMR
        default:
            uType = .UNKNOWN
        }

        return AX25ControlFieldDecoded(
            frameClass: .U,
            sType: nil,
            uType: uType,
            ns: nil,
            nr: nil,
            pf: pf,
            ctl0: ctl0,
            ctl1: nil,
            isExtended: false
        )
    }
}

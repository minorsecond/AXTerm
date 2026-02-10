//
//  AX25ControlField.swift
//  AXTerm
//
//  Types for decoded AX.25 control field information.
//

import Foundation

/// AX.25 frame class (I, S, U, or unknown)
nonisolated enum AX25FrameClass: String, Codable, Hashable, Sendable {
    case I = "I"
    case S = "S"
    case U = "U"
    case unknown = "unknown"
}

/// AX.25 S-frame (Supervisory) subtypes
nonisolated enum AX25SType: String, Codable, Hashable, Sendable {
    case RR = "RR"       // Receive Ready
    case RNR = "RNR"     // Receive Not Ready
    case REJ = "REJ"     // Reject
    case SREJ = "SREJ"   // Selective Reject
}

/// AX.25 U-frame (Unnumbered) subtypes
nonisolated enum AX25UType: String, Codable, Hashable, Sendable {
    case UI = "UI"       // Unnumbered Information
    case SABM = "SABM"   // Set Asynchronous Balanced Mode
    case SABME = "SABME" // Set Asynchronous Balanced Mode Extended
    case DISC = "DISC"   // Disconnect
    case UA = "UA"       // Unnumbered Acknowledge
    case DM = "DM"       // Disconnected Mode
    case FRMR = "FRMR"   // Frame Reject
    case UNKNOWN = "UNKNOWN" // Unknown U-frame subtype
}

/// Decoded AX.25 control field information
nonisolated struct AX25ControlFieldDecoded: Codable, Hashable, Sendable {
    /// Frame class (I, S, U, or unknown)
    let frameClass: AX25FrameClass

    /// S-frame subtype (only for S-frames)
    let sType: AX25SType?

    /// U-frame subtype (only for U-frames)
    let uType: AX25UType?

    /// N(S) sequence number (only for I-frames)
    let ns: Int?

    /// N(R) sequence number (for I-frames and S-frames)
    let nr: Int?

    /// Poll/Final bit (0 or 1)
    let pf: Int?

    /// Raw first control byte (0-255)
    let ctl0: UInt8?

    /// Raw second control byte (0-255), present for I-frames in modulo-8 mode
    let ctl1: UInt8?

    /// Whether this is an extended (modulo-128) frame
    let isExtended: Bool

    /// Create an unknown/empty decoded result
    static let unknown = AX25ControlFieldDecoded(
        frameClass: .unknown,
        sType: nil,
        uType: nil,
        ns: nil,
        nr: nil,
        pf: nil,
        ctl0: nil,
        ctl1: nil,
        isExtended: false
    )
}

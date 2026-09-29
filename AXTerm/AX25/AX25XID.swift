//
//  AX25XID.swift
//  AXTerm
//
//  XID parameter negotiation (AX.25 2.2 §4.3.3.7 / §6.3.2).
//
//  Wire format: FI 0x82, GI 0x80, 16-bit group length, then PI/PL/PV
//  triplets. Bit values follow the de-facto field reference — Direwolf's
//  xid.c — which interoperates with BPQ and UZ7HO on the air. A command
//  OFFERS a menu of acceptable options (multiple reject-mode bits may be
//  set); a response PICKS exactly one. Pre-2.2 implementations answer an
//  XID command with FRMR, which callers must treat as "negotiate nothing",
//  never as an error (§6.3.2).
//
//  AXTerm offers modulo 8 only. Modulo 128 changes the control-field
//  length on every I- and S-frame, and the inbound KISS decode pipeline
//  is not session-aware — it cannot know where a peer's extended control
//  field ends. At 1200 baud the negotiation prize is SREJ (selective
//  retransmission instead of go-back-N) and the N1/k notifications;
//  k=7 × 256 bytes already keeps ~14 s of airtime in flight, so a larger
//  window buys nothing the channel can carry.
//

import Foundation

nonisolated struct AX25XIDParameters: Equatable, Sendable {

    var halfDuplex: Bool = true
    var supportsREJ: Bool = true
    var supportsSREJ: Bool = false
    /// Parsed from peers so negotiation can decline it; never offered.
    var modulo128: Bool = false
    /// Maximum I-field we can receive, in bytes (PI 6 carries bits).
    var iFieldLengthRx: Int?
    var windowSizeRx: Int?
    var ackTimerMs: Int?
    var retries: Int?

    // MARK: - Field constants (Direwolf xid.c names)

    private static let formatIndicator: UInt8 = 0x82
    private static let groupIdentifier: UInt8 = 0x80

    private enum PI {
        static let classesOfProcedures = 2
        static let hdlcOptionalFunctions = 3
        static let iFieldLengthRx = 6
        static let windowSizeRx = 8
        static let ackTimer = 9
        static let retries = 10
    }

    private enum Classes {
        static let balancedABM: UInt16 = 0x0100
        static let halfDuplex: UInt16 = 0x2000
        static let fullDuplex: UInt16 = 0x4000
    }

    private enum Optional {
        static let rej: UInt32 = 0x020000
        static let srej: UInt32 = 0x040000
        static let multiSREJ: UInt32 = 0x000020
        static let extendedAddress: UInt32 = 0x800000
        static let modulo8: UInt32 = 0x000400
        static let modulo128: UInt32 = 0x000800
        static let testCmdResp: UInt32 = 0x002000
        static let fcs16Bit: UInt32 = 0x008000
        static let synchronousTx: UInt32 = 0x000002
    }

    // MARK: - Encoding

    func encoded(isCommand: Bool) -> Data {
        var body = Data()
        func triplet16(_ pi: Int, _ value: UInt16) {
            body.append(contentsOf: [UInt8(pi), 2, UInt8(value >> 8), UInt8(value & 0xFF)])
        }

        var classes = Classes.balancedABM
        classes |= halfDuplex ? Classes.halfDuplex : Classes.fullDuplex
        triplet16(PI.classesOfProcedures, classes)

        var opt = Optional.extendedAddress | Optional.testCmdResp
            | Optional.fcs16Bit | Optional.synchronousTx | Optional.modulo8
        if isCommand {
            // Offer the menu of everything acceptable.
            opt |= Optional.rej
            if supportsSREJ { opt |= Optional.srej }
        } else {
            // Pick exactly one.
            opt |= supportsSREJ ? Optional.srej : Optional.rej
        }
        body.append(contentsOf: [UInt8(PI.hdlcOptionalFunctions), 3,
                                 UInt8((opt >> 16) & 0xFF), UInt8((opt >> 8) & 0xFF), UInt8(opt & 0xFF)])

        if let n1 = iFieldLengthRx {
            triplet16(PI.iFieldLengthRx, UInt16(clamping: n1 * 8))
        }
        if let k = windowSizeRx {
            body.append(contentsOf: [UInt8(PI.windowSizeRx), 1, UInt8(clamping: k)])
        }
        if let timer = ackTimerMs {
            triplet16(PI.ackTimer, UInt16(clamping: timer))
        }
        if let n2 = retries {
            body.append(contentsOf: [UInt8(PI.retries), 1, UInt8(clamping: n2)])
        }

        var out = Data([Self.formatIndicator, Self.groupIdentifier,
                        UInt8(body.count >> 8), UInt8(body.count & 0xFF)])
        out.append(body)
        return out
    }

    // MARK: - Parsing

    /// Parses an XID information field. Unknown parameters are skipped
    /// (the spec keeps adding them); structural damage returns nil.
    static func parse(_ info: Data) -> AX25XIDParameters? {
        let b = [UInt8](info)
        guard b.count >= 4,
              b[0] == formatIndicator,
              b[1] == groupIdentifier else { return nil }
        let groupLength = Int(b[2]) << 8 | Int(b[3])
        guard b.count >= 4 + groupLength else { return nil }

        var params = AX25XIDParameters()
        params.supportsREJ = false

        var index = 4
        let end = 4 + groupLength
        while index < end {
            guard index + 2 <= end else { return nil }
            let pi = Int(b[index])
            let pl = Int(b[index + 1])
            guard index + 2 + pl <= end else { return nil }
            let value = b[(index + 2)..<(index + 2 + pl)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            index += 2 + pl

            switch pi {
            case PI.classesOfProcedures:
                params.halfDuplex = (UInt16(truncatingIfNeeded: value) & Classes.fullDuplex) == 0
            case PI.hdlcOptionalFunctions:
                params.supportsREJ = (value & Optional.rej) != 0
                params.supportsSREJ = (value & Optional.srej) != 0
                params.modulo128 = (value & Optional.modulo128) != 0
            case PI.iFieldLengthRx:
                params.iFieldLengthRx = Int(value) / 8
            case PI.windowSizeRx:
                params.windowSizeRx = Int(value)
            case PI.ackTimer:
                params.ackTimerMs = Int(value)
            case PI.retries:
                params.retries = Int(value)
            default:
                break  // Unknown parameter — skip, never fail.
            }
        }
        return params
    }
}

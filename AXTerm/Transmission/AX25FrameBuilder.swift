//
//  AX25FrameBuilder.swift
//  AXTerm
//
//  Builders for AX.25 frame types: U-frames, S-frames, I-frames.
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 5.2, 7
//

import Foundation

// MARK: - Control Byte Constants

/// AX.25 control byte constants for frame building
enum AX25Control {
    // U-frame control bytes (unnumbered)
    static let ui: UInt8       = 0x03    // UI (Unnumbered Information)
    static let sabm: UInt8     = 0x2F    // SABM (Set Asynchronous Balanced Mode)
    static let sabme: UInt8    = 0x6F    // SABME (SABM Extended - modulo 128)
    static let disc: UInt8     = 0x43    // DISC (Disconnect)
    static let dm: UInt8       = 0x0F    // DM (Disconnected Mode)
    static let ua: UInt8       = 0x63    // UA (Unnumbered Acknowledge)
    static let frmr: UInt8     = 0x87    // FRMR (Frame Reject)

    // S-frame control byte base patterns (modulo 8)
    // Format: xxxNNNN1 where x=frame type, NNNN=N(R) shifted left 5 bits
    static let rrBase: UInt8   = 0x01    // RR (Receive Ready)
    static let rnrBase: UInt8  = 0x05    // RNR (Receive Not Ready)
    static let rejBase: UInt8  = 0x09    // REJ (Reject)
    static let srejBase: UInt8 = 0x0D    // SREJ (Selective Reject)

    /// Build S-frame control byte for modulo 8
    /// - Parameters:
    ///   - base: Base control pattern (rrBase, rnrBase, etc.)
    ///   - nr: N(R) - next expected receive sequence (0-7)
    ///   - pf: Poll/Final bit
    static func sFrame(base: UInt8, nr: Int, pf: Bool = false) -> UInt8 {
        // Format: NNNP0001 for RR (base=0x01)
        //         NNN = N(R) in bits 5-7
        //         P = P/F bit in bit 4
        var ctrl = base
        ctrl |= UInt8((nr & 0x07) << 5)  // N(R) in bits 5-7
        if pf { ctrl |= 0x10 }           // P/F bit in bit 4
        return ctrl
    }

    /// Build I-frame control byte for modulo 8
    /// - Parameters:
    ///   - ns: N(S) - send sequence number (0-7)
    ///   - nr: N(R) - next expected receive sequence (0-7)
    ///   - pf: Poll/Final bit
    static func iFrame(ns: Int, nr: Int, pf: Bool = false) -> UInt8 {
        // Format: NNNPSSS0
        //         NNN = N(R) in bits 5-7
        //         P = P/F bit in bit 4
        //         SSS = N(S) in bits 1-3
        //         0 in bit 0 identifies I-frame
        var ctrl: UInt8 = 0
        ctrl |= UInt8((nr & 0x07) << 5)  // N(R) in bits 5-7
        if pf { ctrl |= 0x10 }           // P/F bit in bit 4
        ctrl |= UInt8((ns & 0x07) << 1)  // N(S) in bits 1-3
        // Bit 0 = 0 for I-frame
        return ctrl
    }

    /// Build U-frame control byte with P/F bit
    static func uFrame(base: UInt8, pf: Bool = false) -> UInt8 {
        if pf {
            return base | 0x10  // P/F bit is bit 4
        }
        return base
    }
}

// MARK: - Frame Builder

/// Builds AX.25 frames for transmission
struct AX25FrameBuilder {

    // MARK: - U-Frame Builders

    /// Build a SABM (Set Asynchronous Balanced Mode) frame to initiate connection
    static func buildSABM(
        from source: AX25Address,
        to destination: AX25Address,
        via path: DigiPath = DigiPath(),
        extended: Bool = false,
        pf: Bool = true
    ) -> OutboundFrame {
        let control = extended
            ? AX25Control.uFrame(base: AX25Control.sabme, pf: pf)
            : AX25Control.uFrame(base: AX25Control.sabm, pf: pf)

        return OutboundFrame(
            destination: destination,
            source: source,
            path: path,
            payload: Data(),  // No payload for SABM
            priority: .interactive,
            frameType: "u",
            pid: nil,         // No PID for U-frames except UI
            controlByte: control,
            displayInfo: extended ? "SABME" : "SABM"
        )
    }

    /// Build a UA (Unnumbered Acknowledge) frame - response to SABM or DISC
    static func buildUA(
        from source: AX25Address,
        to destination: AX25Address,
        via path: DigiPath = DigiPath(),
        pf: Bool = true
    ) -> OutboundFrame {
        return OutboundFrame(
            destination: destination,
            source: source,
            path: path,
            payload: Data(),
            priority: .interactive,
            frameType: "u",
            pid: nil,
            controlByte: AX25Control.uFrame(base: AX25Control.ua, pf: pf),
            displayInfo: "UA"
        )
    }

    /// Build a DM (Disconnected Mode) frame - reject connection
    static func buildDM(
        from source: AX25Address,
        to destination: AX25Address,
        via path: DigiPath = DigiPath(),
        pf: Bool = true
    ) -> OutboundFrame {
        return OutboundFrame(
            destination: destination,
            source: source,
            path: path,
            payload: Data(),
            priority: .interactive,
            frameType: "u",
            pid: nil,
            controlByte: AX25Control.uFrame(base: AX25Control.dm, pf: pf),
            displayInfo: "DM"
        )
    }

    /// Build a DISC (Disconnect) frame - terminate connection
    static func buildDISC(
        from source: AX25Address,
        to destination: AX25Address,
        via path: DigiPath = DigiPath(),
        pf: Bool = true
    ) -> OutboundFrame {
        return OutboundFrame(
            destination: destination,
            source: source,
            path: path,
            payload: Data(),
            priority: .interactive,
            frameType: "u",
            pid: nil,
            controlByte: AX25Control.uFrame(base: AX25Control.disc, pf: pf),
            displayInfo: "DISC"
        )
    }

    /// Build a UI (Unnumbered Information) frame - datagram/broadcast
    static func buildUI(
        from source: AX25Address,
        to destination: AX25Address,
        via path: DigiPath = DigiPath(),
        pid: UInt8 = 0xF0,
        payload: Data,
        displayInfo: String? = nil
    ) -> OutboundFrame {
        return OutboundFrame(
            destination: destination,
            source: source,
            path: path,
            payload: payload,
            priority: .normal,
            frameType: "ui",
            pid: pid,
            controlByte: AX25Control.ui,
            displayInfo: displayInfo
        )
    }

    // MARK: - S-Frame Builders

    /// Build an RR (Receive Ready) frame - acknowledge received frames
    static func buildRR(
        from source: AX25Address,
        to destination: AX25Address,
        via path: DigiPath = DigiPath(),
        nr: Int,
        pf: Bool = false
    ) -> OutboundFrame {
        return OutboundFrame(
            destination: destination,
            source: source,
            path: path,
            payload: Data(),
            priority: .interactive,
            frameType: "s",
            pid: nil,
            controlByte: AX25Control.sFrame(base: AX25Control.rrBase, nr: nr, pf: pf),
            displayInfo: "RR(\(nr))"
        )
    }

    /// Build an RNR (Receive Not Ready) frame - busy, stop sending
    static func buildRNR(
        from source: AX25Address,
        to destination: AX25Address,
        via path: DigiPath = DigiPath(),
        nr: Int,
        pf: Bool = false
    ) -> OutboundFrame {
        return OutboundFrame(
            destination: destination,
            source: source,
            path: path,
            payload: Data(),
            priority: .interactive,
            frameType: "s",
            pid: nil,
            controlByte: AX25Control.sFrame(base: AX25Control.rnrBase, nr: nr, pf: pf),
            displayInfo: "RNR(\(nr))"
        )
    }

    /// Build a REJ (Reject) frame - request retransmit from sequence nr
    static func buildREJ(
        from source: AX25Address,
        to destination: AX25Address,
        via path: DigiPath = DigiPath(),
        nr: Int,
        pf: Bool = false
    ) -> OutboundFrame {
        return OutboundFrame(
            destination: destination,
            source: source,
            path: path,
            payload: Data(),
            priority: .interactive,
            frameType: "s",
            pid: nil,
            controlByte: AX25Control.sFrame(base: AX25Control.rejBase, nr: nr, pf: pf),
            displayInfo: "REJ(\(nr))"
        )
    }

    // MARK: - I-Frame Builder

    /// Build an I (Information) frame - data in connected mode
    static func buildIFrame(
        from source: AX25Address,
        to destination: AX25Address,
        via path: DigiPath = DigiPath(),
        ns: Int,
        nr: Int,
        pid: UInt8 = 0xF0,
        payload: Data,
        pf: Bool = false,
        sessionId: UUID? = nil,
        displayInfo: String? = nil
    ) -> OutboundFrame {
        return OutboundFrame(
            destination: destination,
            source: source,
            path: path,
            payload: payload,
            priority: .interactive,
            frameType: "i",
            pid: pid,
            sessionId: sessionId,
            controlByte: AX25Control.iFrame(ns: ns, nr: nr, pf: pf),
            ns: ns,
            nr: nr,
            displayInfo: displayInfo ?? "I(\(ns),\(nr))"
        )
    }
}

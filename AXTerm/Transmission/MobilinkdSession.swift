//
//  MobilinkdSession.swift
//  AXTerm
//
//  What AXTerm says to a Mobilinkd TNC4 when a link comes up, and what it
//  puts back when the link goes down. Pure, so the byte sequences can be
//  pinned in tests; the links do the timing.
//

import Foundation

/// The four KISS timing parameters, in milliseconds as the operator thinks of
/// them. KISS carries them in 10 ms units.
nonisolated struct KISSTimingParameters: Equatable, Sendable {
    var txDelayMs: Int = 300
    var persistence: UInt8 = 63
    var slotTimeMs: Int = 100
    var txTailMs: Int = 50
    var fullDuplex: Bool = false

    static let `default` = KISSTimingParameters()

    /// TXDELAY, PERSISTENCE, SLOTTIME, TXTAIL and FULLDUPLEX frames, in that order.
    func frames(port: UInt8 = 0) -> [Data] {
        func tens(_ ms: Int) -> UInt8 { UInt8(clamping: (max(0, ms) + 5) / 10) }
        let fend: UInt8 = 0xC0
        let cmd = port << 4
        return [
            Data([fend, cmd | 1, tens(txDelayMs), fend]),
            Data([fend, cmd | 2, persistence, fend]),
            Data([fend, cmd | 3, tens(slotTimeMs), fend]),
            Data([fend, cmd | 4, tens(txTailMs), fend]),
            Data([fend, cmd | 5, fullDuplex ? 1 : 0, fend]),
        ]
    }
}

nonisolated enum MobilinkdSession {

    // MARK: Liveness

    /// Asked once the link is up, to prove the TNC4 can be heard.
    ///
    /// About one BLE connection in four to a TNC4 comes up with notifications
    /// reported as enabled and then never delivers a byte, while writes still
    /// reach the TNC4 (measured 2026-09-29). A link like that looks connected
    /// and hears nothing, so nothing is trusted until this is answered.
    static let probe = Data(MobilinkdTNC.getFirmwareVersion())

    static func isProbeReply(_ frame: Data) -> Bool {
        MobilinkdTNC.parseFirmwareVersion(frame) != nil
    }

    // MARK: Reading what the TNC4 holds

    /// One GET_ALL_VALUES brings every managed setting back. It stops the
    /// demodulator, which is fine: `connectFrames` always ends with RESET.
    static let readRequest = Data(MobilinkdTNC.getAllValues())

    // MARK: Changing it

    /// Everything sent to a TNC4 once it has answered the probe: the profile's
    /// settings where they differ from what the TNC4 holds, then RESET.
    ///
    /// Always ends with RESET. On 2026-09-29 a TNC4 that had just connected
    /// passed up no packets until its demodulator was restarted, and the level
    /// read (GET_ALL_VALUES) stops the demodulator besides.
    static func connectFrames(wanted: MobilinkdSettings?, found: MobilinkdSettings?) -> [Data] {
        var out: [Data] = []
        if let wanted, let found { out = MobilinkdSettings.frames(toReach: wanted, from: found) }
        let reset = Data(MobilinkdTNC.reset())
        if out.last != reset { out.append(reset) }
        return out
    }

    /// What to send on the way out so the TNC4 is left as it was found:
    /// the original value of every field this link set. Empty when the link
    /// changed nothing.
    static func restoreFrames(applied: MobilinkdSettings?, found: MobilinkdSettings?) -> [Data] {
        guard let applied, let found else { return [] }
        return MobilinkdSettings.frames(toReach: found.restricted(to: applied), from: applied)
    }
}

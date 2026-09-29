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

    /// Individual queries for the managed settings.
    ///
    /// Not GET_ALL_VALUES: that also queues a battery and twist measurement on
    /// the TNC4's audio task. Sent just after a reconnect, while the task was
    /// still settling from the last gain change, it went unanswered and the
    /// TNC4 rebooted (2026-09-29). These are answered by the KISS task alone.
    static let readRequests: [Data] = [
        Data(MobilinkdTNC.getOutputGain()),
        Data(MobilinkdTNC.getOutputTwist()),
        Data(MobilinkdTNC.getInputGain()),
        Data(MobilinkdTNC.getInputTwist()),
        Data(MobilinkdTNC.getModemType()),
        Data(MobilinkdTNC.getPTTChannel()),
    ]

    /// Everything the settings page shows, as individual queries the TNC4
    /// answers from its KISS task, then the battery.
    ///
    /// Not GET_ALL_VALUES. That queues a battery and a twist measurement on the
    /// audio task, and the twist measurement waits for samples with no
    /// timeout. On 2026-09-29, sent right after connecting, the TNC4 answered
    /// its first line and then stopped. It rebooted seconds later, when the
    /// audio queue (depth 8) filled and the next post blocked the task that
    /// handles commands. The battery is the one reading that needs the audio
    /// task, so it goes last, alone, with the RESET that restarts the
    /// demodulator after it.
    static let statusRequests: [Data] = [
        Data(MobilinkdTNC.getHardwareVersion()),
        Data(MobilinkdTNC.getFirmwareVersion()),
        Data(MobilinkdTNC.getSerialNumber()),
        Data(MobilinkdTNC.getCapabilities()),
        Data(MobilinkdTNC.getModemTypes()),
        Data(MobilinkdTNC.getTimingValue(33)), Data(MobilinkdTNC.getTimingValue(34)),
        Data(MobilinkdTNC.getTimingValue(35)), Data(MobilinkdTNC.getTimingValue(36)),
        Data(MobilinkdTNC.getPassall()),
        Data(MobilinkdTNC.getRxReversePolarity()), Data(MobilinkdTNC.getTxReversePolarity()),
        Data(MobilinkdTNC.getUSBPowerOn()), Data(MobilinkdTNC.getUSBPowerOff()),
    ] + readRequests + [Data(MobilinkdTNC.pollBatteryLevelAndResume())]

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

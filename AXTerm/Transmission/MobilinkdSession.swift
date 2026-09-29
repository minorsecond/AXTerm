//
//  MobilinkdSession.swift
//  AXTerm
//
//  What AXTerm says to a Mobilinkd TNC4 when a link comes up, and what it
//  puts back when the link goes down. Pure, so the byte sequences can be
//  pinned in tests; KISSLinkBLE does the timing.
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

    /// The TNC4 settings AXTerm manages for a radio profile.
    struct Levels: Equatable, Sendable {
        var outputGain: UInt16
        var inputGain: UInt16
        var modemType: UInt8

        init(outputGain: UInt16, inputGain: UInt16, modemType: UInt8) {
            self.outputGain = outputGain
            self.inputGain = inputGain
            self.modemType = modemType
        }

        init(_ config: MobilinkdConfig) {
            self.init(outputGain: UInt16(config.outputGain), inputGain: UInt16(config.inputGain),
                      modemType: config.modemType.rawValue)
        }
    }

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

    static let readRequests: [Data] = [
        Data(MobilinkdTNC.getOutputGain()),
        Data(MobilinkdTNC.getInputGain()),
        Data(MobilinkdTNC.getModemType()),
    ]

    /// Collects the answers to `readRequests`.
    struct Reader: Equatable {
        private(set) var outputGain: UInt16?
        private(set) var inputGain: UInt16?
        private(set) var modemType: UInt8?

        mutating func observe(_ frame: Data) {
            if let v = MobilinkdTNC.parseOutputGain(frame) { outputGain = UInt16(clamping: v) }
            if let v = MobilinkdTNC.parseInputGain(frame) { inputGain = UInt16(clamping: v) }
            if let v = MobilinkdTNC.parseModemType(frame) { modemType = v }
        }

        var levels: Levels? {
            guard let outputGain, let inputGain, let modemType else { return nil }
            return Levels(outputGain: outputGain, inputGain: inputGain, modemType: modemType)
        }
    }

    /// Whether a hardware frame is the kind of reply the session asks for.
    static func isSessionReply(_ frame: Data) -> Bool {
        replyKey(of: frame) != nil
    }

    // MARK: Matching replies to requests
    //
    // Replies to the session's own requests have to stay inside the link.
    // PacketEngine reads any input-gain reply as the result of an auto-adjust
    // and writes it into the radio's profile, which would overwrite the
    // operator's setting with whatever the TNC4 held, and the profile change
    // would then reconnect the link. So the link holds back one reply per
    // request it sent, and lets everything else through: a query the app
    // makes a moment later still gets its answer.

    /// Which reply a request draws, or nil if it draws none (RESET, KISS
    /// timing). A SET is answered like the matching GET: the firmware falls
    /// through to the GET handler.
    static func replyKey(forRequest frame: Data) -> UInt8? {
        let body = Array(frame.drop { $0 == KISS.FEND })
        guard body.count >= 2, body[0] == MobilinkdTNC.CMD_HARDWARE else { return nil }
        switch body[1] {
        case MobilinkdTNC.GET_FIRMWARE_VERSION: return MobilinkdTNC.GET_FIRMWARE_VERSION
        case MobilinkdTNC.SET_OUTPUT_GAIN, MobilinkdTNC.GET_OUTPUT_GAIN: return MobilinkdTNC.GET_OUTPUT_GAIN
        case MobilinkdTNC.SET_INPUT_GAIN, MobilinkdTNC.GET_INPUT_GAIN: return MobilinkdTNC.GET_INPUT_GAIN
        case MobilinkdTNC.EXT_CMD_PREFIX:
            guard body.count >= 3,
                  body[2] == MobilinkdTNC.EXT_GET_MODEM_TYPE || body[2] == MobilinkdTNC.EXT_SET_MODEM_TYPE
            else { return nil }
            return MobilinkdTNC.EXT_GET_MODEM_TYPE
        default: return nil
        }
    }

    /// Which request a reply answers, in the same terms as `replyKey(forRequest:)`.
    static func replyKey(of reply: Data) -> UInt8? {
        if isProbeReply(reply) { return MobilinkdTNC.GET_FIRMWARE_VERSION }
        if MobilinkdTNC.parseOutputGain(reply) != nil { return MobilinkdTNC.GET_OUTPUT_GAIN }
        if MobilinkdTNC.parseInputGain(reply) != nil { return MobilinkdTNC.GET_INPUT_GAIN }
        if MobilinkdTNC.parseModemType(reply) != nil { return MobilinkdTNC.EXT_GET_MODEM_TYPE }
        return nil
    }

    /// The replies still owed to the session. Each expires, so one the TNC4
    /// never sent can't swallow a later reply meant for the app.
    struct ExpectedReplies {
        private var pending: [(key: UInt8, until: Date)] = []
        static let lifetime: TimeInterval = 3

        var isEmpty: Bool { pending.isEmpty }

        mutating func expect(repliesTo frames: [Data], now: Date = Date()) {
            for frame in frames {
                if let key = MobilinkdSession.replyKey(forRequest: frame) {
                    pending.append((key, now.addingTimeInterval(Self.lifetime)))
                }
            }
        }

        /// True, and one expectation used up, if `reply` is owed to the session.
        mutating func claim(_ reply: Data, now: Date = Date()) -> Bool {
            pending.removeAll { $0.until < now }
            guard let key = MobilinkdSession.replyKey(of: reply),
                  let i = pending.firstIndex(where: { $0.key == key }) else { return false }
            pending.remove(at: i)
            return true
        }

        mutating func removeAll() { pending.removeAll() }
    }

    // MARK: Changing it

    /// The frames that take the TNC4 from `current` to `target`, changing only
    /// what differs. Nothing here is saved to flash.
    ///
    /// Modem type goes first because switching it restarts the modulator and
    /// demodulator. A modem-type or input-gain change ends with RESET: the
    /// input-gain change leaves the TNC4 streaming levels instead of decoding.
    static func frames(toReach target: Levels, from current: Levels) -> [Data] {
        var out: [Data] = []
        var needsReset = false
        if target.modemType != current.modemType,
           let type = MobilinkdTNC.ModemType(rawValue: target.modemType) {
            out.append(Data(MobilinkdTNC.setModemType(type)))
            needsReset = true
        }
        if target.outputGain != current.outputGain {
            out.append(Data(MobilinkdTNC.setOutputGain(target.outputGain)))
        }
        if target.inputGain != current.inputGain {
            out.append(Data(MobilinkdTNC.setInputGain(target.inputGain)))
            needsReset = true
        }
        if needsReset { out.append(Data(MobilinkdTNC.reset())) }
        return out
    }

    /// Everything sent to a TNC4 once it has answered the probe.
    ///
    /// Always ends with RESET. On 2026-09-29 a TNC4 that had just connected
    /// passed up no packets at all until its demodulator was restarted, while
    /// the startup watchdog would have waited 30 to 90 seconds to do it.
    static func connectFrames(wanted: Levels?, found: Levels?) -> [Data] {
        var out: [Data] = []
        if let wanted, let found { out = frames(toReach: wanted, from: found) }
        let reset = Data(MobilinkdTNC.reset())
        if out.last != reset { out.append(reset) }
        return out
    }

    /// What to send on the way out so the TNC4 is left as it was found. Empty
    /// when the session changed nothing.
    static func restoreFrames(applied: Levels?, found: Levels?) -> [Data] {
        guard let applied, let found else { return [] }
        return frames(toReach: found, from: applied)
    }
}

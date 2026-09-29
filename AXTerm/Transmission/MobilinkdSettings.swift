//
//  MobilinkdSettings.swift
//  AXTerm
//

import Foundation

/// The TNC4 settings a radio profile manages.
///
/// Each field is either set by the operator for this radio or nil, which
/// means "leave it as the TNC4 has it". A TNC4 is often shared between radios
/// (a handheld one day, a mobile the next), and what suits one radio's audio
/// is wrong for another's, so a profile only changes what it has an opinion
/// on. Nothing here is saved to the TNC4's flash; the link applies it when it
/// connects and puts the TNC4's own values back when it closes.
nonisolated struct MobilinkdSettings: Codable, Hashable, Sendable {
    /// 0...255. Mobilinkd: above 64 is too hot for a handheld's mic input.
    var outputGain: Int?
    /// 0...100, 50 flat.
    var outputTwist: Int?
    /// Gain step 0...4 (0 to 24 dB).
    var inputGain: Int?
    /// dB, -3...9.
    var inputTwist: Int?
    /// 1 = 1200 AFSK, 3 = 9600, 5 = M17 on firmware 2.5.14.
    var modemType: Int?
    /// Multiplex (PTT on the mic line) or simplex (separate PTT line).
    var pttMultiplex: Bool?

    var isEmpty: Bool { self == MobilinkdSettings() }

    /// The managed values a TNC4 reports, or nil until all of them are in.
    init?(reportedBy state: MobilinkdDeviceState) {
        guard let og = state.outputGain, let ot = state.outputTwist, let ig = state.inputGain,
              let it = state.inputTwist, let mt = state.modemType, let ptt = state.pttMultiplex else { return nil }
        self.init(outputGain: og, outputTwist: ot, inputGain: ig, inputTwist: it,
                  modemType: Int(mt), pttMultiplex: ptt)
    }

    init(outputGain: Int? = nil, outputTwist: Int? = nil, inputGain: Int? = nil,
         inputTwist: Int? = nil, modemType: Int? = nil, pttMultiplex: Bool? = nil) {
        self.outputGain = outputGain
        self.outputTwist = outputTwist
        self.inputGain = inputGain
        self.inputTwist = inputTwist
        self.modemType = modemType
        self.pttMultiplex = pttMultiplex
    }

    /// Only the fields that are set in `mask`, taken from `self`.
    func restricted(to mask: MobilinkdSettings) -> MobilinkdSettings {
        MobilinkdSettings(
            outputGain: mask.outputGain == nil ? nil : outputGain,
            outputTwist: mask.outputTwist == nil ? nil : outputTwist,
            inputGain: mask.inputGain == nil ? nil : inputGain,
            inputTwist: mask.inputTwist == nil ? nil : inputTwist,
            modemType: mask.modemType == nil ? nil : modemType,
            pttMultiplex: mask.pttMultiplex == nil ? nil : pttMultiplex)
    }

    /// `self` with every field that is set in `other` replaced by it.
    func merging(_ other: MobilinkdSettings?) -> MobilinkdSettings {
        guard let other else { return self }
        return MobilinkdSettings(
            outputGain: other.outputGain ?? outputGain,
            outputTwist: other.outputTwist ?? outputTwist,
            inputGain: other.inputGain ?? inputGain,
            inputTwist: other.inputTwist ?? inputTwist,
            modemType: other.modemType ?? modemType,
            pttMultiplex: other.pttMultiplex ?? pttMultiplex)
    }

    /// `self` without the fields that are set in `mask`.
    func subtracting(_ mask: MobilinkdSettings) -> MobilinkdSettings {
        MobilinkdSettings(
            outputGain: mask.outputGain == nil ? outputGain : nil,
            outputTwist: mask.outputTwist == nil ? outputTwist : nil,
            inputGain: mask.inputGain == nil ? inputGain : nil,
            inputTwist: mask.inputTwist == nil ? inputTwist : nil,
            modemType: mask.modemType == nil ? modemType : nil,
            pttMultiplex: mask.pttMultiplex == nil ? pttMultiplex : nil)
    }

    /// The frames that make the TNC4 match every field set in `target`,
    /// sending only what differs from `current` (a field nil in `current` is
    /// unknown, so it is sent).
    ///
    /// Modem type goes first because switching it restarts the modulator and
    /// demodulator. A change to modem type, input gain or input twist ends
    /// with RESET: the input changes leave the TNC4 streaming levels, and
    /// nothing but RESET gets it back to decoding.
    static func frames(toReach target: MobilinkdSettings, from current: MobilinkdSettings) -> [Data] {
        var out: [Data] = []
        var needsReset = false
        func differs<T: Equatable>(_ t: T?, _ c: T?) -> T? {
            guard let t, t != c else { return nil }
            return t
        }
        if let v = differs(target.modemType, current.modemType),
           let type = MobilinkdTNC.ModemType(rawValue: UInt8(clamping: v)) {
            out.append(Data(MobilinkdTNC.setModemType(type)))
            needsReset = true
        }
        if let v = differs(target.pttMultiplex, current.pttMultiplex) {
            out.append(Data(MobilinkdTNC.setPTTMultiplex(v)))
        }
        if let v = differs(target.outputGain, current.outputGain) {
            out.append(Data(MobilinkdTNC.setOutputGain(UInt16(clamping: v))))
        }
        if let v = differs(target.outputTwist, current.outputTwist) {
            out.append(Data(MobilinkdTNC.setOutputTwist(v)))
        }
        if let v = differs(target.inputGain, current.inputGain) {
            out.append(Data(MobilinkdTNC.setInputGain(UInt16(clamping: v))))
            needsReset = true
        }
        if let v = differs(target.inputTwist, current.inputTwist) {
            out.append(Data(MobilinkdTNC.setInputTwist(v)))
            needsReset = true
        }
        if needsReset { out.append(Data(MobilinkdTNC.reset())) }
        return out
    }
}

//
//  ReceiveLevelFinding.swift
//  AXTerm
//
//  What the operator reads when a radio's receive level looks wrong, with
//  the evidence behind it for the tooltip, and what Retune does.
//

import Foundation

nonisolated struct ReceiveLevelFinding: Equatable, Sendable {
    /// What the Retune button does.
    enum Retune: Equatable, Sendable {
        /// Run a calibration (APRS: one beacon, listen for digipeats).
        case calibrate
        /// Set this input gain step for the radio.
        case useGain(Int)
        /// No step will do; the radio's volume has to move. On APRS the
        /// operator can calibrate once it has.
        case turnVolume(ReceiveLevelDrift.VolumeTurn, thenCalibrate: Bool)
        /// Nothing to go on but the level meter (a packet channel with too
        /// few packets heard to recommend a step).
        case levelMeter
    }

    let message: String
    /// Lines for the tooltip: what was measured, when, and the rule.
    let evidence: [String]
    let retune: Retune

    /// The tooltip text.
    var help: String { ([message] + evidence).joined(separator: "\n") }

    // MARK: Building

    typealias TimeText = @Sendable (Date) -> String

    static let defaultTimeText: TimeText = { $0.formatted(date: .omitted, time: .shortened) }

    /// A level finding.
    static func level(_ f: ReceiveLevelDrift.Finding, radioName: String, onAPRS: Bool,
                      time: TimeText = defaultTimeText) -> ReceiveLevelFinding {
        let when = time(f.baseline.at)
        let amount = Int(abs(f.deltaDb).rounded())
        let message: String
        switch f.kind {
        case .louder:
            message = "Receive audio on \(radioName) is about \(amount) dB louder than when calibrated at \(when). The volume may have been moved."
        case .quieter:
            let why = f.deltaDb <= -12
                ? "The volume may have been turned down or the squelch closed."
                : "The volume may have been moved."
            message = "Receive audio on \(radioName) is about \(amount) dB quieter than when calibrated at \(when). \(why)"
        case .clipping:
            message = "Packets on \(radioName) are clipping at the TNC4's input. The volume may have been turned up."
        }

        var evidence = [baselineLine(f.baseline, time: time)]
        let gains = Set(f.samples.map(\.gain))
        let gainNote = gains.count == 1 ? " at \(ReceiveGainAdvice.gainText(gains.first ?? 0))" : ""
        let times = f.samples.map { time($0.at) }.joined(separator: " and ")
        switch f.basis {
        case .noise:
            let levels = f.samples.map { $0.noiseSaturated ? "full scale" : percent($0.noiseVpp) }
            evidence.append("Level checks at \(times)\(gainNote): noise \(levels.joined(separator: " and ")).")
            evidence.append("That is \(f.deltas.map(signedDb).joined(separator: " and ")) against calibration, with gain steps taken out.")
            evidence.append("Rule: two checks in a row at least \(Int(ReceiveLevelDrift.noiseShiftDb)) dB from calibration.")
        case .tones:
            let levels = f.samples.map { obs -> String in
                let tone = PacketToneSignature.median(obs.toneVpps)
                return percent(tone) + (obs.tonesClipped ? " (clipped)" : "")
            }
            evidence.append("Packets caught in level checks at \(times)\(gainNote): \(levels.joined(separator: " and ")).")
            if f.kind == .clipping {
                evidence.append("Rule: packets clipped in two checks in a row.")
            } else {
                evidence.append("That is \(f.deltas.map(signedDb).joined(separator: " and ")) against calibration, with gain steps taken out.")
                evidence.append("Rule: packets in two checks in a row at least \(Int(ReceiveLevelDrift.toneShiftDb)) dB from calibration.")
            }
        }

        let retune: Retune
        if let turn = f.turnVolume {
            evidence.append(turn == .down
                ? "No input gain step is low enough: turn the radio's volume down."
                : "No input gain step is high enough: turn the radio's volume up.")
            retune = .turnVolume(turn, thenCalibrate: onAPRS)
        } else if onAPRS {
            if let g = f.suggestedGain {
                evidence.append("\(ReceiveGainAdvice.gainText(g)) would likely bring packets back where they were. Retune measures to be sure.")
            }
            retune = .calibrate
        } else if let g = f.suggestedGain {
            evidence.append("\(ReceiveGainAdvice.gainText(g)) would bring packets back where they were.")
            retune = .useGain(g)
        } else {
            retune = .levelMeter
        }
        return ReceiveLevelFinding(message: message, evidence: evidence, retune: retune)
    }

    /// A digipeat finding.
    static func digipeats(_ f: DigipeatExpectation.Finding, radioName: String,
                          time: TimeText = defaultTimeText) -> ReceiveLevelFinding {
        let lead = f.usual.first
        let usual = lead.map { "\($0.call) repeated \($0.repeated) of the \(f.earlierFrames) before" } ?? ""
        let message = "None of your last \(f.misses) frames on \(radioName) were heard repeated, though \(usual). "
            + "Check the radio's volume, squelch and antenna."
        var evidence = f.usual.map { "\($0.call): repeated \($0.repeated) of \(f.earlierFrames) earlier frames." }
        if let last = f.lastEchoAt { evidence.append("Last repeat heard at \(time(last)).") }
        evidence.append("Rule: \(DigipeatExpectation.missesBeforeWarning) frames in a row with no repeat heard, "
                        + "from a digipeater that repeated at least \(Int(DigipeatExpectation.usualShare * 100))% of the earlier ones.")
        evidence.append("This can't tell a receive problem from a transmit problem.")
        return ReceiveLevelFinding(message: message, evidence: evidence, retune: .calibrate)
    }

    // MARK: Pieces

    static func baselineLine(_ b: ReceiveLevelBaseline, time: TimeText) -> String {
        let from: String
        switch b.source {
        case .beacon: from = b.packets == 1 ? "from 1 digipeat" : "from \(b.packets) digipeats"
        case .passive: from = b.packets == 1 ? "from 1 packet" : "from \(b.packets) packets"
        }
        var parts: [String] = []
        if let tone = b.toneVpp { parts.append("packets \(percent(tone))") }
        if let noise = b.noiseVpp { parts.append("noise \(b.noiseSaturated ? "full scale" : percent(noise))") }
        let levels = parts.isEmpty ? "" : ": " + parts.joined(separator: ", ")
        return "Calibrated at \(time(b.at)) \(from) at \(ReceiveGainAdvice.gainText(b.gain))\(levels)."
    }

    static func percent(_ vpp: Int?) -> String {
        guard let vpp else { return "unknown" }
        return ReceiveGainAdvice.percent(Double(vpp) / Double(TNC4LevelSample.fullScale))
    }

    static func signedDb(_ value: Double) -> String {
        String(format: "%@%.1f dB", value >= 0 ? "+" : "\u{2212}", abs(value))
    }
}

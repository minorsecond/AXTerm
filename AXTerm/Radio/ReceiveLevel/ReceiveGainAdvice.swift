//
//  ReceiveGainAdvice.swift
//  AXTerm
//
//  Turns a measured packet tone level into a TNC4 input gain step.
//

import Foundation

/// Which TNC4 input gain puts packets where the demodulator wants them.
///
/// The TNC4's input gain is a programmable amplifier with five steps, 0 to
/// 24 dB, 6 dB apart: follower mode, then PGA gains of 2, 4, 8 and 16
/// (tnc4-firmware AudioLevel.cpp, set_input_gain). So one step up doubles the
/// peak-to-peak of everything at the input, until it runs into the end of the
/// ADC's range. That makes the level at every other step predictable from
/// one measurement.
///
/// The level it works from is the packets' tones as measured. On 2026-09-30
/// open-squelch noise filled 55% of the range while packets arrived at 16%,
/// so a gain chosen from noise left packets 10 dB lower than intended.
nonisolated enum ReceiveGainAdvice {

    /// Where to aim packet tones: 45% of full scale peak to peak.
    ///
    /// The firmware's own auto-adjust picks the step that puts its input
    /// between 50% and 100% of the range (AudioLevel.cpp, adjust_input_gain),
    /// but it measures whatever is on the input, usually noise. Tones need
    /// headroom that noise doesn't: stations differ in deviation by 3 dB or
    /// so, and the loudest should not clip. 45% leaves 7 dB above the target
    /// and is the middle, in dB, of the acceptable band below.
    static let targetFraction = 0.45
    /// Never pick a step predicted to put tones above 80% (-2 dB): louder
    /// stations would clip.
    static let ceilingFraction = 0.80
    /// Tones anywhere in 30% to 70% are fine. The band is wider than one
    /// 6 dB step, so there is always a step inside it unless the radio's
    /// volume is far off.
    static let acceptableBand = 0.30...0.70
    /// A lower step wins unless a higher one is more than 1.5 dB nearer the
    /// target. Less gain recovers sooner after the radio unkeys and leaves
    /// more room for loud stations. Today's 16% sits almost exactly between
    /// +6 dB (32%) and +12 dB (64%), and +6 dB is the better choice.
    static let lowerStepPreferenceDb = 1.5

    enum Action: Equatable, Sendable {
        /// The current step is the right one.
        case keep(gain: Int)
        /// Change to this step.
        case set(gain: Int)
        /// Even the highest step leaves packets quiet: use it, and turn the
        /// radio's volume up.
        case turnVolumeUp(gain: Int)
        /// Even the lowest step leaves packets too loud: use it, and turn the
        /// radio's volume down.
        case turnVolumeDown(gain: Int)

        var gain: Int {
            switch self {
            case .keep(let g), .set(let g), .turnVolumeUp(let g), .turnVolumeDown(let g): return g
            }
        }
    }

    struct Recommendation: Equatable, Sendable {
        let action: Action
        /// What was measured, and at which step.
        let measuredVpp: Int
        let measuredGain: Int
        let measuredClipped: Bool
        /// Predicted tone level (share of full scale) at the recommended step.
        let predictedFraction: Double

        var measuredFraction: Double { Double(measuredVpp) / Double(TNC4LevelSample.fullScale) }
        var gain: Int { action.gain }
    }

    /// Tone level at `gain`, from one measured at `measuredGain`, as a share
    /// of full scale. Each step is ×2, and nothing reads above full scale.
    static func predictedFraction(vpp: Int, measuredAt measuredGain: Int, at gain: Int) -> Double {
        let scaled = Double(vpp) * pow(2, Double(gain - measuredGain))
        return min(1, scaled / Double(TNC4LevelSample.fullScale))
    }

    /// The step to use, from packet tones measured at `vpp` with the TNC4 at
    /// `measuredGain`.
    ///
    /// Among the steps predicted at or under the ceiling, picks the lowest
    /// one within `lowerStepPreferenceDb` of the nearest to the target. Less
    /// gain recovers sooner after the radio unkeys (see "The unkey jolt" in
    /// Docs/MobilinkdTNC4.md).
    static func recommend(toneVpp vpp: Int, measuredAt measuredGain: Int, clipped: Bool,
                          range: ClosedRange<Int> = 0...4) -> Recommendation {
        func result(_ action: Action) -> Recommendation {
            Recommendation(action: action, measuredVpp: vpp, measuredGain: measuredGain,
                           measuredClipped: clipped,
                           predictedFraction: predictedFraction(vpp: vpp, measuredAt: measuredGain,
                                                                at: action.gain))
        }
        // Clipped tones only say the level is at least this loud, so nothing
        // above can be predicted. Step down one and measure again.
        if clipped {
            let lower = min(max(measuredGain - 1, range.lowerBound), range.upperBound)
            return lower < measuredGain ? result(.set(gain: lower)) : result(.turnVolumeDown(gain: range.lowerBound))
        }
        guard vpp > 0 else { return result(.turnVolumeUp(gain: range.upperBound)) }
        func distance(_ step: Int) -> Double {
            abs(20 * log10(predictedFraction(vpp: vpp, measuredAt: measuredGain, at: step) / targetFraction))
        }
        let eligible = range.filter {
            predictedFraction(vpp: vpp, measuredAt: measuredGain, at: $0) <= ceilingFraction
        }
        guard let nearest = eligible.map(distance).min(),
              let best = eligible.first(where: { distance($0) <= nearest + lowerStepPreferenceDb }) else {
            return result(.turnVolumeDown(gain: range.lowerBound))
        }
        let predicted = predictedFraction(vpp: vpp, measuredAt: measuredGain, at: best)
        if best == range.upperBound, predicted < acceptableBand.lowerBound {
            return result(.turnVolumeUp(gain: best))
        }
        return result(best == measuredGain ? .keep(gain: best) : .set(gain: best))
    }

    // MARK: Words

    static func gainText(_ step: Int) -> String { step == 0 ? "0 dB" : "+\(step * 6) dB" }

    static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

    /// One line on what to do, for after "Heard ... at ...".
    static func advice(_ rec: Recommendation) -> String {
        let predicted = percent(rec.predictedFraction)
        switch rec.action {
        case .keep(let g):
            return "\(gainText(g)) is already right; they sit near \(predicted)."
        case .set(let g):
            if rec.measuredClipped {
                return "They clipped, so \(gainText(g)) is one step down. Calibrate again to check it."
            }
            return "\(gainText(g)) puts them near \(predicted)."
        case .turnVolumeUp(let g):
            return "Even \(gainText(g)) only brings them to \(predicted). Turn the radio's volume up and calibrate again."
        case .turnVolumeDown(let g):
            return rec.measuredClipped && rec.measuredGain == g
                ? "They clip even at \(gainText(g)). Turn the radio's volume down and calibrate again."
                : "Even \(gainText(g)) puts them at \(predicted). Turn the radio's volume down and calibrate again."
        }
    }
}

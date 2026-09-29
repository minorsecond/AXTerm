//
//  MobilinkdLevelAssistant.swift
//  AXTerm
//

import Foundation

/// Picks a TNC4 input gain for one radio from level readings.
///
/// The firmware has its own auto-adjust, but it saves the result to the
/// TNC4's flash (changing it for every radio) and loops forever if the input
/// clips even at the lowest gain (tnc4-firmware AudioLevel.cpp). This one only
/// decides; the caller applies the gain to the radio's profile.
///
/// It prefers the lowest gain that gives a usable level. Unkeying an IC-V8
/// pins the TNC4's input at full scale for a moment, and the higher the gain
/// the longer it takes to come back: about 3 s at the top gain, 1.5 s at the
/// bottom (measured 2026-09-29). A node's reply that lands in that window is
/// lost.
nonisolated struct MobilinkdLevelAssistant: Equatable, Sendable {

    enum Step: Equatable, Sendable {
        /// Set this gain, let the input settle, and report readings.
        case measure(gain: Int)
        /// This gain gives a good level.
        case done(gain: Int)
        /// Even the lowest gain clips: turn the radio's volume down.
        case radioTooLoud
        /// Even the highest gain is too quiet: turn the radio's volume up.
        case radioTooQuiet(bestGain: Int)
        /// One gain is too quiet and the next clips: the radio's volume sits
        /// between two steps. Use the quieter one and turn the radio up a little.
        case betweenSteps(quieterGain: Int)
    }

    /// Open-squelch noise should fill at least this much of the range.
    static let minimumFraction = 0.30
    /// The share of readings that may touch an end before it counts as clipping.
    static let clipTolerance = 0.2

    let minGain: Int
    let maxGain: Int
    private(set) var step: Step

    init(minGain: Int = 0, maxGain: Int = 4) {
        self.minGain = minGain
        self.maxGain = maxGain
        step = .measure(gain: minGain)
    }

    /// Record the readings taken at the gain `step` asked for, and move on.
    @discardableResult
    mutating func record(_ readings: [MobilinkdInputLevel]) -> Step {
        guard case .measure(let gain) = step, !readings.isEmpty else { return step }
        switch Self.judge(readings) {
        case .clipping:
            // Starting from the bottom, a clip means the gain below was too
            // quiet (or this is the bottom already).
            step = gain == minGain ? .radioTooLoud : .betweenSteps(quieterGain: gain - 1)
        case .good:
            step = .done(gain: gain)
        case .tooQuiet:
            step = gain >= maxGain ? .radioTooQuiet(bestGain: maxGain) : .measure(gain: gain + 1)
        }
        return step
    }

    enum Verdict: Equatable { case clipping, good, tooQuiet }

    static func judge(_ readings: [MobilinkdInputLevel]) -> Verdict {
        let clipped = readings.filter { $0.vmin == 0 || $0.vmax >= 65_400 }.count
        if Double(clipped) > Double(readings.count) * clipTolerance { return .clipping }
        let fractions = readings.map { Double($0.vpp) / 65_535 }.sorted()
        let median = fractions[fractions.count / 2]
        return median >= minimumFraction ? .good : .tooQuiet
    }
}

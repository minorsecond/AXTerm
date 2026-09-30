//
//  ReceiveLevelDrift.swift
//  AXTerm
//
//  Whether a radio's receive audio has moved since it was calibrated, from
//  the drift watch's short samples.
//

import Foundation

/// Compares the drift watch's samples with the calibration.
///
/// The usual cause is the radio's volume knob: bumped in a bag, turned down
/// for a phone call, or moved by someone else. The TNC4 can't see the knob,
/// only what reaches its input, and it can measure that without a second
/// radio: the input between packets (the noise floor, when the squelch is
/// open) and the tones of any packet that happens to arrive during a sample.
///
/// Every comparison takes the input gain out first. Each step is exactly
/// 6 dB, so a sample at +12 dB compares with a calibration at +6 dB by
/// subtracting one step. Readings that fill the range only bound the change:
/// noise pinned at full scale can still show the audio got quieter, never
/// that it got louder.
nonisolated enum ReceiveLevelDrift {

    /// The noise floor has to move 4 dB. With nothing touched, the noise
    /// floor of 2 s samples wandered about ±1.2 dB (30,000 to 40,000 on
    /// 2026-09-30), and 4 dB is enough to push packets from the middle of
    /// the 30-70% band past its edge.
    static let noiseShiftDb = 4.0
    /// Packet tones have to move 6 dB. Stations' deviation differs by 3 dB or
    /// so, and a sample catches whichever station happened to be on, so the
    /// tone test needs a wider margin than the noise test.
    static let toneShiftDb = 6.0
    /// Two samples in a row. One can land on a burst of interference or
    /// another station's carrier.
    static let sustainedSamples = 2
    /// And those two no more than two hours apart, so a change and a change
    /// back aren't read as one sustained shift.
    static let sustainedWithin: TimeInterval = 2 * 60 * 60
    /// More than 20% of a sample's reports touching an end of the range is
    /// clipping. The level assistant uses the same share.
    static let clipShare = 0.2
    /// Noise at 90% of full scale or more is treated as filling the range.
    static let saturatedFraction = 0.9
    /// A calibration noise floor under 5% of full scale is a closed squelch
    /// (hiss at most). Differences between two near-silences are large in
    /// dB and mean nothing, so the noise test is off for that radio and only
    /// packet tones count.
    static let openSquelchFraction = 0.05

    enum Kind: Equatable, Sendable {
        case louder
        case quieter
        /// Packet tones touched the end of the range in two samples running.
        case clipping
    }

    enum Basis: Equatable, Sendable { case noise, tones }

    /// Which way the radio's volume knob should go.
    enum VolumeTurn: Equatable, Sendable { case up, down }

    struct Finding: Equatable, Sendable {
        let kind: Kind
        let basis: Basis
        /// The newest sample's change in dB, gain taken out. Zero for clipping.
        let deltaDb: Double
        /// Both samples' changes, oldest first.
        let deltas: [Double]
        let baseline: ReceiveLevelBaseline
        /// The samples the finding rests on, oldest first.
        let samples: [ReceiveLevelObservation]
        /// The step that would put packets back where calibration had them,
        /// or nil when that is outside the TNC4's range.
        let suggestedGain: Int?
        /// Which way to turn the radio's volume when no step will do.
        let turnVolume: VolumeTurn?
    }

    static func assess(baseline: ReceiveLevelBaseline?, observations: [ReceiveLevelObservation],
                       range: ClosedRange<Int> = 0...4) -> Finding? {
        guard let baseline else { return nil }
        let recent = observations.filter { $0.at > baseline.at }.sorted { $0.at < $1.at }

        // Clipping packets beat everything else: they are lost now.
        let withTones = recent.filter { !$0.toneVpps.isEmpty }
        if let pair = lastPair(withTones), pair.allSatisfy(\.tonesClipped) {
            let gain = pair.last?.gain ?? baseline.gain
            let lower = gain - 1
            return Finding(kind: .clipping, basis: .tones, deltaDb: 0, deltas: [], baseline: baseline,
                           samples: pair, suggestedGain: range.contains(lower) ? lower : nil,
                           turnVolume: range.contains(lower) ? nil : .down)
        }

        let noise = recent.compactMap { obs in noiseDelta(obs, baseline: baseline).map { (obs, $0) } }
        if let finding = sustained(noise, threshold: noiseShiftDb, basis: .noise, baseline: baseline, range: range) {
            return finding
        }
        let tones = recent.compactMap { obs in toneDelta(obs, baseline: baseline).map { (obs, $0) } }
        return sustained(tones, threshold: toneShiftDb, basis: .tones, baseline: baseline, range: range)
    }

    /// The noise floor's change in dB against the baseline, gain taken out.
    /// Nil when the two can't be compared.
    static func noiseDelta(_ obs: ReceiveLevelObservation, baseline: ReceiveLevelBaseline) -> Double? {
        guard let base = baseline.noiseVpp, base > 0,
              Double(base) >= openSquelchFraction * Double(TNC4LevelSample.fullScale) else { return nil }
        let reading = Double(obs.noiseVpp ?? TNC4LevelSample.fullScale)
        guard reading > 0 else { return nil }
        let delta = dB(reading, over: Double(base)) - stepDb * Double(obs.gain - baseline.gain)
        switch (obs.noiseSaturated, baseline.noiseSaturated) {
        case (false, false): return delta
        // Only a lower bound on how much louder; useful only if louder.
        case (true, false): return delta > 0 ? delta : nil
        // Only an upper bound on the change; useful only if quieter.
        case (false, true): return delta < 0 ? delta : nil
        case (true, true): return nil
        }
    }

    /// The packets' change in dB against the baseline, gain taken out.
    static func toneDelta(_ obs: ReceiveLevelObservation, baseline: ReceiveLevelBaseline) -> Double? {
        guard let base = baseline.toneVpp, base > 0,
              let tone = PacketToneSignature.median(obs.toneVpps), tone > 0 else { return nil }
        let delta = dB(Double(tone), over: Double(base)) - stepDb * Double(obs.gain - baseline.gain)
        // Clipped tones are at least this loud.
        if obs.tonesClipped { return delta > 0 ? delta : nil }
        return delta
    }

    static let stepDb = 20 * log10(2.0)

    static func dB(_ value: Double, over reference: Double) -> Double {
        20 * log10(value / reference)
    }

    private static func lastPair(_ observations: [ReceiveLevelObservation]) -> [ReceiveLevelObservation]? {
        guard observations.count >= sustainedSamples else { return nil }
        let pair = Array(observations.suffix(sustainedSamples))
        guard let first = pair.first, let last = pair.last,
              last.at.timeIntervalSince(first.at) <= sustainedWithin else { return nil }
        return pair
    }

    private static func sustained(_ readings: [(ReceiveLevelObservation, Double)], threshold: Double,
                                  basis: Basis, baseline: ReceiveLevelBaseline,
                                  range: ClosedRange<Int>) -> Finding? {
        guard let pair = lastPair(readings.map(\.0)) else { return nil }
        let deltas = readings.suffix(sustainedSamples).map(\.1)
        let louder = deltas.allSatisfy { $0 >= threshold }
        let quieter = deltas.allSatisfy { $0 <= -threshold }
        guard louder || quieter, let latest = deltas.last else { return nil }
        // Each 6 dB of change is one step the other way.
        let target = baseline.gain - Int((latest / stepDb).rounded())
        let inRange = range.contains(target)
        return Finding(kind: louder ? .louder : .quieter, basis: basis, deltaDb: latest, deltas: deltas,
                       baseline: baseline, samples: pair,
                       suggestedGain: inRange ? target : nil,
                       turnVolume: inRange ? nil : (louder ? .down : .up))
    }
}

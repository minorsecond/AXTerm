//
//  ReceiveLevelAnalysis.swift
//  AXTerm
//
//  From a level recording to what the receive-level tuner keeps and says:
//  packets found, the noise floor, a calibration result, a baseline, and the
//  passive recommendation built from packets the drift watch happened to
//  catch.
//

import Foundation

nonisolated enum ReceiveLevelAnalysis {

    /// Reports within 3 s of the end of our own transmission are left out
    /// of the noise floor. Unkeying an IC-V8 pins the TNC4's input for up to
    /// 2.7 s (Docs/MobilinkdTNC4.md, "The unkey jolt"); packets in that time
    /// still count, since the tone test doesn't depend on the floor there.
    static let unkeySettleSeconds = 3.0
    /// A noise floor needs at least half a second of clean reports.
    static let minimumNoiseReports = 5
    /// Three packets before a passive recommendation. One station's
    /// deviation shouldn't set the gain for the channel.
    static let passiveMinimumPackets = 3
    /// Packets older than a day are forgotten for the passive recommendation;
    /// the radio or its volume has likely changed since.
    static let passiveMaxAge: TimeInterval = 24 * 60 * 60

    /// What one recording shows.
    struct Reading: Equatable, Sendable {
        let segments: [PacketToneSignature.Segment]
        /// Median between packets, or nil with too few clean reports.
        let noiseVpp: Int?
        /// Share of the reports considered for noise that clipped.
        let clippedShare: Double
        let reports: Int

        var toneVpp: Int? { PacketToneSignature.toneLevel(of: segments) }
        var tonesClipped: Bool { segments.contains(where: \.clipped) }
    }

    /// Read a recording. Reports before `quietFrom` (seconds, on the
    /// recording's own clock) count for packets but not for noise.
    static func read(_ samples: [TNC4LevelSample], quietFrom: Double? = nil) -> Reading {
        let segments = PacketToneSignature.segments(in: samples)
        let considered = samples.filter { quietFrom == nil || $0.t >= quietFrom! }
        let clipped = considered.filter(\.clipped).count
        let share = considered.isEmpty ? 0 : Double(clipped) / Double(considered.count)
        let clean = considered.filter { s in
            !s.clipped && !segments.contains { s.t >= $0.start && s.t <= $0.end }
        }
        let noise = clean.count >= minimumNoiseReports ? PacketToneSignature.median(clean.map(\.vpp)) : nil
        return Reading(segments: segments, noiseVpp: noise, clippedShare: share, reports: samples.count)
    }

    static func observation(_ reading: Reading, at date: Date, gain: Int) -> ReceiveLevelObservation {
        ReceiveLevelObservation(at: date, gain: gain, noiseVpp: reading.noiseVpp,
                                clippedShare: reading.clippedShare,
                                toneVpps: reading.segments.map(\.toneVpp),
                                tonesClipped: reading.tonesClipped)
    }

    static func packetLevels(_ reading: Reading, at date: Date, gain: Int) -> [PacketLevelObservation] {
        reading.segments.map { PacketLevelObservation(at: date, gain: gain, toneVpp: $0.toneVpp, clipped: $0.clipped) }
    }

    // MARK: Calibration

    enum Calibration: Equatable, Sendable {
        /// Heard `packets` packets; here is what to do.
        case recommend(ReceiveGainAdvice.Recommendation, packets: Int, noiseVpp: Int?)
        /// Reports came in, but no packet among them.
        case nothingHeard(reports: Int)
        /// The TNC4 sent no level reports at all.
        case noReports
    }

    static func calibrate(_ reading: Reading, gain: Int, range: ClosedRange<Int>) -> Calibration {
        guard reading.reports > 0 else { return .noReports }
        guard let tone = reading.toneVpp else { return .nothingHeard(reports: reading.reports) }
        let rec = ReceiveGainAdvice.recommend(toneVpp: tone, measuredAt: gain,
                                              clipped: reading.tonesClipped, range: range)
        return .recommend(rec, packets: reading.segments.count, noiseVpp: reading.noiseVpp)
    }

    /// The baseline a recommendation leaves behind, with the measured levels
    /// carried to the recommended step (×2 per step).
    static func baseline(_ rec: ReceiveGainAdvice.Recommendation, packets: Int, noiseVpp: Int?,
                         at date: Date, source: ReceiveLevelBaseline.Source) -> ReceiveLevelBaseline {
        let shift = pow(2, Double(rec.gain - rec.measuredGain))
        let full = Double(TNC4LevelSample.fullScale)
        let tone = rec.measuredClipped ? nil : Int(min(full, Double(rec.measuredVpp) * shift))
        var noise: Int?
        var saturated = false
        if let noiseVpp {
            let projected = Double(noiseVpp) * shift
            saturated = projected >= ReceiveLevelDrift.saturatedFraction * full
            noise = Int(min(full, projected))
        }
        return ReceiveLevelBaseline(at: date, gain: rec.gain, toneVpp: tone, noiseVpp: noise,
                                    noiseSaturated: saturated, source: source, packets: packets)
    }

    /// Fill a baseline's missing noise floor from the first sample taken at
    /// its gain. Returns nil when there is nothing to fill.
    static func completing(_ baseline: ReceiveLevelBaseline,
                           with obs: ReceiveLevelObservation) -> ReceiveLevelBaseline? {
        guard baseline.noiseVpp == nil, obs.gain == baseline.gain, obs.at > baseline.at else { return nil }
        var filled = baseline
        filled.noiseVpp = obs.noiseVpp ?? TNC4LevelSample.fullScale
        filled.noiseSaturated = obs.noiseSaturated
        return filled
    }

    // MARK: Passive

    struct Passive: Equatable, Sendable {
        let recommendation: ReceiveGainAdvice.Recommendation
        let packets: Int
        let since: Date
    }

    /// A recommendation from packets caught in drift-watch samples, with
    /// every level carried to `currentGain`. Nil with fewer than
    /// `passiveMinimumPackets` in the last day.
    static func passive(_ levels: [PacketLevelObservation], currentGain: Int,
                        range: ClosedRange<Int>, now: Date) -> Passive? {
        let recent = levels.filter { now.timeIntervalSince($0.at) <= passiveMaxAge }
        guard recent.count >= passiveMinimumPackets, let first = recent.map(\.at).min() else { return nil }
        let full = Double(TNC4LevelSample.fullScale)
        let carried = recent.map { Int(min(full, Double($0.toneVpp) * pow(2, Double(currentGain - $0.gain)))) }
        guard let median = PacketToneSignature.median(carried) else { return nil }
        let clipped = recent.filter(\.clipped).count * 2 > recent.count
        let rec = ReceiveGainAdvice.recommend(toneVpp: median, measuredAt: currentGain, clipped: clipped, range: range)
        return Passive(recommendation: rec, packets: recent.count, since: first)
    }
}

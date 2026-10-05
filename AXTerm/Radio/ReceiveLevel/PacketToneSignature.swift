//
//  PacketToneSignature.swift
//  AXTerm
//
//  Finds packets in a TNC4 level recording by the shape they leave, and
//  reads how loud their tones arrived. See Docs/MobilinkdTNC4.md,
//  "Receive-level calibration".
//

import Foundation

/// Picks packets out of a series of TNC4 level reports.
///
/// On 2026-09-30, with an IC-V8's squelch open on 144.390, every packet left
/// the same trace in the level stream: open-squelch noise at 30,000 to 40,000
/// (about 55% of full scale), then the sending station's carrier quieting it
/// to almost nothing (vpp about 560), then the AFSK tones at a steady, lower
/// level (about 10,500, 16%) for the half second to a second the packet
/// lasts, then noise again. With the squelch closed the noise is missing and
/// the trace is silence, tones, silence. Either way the tones are a steady
/// run that starts right after a much quieter moment, and that is what this
/// looks for:
///
/// 1. A run of reports that stay within `steadiness` of the run's median.
///    AFSK has a constant envelope, so its peak-to-peak barely moves.
/// 2. Preceded, within `carrierLookback` reports, by one at or below
///    `carrierRatio` of the run's level: the carrier, or a closed squelch.
/// 3. Between `minimumReports` and `maximumDuration` long.
/// 4. Clearly apart from the recording's noise floor (`floorSeparation`), so
///    open-squelch noise returning after a carrier drops isn't taken for
///    tones.
///
/// The rules are ratios, so they hold at any input gain: each 6 dB step
/// doubles the carrier, the tones and the noise alike.
nonisolated enum PacketToneSignature {

    /// One packet's tones.
    struct Segment: Equatable, Sendable {
        /// Time of the first and last tone reports.
        let start: Double
        let end: Double
        let reports: Int
        /// Median peak-to-peak of the tone reports.
        let toneVpp: Int
        /// Peak-to-peak of the quiet report before the tones.
        let carrierVpp: Int
        /// A tone report touched an end of the ADC's range, so `toneVpp`
        /// understates the real level.
        let clipped: Bool
        /// The packet's first report touched an end of the range. It is the
        /// onset and is left out of `toneVpp` and `clipped` (see
        /// `onsetReports`); kept so the evidence can say so.
        var onsetClipped: Bool = false

        var toneFraction: Double { Double(toneVpp) / Double(TNC4LevelSample.fullScale) }
        var duration: Double { end - start }
    }

    /// The quiet report before the tones is at most this share of the tone
    /// level (-16.5 dB). Today's carrier sat 25 dB under the tones and a
    /// closed squelch's hiss about 30 dB under. The margin matters the other
    /// way too: the tones that end a packet were 10 dB under the noise that
    /// followed, and must not pass for the carrier before a run of noise.
    static let carrierRatio = 0.15
    /// Every tone report within ±30% of the run's median (about ±2.5 dB).
    /// The 100 ms reports of one packet varied by a few percent; open-squelch
    /// noise wandered ±13% and is caught by the floor test instead.
    static let steadiness = 0.30
    /// Three reports, 0.3 s. The shortest APRS frame worth hearing, a bare
    /// status with a 150 ms preamble, takes about that long at 1200 baud.
    static let minimumReports = 3
    /// Four seconds. A 256-byte frame with a 500 ms preamble takes 2.3 s; a
    /// steady run much longer than that is a carrier with a tone on it, or
    /// someone's voice, not a packet.
    static let maximumDuration = 4.0
    /// The key-up of a carrier can smear into the first 100 ms report, so the
    /// quiet report may sit one report further back.
    static let carrierLookback = 2
    /// The start of the tones is a transient as well. On 2026-10-04 every
    /// packet from an IC-705 reached an ID-50's TNC4 with its first 100 ms
    /// report swinging about twice as wide as the tones after it, off
    /// center; at +24 dB that report touched the top rail while the tones sat
    /// at 54% with room on both sides. So a packet longer than the minimum
    /// takes its level, and whether it clipped, from the reports after the
    /// first. Tones that are really too loud clip in every report.
    static let onsetReports = 1
    /// Tones at least 15% (about 1.4 dB) away from the level between packets.
    /// This is what rejects the noise that comes back after a carrier
    /// with no data on it: a run of that noise has the same median as the
    /// rest of the noise to within a few percent. Real tones were 10 dB under
    /// the open-squelch noise today, far outside this.
    static let floorSeparation = 0.15

    static func segments(in samples: [TNC4LevelSample]) -> [Segment] {
        let candidates = candidateRuns(in: samples)
        // What the input sits at between packets: the clean reports outside
        // the candidates. Clipped reports are left out because an input
        // pinned at one end (the IC-V8's unkey jolt) reads as a small
        // peak-to-peak and would drag the floor down to the tones. When
        // open-squelch noise fills the range at a high gain, what is left is
        // the carriers, which is the right answer too: tones are far above.
        let floor = noiseFloor(in: samples, excluding: candidates) ?? median(samples.map(\.vpp))
        return candidates.filter { segment in
            guard let floor, floor > 0 else { return true }
            return abs(Double(segment.toneVpp) - Double(floor)) >= floorSeparation * Double(floor)
        }
    }

    /// Median peak-to-peak of the reports that are neither tones nor
    /// clipped: what the input sits at between packets. Nil when nothing is
    /// left to take it from.
    static func noiseFloor(in samples: [TNC4LevelSample], excluding segments: [Segment]) -> Int? {
        let quiet = samples.filter { sample in
            !sample.clipped && !segments.contains { sample.t >= $0.start && sample.t <= $0.end }
        }
        return median(quiet.map(\.vpp))
    }

    /// The median tone level across `segments`, or nil for none.
    static func toneLevel(of segments: [Segment]) -> Int? {
        median(segments.map(\.toneVpp))
    }

    // MARK: Internals

    private static func candidateRuns(in samples: [TNC4LevelSample]) -> [Segment] {
        var found: [Segment] = []
        var i = 0
        while i < samples.count {
            guard samples[i].vpp > 0 else { i += 1; continue }
            // Clipped reports may join a run: tones that hit the end of the
            // range are still tones, and saying so is the point.
            var run = [samples[i].vpp]
            var j = i + 1
            while j < samples.count {
                let level = Double(median(run) ?? samples[i].vpp)
                guard abs(Double(samples[j].vpp) - level) <= steadiness * level else { break }
                run.append(samples[j].vpp)
                j += 1
            }
            let level = median(run) ?? samples[i].vpp
            let duration = samples[j - 1].t - samples[i].t
            // The quiet report must itself be clean: an input pinned at one
            // end (the IC-V8's unkey jolt) can read as a small peak-to-peak.
            let carrier = (max(0, i - carrierLookback)..<i)
                .map { samples[$0] }
                .filter { !$0.clipped && Double($0.vpp) <= carrierRatio * Double(level) }
                .min { $0.vpp < $1.vpp }
            if run.count >= minimumReports, duration <= maximumDuration, let carrier {
                // Past the onset, when enough is left to stand on its own.
                let body = run.count > minimumReports ? (i + onsetReports)..<j : i..<j
                found.append(Segment(start: samples[i].t, end: samples[j - 1].t, reports: run.count,
                                     toneVpp: median(samples[body].map(\.vpp)) ?? level,
                                     carrierVpp: carrier.vpp,
                                     clipped: samples[body].contains(where: \.clipped),
                                     onsetClipped: body.lowerBound > i && samples[i].clipped))
                i = j
            } else {
                i += 1
            }
        }
        return found
    }

    static func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }
}

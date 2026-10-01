//
//  LevelSeries.swift
//  AXTermTests
//
//  Synthetic TNC4 level recordings built from the numbers measured on
//  2026-09-30 (IC-V8, squelch open, 144.390, input gain 0): open-squelch
//  noise 30,000 to 40,000, a carrier at about 560, packet tones at about
//  10,500, ten reports a second.
//

import Foundation
@testable import AXTerm

struct LevelSeries {
    private(set) var samples: [TNC4LevelSample] = []
    private var t = 0.0
    private var rng: UInt64

    static let step = 0.1
    static let noiseRange = 30_000...40_000
    static let carrier = 560
    static let tone = 10_500

    init(seed: UInt64 = 1) { rng = seed }

    /// Deterministic 0..<1.
    private mutating func next() -> Double {
        rng = rng &* 6364136223846793005 &+ 1442695040888963407
        return Double(rng >> 11) / Double(1 << 53)
    }

    private mutating func add(_ level: Int, clipped wasClipped: Bool = false) {
        // More than the ADC can hold reads as full scale, clipped.
        let vpp = min(level, TNC4LevelSample.fullScale)
        let clipped = wasClipped || level >= 65_400
        let center = 32_768
        let half = vpp / 2
        let vmin = clipped ? 0 : max(1, center - half)
        let vmax = clipped ? TNC4LevelSample.fullScale : min(65_399, center + half)
        samples.append(TNC4LevelSample(t: t, vpp: vpp, vmin: vmin, vmax: vmax))
        t += Self.step
    }

    /// Open-squelch noise with jitter across the measured range.
    mutating func noise(_ seconds: Double, scale: Double = 1) {
        for _ in 0..<Int((seconds / Self.step).rounded()) {
            let span = Double(Self.noiseRange.upperBound - Self.noiseRange.lowerBound)
            add(Int((Double(Self.noiseRange.lowerBound) + next() * span) * scale))
        }
    }

    /// A closed squelch: hiss at a few hundred.
    mutating func silence(_ seconds: Double, scale: Double = 1) {
        for _ in 0..<Int((seconds / Self.step).rounded()) { add(Int((200 + next() * 150) * scale)) }
    }

    /// One packet: carrier, then tones within ±3%.
    mutating func packet(tone: Int = LevelSeries.tone, seconds: Double = 0.7,
                         carrierReports: Int = 2, scale: Double = 1, clipped: Bool = false) {
        for _ in 0..<carrierReports { add(Int(Double(Self.carrier) * scale * (0.9 + next() * 0.2))) }
        for _ in 0..<Int((seconds / Self.step).rounded()) {
            add(Int(Double(tone) * scale * (0.97 + next() * 0.06)), clipped: clipped)
        }
    }

    /// Reports pinned at one end, as after an IC-V8 unkeys.
    mutating func pinned(_ seconds: Double) {
        for _ in 0..<Int((seconds / Self.step).rounded()) {
            samples.append(TNC4LevelSample(t: t, vpp: 900, vmin: 64_600, vmax: TNC4LevelSample.fullScale))
            t += Self.step
        }
    }
}

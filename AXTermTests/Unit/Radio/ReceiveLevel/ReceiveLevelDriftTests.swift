//
//  ReceiveLevelDriftTests.swift
//  AXTermTests
//
//  The drift watch's rules: a sustained 4 dB move of the noise floor, a
//  6 dB move of packet tones, clipping packets, with gain steps taken out
//  and pinned readings used only for what they can show.
//

import XCTest
@testable import AXTerm

final class ReceiveLevelDriftTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    private func baseline(gain: Int = 1, tone: Int? = 21_000, noise: Int? = 20_000,
                          saturated: Bool = false) -> ReceiveLevelBaseline {
        ReceiveLevelBaseline(at: t0, gain: gain, toneVpp: tone, noiseVpp: noise, noiseSaturated: saturated,
                             source: .beacon, packets: 2)
    }

    private func obs(_ minutes: Double, gain: Int = 1, noise: Int?, clipped: Double = 0,
                     tones: [Int] = [], tonesClipped: Bool = false) -> ReceiveLevelObservation {
        ReceiveLevelObservation(at: at(minutes), gain: gain, noiseVpp: noise, clippedShare: clipped,
                                toneVpps: tones, tonesClipped: tonesClipped)
    }

    private func scaled(_ value: Int, dB: Double) -> Int { Int(Double(value) * pow(10, dB / 20)) }

    func testNothingWithoutABaseline() {
        XCTAssertNil(ReceiveLevelDrift.assess(baseline: nil, observations: [obs(30, noise: 60_000), obs(60, noise: 60_000)]))
    }

    func testSmallWanderIsNothing() {
        let b = baseline()
        let o = [obs(30, noise: scaled(20_000, dB: 3)), obs(60, noise: scaled(20_000, dB: -2))]
        XCTAssertNil(ReceiveLevelDrift.assess(baseline: b, observations: o))
    }

    func testOneLoudSampleIsNotSustained() {
        let b = baseline()
        let o = [obs(30, noise: 20_000), obs(60, noise: scaled(20_000, dB: 8))]
        XCTAssertNil(ReceiveLevelDrift.assess(baseline: b, observations: o))
    }

    func testTwoLouderSamplesAreAFinding() throws {
        let b = baseline()
        let o = [obs(30, noise: scaled(20_000, dB: 8)), obs(60, noise: scaled(20_000, dB: 8.2))]
        let f = try XCTUnwrap(ReceiveLevelDrift.assess(baseline: b, observations: o))
        XCTAssertEqual(f.kind, .louder)
        XCTAssertEqual(f.basis, .noise)
        XCTAssertEqual(f.deltaDb, 8.2, accuracy: 0.1)
        XCTAssertEqual(f.deltas.count, 2)
        // 8 dB louder is about one step: +6 dB back to 0 dB.
        XCTAssertEqual(f.suggestedGain, 0)
        XCTAssertNil(f.turnVolume)
    }

    func testJustUnderTheThresholdIsNothing() {
        let b = baseline()
        let o = [obs(30, noise: scaled(20_000, dB: 3.9)), obs(60, noise: scaled(20_000, dB: 5))]
        XCTAssertNil(ReceiveLevelDrift.assess(baseline: b, observations: o))
    }

    func testMixedDirectionsAreNothing() {
        let b = baseline()
        let o = [obs(30, noise: scaled(20_000, dB: 6)), obs(60, noise: scaled(20_000, dB: -6))]
        XCTAssertNil(ReceiveLevelDrift.assess(baseline: b, observations: o))
    }

    func testSamplesFarApartAreNotSustained() {
        let b = baseline()
        let o = [obs(30, noise: scaled(20_000, dB: 8)), obs(200, noise: scaled(20_000, dB: 8))]
        XCTAssertNil(ReceiveLevelDrift.assess(baseline: b, observations: o))
    }

    /// A sample one step higher reads 6 dB more for the same audio.
    func testGainStepsAreTakenOut() {
        let b = baseline(gain: 1)
        let same = [obs(30, gain: 2, noise: 40_000), obs(60, gain: 2, noise: 40_500)]
        XCTAssertNil(ReceiveLevelDrift.assess(baseline: b, observations: same))
        let quieter = [obs(30, gain: 2, noise: 20_000), obs(60, gain: 2, noise: 20_000)]
        XCTAssertEqual(ReceiveLevelDrift.assess(baseline: b, observations: quieter)?.kind, .quieter)
    }

    func testObservationsBeforeTheBaselineDontCount() {
        let b = baseline()
        let o = [obs(-60, noise: 60_000), obs(-30, noise: 60_000)]
        XCTAssertNil(ReceiveLevelDrift.assess(baseline: b, observations: o))
    }

    /// Noise pinned at full scale can only show the audio got louder.
    func testSaturatedSamplesCountOnlyAsLouder() throws {
        let b = baseline(noise: 20_000)
        let pinned = [obs(30, noise: 65_000, clipped: 0.6), obs(60, noise: nil, clipped: 1)]
        let f = try XCTUnwrap(ReceiveLevelDrift.assess(baseline: b, observations: pinned))
        XCTAssertEqual(f.kind, .louder)
        XCTAssertGreaterThanOrEqual(f.deltaDb, 4)
    }

    /// A saturated baseline can only show the audio got quieter.
    func testASaturatedBaselineShowsOnlyQuieter() {
        let b = baseline(noise: 65_535, saturated: true)
        let same = [obs(30, noise: 65_535, clipped: 0.8), obs(60, noise: 65_535, clipped: 0.8)]
        XCTAssertNil(ReceiveLevelDrift.assess(baseline: b, observations: same))
        let quieter = [obs(30, noise: 20_000), obs(60, noise: 21_000)]
        XCTAssertEqual(ReceiveLevelDrift.assess(baseline: b, observations: quieter)?.kind, .quieter)
    }

    /// With the squelch closed at calibration the noise test is off; packets
    /// still count, with a wider margin.
    func testClosedSquelchUsesTonesOnly() throws {
        let b = baseline(tone: 21_000, noise: 400)
        let noisy = [obs(30, noise: 4_000), obs(60, noise: 4_000)]
        XCTAssertNil(ReceiveLevelDrift.assess(baseline: b, observations: noisy))
        let tones = [obs(30, noise: 400, tones: [scaled(21_000, dB: -7)]),
                     obs(60, noise: 400, tones: [scaled(21_000, dB: -7.5)])]
        let f = try XCTUnwrap(ReceiveLevelDrift.assess(baseline: b, observations: tones))
        XCTAssertEqual(f.kind, .quieter)
        XCTAssertEqual(f.basis, .tones)
    }

    func testTonesUnderSixDbAreNothing() {
        let b = baseline(tone: 21_000, noise: 400)
        let tones = [obs(30, noise: 400, tones: [scaled(21_000, dB: 5)]),
                     obs(60, noise: 400, tones: [scaled(21_000, dB: 5)])]
        XCTAssertNil(ReceiveLevelDrift.assess(baseline: b, observations: tones))
    }

    func testClippingPacketsAreAFinding() throws {
        let b = baseline(gain: 2)
        let o = [obs(30, gain: 2, noise: 20_000, tones: [65_535], tonesClipped: true),
                 obs(90, gain: 2, noise: 20_000),
                 obs(100, gain: 2, noise: 20_000, tones: [65_535], tonesClipped: true)]
        let f = try XCTUnwrap(ReceiveLevelDrift.assess(baseline: b, observations: o))
        XCTAssertEqual(f.kind, .clipping)
        XCTAssertEqual(f.suggestedGain, 1)
    }

    func testClippingAtTheBottomSaysTurnTheVolumeDown() throws {
        let b = baseline(gain: 0)
        let o = [obs(30, gain: 0, noise: 20_000, tones: [65_535], tonesClipped: true),
                 obs(60, gain: 0, noise: 20_000, tones: [65_535], tonesClipped: true)]
        let f = try XCTUnwrap(ReceiveLevelDrift.assess(baseline: b, observations: o))
        XCTAssertNil(f.suggestedGain)
        XCTAssertEqual(f.turnVolume, .down)
    }

    /// 14 dB louder at 0 dB needs a step below the bottom.
    func testOutOfRangeSaysWhichWayToTurnTheVolume() throws {
        let b = baseline(gain: 0, noise: 10_000)
        let o = [obs(30, gain: 0, noise: scaled(10_000, dB: 14)), obs(60, gain: 0, noise: scaled(10_000, dB: 14))]
        let f = try XCTUnwrap(ReceiveLevelDrift.assess(baseline: b, observations: o))
        XCTAssertEqual(f.kind, .louder)
        XCTAssertNil(f.suggestedGain)
        XCTAssertEqual(f.turnVolume, .down)

        let quiet = baseline(gain: 4, noise: 30_000)
        let q = [obs(30, gain: 4, noise: scaled(30_000, dB: -13)), obs(60, gain: 4, noise: scaled(30_000, dB: -13))]
        XCTAssertEqual(ReceiveLevelDrift.assess(baseline: quiet, observations: q)?.turnVolume, .up)
    }

    // MARK: The words

    func testLouderMessageAndEvidence() throws {
        let b = baseline()
        let o = [obs(30, noise: scaled(20_000, dB: 8)), obs(60, noise: scaled(20_000, dB: 8))]
        let f = try XCTUnwrap(ReceiveLevelDrift.assess(baseline: b, observations: o))
        let finding = ReceiveLevelFinding.level(f, radioName: "TNC4 Mobilinkd", onAPRS: true,
                                                time: { _ in "10:05" })
        XCTAssertEqual(finding.message,
                       "Receive audio on TNC4 Mobilinkd is about 8 dB louder than when calibrated at 10:05. The volume may have been moved.")
        XCTAssertEqual(finding.retune, .calibrate)
        XCTAssertTrue(finding.evidence.contains { $0.hasPrefix("Calibrated at 10:05 from 2 digipeats at +6 dB") })
        XCTAssertTrue(finding.evidence.contains { $0.hasPrefix("Rule: two checks in a row at least 4 dB") })
        XCTAssertFalse(finding.message.contains("\u{2014}"))
    }

    func testPacketChannelFindingOffersTheGain() throws {
        let b = baseline()
        let o = [obs(30, noise: scaled(20_000, dB: 8)), obs(60, noise: scaled(20_000, dB: 8))]
        let f = try XCTUnwrap(ReceiveLevelDrift.assess(baseline: b, observations: o))
        XCTAssertEqual(ReceiveLevelFinding.level(f, radioName: "R", onAPRS: false).retune, .useGain(0))
    }

    func testVeryQuietMentionsTheSquelch() throws {
        let b = baseline(noise: 30_000)
        let o = [obs(30, noise: 2_000), obs(60, noise: 2_100)]
        let f = try XCTUnwrap(ReceiveLevelDrift.assess(baseline: b, observations: o))
        let text = ReceiveLevelFinding.level(f, radioName: "R", onAPRS: true, time: { _ in "9:00" }).message
        XCTAssertTrue(text.contains("quieter"))
        XCTAssertTrue(text.contains("squelch closed"))
    }

    // MARK: Pinned input, no calibration

    /// Field case 2026-10-01: a TNC4 at +24 dB with no calibration found
    /// every report at the end of the range in every check, and nothing was
    /// said. With no calibration to compare against, a pinned input is still
    /// wrong on its own terms.
    func testTwoPinnedChecksInARowArePinned() {
        let o = [obs(30, gain: 4, noise: nil, clipped: 1), obs(64, gain: 4, noise: nil, clipped: 1)]
        let pinned = ReceiveLevelDrift.assessUncalibrated(observations: o)
        XCTAssertEqual(pinned?.samples, o)
        XCTAssertEqual(pinned?.gain, 4)
    }

    func testOnePinnedCheckIsNotEnough() {
        XCTAssertNil(ReceiveLevelDrift.assessUncalibrated(observations: [obs(30, noise: nil, clipped: 1)]))
    }

    /// The newest two decide: a pinned check followed by a good one is fixed.
    func testAGoodCheckAfterAPinnedOneClearsIt() {
        let o = [obs(30, noise: nil, clipped: 1), obs(64, noise: nil, clipped: 1), obs(98, noise: 30_000, clipped: 0)]
        XCTAssertNil(ReceiveLevelDrift.assessUncalibrated(observations: o))
    }

    /// The same 20% share the drift rules and the level assistant use.
    func testAFewClippedReportsAreNotPinned() {
        let o = [obs(30, noise: 50_000, clipped: 0.15), obs(64, noise: 50_000, clipped: 0.2)]
        XCTAssertNil(ReceiveLevelDrift.assessUncalibrated(observations: o))
    }

    /// Two checks far apart are two separate events, not a sustained level.
    func testPinnedChecksHoursApartDoNotCount() {
        let o = [obs(30, noise: nil, clipped: 1), obs(30 + 3 * 60, noise: nil, clipped: 1)]
        XCTAssertNil(ReceiveLevelDrift.assessUncalibrated(observations: o))
    }
}

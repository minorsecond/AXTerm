//
//  ReceiveGainAdviceTests.swift
//  AXTermTests
//
//  The input gain step from a measured packet level: predicted ×2 per step,
//  aimed at 45%, never above 80%, and "turn the volume" when no step will do.
//

import XCTest
@testable import AXTerm

final class ReceiveGainAdviceTests: XCTestCase {

    private let full = 65_535

    private func vpp(_ fraction: Double) -> Int { Int(fraction * Double(full)) }

    func testPredictionDoublesPerStepAndCapsAtFullScale() {
        XCTAssertEqual(ReceiveGainAdvice.predictedFraction(vpp: 10_500, measuredAt: 0, at: 1), 0.32, accuracy: 0.005)
        XCTAssertEqual(ReceiveGainAdvice.predictedFraction(vpp: 10_500, measuredAt: 0, at: 2), 0.64, accuracy: 0.005)
        XCTAssertEqual(ReceiveGainAdvice.predictedFraction(vpp: 10_500, measuredAt: 0, at: 4), 1.0)
        XCTAssertEqual(ReceiveGainAdvice.predictedFraction(vpp: 20_000, measuredAt: 2, at: 1), 10_000 / 65_535, accuracy: 0.001)
    }

    /// Today's packets: 16% at 0 dB. +6 dB (32%) and +12 dB (64%) are about
    /// equally far from 45%; the lower one wins.
    func testTodaysPacketsGoUpOneStep() {
        let rec = ReceiveGainAdvice.recommend(toneVpp: 10_500, measuredAt: 0, clipped: false)
        XCTAssertEqual(rec.action, .set(gain: 1))
        XCTAssertEqual(rec.predictedFraction, 0.32, accuracy: 0.005)
        XCTAssertEqual(ReceiveGainAdvice.advice(rec), "+6 dB puts them near 32%.")
    }

    /// The lower step wins only while it is within 1.5 dB of the nearest.
    func testLowerStepPreferenceHasALimit() {
        XCTAssertEqual(ReceiveGainAdvice.recommend(toneVpp: vpp(0.155), measuredAt: 0, clipped: false).gain, 1)
        XCTAssertEqual(ReceiveGainAdvice.recommend(toneVpp: vpp(0.13), measuredAt: 0, clipped: false).gain, 2)
    }

    func testAlreadyRightIsKept() {
        let rec = ReceiveGainAdvice.recommend(toneVpp: vpp(0.45), measuredAt: 2, clipped: false)
        XCTAssertEqual(rec.action, .keep(gain: 2))
    }

    func testTooLoudStepsDown() {
        let rec = ReceiveGainAdvice.recommend(toneVpp: vpp(0.75), measuredAt: 3, clipped: false)
        XCTAssertEqual(rec.action, .set(gain: 2))
        XCTAssertEqual(rec.predictedFraction, 0.375, accuracy: 0.005)
    }

    func testNeverPicksAStepAboveTheCeiling() {
        // 21% at 0: +6 → 42% (0.1 dB from target), fine; now 11% at 0:
        // +12 → 44%, +18 → 88% is over the ceiling and never chosen.
        let rec = ReceiveGainAdvice.recommend(toneVpp: vpp(0.11), measuredAt: 0, clipped: false)
        XCTAssertEqual(rec.gain, 2)
        for step in 0...4 {
            let r = ReceiveGainAdvice.recommend(toneVpp: vpp(0.30), measuredAt: step, clipped: false, range: 0...4)
            XCTAssertLessThanOrEqual(r.predictedFraction, ReceiveGainAdvice.ceilingFraction)
        }
    }

    func testTooQuietEvenAtTheTopSaysTurnTheVolumeUp() {
        let rec = ReceiveGainAdvice.recommend(toneVpp: vpp(0.01), measuredAt: 0, clipped: false)
        XCTAssertEqual(rec.action, .turnVolumeUp(gain: 4))
        XCTAssertTrue(ReceiveGainAdvice.advice(rec).contains("Turn the radio's volume up"))
    }

    func testTooLoudEvenAtTheBottomSaysTurnTheVolumeDown() {
        let rec = ReceiveGainAdvice.recommend(toneVpp: vpp(0.9), measuredAt: 0, clipped: false)
        XCTAssertEqual(rec.action, .turnVolumeDown(gain: 0))
        XCTAssertTrue(ReceiveGainAdvice.advice(rec).contains("Turn the radio's volume down"))
    }

    func testClippedStepsDownOne() {
        let rec = ReceiveGainAdvice.recommend(toneVpp: 65_535, measuredAt: 3, clipped: true)
        XCTAssertEqual(rec.action, .set(gain: 2))
        XCTAssertTrue(ReceiveGainAdvice.advice(rec).contains("Calibrate again"))
    }

    func testClippedAtTheBottomSaysTurnTheVolumeDown() {
        let rec = ReceiveGainAdvice.recommend(toneVpp: 65_535, measuredAt: 0, clipped: true)
        XCTAssertEqual(rec.action, .turnVolumeDown(gain: 0))
        XCTAssertEqual(ReceiveGainAdvice.advice(rec), "They clip even at 0 dB. Turn the radio's volume down and calibrate again.")
    }

    func testRespectsANarrowerRange() {
        let rec = ReceiveGainAdvice.recommend(toneVpp: vpp(0.02), measuredAt: 0, clipped: false, range: 0...2)
        XCTAssertEqual(rec.action, .turnVolumeUp(gain: 2))
    }

    func testGainText() {
        XCTAssertEqual(ReceiveGainAdvice.gainText(0), "0 dB")
        XCTAssertEqual(ReceiveGainAdvice.gainText(3), "+18 dB")
    }
}

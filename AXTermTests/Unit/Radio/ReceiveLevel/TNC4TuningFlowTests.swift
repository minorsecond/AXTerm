//
//  TNC4TuningFlowTests.swift
//  AXTermTests
//
//  The TNC4 tuning wizard's state: the steps in order, Next held back until
//  the receive gain is usable, Cancel putting the radio's own gain setting
//  back exactly as it was, and a summary that says what changed.
//

import XCTest
@testable import AXTerm

@MainActor
final class TNC4TuningFlowTests: XCTestCase {

    private var managedGain: Int?
    private var writes: [Int?] = []

    private func flow(onAPRS: Bool = false, managed: Int? = nil, tncGain: Int? = 4) -> TNC4TuningFlow {
        managedGain = managed
        writes = []
        return TNC4TuningFlow(
            radioID: RadioID(rawValue: "tnc4"), radioName: "ID-50", onAPRS: onAPRS, tncGain: tncGain,
            readGain: { [unowned self] in self.managedGain },
            writeGain: { [unowned self] in self.managedGain = $0; self.writes.append($0) })
    }

    func testTheStepsRunInOrder() {
        let f = flow()
        XCTAssertEqual(TNC4TuningFlow.Step.allCases.map(\.title),
                       ["Start", "Receive Gain", "Squelch", "Packets", "Done"])
        XCTAssertFalse(f.canGoBack)
        f.next()
        XCTAssertEqual(f.step, .receiveGain)
        XCTAssertTrue(f.canGoBack)
        f.back()
        XCTAssertEqual(f.step, .start)
    }

    /// Next waits on the receive gain step until the finder has found a gain
    /// that can be used.
    func testReceiveGainHoldsNextUntilAGainIsUsable() {
        let f = flow()
        f.next()
        XCTAssertFalse(f.canContinue, "nothing measured yet")
        f.recordGainOutcome(.radioTooLoud)
        XCTAssertFalse(f.canContinue, "clipping at the lowest gain: the volume has to come down first")
        f.retryGain()
        XCTAssertNil(f.gainOutcome)
        f.recordGainOutcome(.done(gain: 2))
        XCTAssertTrue(f.canContinue)
        f.recordGainOutcome(.betweenSteps(quieterGain: 1))
        XCTAssertTrue(f.canContinue)
        f.recordGainOutcome(.radioTooQuiet(bestGain: 4))
        XCTAssertTrue(f.canContinue, "quiet but usable at the top gain")
    }

    func testThePacketCheckFollowsTheChannel() {
        XCTAssertEqual(flow(onAPRS: true).packetCheck, .beacon)
        XCTAssertEqual(flow(onAPRS: false).packetCheck, .listen)
    }

    /// The radio used the TNC4's own gain before the wizard; Cancel goes back
    /// to that, not to whichever step the finder last tried.
    func testCancelPutsBackTheTNC4sOwnGain() {
        let f = flow(managed: nil)
        f.next()
        managedGain = 1          // the finder tried gains on the way
        f.recordGainOutcome(.done(gain: 1))
        f.cancel()
        XCTAssertNil(managedGain)
        XCTAssertEqual(writes, [nil])
    }

    func testCancelPutsBackAGainTheRadioAlreadyHad() {
        let f = flow(managed: 3)
        managedGain = 1
        f.cancel()
        XCTAssertEqual(managedGain, 3)
    }

    func testCancelWithNothingChangedWritesNothing() {
        let f = flow(managed: 2)
        f.cancel()
        XCTAssertTrue(writes.isEmpty)
    }

    func testDoneKeepsTheNewGainAndCancelAfterwardDoesNothing() {
        let f = flow(managed: nil)
        managedGain = 2
        f.finish()
        f.cancel()
        XCTAssertEqual(managedGain, 2)
        XCTAssertTrue(writes.isEmpty)
    }

    func testTheSummarySaysWhatChangedAndWhatItWas() {
        let f = flow(managed: nil, tncGain: 4)
        managedGain = 2
        XCTAssertEqual(f.gainSummary, "Input gain for ID-50: +12 dB. It was the TNC4's own, +24 dB.")
        managedGain = nil
        XCTAssertEqual(f.gainSummary, "Input gain for ID-50: unchanged, the TNC4's own, +24 dB.")
    }

    func testTheSummaryCopesWithAnUnknownTNC4Gain() {
        let f = flow(managed: 1, tncGain: nil)
        managedGain = 1
        XCTAssertEqual(f.gainSummary, "Input gain for ID-50: unchanged, +6 dB.")
        managedGain = nil
        XCTAssertEqual(f.gainSummary, "Input gain for ID-50: the TNC4's own. It was +6 dB.")
    }

    /// Field case 2026-10-01: the radio had run on the TNC4's own +24 dB, the
    /// packet check confirmed +24 dB, and the summary read "+24 dB. It was
    /// the TNC4's own, +24 dB." The number is the same; what changed is that
    /// the radio now has a gain of its own.
    func testTheSummarySaysWhenTheSameGainBecameTheRadiosOwn() {
        let f = flow(managed: nil, tncGain: 4)
        managedGain = 4
        XCTAssertEqual(f.gainSummary, "Input gain for ID-50: +24 dB, now set for this radio. The TNC4's own is the same.")
    }

    // MARK: Open-squelch noise against the packets' advice

    /// Field case 2026-10-01: with the squelch open, noise measured 44% at
    /// +12 dB and packets 13%. The packets' advice was +24 dB, which puts
    /// that noise at four times its level, pinned at the top of the range.
    func testAPacketGainThatPinsTheOpenSquelchNoiseIsFlagged() {
        let noise = 29_060 // 44% at +12 dB
        XCTAssertTrue(TNC4TuningFlow.pinsNoise(recommendedGain: 4, noiseVpp: noise, measuredGain: 2))
        XCTAssertFalse(TNC4TuningFlow.pinsNoise(recommendedGain: 2, noiseVpp: noise, measuredGain: 2),
                       "the gain the noise was measured at is fine by definition")
    }

    func testANoiseFloorWithHeadroomIsNotFlagged() {
        // 10% at +6 dB doubles to 20% at +12 dB.
        XCTAssertFalse(TNC4TuningFlow.pinsNoise(recommendedGain: 2, noiseVpp: 6_550, measuredGain: 1))
    }

    /// A closed squelch measures near-silence between packets, and no gain
    /// makes silence clip.
    func testAClosedSquelchIsNeverFlagged() {
        XCTAssertFalse(TNC4TuningFlow.pinsNoise(recommendedGain: 4, noiseVpp: 148, measuredGain: 4))
        XCTAssertFalse(TNC4TuningFlow.pinsNoise(recommendedGain: 4, noiseVpp: 900, measuredGain: 0))
    }

    func testANoiseFloorAlreadyPinnedIsFlagged() {
        XCTAssertTrue(TNC4TuningFlow.pinsNoise(recommendedGain: 4, noiseVpp: nil, measuredGain: 4),
                      "no noise floor because every report clipped")
    }
}

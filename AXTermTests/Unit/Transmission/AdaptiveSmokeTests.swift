//
//  AdaptiveSmokeTests.swift
//  AXTermTests
//
//  End-to-end smoke test: the adaptive controller fed by REAL session
//  evidence (two AX.25 stacks over a seeded virtual RF channel), driven
//  through the full lifecycle a marginal link produces in the field —
//  clean traffic, a collapse, and a recovery. Verifies the controller
//  earns its upgrades, falls back fast when the channel turns, and works
//  its way back on sustained evidence, with every invariant held.
//

import XCTest
@testable import AXTerm

@MainActor
final class AdaptiveSmokeTests: XCTestCase {

    private final class ControllerBox {
        var settings = TxAdaptiveSettings()
        var samples = 0
    }

    func testFullLifecycleCleanCollapseRecover() {
        var config = HarnessConfig()
        config.seed = 7
        config.baseLatency = 0.5
        config.forwardModel = PerfectChannelModel(latency: 0.5)
        config.reverseModel = PerfectChannelModel(latency: 0.5)
        config.sessionConfig = AX25SessionConfig(
            windowSize: 2, paclen: 128, maxRetries: 10,
            rtoMin: 1.0, rtoMax: 16.0, initialRto: 2.0,
            adaptiveTimeout: true
        )
        let harness = AdaptiveTestHarness(config: config)
        let box = ControllerBox()
        harness.alice.onLinkQualitySample = { _, sample in
            box.samples += 1
            box.settings.updateFromLinkQuality(
                lossRate: sample.lossRate, etx: sample.etx, srtt: sample.srtt,
                newFrames: sample.newFrames, retransmits: sample.retransmits
            )
        }
        XCTAssertTrue(harness.connect())

        func sendFrames(_ count: Int, tag: String) {
            for i in 0..<count {
                harness.queueFrames(count: 1, payload: Data("\(tag)-\(i) payload".utf8))
            }
        }

        // PHASE 1 — clean channel: the controller must EARN its upgrades
        // (streak → probe → trial survived → confirmed).
        sendFrames(25, tag: "clean")
        for _ in 0..<40 { harness.advance(seconds: 2.0) }

        XCTAssertGreaterThan(box.samples, 0, "session evidence must reach the controller")
        XCTAssertGreaterThanOrEqual(box.settings.windowSize.currentAdaptive, 3,
                                    "sustained clean traffic earns a larger window")
        XCTAssertGreaterThanOrEqual(box.settings.paclen.currentAdaptive, 192,
                                    "sustained clean traffic probes larger frames")
        XCTAssertGreaterThanOrEqual(box.settings.metrics.upgradesConfirmed, 1,
                                    "at least one probe survived its trial")
        XCTAssertLessThan(box.settings.lossRateEWMA ?? 1.0, 0.05)

        // PHASE 2 — the channel collapses: fast fallback is the safety
        // requirement. Heavy loss must drive stop-and-wait and minimum paclen.
        harness.setForwardModel(UniformLossModel(latency: 0.5, lossProbability: 0.45))
        harness.setReverseModel(UniformLossModel(latency: 0.5, lossProbability: 0.45))
        sendFrames(12, tag: "storm")
        for _ in 0..<120 { harness.advance(seconds: 3.0) }

        XCTAssertEqual(box.settings.windowSize.currentAdaptive, 1,
                       "collapse → stop-and-wait")
        XCTAssertEqual(box.settings.paclen.currentAdaptive, 64,
                       "collapse → minimum frame size")
        XCTAssertGreaterThanOrEqual(
            box.settings.metrics.probeRollbacks + box.settings.metrics.lossDowngrades, 1,
            "the fallback must be visible in the metrics, not silent")

        // PHASE 3 — the channel heals: recovery on sustained evidence only,
        // through whatever skepticism the failed probes earned.
        harness.setForwardModel(PerfectChannelModel(latency: 0.5))
        harness.setReverseModel(PerfectChannelModel(latency: 0.5))
        sendFrames(60, tag: "heal")
        for _ in 0..<120 { harness.advance(seconds: 2.0) }

        XCTAssertGreaterThanOrEqual(box.settings.windowSize.currentAdaptive, 2,
                                    "sustained clean traffic climbs back out of stop-and-wait")
        XCTAssertLessThan(box.settings.lossRateEWMA ?? 1.0, 0.1,
                          "the EWMA must forgive the collapse after enough clean evidence")

        // Whole-run invariants.
        XCTAssertTrue(harness.invariantViolations.isEmpty,
                      "harness invariants: \(harness.invariantViolations)")
        XCTAssertTrue([64, 128, 192, 256].contains(box.settings.paclen.currentAdaptive))
        XCTAssertTrue((1...4).contains(box.settings.windowSize.currentAdaptive))
        XCTAssertFalse(box.settings.lossRateEWMA?.isNaN ?? true)
        XCTAssertEqual(box.settings.metrics.samplesSeen, box.samples,
                       "every sample is accounted for in the metrics")
    }
}

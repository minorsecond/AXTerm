//
//  AdaptiveSettingsTests.swift
//  AXTermTests
//
//  TDD tests for adaptive parameter settings (Auto/Manual mode).
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 4.1
//

import XCTest
@testable import AXTerm

final class AdaptiveSettingsTests: XCTestCase {

    // MARK: - Settings Mode Tests

    func testAdaptiveSettingsModes() {
        XCTAssertEqual(AdaptiveMode.auto.rawValue, "auto")
        XCTAssertEqual(AdaptiveMode.manual.rawValue, "manual")
    }

    func testAdaptiveSettingDefaultsToAuto() {
        let setting = AdaptiveSetting<Int>(
            name: "paclen",
            displayName: "Packet Length",
            defaultValue: 128,
            range: 32...256
        )

        XCTAssertEqual(setting.mode, .auto)
        XCTAssertEqual(setting.manualValue, 128)
    }

    func testAdaptiveSettingManualOverride() {
        var setting = AdaptiveSetting<Int>(
            name: "paclen",
            displayName: "Packet Length",
            defaultValue: 128,
            range: 32...256
        )

        setting.mode = .manual
        setting.manualValue = 64

        XCTAssertEqual(setting.mode, .manual)
        XCTAssertEqual(setting.manualValue, 64)
    }

    func testAdaptiveSettingEffectiveValue() {
        var setting = AdaptiveSetting<Int>(
            name: "paclen",
            displayName: "Packet Length",
            defaultValue: 128,
            range: 32...256
        )

        // In auto mode, effective = current adaptive
        setting.currentAdaptive = 96
        XCTAssertEqual(setting.effectiveValue, 96)

        // In manual mode, effective = manual
        setting.mode = .manual
        setting.manualValue = 64
        XCTAssertEqual(setting.effectiveValue, 64)
    }

    func testAdaptiveSettingRangeClamping() {
        var setting = AdaptiveSetting<Int>(
            name: "paclen",
            displayName: "Packet Length",
            defaultValue: 128,
            range: 32...256
        )

        // Try to set value below range
        setting.manualValue = 16
        XCTAssertGreaterThanOrEqual(setting.clampedManualValue, 32)

        // Try to set value above range
        setting.manualValue = 500
        XCTAssertLessThanOrEqual(setting.clampedManualValue, 256)
    }

    // MARK: - TxSettings Tests

    func testTxSettingsDefaultValues() {
        let settings = TxAdaptiveSettings()

        XCTAssertEqual(settings.paclen.defaultValue, 128)
        XCTAssertEqual(settings.windowSize.defaultValue, 2)
        XCTAssertEqual(settings.maxRetries.defaultValue, 15)
        XCTAssertEqual(settings.rtoMin.defaultValue, 3.0, accuracy: 0.01)
        XCTAssertEqual(settings.rtoMax.defaultValue, 30.0, accuracy: 0.01)
    }

    func testTxSettingsAllInAutoByDefault() {
        let settings = TxAdaptiveSettings()

        XCTAssertEqual(settings.paclen.mode, .auto)
        XCTAssertEqual(settings.windowSize.mode, .auto)
        XCTAssertEqual(settings.maxRetries.mode, .auto)
        XCTAssertEqual(settings.rtoMin.mode, .auto)
        XCTAssertEqual(settings.rtoMax.mode, .auto)
    }

    func testTxSettingsIndividualOverride() {
        var settings = TxAdaptiveSettings()

        // Override just paclen
        settings.paclen.mode = .manual
        settings.paclen.manualValue = 64

        // Others should still be auto
        XCTAssertEqual(settings.paclen.mode, .manual)
        XCTAssertEqual(settings.windowSize.mode, .auto)
    }

    // MARK: - Reason Display Tests

    func testAdaptiveReasonGeneration() {
        var setting = AdaptiveSetting<Int>(
            name: "paclen",
            displayName: "Packet Length",
            defaultValue: 128,
            range: 32...256
        )

        setting.currentAdaptive = 64
        setting.adaptiveReason = "Loss 28%, ETX 2.7"

        XCTAssertEqual(setting.adaptiveReason, "Loss 28%, ETX 2.7")
    }

    func testAdaptiveReasonInAutoMode() {
        var setting = AdaptiveSetting<Int>(
            name: "paclen",
            displayName: "Packet Length",
            defaultValue: 128,
            range: 32...256
        )

        setting.mode = .auto
        setting.currentAdaptive = 64
        setting.adaptiveReason = "High loss rate"

        // In auto mode, reason should be shown
        XCTAssertNotNil(setting.displayReason)
        XCTAssertTrue(setting.displayReason?.contains("loss") ?? false)
    }

    func testAdaptiveReasonHiddenInManualMode() {
        var setting = AdaptiveSetting<Int>(
            name: "paclen",
            displayName: "Packet Length",
            defaultValue: 128,
            range: 32...256
        )

        setting.mode = .manual
        setting.adaptiveReason = "High loss rate"

        // In manual mode, adaptive reason not relevant
        // (user chose the value)
        XCTAssertNil(setting.displayReason)
    }

    // MARK: - Version Selection Tests

    func testAXDPVersionSelection() {
        var settings = TxAdaptiveSettings()

        // Default should be latest
        XCTAssertEqual(settings.axdpVersion, AXDP.version)

        // Can override to older version
        settings.axdpVersion = 1
        XCTAssertEqual(settings.axdpVersion, 1)
    }

    // MARK: - Compression Settings Tests

    func testCompressionEnabled() {
        var settings = TxAdaptiveSettings()

        XCTAssertTrue(settings.compressionEnabled)

        settings.compressionEnabled = false
        XCTAssertFalse(settings.compressionEnabled)
    }

    func testCompressionAlgorithmSelection() {
        var settings = TxAdaptiveSettings()

        XCTAssertEqual(settings.compressionAlgorithm, .lz4)

        settings.compressionAlgorithm = .deflate
        XCTAssertEqual(settings.compressionAlgorithm, .deflate)
    }

    func testMaxDecompressedPayload() {
        var settings = TxAdaptiveSettings()

        XCTAssertEqual(settings.maxDecompressedPayload, 4096)

        settings.maxDecompressedPayload = 8192
        XCTAssertEqual(settings.maxDecompressedPayload, 8192)

        // Should not exceed absolute max
        settings.maxDecompressedPayload = 16384
        XCTAssertLessThanOrEqual(
            settings.clampedMaxDecompressedPayload,
            AXDPCompression.absoluteMaxDecompressedLen
        )
    }

    // MARK: - AXDP Extension Toggles

    func testAXDPExtensionsEnabled() {
        var settings = TxAdaptiveSettings()

        XCTAssertTrue(settings.axdpExtensionsEnabled)

        settings.axdpExtensionsEnabled = false
        XCTAssertFalse(settings.axdpExtensionsEnabled)
    }

    func testAutoNegotiateCapabilities() {
        var settings = TxAdaptiveSettings()

        XCTAssertFalse(settings.autoNegotiateCapabilities)
        settings.autoNegotiateCapabilities = true
        XCTAssertTrue(settings.autoNegotiateCapabilities)
    }

    // MARK: - updateFromLinkQuality (adaptive learning)

    func testUpdateFromLinkQualityHighLoss() {
        var settings = TxAdaptiveSettings()
        settings.updateFromLinkQuality(lossRate: 0.3, etx: 2.5, srtt: nil)
        XCTAssertEqual(settings.paclen.currentAdaptive, 64)
        XCTAssertEqual(settings.windowSize.currentAdaptive, 1)
        // The reasons name the direction now, because the direction is
        // what decides whether backing off can help at all.
        XCTAssertTrue(settings.paclen.adaptiveReason?.contains("Our frames losing") ?? false,
                      settings.paclen.adaptiveReason ?? "nil")
        XCTAssertEqual(settings.windowSize.adaptiveReason,
                       "Our frames losing 30% — stop-and-wait")
    }

    /// Spec 4.2/4.4: parameters must not move on a single good sample — the
    /// old behavior raised K from one clean RR and flapped 1↔3 on marginal
    /// links (field capture 2026-08-22). Upgrades require a sustained streak.
    func testSingleGoodSampleDoesNotFlapParametersUp() {
        var settings = TxAdaptiveSettings()
        settings.updateFromLinkQuality(lossRate: 0.05, etx: 1.2, srtt: nil, newFrames: 1, retransmits: 0)
        XCTAssertEqual(settings.paclen.currentAdaptive, 128, "one sample is not stability evidence")
        XCTAssertEqual(settings.windowSize.currentAdaptive, 2, "K must hold at default on a single good sample")
    }

    /// Spec 4.2: "if successStreak >= 10 → increase … reset to something like
    /// 5 (so it doesn't rocket upward)". Sustained clean traffic earns one
    /// notch; the next needs a fresh half-streak.
    func testSustainedSuccessRaisesOneNotchWithAntiRocketReset() {
        var settings = TxAdaptiveSettings()
        for _ in 0..<10 {
            settings.updateFromLinkQuality(lossRate: 0.0, etx: 1.0, srtt: nil, newFrames: 1, retransmits: 0)
        }
        XCTAssertEqual(settings.windowSize.currentAdaptive, 3, "10 clean frames earn K+1")
        XCTAssertEqual(settings.paclen.currentAdaptive, 192, "10 clean frames probe paclen upward")
        XCTAssertEqual(settings.windowSize.adaptiveReason, "Good link quality")
        XCTAssertEqual(settings.successStreak, 5, "anti-rocket: streak resets to 5 after an upgrade")

        // The very next clean sample must NOT upgrade again (streak is 6, and
        // the first upgrade's probation trial is still running).
        settings.updateFromLinkQuality(lossRate: 0.0, etx: 1.0, srtt: nil, newFrames: 1, retransmits: 0)
        XCTAssertEqual(settings.windowSize.currentAdaptive, 3)
        XCTAssertEqual(settings.paclen.currentAdaptive, 192)

        // Nine more clean frames finish the 10-frame probation trial (streak
        // is also ≥ 10 again); the NEXT sample may then open the second probe.
        for _ in 0..<9 {
            settings.updateFromLinkQuality(lossRate: 0.0, etx: 1.0, srtt: nil, newFrames: 1, retransmits: 0)
        }
        XCTAssertNil(settings.probation, "first upgrade confirmed")
        XCTAssertEqual(settings.windowSize.currentAdaptive, 3,
                       "a confirmation sample must not immediately stack the next probe")

        settings.updateFromLinkQuality(lossRate: 0.0, etx: 1.0, srtt: nil, newFrames: 1, retransmits: 0)
        XCTAssertEqual(settings.windowSize.currentAdaptive, 4, "second upgrade after trial + streak")
        XCTAssertEqual(settings.paclen.currentAdaptive, 256)

        // K caps at 4 and paclen at 256 no matter how long the streak runs.
        for _ in 0..<30 {
            settings.updateFromLinkQuality(lossRate: 0.0, etx: 1.0, srtt: nil, newFrames: 1, retransmits: 0)
        }
        XCTAssertEqual(settings.windowSize.currentAdaptive, 4)
        XCTAssertEqual(settings.paclen.currentAdaptive, 256)
    }

    /// A fresh retransmission degrades immediately (spec: "failStreak >= 1 →
    /// decrease") — safety is asymmetric: down fast, up only on evidence.
    func testFreshRetransmitDegradesImmediately() {
        var settings = TxAdaptiveSettings()
        // 12 clean frames: one upgrade at 10 (streak resets to 5, then 6, 7).
        for _ in 0..<12 {
            settings.updateFromLinkQuality(lossRate: 0.0, etx: 1.0, srtt: nil, newFrames: 1, retransmits: 0)
        }
        XCTAssertEqual(settings.windowSize.currentAdaptive, 3)
        XCTAssertEqual(settings.paclen.currentAdaptive, 192)

        settings.updateFromLinkQuality(lossRate: 0.5, etx: 4.0, srtt: nil, newFrames: 1, retransmits: 1)
        XCTAssertLessThanOrEqual(settings.windowSize.currentAdaptive, 2, "retransmit halves the window")
        XCTAssertLessThanOrEqual(settings.paclen.currentAdaptive, 128, "retransmit steps paclen down")
        XCTAssertEqual(settings.successStreak, 0, "failure resets the success streak")
    }

    /// Aggregate sources (network-wide inference) carry no per-frame evidence
    /// and must never move the streaks — the spec's "don't learn nonsense" rule.
    func testAggregateSamplesNeverMoveStreaks() {
        var settings = TxAdaptiveSettings()
        for _ in 0..<20 {
            settings.updateFromLinkQuality(lossRate: 0.0, etx: 1.0, srtt: nil)  // retransmits: nil
        }
        XCTAssertEqual(settings.successStreak, 0, "aggregate samples are not delivery evidence")
        XCTAssertEqual(settings.windowSize.currentAdaptive, 2, "no upgrade without evidence-bearing samples")
    }

    /// NaN/Inf samples must be discarded, not blended into the EWMAs.
    func testNonFiniteSamplesAreIgnored() {
        var settings = TxAdaptiveSettings()
        settings.updateFromLinkQuality(lossRate: 0.1, etx: 1.2, srtt: nil, newFrames: 1, retransmits: 0)
        let lossBefore = settings.lossRateEWMA
        settings.updateFromLinkQuality(lossRate: .nan, etx: 1.0, srtt: nil, newFrames: 1, retransmits: 0)
        settings.updateFromLinkQuality(lossRate: 0.0, etx: .infinity, srtt: nil, newFrames: 1, retransmits: 0)
        XCTAssertEqual(settings.lossRateEWMA, lossBefore, "poisoned samples must not touch state")
        XCTAssertFalse(settings.lossRateEWMA?.isNaN ?? true)
    }

    func testUpdateFromLinkQualityWithSrttSetsRtoReasons() {
        var settings = TxAdaptiveSettings()
        settings.updateFromLinkQuality(lossRate: 0.1, etx: 1.5, srtt: 2.0)
        XCTAssertNotNil(settings.rtoMin.adaptiveReason)
        XCTAssertTrue(settings.rtoMin.adaptiveReason?.contains("RTT") ?? false)
        XCTAssertNotNil(settings.rtoMax.adaptiveReason)
    }

    func testUpdateFromLinkQualityModerateLoss() {
        var settings = TxAdaptiveSettings()
        settings.paclen.currentAdaptive = 256
        settings.updateFromLinkQuality(lossRate: 0.15, etx: 1.8, srtt: nil)
        XCTAssertLessThanOrEqual(settings.paclen.currentAdaptive, 128)
        XCTAssertEqual(settings.windowSize.currentAdaptive, 2) // default
    }

    func testUpdateFromLinkQualityZeroLossStaysReasonable() {
        var settings = TxAdaptiveSettings()
        settings.updateFromLinkQuality(lossRate: 0.0, etx: 1.0, srtt: 0.5)
        XCTAssertGreaterThanOrEqual(settings.windowSize.currentAdaptive, 1)
        XCTAssertLessThanOrEqual(settings.windowSize.currentAdaptive, 7)
        XCTAssertGreaterThanOrEqual(settings.paclen.currentAdaptive, 32)
        XCTAssertLessThanOrEqual(settings.paclen.currentAdaptive, 256)
    }

    func testUpdateFromLinkQualityNilSrttDoesNotCrash() {
        var settings = TxAdaptiveSettings()
        settings.updateFromLinkQuality(lossRate: 0.2, etx: 2.0, srtt: nil)
        XCTAssertEqual(settings.windowSize.currentAdaptive, 1)
        XCTAssertEqual(settings.paclen.currentAdaptive, 64)
    }

    func testUpdateFromLinkQualityExtremeLossClampsWindowToOne() {
        var settings = TxAdaptiveSettings()
        settings.updateFromLinkQuality(lossRate: 0.9, etx: 20.0, srtt: nil)
        XCTAssertEqual(settings.windowSize.currentAdaptive, 1)
        XCTAssertLessThanOrEqual(settings.paclen.currentAdaptive, 64)
    }

    /// Recovery from stop-and-wait requires sustained clean evidence, not one
    /// lucky sample (spec 4.4: additive increase per clean round).
    func testWindowRecoversFromStopAndWaitOnSustainedEvidence() {
        var settings = TxAdaptiveSettings()
        settings.windowSize.currentAdaptive = 1
        settings.updateFromLinkQuality(lossRate: 0.02, etx: 1.05, srtt: 1.0, newFrames: 1, retransmits: 0)
        XCTAssertEqual(settings.windowSize.currentAdaptive, 1, "one clean sample must not leave stop-and-wait")

        for _ in 0..<9 {
            settings.updateFromLinkQuality(lossRate: 0.0, etx: 1.0, srtt: 1.0, newFrames: 1, retransmits: 0)
        }
        XCTAssertEqual(settings.windowSize.currentAdaptive, 2, "10 clean frames earn the way back up")
    }

    /// Property fuzz: seeded random sample streams must never drive the
    /// controller out of its invariants — values stay in range, no NaN, high
    /// smoothed loss always forces stop-and-wait, and K never rises without a
    /// full success streak.
    func testFuzzRandomSampleStreamsHoldInvariants() {
        let paclenLadder: Set<Int> = [64, 128, 192, 256]
        for seed: UInt64 in 1...20 {
            var rng = RFRng(seed: seed)
            var settings = TxAdaptiveSettings()
            var streakBefore = 0

            for step in 0..<300 {
                let bad = rng.chance(0.3)
                let retransmits = bad ? Int(rng.next() % 3 + 1) : 0
                let newFrames = Int(rng.next() % 3)
                let loss = retransmits > 0
                    ? Double(retransmits) / Double(max(1, newFrames + retransmits))
                    : 0.0
                let delivery = max(0.05, 1.0 - loss)
                let etx = 1.0 / (delivery * delivery)

                let kBefore = settings.windowSize.currentAdaptive
                streakBefore = settings.successStreak
                settings.updateFromLinkQuality(
                    lossRate: loss, etx: etx, srtt: rng.chance(0.5) ? Double(rng.next() % 10) + 0.5 : nil,
                    newFrames: newFrames, retransmits: retransmits
                )

                let ctx = "seed \(seed) step \(step)"
                XCTAssertTrue(paclenLadder.contains(settings.paclen.currentAdaptive),
                              "\(ctx): paclen \(settings.paclen.currentAdaptive) off the ladder")
                XCTAssertTrue((1...4).contains(settings.windowSize.currentAdaptive),
                              "\(ctx): K \(settings.windowSize.currentAdaptive) out of range")
                XCTAssertFalse(settings.lossRateEWMA?.isNaN ?? false, "\(ctx): loss EWMA NaN")
                XCTAssertFalse(settings.etxEWMA?.isNaN ?? false, "\(ctx): ETX EWMA NaN")
                if let smoothed = settings.lossRateEWMA, smoothed >= 0.2 {
                    XCTAssertEqual(settings.windowSize.currentAdaptive, 1,
                                   "\(ctx): smoothed loss \(smoothed) must force stop-and-wait")
                }
                if settings.windowSize.currentAdaptive > kBefore {
                    XCTAssertGreaterThanOrEqual(streakBefore + max(0, newFrames), 10,
                                                "\(ctx): K rose without a full success streak")
                }
                if let rto = settings.currentRto {
                    XCTAssertGreaterThanOrEqual(rto, settings.rtoMin.effectiveValue, ctx)
                    XCTAssertLessThanOrEqual(rto, settings.rtoMax.effectiveValue, ctx)
                }
                XCTAssertTrue([10, 20, 40].contains(settings.upgradeStreakRequirement),
                              "\(ctx): skepticism \(settings.upgradeStreakRequirement) off the ladder")
                if let trial = settings.probation {
                    XCTAssertTrue((1...10).contains(trial.framesRemaining),
                                  "\(ctx): trial frames \(trial.framesRemaining) out of range")
                    XCTAssertGreaterThanOrEqual(trial.priorWindow, 1, ctx)
                    XCTAssertTrue([64, 128, 192, 256].contains(trial.priorPaclen), ctx)
                }
                XCTAssertGreaterThanOrEqual(settings.metrics.upgradesAttempted,
                                            settings.metrics.upgradesConfirmed + settings.metrics.probeRollbacks
                                            - (settings.probation == nil ? 0 : 1),
                                            "\(ctx): every confirmation/rollback traces to an attempt")
            }
        }
    }

    // MARK: - resetAdaptiveToDefaults

    func testResetAdaptiveToDefaultsResetsCurrentAdaptive() {
        var settings = TxAdaptiveSettings()
        // Simulate high-loss learning
        settings.updateFromLinkQuality(lossRate: 0.3, etx: 2.5, srtt: 2.0)
        XCTAssertEqual(settings.windowSize.currentAdaptive, 1)
        XCTAssertEqual(settings.paclen.currentAdaptive, 64)
        XCTAssertNotNil(settings.currentRto)

        settings.resetAdaptiveToDefaults()

        XCTAssertEqual(settings.windowSize.currentAdaptive, settings.windowSize.defaultValue)
        XCTAssertEqual(settings.paclen.currentAdaptive, settings.paclen.defaultValue)
        XCTAssertEqual(settings.maxRetries.currentAdaptive, settings.maxRetries.defaultValue)
        XCTAssertEqual(settings.rtoMin.currentAdaptive, settings.rtoMin.defaultValue, accuracy: 0.001)
        XCTAssertEqual(settings.rtoMax.currentAdaptive, settings.rtoMax.defaultValue, accuracy: 0.001)
        XCTAssertNil(settings.currentRto)
        XCTAssertNil(settings.windowSize.adaptiveReason)
        XCTAssertNil(settings.paclen.adaptiveReason)
    }

    func testResetAdaptivePreservesManualOverrides() {
        var settings = TxAdaptiveSettings()
        settings.windowSize.mode = .manual
        settings.windowSize.manualValue = 4
        settings.paclen.mode = .manual
        settings.paclen.manualValue = 64

        // Simulate learning then reset
        settings.updateFromLinkQuality(lossRate: 0.3, etx: 2.5, srtt: nil)
        settings.resetAdaptiveToDefaults()

        // Manual mode and values must survive
        XCTAssertEqual(settings.windowSize.mode, .manual)
        XCTAssertEqual(settings.windowSize.manualValue, 4)
        XCTAssertEqual(settings.paclen.mode, .manual)
        XCTAssertEqual(settings.paclen.manualValue, 64)

        // But currentAdaptive should be reset to defaults
        XCTAssertEqual(settings.windowSize.currentAdaptive, settings.windowSize.defaultValue)
        XCTAssertEqual(settings.paclen.currentAdaptive, settings.paclen.defaultValue)
    }

    func testResetAdaptivePreservesAXDPSettings() {
        var settings = TxAdaptiveSettings()
        settings.compressionEnabled = false
        settings.axdpExtensionsEnabled = false
        settings.compressionAlgorithm = .deflate
        settings.maxDecompressedPayload = 8192

        settings.updateFromLinkQuality(lossRate: 0.3, etx: 2.5, srtt: nil)
        settings.resetAdaptiveToDefaults()

        XCTAssertFalse(settings.compressionEnabled)
        XCTAssertFalse(settings.axdpExtensionsEnabled)
        XCTAssertEqual(settings.compressionAlgorithm, .deflate)
        XCTAssertEqual(settings.maxDecompressedPayload, 8192)
    }
}

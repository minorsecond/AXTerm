//
//  AdaptiveProbationTests.swift
//  AXTermTests
//
//  TDD spec for the adaptive controller's self-defense: every upgrade is a
//  PROBE under probation. If the link degrades while the probe is on trial,
//  the controller rolls back immediately and becomes more skeptical (the next
//  upgrade needs a longer clean streak). If the probe survives its trial, the
//  skepticism resets. This is the "safe and quick to fall back if it detects
//  it is making things worse" requirement, made mechanical.
//

import XCTest
@testable import AXTerm

final class AdaptiveProbationTests: XCTestCase {

    /// Drive `count` clean evidence frames through the controller.
    private func feedClean(_ settings: inout TxAdaptiveSettings, _ count: Int) {
        for _ in 0..<count {
            settings.updateFromLinkQuality(lossRate: 0.0, etx: 1.0, srtt: nil,
                                           newFrames: 1, retransmits: 0)
        }
    }

    private func feedFailure(_ settings: inout TxAdaptiveSettings) {
        settings.updateFromLinkQuality(lossRate: 0.5, etx: 4.0, srtt: nil,
                                       newFrames: 0, retransmits: 1)
    }

    // MARK: - Rollback on a probe that made things worse

    func testFailureDuringProbationRollsBackAndDoublesSkepticism() {
        var settings = TxAdaptiveSettings()
        feedClean(&settings, 10)   // earns the upgrade → probation begins
        XCTAssertEqual(settings.windowSize.currentAdaptive, 3)
        XCTAssertEqual(settings.paclen.currentAdaptive, 192)
        XCTAssertNotNil(settings.probation, "an upgrade is a probe under trial")

        feedFailure(&settings)

        XCTAssertLessThanOrEqual(settings.windowSize.currentAdaptive, 2,
                                 "rollback: at or below the pre-upgrade window")
        XCTAssertLessThanOrEqual(settings.paclen.currentAdaptive, 128,
                                 "rollback: at or below the pre-upgrade paclen")
        XCTAssertNil(settings.probation, "the failed probe is over")
        XCTAssertEqual(settings.upgradeStreakRequirement, 20,
                       "a failed probe doubles the streak needed to try again")
        XCTAssertEqual(settings.metrics.probeRollbacks, 1)
    }

    func testRepeatedFailedProbesCapSkepticismAt40() {
        var settings = TxAdaptiveSettings()
        for _ in 0..<3 {
            let needed = settings.upgradeStreakRequirement
            feedClean(&settings, needed)
            if settings.probation != nil { feedFailure(&settings) }
            // Clear the EWMA poisoning between rounds so the streak can rebuild.
            feedClean(&settings, 8)
            settings.successStreak = 0
        }
        XCTAssertEqual(settings.upgradeStreakRequirement, 40,
                       "skepticism doubles per failed probe but caps at 40")
    }

    // MARK: - Confirmation of a probe that held up

    func testCleanProbationConfirmsUpgradeAndResetsSkepticism() {
        var settings = TxAdaptiveSettings()
        feedClean(&settings, 10)                    // upgrade → probation
        XCTAssertNotNil(settings.probation)

        feedClean(&settings, 10)                    // survive the trial
        XCTAssertNil(settings.probation, "clean trial ends probation")
        XCTAssertEqual(settings.windowSize.currentAdaptive, 3, "confirmed upgrade sticks")
        XCTAssertEqual(settings.upgradeStreakRequirement, 10,
                       "a confirmed probe resets skepticism to baseline")
        XCTAssertEqual(settings.metrics.upgradesConfirmed, 1)
    }

    func testNoSecondUpgradeWhileProbationRuns() {
        var settings = TxAdaptiveSettings()
        feedClean(&settings, 10)                    // upgrade → probation (trial = 10)
        let kDuringProbation = settings.windowSize.currentAdaptive
        feedClean(&settings, 9)                     // streak rebuilds but trial not done
        XCTAssertEqual(settings.windowSize.currentAdaptive, kDuringProbation,
                       "one probe at a time — no stacking upgrades during a trial")
    }

    // MARK: - Raised skepticism actually gates the next upgrade

    func testDoubledRequirementGatesTheNextUpgrade() {
        var settings = TxAdaptiveSettings()
        feedClean(&settings, 10)
        feedFailure(&settings)                      // requirement now 20
        feedClean(&settings, 8)                     // let the EWMA recover
        settings.successStreak = 0                  // clean slate for the streak

        let kBefore = settings.windowSize.currentAdaptive
        feedClean(&settings, 10)
        XCTAssertEqual(settings.windowSize.currentAdaptive, kBefore,
                       "10 clean frames no longer suffice after a failed probe")
        feedClean(&settings, 10)
        XCTAssertGreaterThan(settings.windowSize.currentAdaptive, kBefore,
                             "20 clean frames meet the doubled requirement")
    }

    // MARK: - Aggregate samples cannot touch a trial

    func testAggregateSamplesNeitherAdvanceNorFailProbation() {
        var settings = TxAdaptiveSettings()
        feedClean(&settings, 10)                    // upgrade → probation
        let trialBefore = settings.probation?.framesRemaining

        // Aggregate (no evidence) samples, including a lossy-looking one.
        settings.updateFromLinkQuality(lossRate: 0.0, etx: 1.0, srtt: nil)
        settings.updateFromLinkQuality(lossRate: 0.15, etx: 1.4, srtt: nil)

        XCTAssertNotNil(settings.probation, "no evidence → the trial neither passes nor fails")
        XCTAssertEqual(settings.probation?.framesRemaining, trialBefore,
                       "aggregate samples must not consume trial frames")
    }

    // MARK: - Reset

    func testResetClearsProbationAndSkepticism() {
        var settings = TxAdaptiveSettings()
        feedClean(&settings, 10)
        feedFailure(&settings)
        settings.resetAdaptiveToDefaults()
        XCTAssertNil(settings.probation)
        XCTAssertEqual(settings.upgradeStreakRequirement, 10)
        XCTAssertEqual(settings.metrics, AdaptiveLearningMetrics(),
                       "reset returns the metrics to zero")
    }
}

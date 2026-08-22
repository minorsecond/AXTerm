import XCTest
@testable import AXTerm

@MainActor
final class AdaptiveStatusStoreTests: XCTestCase {

    func testEffectiveAdaptivePrefersSelectedSessionWhenAvailable() {
        let store = AdaptiveStatusStore()
        var global = TxAdaptiveSettings()
        global.windowSize.currentAdaptive = 2
        global.paclen.currentAdaptive = 128
        global.maxRetries.currentAdaptive = 15
        store.updateGlobal(settings: global, lossRate: 0.12, etx: 1.6, srtt: nil, updatedAt: Date())

        var session = TxAdaptiveSettings()
        session.windowSize.currentAdaptive = 1
        session.paclen.currentAdaptive = 64
        session.maxRetries.currentAdaptive = 10
        store.updateSession(
            id: "N0HI-7|WIDE1-1",
            destination: "N0HI-7",
            pathSignature: "WIDE1-1",
            settings: session,
            lossRate: 0.22,
            etx: 2.4,
            srtt: nil,
            updatedAt: Date()
        )

        store.setSelectedSession(id: "N0HI-7|WIDE1-1")
        XCTAssertEqual(store.effectiveAdaptive?.k, 1)
        XCTAssertEqual(store.effectiveAdaptive?.p, 64)
        XCTAssertEqual(store.effectiveAdaptive?.n2, 10)

        store.setSelectedSession(id: "UNKNOWN|")
        XCTAssertEqual(store.effectiveAdaptive?.k, 2)
        XCTAssertEqual(store.effectiveAdaptive?.p, 128)
        XCTAssertEqual(store.effectiveAdaptive?.n2, 15)
    }

    /// The store must surface the controller's learning state — the smoothed
    /// metrics decisions are actually made on, the streak progress toward the
    /// next upgrade, the probation trial, and the what-happened counters —
    /// so the UI can show its work (CLAUDE.md: tooltips must explain WHY).
    func testSessionParamsCarryLearningStateAndMetrics() {
        let store = AdaptiveStatusStore()
        var settings = TxAdaptiveSettings()
        // Earn an upgrade (opens probation) then take a hit (rollback).
        for _ in 0..<10 {
            settings.updateFromLinkQuality(lossRate: 0.0, etx: 1.0, srtt: 2.0, newFrames: 1, retransmits: 0)
        }
        let probationRemaining = settings.probation?.framesRemaining
        XCTAssertNotNil(probationRemaining, "precondition: upgrade opened a trial")

        store.updateSession(
            id: "KB5YZB-7|DRLNOD", destination: "KB5YZB-7", pathSignature: "DRLNOD",
            settings: settings, lossRate: 0.0, etx: 1.0, srtt: 2.0, updatedAt: Date()
        )

        let params = store.sessionAdaptiveByID["KB5YZB-7|DRLNOD"]
        XCTAssertEqual(params?.smoothedLoss ?? -1, settings.lossRateEWMA ?? -2, accuracy: 0.0001,
                       "the store carries the EWMA the controller decides on")
        XCTAssertEqual(params?.smoothedEtx ?? -1, settings.etxEWMA ?? -2, accuracy: 0.0001)
        XCTAssertEqual(params?.successStreak, settings.successStreak)
        XCTAssertEqual(params?.upgradeStreakRequirement, settings.upgradeStreakRequirement)
        XCTAssertEqual(params?.probationFramesRemaining, probationRemaining,
                       "an upgrade on trial is visible to the user")
        XCTAssertEqual(params?.metrics, settings.metrics)
        XCTAssertEqual(params?.metrics.upgradesAttempted, 1)
    }

    func testGlobalParamsCarryLearningStateAndMetrics() {
        let store = AdaptiveStatusStore()
        var settings = TxAdaptiveSettings()
        settings.updateFromLinkQuality(lossRate: 0.4, etx: 3.0, srtt: nil, newFrames: 0, retransmits: 2)
        store.updateGlobal(settings: settings, lossRate: 0.4, etx: 3.0, srtt: nil, updatedAt: Date())

        let params = store.globalAdaptive
        XCTAssertEqual(params?.smoothedLoss ?? -1, 0.4, accuracy: 0.0001)
        XCTAssertNil(params?.probationFramesRemaining, "no trial open")
        XCTAssertEqual(params?.metrics.retransmitsSeen, 2)
    }

    func testSessionHistoryIsCappedToTenMinutes() {
        let store = AdaptiveStatusStore()
        let now = Date()

        var settings = TxAdaptiveSettings()
        settings.windowSize.currentAdaptive = 1
        settings.paclen.currentAdaptive = 64
        settings.maxRetries.currentAdaptive = 10

        store.updateSession(
            id: "N0HI-7|",
            destination: "N0HI-7",
            pathSignature: "",
            settings: settings,
            lossRate: 0.2,
            etx: 2.6,
            srtt: nil,
            updatedAt: now.addingTimeInterval(-11 * 60)
        )
        store.updateSession(
            id: "N0HI-7|",
            destination: "N0HI-7",
            pathSignature: "",
            settings: settings,
            lossRate: 0.18,
            etx: 2.1,
            srtt: nil,
            updatedAt: now
        )

        store.setSelectedSession(id: "N0HI-7|")
        let history = store.effectiveETXHistory
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.etx ?? 0, 2.1, accuracy: 0.001)
    }
}

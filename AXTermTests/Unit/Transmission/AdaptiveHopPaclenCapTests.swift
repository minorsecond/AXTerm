//
//  AdaptiveHopPaclenCapTests.swift
//  AXTermTests
//
//  Hop-scaled paclen ceiling: every digipeater hop multiplies a frame's
//  on-air exposure (2m+1 transmissions per round trip), so longer frames
//  compound their corruption probability across hops. The adaptive ladder
//  therefore gives up one rung of maximum paclen per digi hop, floored at
//  128 — the 64-byte rung stays reserved as a LOSS response, never a prior.
//
//  The cap is a ceiling on optimism, not a verdict: the probation machinery
//  still guards every upgrade below it, and a clean digi path still earns
//  everything the ceiling allows.
//

import XCTest
@testable import AXTerm

@MainActor
final class AdaptiveHopPaclenCapTests: XCTestCase {

    // MARK: - The ceiling policy

    func testCeilingGivesUpOneLadderRungPerHopFlooredAt128() {
        XCTAssertEqual(TxAdaptiveSettings.paclenCeiling(forHops: 0), 256)
        XCTAssertEqual(TxAdaptiveSettings.paclenCeiling(forHops: 1), 192)
        XCTAssertEqual(TxAdaptiveSettings.paclenCeiling(forHops: 2), 128)
        XCTAssertEqual(TxAdaptiveSettings.paclenCeiling(forHops: 5), 128,
                       "the floor is 128 — 64 is a loss response, never a hop prior")
    }

    // MARK: - Controller honors the ceiling

    /// Sustained clean traffic on a one-digi route earns paclen 192 and K=4,
    /// but must never probe 256 — not even transiently.
    func testCleanTrafficNeverProbesAboveTheCeiling() {
        var settings = TxAdaptiveSettings()
        settings.applyPaclenCeiling(forHops: 1)

        var maxPaclenSeen = settings.paclen.currentAdaptive
        for _ in 0..<200 {
            settings.updateFromLinkQuality(lossRate: 0.0, etx: 1.0, srtt: 4.0,
                                           newFrames: 1, retransmits: 0)
            maxPaclenSeen = max(maxPaclenSeen, settings.paclen.currentAdaptive)
        }

        XCTAssertEqual(maxPaclenSeen, 192,
                       "the ceiling caps even transient probes — 256 must never hit the air")
        XCTAssertEqual(settings.paclen.currentAdaptive, 192,
                       "a clean one-digi path still earns everything the ceiling allows")
        XCTAssertEqual(settings.windowSize.currentAdaptive, 4,
                       "the window ladder is independent of the paclen ceiling")
    }

    /// Applying a lower ceiling to already-learned settings clamps immediately —
    /// a route must never keep an inherited paclen its hop count forbids.
    func testCeilingClampsAlreadyLearnedPaclen() {
        var settings = TxAdaptiveSettings()
        for _ in 0..<200 {
            settings.updateFromLinkQuality(lossRate: 0.0, etx: 1.0, srtt: 4.0,
                                           newFrames: 1, retransmits: 0)
        }
        XCTAssertEqual(settings.paclen.currentAdaptive, 256, "precondition: direct path earned 256")

        settings.applyPaclenCeiling(forHops: 2)
        XCTAssertEqual(settings.paclen.currentAdaptive, 128)
        XCTAssertNotNil(settings.paclen.adaptiveReason,
                        "the clamp must explain itself like every other adaptive change")
    }

    /// The ceiling is a cap on optimism only: loss response below the ceiling
    /// is untouched, including the drop to 64 and later recovery to the ceiling.
    func testLossResponseBelowCeilingIsUnchanged() {
        var settings = TxAdaptiveSettings()
        settings.applyPaclenCeiling(forHops: 2)

        // Heavy loss: collapse to the 64-byte rung as always.
        for _ in 0..<8 {
            settings.updateFromLinkQuality(lossRate: 0.5, etx: 4.0, srtt: nil,
                                           newFrames: 0, retransmits: 2)
        }
        XCTAssertEqual(settings.paclen.currentAdaptive, 64,
                       "the loss floor is below the hop ceiling and must stay reachable")

        // Recovery: climbs back, but only to the ceiling.
        for _ in 0..<400 {
            settings.updateFromLinkQuality(lossRate: 0.0, etx: 1.0, srtt: 4.0,
                                           newFrames: 1, retransmits: 0)
        }
        XCTAssertEqual(settings.paclen.currentAdaptive, 128,
                       "recovery tops out at the hop ceiling")
    }

    /// Fuzz: under arbitrary loss/recovery streams the ceiling is an
    /// invariant, not a tendency — paclen stays on the ladder and at or
    /// below the hop cap at every single step.
    func testFuzzedEvidenceStreamsNeverBreachTheCeiling() {
        for seed in 0..<20 {
            var rngState = UInt64(seed) &* 2_862_933_555_777_941_757 &+ 3_037_000_493
            func nextRandom() -> UInt64 {
                rngState = rngState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return rngState
            }

            let hops = Int(nextRandom() % 4)
            let ceiling = TxAdaptiveSettings.paclenCeiling(forHops: hops)
            var settings = TxAdaptiveSettings()
            settings.applyPaclenCeiling(forHops: hops)

            for step in 0..<300 {
                let retransmits = (nextRandom() % 10 < 3) ? Int(nextRandom() % 3) : 0
                let loss = retransmits > 0 ? Double(nextRandom() % 60) / 100.0 : 0.0
                settings.updateFromLinkQuality(
                    lossRate: loss,
                    etx: 1.0 / max(0.05, 1.0 - loss),
                    srtt: Double(1 + nextRandom() % 8),
                    newFrames: retransmits > 0 ? 0 : 1,
                    retransmits: retransmits
                )
                let p = settings.paclen.currentAdaptive
                XCTAssertLessThanOrEqual(p, ceiling,
                                         "seed \(seed) step \(step): paclen \(p) breached ceiling \(ceiling) (hops \(hops))")
                XCTAssertTrue([64, 128, 192, 256].contains(p),
                              "seed \(seed) step \(step): paclen \(p) left the ladder")
            }
        }
    }

    // MARK: - Coordinator wires hop count from the route

    /// Identical clean traffic: the two-digi route caps at 128 while the
    /// direct route climbs past it — the cap is strictly per-route.
    func testCoordinatorCapsPaclenByRouteHopCount() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }
        coordinator.adaptiveTransmissionEnabled = true

        let twoDigi = RouteAdaptiveKey(destination: "KB5YZB-7", pathSignature: "DRLNOD,FNKTWN")
        let direct = RouteAdaptiveKey(destination: "KB5YZB-1", pathSignature: "")
        for _ in 0..<200 {
            coordinator.applyLinkQualitySample(lossRate: 0.0, etx: 1.0, srtt: 4.0,
                                               source: "session", routeKey: twoDigi,
                                               newFrames: 1, retransmits: 0)
            coordinator.applyLinkQualitySample(lossRate: 0.0, etx: 1.0, srtt: 4.0,
                                               source: "session", routeKey: direct,
                                               newFrames: 1, retransmits: 0)
        }

        let capped = coordinator.sessionManager.getConfigForDestination?("KB5YZB-7", "DRLNOD,FNKTWN")
        XCTAssertEqual(capped?.paclen, 128,
                       "two digi hops cap the session config at 128")
        let uncapped = coordinator.sessionManager.getConfigForDestination?("KB5YZB-1", "")
        XCTAssertEqual(uncapped?.paclen, 256,
                       "the direct route to another station is not dragged down")
    }
}

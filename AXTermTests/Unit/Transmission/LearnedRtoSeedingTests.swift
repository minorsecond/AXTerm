//
//  LearnedRtoSeedingTests.swift
//  AXTermTests
//
//  TDD spec for learned-RTT connect seeding.
//
//  Design contract (agreed 2026-08-22):
//  - AX25SessionConfig.learnedPathRto is a FULL-PATH RTO learned for one
//    specific route. When present it IS the session's initial RTO seed and is
//    never hop-scaled (the learned value already includes digipeater delay).
//  - It has exactly one writer: the per-route adaptive cache-hit branch, which
//    only runs with adaptive ON and a fresh (TTL-valid) entry.
//  - It never survives config merging (multiple sessions to one destination
//    over different routes must not cross-pollinate learned values).
//  - It is clamped into [max(rtoMin, 4.0), rtoMax] so a freak low sample can
//    never produce a hair-trigger SABM timer.
//  - The seed is a timer value, not an RTT sample: session SRTT starts nil and
//    the first real sample fully replaces the seed (fresh-start invariant).
//

import XCTest
@testable import AXTerm

@MainActor
final class LearnedRtoSeedingTests: XCTestCase {

    private let local = AX25Address(call: "K0EPI", ssid: 7)
    private let remote = AX25Address(call: "KB5YZB", ssid: 7)

    // MARK: - Session seed semantics

    func testLearnedSeedIsUsedVerbatimAndNeverHopScaled() {
        let config = AX25SessionConfig(initialRto: 8.0, adaptiveTimeout: true, learnedPathRto: 10.0)
        let session = AX25Session(
            localAddress: local, remoteAddress: remote,
            path: DigiPath.from(["DRLNOD"]),   // 1 digi would scale 8 s → 24 s
            config: config
        )
        XCTAssertEqual(session.timers.rto, 10.0, accuracy: 0.01,
                       "a learned full-path RTO is the seed, with NO hop multiplier on top")
        XCTAssertNil(session.timers.srtt,
                     "the seed is a timer value, not a sample — the estimator starts fresh")
    }

    func testWithoutLearnedSeedHopScalingStillApplies() {
        let config = AX25SessionConfig(initialRto: 8.0, adaptiveTimeout: true)
        let session = AX25Session(
            localAddress: local, remoteAddress: remote,
            path: DigiPath.from(["DRLNOD"]),
            config: config
        )
        XCTAssertEqual(session.timers.rto, 24.0, accuracy: 0.01,
                       "no learned value → existing scaled-default behavior, unchanged")
    }

    func testLearnedSeedRespectsTimerBounds() {
        // The timers clamp the seed into [rtoMin, rtoMax] like any other seed.
        let config = AX25SessionConfig(rtoMin: 3.0, rtoMax: 12.0, initialRto: 8.0,
                                       adaptiveTimeout: true, learnedPathRto: 50.0)
        let session = AX25Session(localAddress: local, remoteAddress: remote,
                                  path: DigiPath(), config: config)
        XCTAssertEqual(session.timers.rto, 12.0, accuracy: 0.01,
                       "learned seed clamps to rtoMax like any seed")
    }

    // MARK: - Coordinator: the single writer

    /// A fresh per-route cache entry with a learned RTO seeds new sessions on
    /// that exact route.
    func testCacheHitSeedsLearnedRtoForThatRoute() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }
        coordinator.adaptiveTransmissionEnabled = true

        // Learn RTT ≈ 5 s on the DRLNOD route → currentRto = 10 s.
        let key = RouteAdaptiveKey(destination: "KB5YZB-7", pathSignature: "DRLNOD")
        coordinator.applyLinkQualitySample(lossRate: 0.0, etx: 1.0, srtt: 5.0,
                                           source: "session", routeKey: key,
                                           newFrames: 1, retransmits: 0)

        let config = coordinator.sessionManager.getConfigForDestination?("KB5YZB-7", "DRLNOD")
        XCTAssertEqual(config?.learnedPathRto ?? -1, 10.0, accuracy: 0.01,
                       "fresh cache entry's currentRto becomes the learned seed")

        // A DIFFERENT path for the same destination has no entry → no seed.
        let other = coordinator.sessionManager.getConfigForDestination?("KB5YZB-7", "FNKTWN")
        XCTAssertNil(other?.learnedPathRto,
                     "learned values are strictly per-route")
    }

    func testAdaptiveOffNeverSeedsLearnedRto() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }
        coordinator.adaptiveTransmissionEnabled = true
        let key = RouteAdaptiveKey(destination: "KB5YZB-7", pathSignature: "DRLNOD")
        coordinator.applyLinkQualitySample(lossRate: 0.0, etx: 1.0, srtt: 5.0,
                                           source: "session", routeKey: key,
                                           newFrames: 1, retransmits: 0)

        coordinator.adaptiveTransmissionEnabled = false
        let config = coordinator.sessionManager.getConfigForDestination?("KB5YZB-7", "DRLNOD")
        XCTAssertNil(config?.learnedPathRto,
                     "opted-out users get vanilla timers — learned data must not leak in")
    }

    func testLearnedSeedFloorClampPreventsHairTriggerTimers() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }
        coordinator.adaptiveTransmissionEnabled = true

        // A freak fast sample: srtt 0.4 s → currentRto would be ~0.8-3 s.
        let key = RouteAdaptiveKey(destination: "KB5YZB-7", pathSignature: "DRLNOD")
        coordinator.applyLinkQualitySample(lossRate: 0.0, etx: 1.0, srtt: 0.4,
                                           source: "session", routeKey: key,
                                           newFrames: 1, retransmits: 0)

        let config = coordinator.sessionManager.getConfigForDestination?("KB5YZB-7", "DRLNOD")
        XCTAssertGreaterThanOrEqual(config?.learnedPathRto ?? 0, 4.0,
                                    "seed floor: never below 4 s regardless of how fast one sample was")
    }

    /// Multiple simultaneous sessions to one destination use the merged config;
    /// learned per-route values must not cross-pollinate through it.
    func testMergedConfigNeverCarriesLearnedRto() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }
        coordinator.adaptiveTransmissionEnabled = true

        let key = RouteAdaptiveKey(destination: "PEER-0", pathSignature: "DIGI-1")
        coordinator.applyLinkQualitySample(lossRate: 0.0, etx: 1.0, srtt: 5.0,
                                           source: "session", routeKey: key,
                                           newFrames: 1, retransmits: 0)

        // An active session to the destination forces the merged-config path.
        _ = coordinator.sessionManager.session(for: AX25Address(call: "PEER", ssid: 0),
                                               path: DigiPath.from(["DIGI-1"]))
        let merged = coordinator.sessionManager.getConfigForDestination?("PEER-0", "OTHER")
        XCTAssertNil(merged?.learnedPathRto,
                     "merged configs mix routes — a route-specific RTO has no meaning there")
    }
}

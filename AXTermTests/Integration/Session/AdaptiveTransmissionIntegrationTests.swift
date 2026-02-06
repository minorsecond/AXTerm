//
//  AdaptiveTransmissionIntegrationTests.swift
//  AXTermTests
//
//  In-process integration tests for adaptive transmission: full pipeline from
//  link quality samples -> per-route cache -> session config, and behavior with
//  vanilla AX.25 vs AXDP-capable stations (capability status -> config/send path).
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 4.1, 7, 7.8
//

import XCTest
@testable import AXTerm

@MainActor
final class AdaptiveTransmissionIntegrationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        #if DEBUG
        SessionCoordinator.disableCompletionNackSackRetransmitForTests = true
        #endif
    }

    override func tearDown() {
        #if DEBUG
        SessionCoordinator.disableCompletionNackSackRetransmitForTests = false
        #endif
        super.tearDown()
    }

    // MARK: - Full adaptive pipeline (no network)

    /// Full pipeline: apply per-route samples -> create sessions -> verify configs -> clearAll -> verify reset.
    func testFullAdaptivePipelinePerRouteThenClear() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }

        coordinator.adaptiveTransmissionEnabled = true
        coordinator.localCallsign = "LOCAL-0"
        let peerA = AX25Address(call: "PEER", ssid: 0)
        let peerB = AX25Address(call: "OTHER", ssid: 1)

        coordinator.applyLinkQualitySample(lossRate: 0.35, etx: 3.0, srtt: nil, source: "session", routeKey: RouteAdaptiveKey(destination: "PEER-0", pathSignature: ""))
        coordinator.applyLinkQualitySample(lossRate: 0.05, etx: 1.1, srtt: 1.0, source: "session", routeKey: RouteAdaptiveKey(destination: "OTHER-1", pathSignature: "WIDE1-1"))

        let sessionA = coordinator.sessionManager.session(for: peerA, path: DigiPath())
        let sessionB = coordinator.sessionManager.session(for: peerB, path: DigiPath.from(["WIDE1-1"]))

        XCTAssertEqual(sessionA.stateMachine.config.windowSize, 1, "PEER direct high loss -> window 1")
        XCTAssertGreaterThanOrEqual(sessionB.stateMachine.config.windowSize, 2, "OTHER via good link -> larger window")

        coordinator.clearAllLearned()

        let configAAfter = coordinator.sessionManager.getConfigForDestination?("PEER-0", "") ?? AX25SessionConfig()
        let configBAfter = coordinator.sessionManager.getConfigForDestination?("OTHER-1", "WIDE1-1") ?? AX25SessionConfig()
        XCTAssertEqual(configAAfter.windowSize, 2, "After clear, PEER route uses global default")
        XCTAssertEqual(configBAfter.windowSize, 2, "After clear, OTHER route uses global default")
    }

    /// Multiple sessions to same destination get merged config; session configs stay fixed.
    func testMultiSessionSameDestinationMergedConfigAndFixedSessionConfig() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }

        coordinator.adaptiveTransmissionEnabled = true
        coordinator.localCallsign = "LOCAL-0"
        let peer = AX25Address(call: "PEER", ssid: 0)

        coordinator.applyLinkQualitySample(lossRate: 0.1, etx: 1.5, srtt: nil, source: "session", routeKey: RouteAdaptiveKey(destination: "PEER-0", pathSignature: ""))
        coordinator.applyLinkQualitySample(lossRate: 0.4, etx: 4.0, srtt: nil, source: "session", routeKey: RouteAdaptiveKey(destination: "PEER-0", pathSignature: "DIGI-1"))

        let sessionDirect = coordinator.sessionManager.session(for: peer, path: DigiPath())
        let sessionVia = coordinator.sessionManager.session(for: peer, path: DigiPath.from(["DIGI-1"]))

        let merged = coordinator.sessionManager.getConfigForDestination?("PEER-0", "other") ?? AX25SessionConfig()
        XCTAssertEqual(merged.windowSize, 1, "Merged uses min(window) across routes")

        XCTAssertEqual(sessionDirect.stateMachine.config.windowSize, 3, "Direct had good link at creation")
        XCTAssertEqual(sessionVia.stateMachine.config.windowSize, 1, "Via had high loss at creation")

        coordinator.applyLinkQualitySample(lossRate: 0.02, etx: 1.0, srtt: nil, source: "session", routeKey: RouteAdaptiveKey(destination: "PEER-0", pathSignature: ""))
        let sameDirect = coordinator.sessionManager.existingSession(for: peer, path: DigiPath())
        XCTAssertNotNil(sameDirect)
        XCTAssertEqual(sameDirect!.stateMachine.config.windowSize, 3, "Existing session config must not change after new samples")
    }

    /// Vanilla AX.25 behavior: when adaptive is off or station in override set, config is default (works with any station).
    func testVanillaAX25GetsDefaultConfigWhenAdaptiveOffOrOverridden() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }

        coordinator.adaptiveTransmissionEnabled = false
        var config = coordinator.sessionManager.getConfigForDestination?("VANILLA-0", "") ?? AX25SessionConfig()
        XCTAssertEqual(config.windowSize, 4)
        XCTAssertEqual(config.maxRetries, 10)

        coordinator.adaptiveTransmissionEnabled = true
        coordinator.globalAdaptiveSettings.windowSize.currentAdaptive = 1
        coordinator.syncSessionManagerConfigFromAdaptive()
        coordinator.useDefaultConfigForDestinations.insert("VANILLA-0")

        config = coordinator.sessionManager.getConfigForDestination?("VANILLA-0", "") ?? AX25SessionConfig()
        XCTAssertEqual(config.windowSize, 4, "Overridden station (e.g. vanilla) gets default config")
    }

    /// AXDP-enabled path: per-route learning applies; config is used for session (works with AXDP stations).
    func testAXDPEnabledPathUsesPerRouteLearnedConfig() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }

        coordinator.adaptiveTransmissionEnabled = true
        coordinator.globalAdaptiveSettings.axdpExtensionsEnabled = true
        coordinator.applyLinkQualitySample(lossRate: 0.08, etx: 1.2, srtt: 1.5, source: "session", routeKey: RouteAdaptiveKey(destination: "AXDP-0", pathSignature: ""))

        let config = coordinator.sessionManager.getConfigForDestination?("AXDP-0", "") ?? AX25SessionConfig()
        XCTAssertGreaterThanOrEqual(config.windowSize, 2)
        XCTAssertLessThanOrEqual(config.windowSize, 7)
        XCTAssertGreaterThanOrEqual(config.rtoMin ?? 0, 1.0)
        XCTAssertLessThanOrEqual(config.rtoMax ?? 60, 60.0)
    }

    /// Session config is immutable for session lifetime (no mid-transmission changes).
    func testSessionConfigImmutableForLifetime() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }

        coordinator.adaptiveTransmissionEnabled = true
        coordinator.globalAdaptiveSettings.windowSize.currentAdaptive = 2
        coordinator.syncSessionManagerConfigFromAdaptive()
        coordinator.localCallsign = "LOCAL-0"
        let peer = AX25Address(call: "PEER", ssid: 0)

        let session = coordinator.sessionManager.session(for: peer, path: DigiPath())
        let windowAtStart = session.stateMachine.config.windowSize
        let maxRetriesAtStart = session.stateMachine.config.maxRetries

        coordinator.globalAdaptiveSettings.windowSize.currentAdaptive = 1
        coordinator.globalAdaptiveSettings.maxRetries.manualValue = 5
        coordinator.globalAdaptiveSettings.maxRetries.mode = .manual
        coordinator.syncSessionManagerConfigFromAdaptive()
        coordinator.applyLinkQualitySample(lossRate: 0.5, etx: 5.0, srtt: nil, source: "session", routeKey: RouteAdaptiveKey(destination: "PEER-0", pathSignature: ""))

        let sameSession = coordinator.sessionManager.existingSession(for: peer, path: DigiPath())
        XCTAssertNotNil(sameSession)
        XCTAssertEqual(sameSession!.stateMachine.config.windowSize, windowAtStart)
        XCTAssertEqual(sameSession!.stateMachine.config.maxRetries, maxRetriesAtStart)
    }
}

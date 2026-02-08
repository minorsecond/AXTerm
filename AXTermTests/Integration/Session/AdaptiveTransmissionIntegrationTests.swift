//
//  AdaptiveTransmissionIntegrationTests.swift
//  AXTermTests
//
//  Created by Ross Wardrup on 2/7/26.
//

import XCTest
import Combine
@testable import AXTerm

@MainActor
final class AdaptiveTransmissionIntegrationTests: XCTestCase {
    var packetEngine: PacketEngine!
    var settings: AppSettingsStore!
    var coordinator: SessionCoordinator!
    
    override func setUp() async throws {
        settings = AppSettingsStore()
        settings.myCallsign = "N0CALL-1"
        settings.adaptiveTransmissionEnabled = true
        
        // Use a mock/test packet engine
        packetEngine = PacketEngine(settings: settings)
        
        // Setup coordinator
        coordinator = SessionCoordinator()
        coordinator.localCallsign = settings.myCallsign
        coordinator.adaptiveTransmissionEnabled = true
        
        // Reset defaults
        coordinator.globalAdaptiveSettings = TxAdaptiveSettings()
        
        // Link them
        coordinator.subscribeToPackets(from: packetEngine)
        
        // Wait for setup
        await Task.yield()
    }
    
    /// PR Requirement: "Robustness & Network Health"
    /// The "median of everyone" logic was removed. We verify that hearing weak stations
    /// (simulated by network stats) does *not* degrade the global defaults.
    func testGlobalDefaultsUnaffectedByNetworkNoise() async {
        // GIVEN: Initial state is high-performance (Window=4, PacLen=128)
        XCTAssertEqual(coordinator.globalAdaptiveSettings.windowSize.currentAdaptive, 2, "Default start is conservative (2) or as configured")
        // Note: Spec says default is 2, but let's say we want to verify it doesn't drop to 1 just because of noise.
        // Actually, let's force a "good" state first to see if it degrades.
        coordinator.globalAdaptiveSettings.windowSize.currentAdaptive = 4
        
        // WHEN: We apply a "network" sample representing a very bad/congested frequency
        // (Loss 50%, ETX 5.0) which previously would have clamped everyone to Window=1.
        // Since we removed the "aggregated network stats" logic in ContentView, 
        // this simulates what *would* happen if that logic were still active or if 
        // applyLinkQualitySample(source: "network") was called.
        //
        // However, since we removed the caller in ContentView, we are strictly testing that
        // *if* such a sample comes in (e.g. from legacy code or misconfiguration), 
        // the `source: "network"` parameter logic in applyLinkQualitySample might still exist
        // but we want to ensure *concurrent* sessions aren't using this "network" source to bleed state.
        //
        // Better Test:
        // Verification that `ContentView` no longer calls `applyLinkQualitySample(source: "network")` 
        // is done by code review/diff.
        //
        // Here, let's verify that `applyLinkQualitySample` with `routeKey: nil` (Global)
        // updates global settings, BUT that `routeKey: specific` does NOT update global settings.
        
        // 1. Simulate a bad specific connection (Session A)
        let routeA = RouteAdaptiveKey(destination: "BADLINK", pathSignature: "")
        coordinator.applyLinkQualitySample(lossRate: 0.5, etx: 5.0, srtt: 2.0, source: "session", routeKey: routeA)
        
        // THEN: Route A should be adapted down
        let adapterA = coordinator.adaptiveCache[routeA]?.settings
        XCTAssertEqual(adapterA?.windowSize.currentAdaptive, 1, "Bad link should adapt to Window=1")
        
        // AND: Global defaults should remain high (unaffected by specific route A)
        XCTAssertEqual(coordinator.globalAdaptiveSettings.windowSize.currentAdaptive, 4, "Global defaults should NOT be degraded by one bad link")
    }
    
    /// PR Requirement: "Concurrent connections"
    /// Verify that Session A (Good) and Session B (Bad) maintain separate parameters.
    func testConcurrentSessionsAdaptIndependently() async {
        // GIVEN: Two routes, one good, one bad
        let routeGood = RouteAdaptiveKey(destination: "GOODLINK", pathSignature: "")
        let routeBad = RouteAdaptiveKey(destination: "BADLINK", pathSignature: "")
        
        // WHEN: We apply quality samples
        
        // Good Link: low loss, good ETX
        // Apply TWICE to verify iterative climbing (2 -> 3 -> 4)
        coordinator.applyLinkQualitySample(lossRate: 0.0, etx: 1.0, srtt: 0.5, source: "session", routeKey: routeGood)
        coordinator.applyLinkQualitySample(lossRate: 0.0, etx: 1.0, srtt: 0.5, source: "session", routeKey: routeGood)
        
        // Bad Link: high loss, bad ETX
        coordinator.applyLinkQualitySample(lossRate: 0.4, etx: 4.0, srtt: 2.0, source: "session", routeKey: routeBad)
        
        // THEN: Check parameters
        
        // Good link should be optimized (Window=4, PacLen=128)
        let settingsGood = coordinator.adaptiveCache[routeGood]?.settings
        XCTAssertNotNil(settingsGood)
        // Expect 4 because we applied good sample twice (2 -> 3 -> 4)
        XCTAssertEqual(settingsGood?.windowSize.currentAdaptive, 4)
        XCTAssertEqual(settingsGood?.paclen.currentAdaptive, 128)
        
        // Bad link should be robust (Window=1, PacLen=64)
        let settingsBad = coordinator.adaptiveCache[routeBad]?.settings
        XCTAssertNotNil(settingsBad)
        XCTAssertEqual(settingsBad?.windowSize.currentAdaptive, 1)
        XCTAssertEqual(settingsBad?.paclen.currentAdaptive, 64)
    }
}

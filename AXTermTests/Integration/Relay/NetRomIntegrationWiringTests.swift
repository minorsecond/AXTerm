//
//  NetRomIntegrationWiringTests.swift
//  AXTermTests
//
//  TDD tests for verifying packet ingestion wiring to NET/ROM integration.
//
//  AUDIT NOTES:
//  - PacketEngine.observePacketForNetRom() calls integration.observePacket()
//  - Existing wiring appears correct but needs verification
//

import XCTest

@testable import AXTerm

@MainActor
final class NetRomIntegrationWiringTests: XCTestCase {

    /// Start from an empty service-endpoint ignore list.
    ///
    /// `CallsignValidator` keeps that list in process-wide state and an
    /// `AppSettingsStore` writes to it whenever the setting changes, so what a
    /// test in this file sees depends on what ran before it in the same
    /// process. These tests route traffic through via-path hops that have to
    /// pass `isValidRoutingNode`, which reads that list — so a stale entry
    /// turns inference off and the failure lands here rather than where it was
    /// caused.
    override func setUp() {
        super.setUp()
        CallsignValidator.configureIgnoredServiceEndpoints([])
    }

    private let localCallsign = "K0EPI"

    // MARK: - Test Helpers

    private func makePacket(
        from: String,
        to: String,
        via: [String] = [],
        timestamp: Date
    ) -> Packet {
        let info = "TEST".data(using: .ascii) ?? Data()
        return Packet(
            timestamp: timestamp,
            from: AX25Address(call: from),
            to: AX25Address(call: to),
            via: via.map { AX25Address(call: $0, repeated: true) },
            frameType: .ui,
            control: 0,
            pid: nil,
            info: info,
            rawAx25: info,
            kissEndpoint: nil,
            infoText: "TEST"
        )
    }


    /// What the process-wide callsign validator thinks of this test's
    /// callsigns, attached to the inference assertions below.
    ///
    /// Left in after a hunt that came up empty. On 2026-09-19 these four
    /// inference cases failed together in one full-suite run and in no other:
    /// not in ten fresh processes of this class alone, not in three further
    /// parallel full runs, and not in a single-process sequential run of all
    /// 7,213 tests — which is where cross-class contamination of a global
    /// would have shown up if that were the cause.
    ///
    /// `CallsignValidator` keeps its ignore list in process-wide mutable
    /// state, `AppSettingsStore.init` rewrites it on every construction, and
    /// `isValidCallsign` is what decides whether `K2BBB` counts as a routing
    /// hop — which is exactly what separates these four tests from the five in
    /// this file that passed. The sequential run argues against it, but the
    /// shape fits well enough that the next occurrence should not have to be
    /// guessed at a second time.
    private func validatorDiagnostics() -> String {
        ["K2BBB", "W0ABC", "K1AAA", "K3CCC"].map {
            "\($0) valid=\(CallsignValidator.isValidCallsign($0)) "
            + "routing=\(CallsignValidator.isValidRoutingNode($0)) "
            + "service=\(CallsignValidator.isServiceEndpoint($0))"
        }.joined(separator: " | ")
    }

    /// Everything needed to tell which gate on the inference path closed:
    /// what the validator thinks of the callsigns, what each observation was
    /// classified as, and the evidence the engine ended up holding.
    private func inferenceDiagnostics(_ integration: NetRomIntegration) -> String {
        "\(validatorDiagnostics())\n  trace: \(integration.observationTrace.joined(separator: "\n         "))"
        + "\n  \(integration.inferenceState)"
    }

    // MARK: - Wiring Tests

    /// Verify that observePacket is called with correct parameters
    func testObservePacket_ProcessesPacketWithTimestamp() {
        // Given: Integration
        let integration = NetRomIntegration(localCallsign: localCallsign, mode: .hybrid)
        let baseTime = Date(timeIntervalSince1970: 1_700_004_000)

        // When: Observe a direct packet
        let packet = makePacket(from: "W0ABC", to: localCallsign, via: [], timestamp: baseTime)
        integration.observePacket(packet, timestamp: baseTime)

        // Then: Should create neighbor
        let neighbors = integration.currentNeighbors()
        XCTAssertTrue(neighbors.contains { $0.call == "W0ABC" },
                      "observePacket should process direct packets")
    }

    func testObservePacket_ProcessesDigipeatedPacket() {
        // Given: Integration in inference mode
        let integration = NetRomIntegration(localCallsign: localCallsign, mode: .inference)
        let baseTime = Date(timeIntervalSince1970: 1_700_004_100)

        // When: Observe third-party digipeated packet
        let packet = makePacket(
            from: "K1AAA",
            to: "K3CCC",
            via: ["K2BBB"],
            timestamp: baseTime
        )
        integration.observePacket(packet, timestamp: baseTime)

        // Then: Should process and create neighbor from via path
        let neighbors = integration.currentNeighbors()
        XCTAssertTrue(neighbors.contains { $0.call == "K2BBB" },
                      "Inference mode should process third-party digipeated packets | "
                      + "neighbors=\(neighbors.map(\.call)) | \(inferenceDiagnostics(integration))")
    }

    func testObservePacket_TracksLinkQuality() {
        // Given: Integration
        let integration = NetRomIntegration(localCallsign: localCallsign, mode: .hybrid)
        let baseTime = Date(timeIntervalSince1970: 1_700_004_200)

        // When: Observe multiple packets
        for i in 0..<10 {
            let packet = makePacket(
                from: "W0ABC",
                to: localCallsign,
                via: [],
                timestamp: baseTime.addingTimeInterval(Double(i))
            )
            integration.observePacket(packet, timestamp: packet.timestamp)
        }

        // Then: Link quality should be tracked
        let linkStats = integration.exportLinkStats()
        XCTAssertTrue(linkStats.contains { $0.fromCall == "W0ABC" && $0.toCall == localCallsign },
                      "observePacket should track link quality")
    }

    func testObservePacket_DuplicateFlagAffectsLinkQuality() {
        // Given: Integration
        let integration = NetRomIntegration(localCallsign: localCallsign, mode: .hybrid)
        let baseTime = Date(timeIntervalSince1970: 1_700_004_300)

        // When: Observe packets with duplicates
        // Packets must be > 0.25s apart to avoid ingestion dedup window
        let packet1 = makePacket(from: "W0ABC", to: localCallsign, via: [], timestamp: baseTime)
        let packet2 = makePacket(from: "W0ABC", to: localCallsign, via: [], timestamp: baseTime.addingTimeInterval(1))
        let packet3 = makePacket(from: "W0ABC", to: localCallsign, via: [], timestamp: baseTime.addingTimeInterval(2))

        integration.observePacket(packet1, timestamp: baseTime, isDuplicate: false)
        integration.observePacket(packet2, timestamp: baseTime.addingTimeInterval(1), isDuplicate: true)
        integration.observePacket(packet3, timestamp: baseTime.addingTimeInterval(2), isDuplicate: true)

        // Then: Link stats should reflect duplicates
        let linkStats = integration.exportLinkStats()
        if let stat = linkStats.first(where: { $0.fromCall == "W0ABC" }) {
            XCTAssertEqual(stat.duplicateCount, 2, "Duplicate count should reflect isDuplicate flags")
        }
    }

    // MARK: - Mode Gating Tests

    func testClassicMode_DoesNotRunInference() {
        // Given: Classic mode
        let integration = NetRomIntegration(localCallsign: localCallsign, mode: .classic)
        let baseTime = Date(timeIntervalSince1970: 1_700_004_400)

        // When: Observe third-party digipeated packet
        let packet = makePacket(
            from: "K1AAA",
            to: "K3CCC",
            via: ["K2BBB"],
            timestamp: baseTime
        )
        integration.observePacket(packet, timestamp: baseTime)

        // Then: Should NOT create inferred routes or neighbors
        let routes = integration.currentRoutes()
        let neighbors = integration.currentNeighbors()

        XCTAssertTrue(routes.isEmpty, "Classic mode should not create inferred routes")
        XCTAssertFalse(neighbors.contains { $0.call == "K2BBB" },
                       "Classic mode should not create inferred neighbors")
    }

    func testInferenceMode_ProcessesThirdPartyTraffic() {
        // Given: Inference mode
        let integration = NetRomIntegration(localCallsign: localCallsign, mode: .inference)
        let baseTime = Date(timeIntervalSince1970: 1_700_004_500)

        // When: Observe third-party digipeated packet
        let packet = makePacket(
            from: "K1AAA",
            to: "K3CCC",
            via: ["K2BBB"],
            timestamp: baseTime
        )
        for i in 0..<3 {
            integration.observePacket(packet, timestamp: baseTime.addingTimeInterval(Double(i)))
        }

        // Then: Should create inferred route
        let routes = integration.currentRoutes()
        XCTAssertTrue(routes.contains { $0.destination == "K1AAA" },
                      "Inference mode should create routes from third-party traffic | "
                      + "routes=\(routes.map(\.destination)) | \(inferenceDiagnostics(integration))")
    }

    func testHybridMode_ProcessesBoth() {
        // Given: Hybrid mode
        let integration = NetRomIntegration(localCallsign: localCallsign, mode: .hybrid)
        let baseTime = Date(timeIntervalSince1970: 1_700_004_600)

        // Direct packet (classic)
        let directPacket = makePacket(from: "W0ABC", to: localCallsign, via: [], timestamp: baseTime)
        integration.observePacket(directPacket, timestamp: baseTime)

        // Third-party packet (inference)
        let thirdPartyPacket = makePacket(
            from: "K1AAA",
            to: "K3CCC",
            via: ["K2BBB"],
            timestamp: baseTime.addingTimeInterval(1)
        )
        for i in 0..<3 {
            integration.observePacket(thirdPartyPacket, timestamp: baseTime.addingTimeInterval(Double(i) + 1))
        }

        // Then: Should have both classic and inferred neighbors
        let neighbors = integration.currentNeighbors()
        XCTAssertTrue(neighbors.contains { $0.call == "W0ABC" },
                      "Hybrid should process direct packets (classic)")
        XCTAssertTrue(neighbors.contains { $0.call == "K2BBB" },
                      "Hybrid should process third-party packets (inference) | "
                      + "neighbors=\(neighbors.map(\.call)) | \(inferenceDiagnostics(integration))")
    }

    // MARK: - Mode Switching Tests

    func testModeSwitching_ClassicToHybrid_EnablesInference() {
        // Given: Start in classic mode
        let integration = NetRomIntegration(localCallsign: localCallsign, mode: .classic)
        let baseTime = Date(timeIntervalSince1970: 1_700_004_700)

        // Observe third-party in classic mode
        let packet = makePacket(from: "K1AAA", to: "K3CCC", via: ["K2BBB"], timestamp: baseTime)
        integration.observePacket(packet, timestamp: baseTime)

        // No routes should exist
        XCTAssertTrue(integration.currentRoutes().isEmpty, "Classic mode should not infer")

        // When: Switch to hybrid
        integration.setMode(.hybrid)

        // And observe another third-party packet
        let packet2 = makePacket(
            from: "K5EEE",
            to: "K6FFF",
            via: ["K7GGG"],
            timestamp: baseTime.addingTimeInterval(1)
        )
        for i in 0..<3 {
            integration.observePacket(packet2, timestamp: baseTime.addingTimeInterval(Double(i) + 1))
        }

        // Then: Should now have inferred routes
        let routes = integration.currentRoutes()
        XCTAssertTrue(routes.contains { $0.destination == "K5EEE" },
                      "After switching to hybrid, inference should be enabled")
    }

    func testModeSwitching_HybridToClassic_DisablesInference() {
        // Given: Start in hybrid mode
        let integration = NetRomIntegration(localCallsign: localCallsign, mode: .hybrid)
        let baseTime = Date(timeIntervalSince1970: 1_700_004_800)

        // Observe third-party packet
        let packet = makePacket(from: "K1AAA", to: "K3CCC", via: ["K2BBB"], timestamp: baseTime)
        for i in 0..<3 {
            integration.observePacket(packet, timestamp: baseTime.addingTimeInterval(Double(i)))
        }

        // Should have inferred route
        let inferred = integration.currentRoutes()
        XCTAssertTrue(inferred.contains { $0.destination == "K1AAA" },
                      "hybrid mode should infer a route to K1AAA before the switch | "
                      + "routes=\(inferred.map(\.destination)) | \(inferenceDiagnostics(integration))")

        // When: Switch to classic
        integration.setMode(.classic)

        // And observe another third-party packet
        let packet2 = makePacket(
            from: "K5EEE",
            to: "K6FFF",
            via: ["K7GGG"],
            timestamp: baseTime.addingTimeInterval(10)
        )
        integration.observePacket(packet2, timestamp: baseTime.addingTimeInterval(10))

        // Then: No new inferred routes should be created
        XCTAssertFalse(integration.currentRoutes().contains { $0.destination == "K5EEE" },
                       "After switching to classic, inference should be disabled")
    }
}

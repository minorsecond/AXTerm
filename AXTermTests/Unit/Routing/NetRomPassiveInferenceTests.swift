//
//  NetRomPassiveInferenceTests.swift
//  AXTermTests
//
//  Created by Codex on 1/30/26.
//

import XCTest

/// NET/ROM passive inference supplements broadcast routing by treating
/// overheard traffic as “soft evidence” for neighbor quality and inferred
/// reachability. Quality math follows the canonical NET/ROM combine formula
/// ((a × b) + 128) / 256 so the inferred confidence integrates with the
/// broadcast router. Decay/obsolescence mirrors the original specification
/// to keep the routing table stable and deterministic.
@testable import AXTerm

@MainActor
final class NetRomPassiveInferenceTests: XCTestCase {
    private let localCallsign = "N0CALL"

    private func makeRouter() -> NetRomRouter {
        NetRomRouter(localCallsign: localCallsign)
    }

    private func makeInference(router: NetRomRouter) -> NetRomPassiveInference {
        NetRomPassiveInference(
            router: router,
            localCallsign: localCallsign,
            config: NetRomInferenceConfig(
                evidenceWindowSeconds: 10,
                inferredRouteHalfLifeSeconds: 5,
                inferredBaseQuality: 60,
                reinforcementIncrement: 30,
                inferredMinimumQuality: 20,
                maxInferredRoutesPerDestination: 2,
                dataProgressWeight: 1.0,
                routingBroadcastWeight: 0.8,
                uiBeaconWeight: 0.4,
                ackOnlyWeight: 0.1,
                retryPenaltyMultiplier: 0.7
            )
        )
    }

    private func makePacket(
        from: String,
        to: String,
        via: [String] = [],
        infoText: String = "OBSERVE",
        frameType: FrameType = .i,
        control: UInt8 = 0x00,
        controlByte1: UInt8? = 0x00,
        timestamp: Date
    ) -> Packet {
        let infoData = infoText.data(using: .ascii) ?? Data()
        return Packet(
            timestamp: timestamp,
            from: AX25Address(call: from),
            to: AX25Address(call: to),
            via: via.map { AX25Address(call: $0, repeated: true) },
            frameType: frameType,
            control: control,
            controlByte1: controlByte1,
            pid: nil,
            info: infoData,
            rawAx25: infoData,
            kissEndpoint: nil,
            infoText: infoText
        )
    }

    func testPassiveNeighborDiscoveryFromDirectPackets() {
        let router = makeRouter()
        let inference = makeInference(router: router)
        let neighbor = "W0ABC"
        let start = Date(timeIntervalSince1970: 1_700_000_800)

        for offset in 0..<4 {
            let packet = makePacket(from: neighbor, to: localCallsign, timestamp: start.addingTimeInterval(Double(offset)))
            inference.observePacket(packet, timestamp: packet.timestamp, classification: PacketClassifier.classify(packet: packet), duplicateStatus: .unique)
        }

        let neighbors = router.currentNeighbors()
        XCTAssertEqual(neighbors.map(\.call), [neighbor])
        let quality = neighbors.first?.quality ?? 0
        XCTAssertGreaterThan(quality, 0)
    }

    func testInfrastructurePacketsDoNotCreateNeighbors() {
        let router = makeRouter()
        let inference = makeInference(router: router)
        let beacon = Date(timeIntervalSince1970: 1_700_000_900)

        let packet = makePacket(
            from: "BEACON",
            to: localCallsign,
            infoText: "BEACON",
            frameType: .ui,
            control: 0x03,
            controlByte1: nil,
            timestamp: beacon
        )
        inference.observePacket(packet, timestamp: beacon, classification: PacketClassifier.classify(packet: packet), duplicateStatus: .unique)

        XCTAssertTrue(router.currentNeighbors().isEmpty)
    }

    func testPassiveRouteInferenceFromViaPatterns() {
        let router = makeRouter()
        let inference = makeInference(router: router)
        let source = "K1AAA"
        let via = "K2BBB"
        let start = Date(timeIntervalSince1970: 1_700_001_000)

        for offset in 0..<5 {
            let packet = makePacket(
                from: source,
                to: localCallsign,
                via: [via],
                infoText: "DATA",
                timestamp: start.addingTimeInterval(Double(offset))
            )
            inference.observePacket(packet, timestamp: packet.timestamp, classification: PacketClassifier.classify(packet: packet), duplicateStatus: .unique)
        }

        let inferredRoutes = router.currentRoutes().filter { $0.destination == source }
        XCTAssertFalse(inferredRoutes.isEmpty)
        let route = inferredRoutes.first!
        XCTAssertTrue(route.path.contains(via))
        XCTAssertGreaterThan(route.quality, 0)
    }

    func testWeakInferredEvidenceStoresHonestQualityNotThresholdFloor() {
        // Inferred route quality must be the honest NET/ROM combine of the
        // evidence-derived advertised quality and the neighbor's path quality —
        // even when that lands below the broadcast acceptance minimum. The old
        // code reverse-engineered whatever value would exactly clear
        // minimumRouteQuality, so every weakly-evidenced route displayed the
        // same fabricated floor (quality 32).
        let router = makeRouter()
        let inference = makeInference(router: router)
        let start = Date(timeIntervalSince1970: 1_700_003_000)

        // Exactly one observation: minimal evidence.
        let packet = makePacket(
            from: "K1AAA",
            to: localCallsign,
            via: ["K2BBB"],
            infoText: "DATA",
            timestamp: start
        )
        inference.observePacket(
            packet,
            timestamp: packet.timestamp,
            classification: PacketClassifier.classify(packet: packet),
            duplicateStatus: .unique
        )

        let route = router.currentRoutes().first { $0.destination == "K1AAA" }
        XCTAssertNotNil(route, "Evidence above inferredMinimumQuality must surface a route")
        guard let route else { return }

        let neighborQuality = router.currentNeighbors().first { $0.call == "K2BBB" }?.quality ?? 0
        // advertised = inferredBaseQuality 60 + reinforcementIncrement 30 × initial score 1.0
        let advertised = 60 + 30
        let expectedCombined = ((advertised * neighborQuality) + 128) / 256

        XCTAssertEqual(route.quality, max(1, expectedCombined),
                       "Stored quality must be the honest combine, not a promoted floor")
        XCTAssertLessThan(expectedCombined, router.config.minimumRouteQuality,
                          "Precondition: this scenario used to be promoted to the floor")
        XCTAssertNotEqual(route.quality, router.config.minimumRouteQuality,
                          "Quality must not sit at the fabricated threshold value")
    }

    func testInferredEvidenceBelowMinimumIsNotPublished() {
        // Weak evidence below inferredMinimumQuality stays internal instead of
        // being inflated into the routing table.
        let router = makeRouter()
        let inference = NetRomPassiveInference(
            router: router,
            localCallsign: localCallsign,
            config: NetRomInferenceConfig(
                evidenceWindowSeconds: 10,
                inferredRouteHalfLifeSeconds: 5,
                inferredBaseQuality: 10,
                reinforcementIncrement: 5,
                inferredMinimumQuality: 20,
                maxInferredRoutesPerDestination: 2,
                dataProgressWeight: 1.0,
                routingBroadcastWeight: 0.8,
                uiBeaconWeight: 0.4,
                ackOnlyWeight: 0.1,
                retryPenaltyMultiplier: 0.7
            )
        )
        let start = Date(timeIntervalSince1970: 1_700_003_100)
        let packet = makePacket(
            from: "K1AAA",
            to: localCallsign,
            via: ["K2BBB"],
            infoText: "DATA",
            timestamp: start
        )
        inference.observePacket(
            packet,
            timestamp: packet.timestamp,
            classification: PacketClassifier.classify(packet: packet),
            duplicateStatus: .unique
        )

        XCTAssertTrue(router.currentRoutes().filter { $0.destination == "K1AAA" }.isEmpty,
                      "Advertised quality below inferredMinimumQuality must not publish a route")
    }

    func testBroadcastRoutesStillEnforceMinimumQuality() {
        // The classic NET/ROM acceptance rule is unchanged for broadcast routes.
        let router = makeRouter()
        let now = Date(timeIntervalSince1970: 1_700_003_200)
        router.observePacket(
            makePacket(from: "K2BBB", to: localCallsign, timestamp: now),
            observedQuality: 80,
            direction: .incoming,
            timestamp: now
        )

        let weak = RouteInfo(
            destination: "K1AAA",
            origin: "K2BBB",
            quality: 10, // combined will land far below minimumRouteQuality
            path: ["K2BBB", "K1AAA"],
            lastUpdated: now
        )
        router.broadcastRoutes(from: "K2BBB", quality: 10, destinations: [weak], timestamp: now)

        XCTAssertTrue(router.currentRoutes().filter { $0.destination == "K1AAA" }.isEmpty,
                      "Broadcast routes below the minimum must still be rejected")
    }

    func testInferredRoutesDecayWithoutReinforcement() {
        let router = makeRouter()
        let inference = makeInference(router: router)
        let source = "K1AAA"
        let via = "K2BBB"
        let start = Date(timeIntervalSince1970: 1_700_001_100)

        let packet = makePacket(from: source, to: localCallsign, via: [via], timestamp: start)
        inference.observePacket(packet, timestamp: start, classification: PacketClassifier.classify(packet: packet), duplicateStatus: .unique)

        XCTAssertFalse(router.currentRoutes().filter { $0.destination == source }.isEmpty)

        let later = start.addingTimeInterval(inference.config.inferredRouteHalfLifeSeconds * 3)
        inference.purgeStaleEvidence(currentDate: later)
        // Expired inferred routes are kept in the router for display purposes.
        // The evidence is purged, but the route entry remains so the UI can show it as expired.
        XCTAssertFalse(router.currentRoutes().filter { $0.destination == source }.isEmpty,
                       "Expired inferred routes should be kept for display")
    }

    func testDirectionalitySanity() {
        let router = makeRouter()
        let inference = makeInference(router: router)
        let source = "K1AAA"
        let via = "K2BBB"
        let start = Date(timeIntervalSince1970: 1_700_001_200)

        let packet = makePacket(from: source, to: localCallsign, via: [via], timestamp: start)
        inference.observePacket(packet, timestamp: start, classification: PacketClassifier.classify(packet: packet), duplicateStatus: .unique)

        XCTAssertFalse(router.currentRoutes().contains { $0.destination == via })
    }

    func testDeterministicOrderingOfInferredRoutes() {
        func driveEvents(router: NetRomRouter) -> [RouteInfo] {
            let inference = makeInference(router: router)
            let source = "K4DDD"
            let via = "K5EEE"
            let start = Date(timeIntervalSince1970: 1_700_001_300)
            for offset in 0..<3 {
                inference.observePacket(
                    makePacket(from: source, to: localCallsign, via: [via], timestamp: start.addingTimeInterval(Double(offset))),
                    timestamp: start.addingTimeInterval(Double(offset)),
                    classification: PacketClassification.dataProgress,
                    duplicateStatus: .unique
                )
            }
            return router.currentRoutes()
        }

        let firstRoutes = driveEvents(router: makeRouter())
        let secondRoutes = driveEvents(router: makeRouter())
        XCTAssertEqual(firstRoutes, secondRoutes)
    }

    func testPassiveRouteInferenceFromMultiHopViaPatterns() {
        let router = makeRouter()
        let inference = makeInference(router: router)
        let source = "K1AAA"
        let viaChain = ["K2BBB", "K3CCC"] // Packet came FROM A VIA B, C
        let start = Date(timeIntervalSince1970: 1_700_001_400)

        for offset in 0..<5 {
            let packet = makePacket(
                from: source,
                to: localCallsign,
                via: viaChain,
                infoText: "DATA",
                timestamp: start.addingTimeInterval(Double(offset))
            )
            inference.observePacket(packet, timestamp: packet.timestamp, classification: PacketClassifier.classify(packet: packet), duplicateStatus: .unique)
        }

        let inferredRoutes = router.currentRoutes().filter { $0.destination == source }
        XCTAssertEqual(inferredRoutes.count, 1)
        let route = inferredRoutes.first!
        
        // The path to reach source A is through the digipeaters in reverse order: [C, B, A]
        XCTAssertEqual(route.path, ["K3CCC", "K2BBB", "K1AAA"])
    }
}

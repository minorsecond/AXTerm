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
                maxInferredRoutesPerDestination: 2
            )
        )
    }

    private func makePacket(
        from: String,
        to: String,
        via: [String] = [],
        infoText: String = "OBSERVE",
        frameType: FrameType = .ui,
        timestamp: Date
    ) -> Packet {
        let infoData = infoText.data(using: .ascii) ?? Data()
        return Packet(
            timestamp: timestamp,
            from: AX25Address(call: from),
            to: AX25Address(call: to),
            via: via.map { AX25Address(call: $0) },
            frameType: frameType,
            control: 0,
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
            inference.observePacket(makePacket(from: neighbor, to: localCallsign, timestamp: start.addingTimeInterval(Double(offset))), timestamp: start.addingTimeInterval(Double(offset)))
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

        inference.observePacket(
            makePacket(
                from: "BEACON",
                to: localCallsign,
                infoText: "BEACON",
                timestamp: beacon
            ),
            timestamp: beacon
        )

        XCTAssertTrue(router.currentNeighbors().isEmpty)
    }

    func testPassiveRouteInferenceFromViaPatterns() {
        let router = makeRouter()
        let inference = makeInference(router: router)
        let source = "K1AAA"
        let via = "K2BBB"
        let start = Date(timeIntervalSince1970: 1_700_001_000)

        for offset in 0..<5 {
            inference.observePacket(
                makePacket(
                    from: source,
                    to: localCallsign,
                    via: [via],
                    infoText: "DATA",
                    timestamp: start.addingTimeInterval(Double(offset))
                ),
                timestamp: start.addingTimeInterval(Double(offset))
            )
        }

        let inferredRoutes = router.currentRoutes().filter { $0.destination == source }
        XCTAssertFalse(inferredRoutes.isEmpty)
        let route = inferredRoutes.first!
        XCTAssertTrue(route.path.contains(via))
        XCTAssertGreaterThan(route.quality, 0)
    }

    func testInferredRoutesDecayWithoutReinforcement() {
        let router = makeRouter()
        let inference = makeInference(router: router)
        let source = "K1AAA"
        let via = "K2BBB"
        let start = Date(timeIntervalSince1970: 1_700_001_100)

        inference.observePacket(
            makePacket(from: source, to: localCallsign, via: [via], timestamp: start),
            timestamp: start
        )

        XCTAssertFalse(router.currentRoutes().filter { $0.destination == source }.isEmpty)

        let later = start.addingTimeInterval(inference.config.inferredRouteHalfLifeSeconds * 3)
        inference.purgeStaleEvidence(currentDate: later)
        XCTAssertTrue(router.currentRoutes().filter { $0.destination == source }.isEmpty)
    }

    func testDirectionalitySanity() {
        let router = makeRouter()
        let inference = makeInference(router: router)
        let source = "K1AAA"
        let via = "K2BBB"
        let start = Date(timeIntervalSince1970: 1_700_001_200)

        inference.observePacket(
            makePacket(from: source, to: localCallsign, via: [via], timestamp: start),
            timestamp: start
        )

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
                    timestamp: start.addingTimeInterval(Double(offset))
                )
            }
            return router.currentRoutes()
        }

        let firstRoutes = driveEvents(router: makeRouter())
        let secondRoutes = driveEvents(router: makeRouter())
        XCTAssertEqual(firstRoutes, secondRoutes)
    }
}

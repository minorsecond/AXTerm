//
//  NetRomRoutingTests.swift
//  AXTermTests
//
//  Created by Codex on 1/30/26.
//

import XCTest

/// NET/ROM routing maintains neighbor path quality and advertised route quality,
/// combining them with [quality = ((broadcastQuality × pathQuality) + 128) / 256]
/// before pruning to the highest-quality peers per destination and expiring
/// stale entries. Tests below encode the canonical NET/ROM behaviors described at
/// packet-radio.net/netrom1.pdf (Section 10 et seq.).
@testable import AXTerm

@MainActor
final class NetRomRoutingTests: XCTestCase {
    private let localCallsign = "N0CALL"
    private func makeRouter() -> NetRomRouter {
        NetRomRouter(localCallsign: localCallsign)
    }

    private func makePacket(
        from: String,
        to: String,
        via: [String] = [],
        infoText: String = "HELLO",
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
            info: infoData,
            rawAx25: infoData,
            infoText: infoText
        )
    }

    private func expectedRouteQuality(broadcastQuality: Int, pathQuality: Int) -> Int {
        let normalized = (broadcastQuality * pathQuality) + 128
        return normalized / 256
    }

    func testNeighborDiscoveryFromRepeatedDirectPackets() {
        let router = makeRouter()
        let neighbor = "W0ABC"
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        for seconds in 0..<3 {
            let packet = makePacket(
                from: neighbor,
                to: localCallsign,
                timestamp: baseDate.addingTimeInterval(Double(seconds))
            )
            router.observePacket(
                packet,
                observedQuality: 180,
                direction: .incoming,
                timestamp: packet.timestamp
            )
        }

        let neighbors = router.currentNeighbors()
        XCTAssertEqual(neighbors.map(\.call), [neighbor], "NET/ROM should build a neighbor entry when repeated direct packets arrive.")
        let quality = neighbors.first?.quality ?? 0
        XCTAssertGreaterThan(quality, 0, "Quality must be positive after multiple receptions.")
        XCTAssertLessThanOrEqual(quality, NetRomConfig.maximumRouteQuality)
    }

    func testMutualDirectNeighborBoostsQuality() {
        let router = makeRouter()
        let neighbor = "W0ABC"
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        router.observePacket(
            makePacket(from: neighbor, to: localCallsign, timestamp: now),
            observedQuality: 120,
            direction: .incoming,
            timestamp: now
        )
        let initialQuality = router.currentNeighbors().first?.quality ?? 0

        router.observePacket(
            makePacket(from: localCallsign, to: neighbor, timestamp: now.addingTimeInterval(1)),
            observedQuality: 210,
            direction: .outgoing,
            timestamp: now.addingTimeInterval(1)
        )

        let mutualQuality = router.currentNeighbors().first?.quality ?? 0
        XCTAssertGreaterThan(mutualQuality, initialQuality, "NET/ROM gives higher preference to neighbors confirmed in both directions.")
    }

    func testInfrastructurePacketsDoNotBecomeNeighbors() {
        let router = makeRouter()
        let beaconDate = Date(timeIntervalSince1970: 1_700_000_200)
        router.observePacket(
            makePacket(
                from: "BEACON",
                to: localCallsign,
                infoText: "BEACON AXTERM",
                timestamp: beaconDate
            ),
            observedQuality: 255,
            direction: .incoming,
            timestamp: beaconDate
        )
        XCTAssertTrue(router.currentNeighbors().isEmpty, "NET/ROM ignores beacon/ID infrastructure packets.")
    }

    func testIndirectRoutesCreatedFromNeighborBroadcasts() {
        let router = makeRouter()
        let neighbor = "W0ABC"
        let now = Date(timeIntervalSince1970: 1_700_000_300)
        router.observePacket(
            makePacket(from: neighbor, to: localCallsign, timestamp: now),
            observedQuality: 200,
            direction: .incoming,
            timestamp: now
        )

        let broadcastQuality = 180
        let advertised = RouteInfo(
            destination: "W1BBB",
            origin: neighbor,
            quality: broadcastQuality,
            path: [neighbor, "W1BBB"],
            lastUpdated: now
        )
        router.broadcastRoutes(
            from: neighbor,
            quality: broadcastQuality,
            destinations: [advertised],
            timestamp: now.addingTimeInterval(1)
        )

        let routes = router.currentRoutes()
        XCTAssertEqual(routes.count, 1)
        let stored = routes.first!
        XCTAssertEqual(stored.destination, advertised.destination)
        XCTAssertEqual(stored.origin, neighbor)

        let neighborQuality = router.currentNeighbors().first?.quality ?? 0
        let expectedQuality = expectedRouteQuality(broadcastQuality: broadcastQuality, pathQuality: neighborQuality)
        XCTAssertEqual(stored.quality, expectedQuality, "Route quality must follow NET/ROM normalization.")
    }

    func testLoopedRoutesIgnored() {
        let router = makeRouter()
        let neighbor = "W0ABC"
        let now = Date(timeIntervalSince1970: 1_700_000_400)
        router.observePacket(
            makePacket(from: neighbor, to: localCallsign, timestamp: now),
            observedQuality: 200,
            direction: .incoming,
            timestamp: now
        )

        let routesToPublish = [
            RouteInfo(destination: localCallsign, origin: neighbor, quality: 200, path: [neighbor, localCallsign], lastUpdated: now),
            RouteInfo(destination: "W2CCC", origin: neighbor, quality: 200, path: [neighbor, "W2CCC"], lastUpdated: now)
        ]
        router.broadcastRoutes(from: neighbor, quality: 200, destinations: routesToPublish, timestamp: now.addingTimeInterval(1))

        let currentDestinations = router.currentRoutes().map(\.destination)
        XCTAssertFalse(currentDestinations.contains(localCallsign), "NET/ROM should ignore routes that loop back to the origin node.")
        XCTAssertTrue(currentDestinations.contains("W2CCC"))
    }

    func testKeepsTopNRoutesAboveThreshold() {
        let router = makeRouter()
        let baseTime = Date(timeIntervalSince1970: 1_700_000_500)
        let destination = "W2DDD"
        let origins = ["W0ABC", "W1XYZ", "K0ZZZ"]
        let advertisedQualities = [210, 190, 170]

        for (index, origin) in origins.enumerated() {
            let timestamp = baseTime.addingTimeInterval(Double(index))
            router.observePacket(
                makePacket(from: origin, to: localCallsign, timestamp: timestamp),
                observedQuality: 200 - (index * 20),
                direction: .incoming,
                timestamp: timestamp
            )
            router.broadcastRoutes(
                from: origin,
                quality: advertisedQualities[index],
                destinations: [
                    RouteInfo(destination: destination, origin: origin, quality: advertisedQualities[index], path: [origin, destination], lastUpdated: timestamp.addingTimeInterval(0.5))
                ],
                timestamp: timestamp.addingTimeInterval(0.5)
            )
        }

        var bestPaths = router.bestPaths(from: destination)
        XCTAssertEqual(bestPaths.count, NetRomConfig.default.maxRoutesPerDestination)
        let sortedQualities = bestPaths.map(\.quality)
        XCTAssertEqual(sortedQualities, sortedQualities.sorted(by: >), "Best paths must be ordered from highest to lowest quality.")

        let lowQualityOrigin = "N0LOW"
        let lowQualityTime = baseTime.addingTimeInterval(10)
        router.observePacket(
            makePacket(from: lowQualityOrigin, to: localCallsign, timestamp: lowQualityTime),
            observedQuality: 10,
            direction: .incoming,
            timestamp: lowQualityTime
        )
        router.broadcastRoutes(
            from: lowQualityOrigin,
            quality: 5,
            destinations: [
                RouteInfo(destination: destination, origin: lowQualityOrigin, quality: 5, path: [lowQualityOrigin, destination], lastUpdated: lowQualityTime)
            ],
            timestamp: lowQualityTime
        )

        bestPaths = router.bestPaths(from: destination)
        XCTAssertFalse(bestPaths.contains { $0.nodes.last == destination && $0.quality < NetRomConfig.default.minimumRouteQuality }, "Routes below minimum quality must be rejected.")
    }

    func testRoutesExpireAfterObsolescenceInterval() {
        let router = makeRouter()
        let now = Date(timeIntervalSince1970: 1_700_000_600)
        let neighbor = "W0ABC"
        router.observePacket(
            makePacket(from: neighbor, to: localCallsign, timestamp: now),
            observedQuality: 220,
            direction: .incoming,
            timestamp: now
        )
        router.broadcastRoutes(
            from: neighbor,
            quality: 200,
            destinations: [
                RouteInfo(destination: "W3EEE", origin: neighbor, quality: 200, path: [neighbor, "W3EEE"], lastUpdated: now)
            ],
            timestamp: now.addingTimeInterval(1)
        )

        // purgeStaleRoutes is now a no-op — expired routes are kept for display.
        // bestRouteTo() guards against using them for routing decisions.
        let later = now.addingTimeInterval(NetRomConfig.default.routeTTLSeconds + 2)
        router.purgeStaleRoutes(currentDate: later)
        XCTAssertFalse(router.currentRoutes().isEmpty, "Expired routes should be kept for display")
        XCTAssertNil(router.bestRouteTo("W3EEE"), "bestRouteTo must not return expired routes")
    }

    func testDeterministicRouteOrdering() {
        let router = makeRouter()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_700)
        let neighbors = ["W0ABC", "W1XYZ"]
        for (index, neighbor) in neighbors.enumerated() {
            router.observePacket(
                makePacket(from: neighbor, to: localCallsign, timestamp: timestamp.addingTimeInterval(Double(index))),
                observedQuality: 230,
                direction: .incoming,
                timestamp: timestamp.addingTimeInterval(Double(index))
            )
            router.broadcastRoutes(
                from: neighbor,
                quality: 200 - (index * 20),
                destinations: [
                    RouteInfo(destination: "W4FFF", origin: neighbor, quality: 200 - (index * 20), path: [neighbor, "W4FFF"], lastUpdated: timestamp.addingTimeInterval(Double(index) + 0.5))
                ],
                timestamp: timestamp.addingTimeInterval(Double(index) + 0.5)
            )
        }

        let routes = router.currentRoutes()
        let deterministicallySorted = routes.sorted { $0.destination == $1.destination ? $0.quality > $1.quality : $0.destination < $1.destination }
        XCTAssertEqual(routes, deterministicallySorted, "Routing table must present entries in a deterministic order even when qualities tie.")
    }

    func testNeighborQualityCanDecreaseWithLowObservedQuality() {
        let router = makeRouter()
        let neighbor = "W0ABC"
        let baseDate = Date(timeIntervalSince1970: 1_700_000_800)

        // First, establish neighbor with high observed quality
        for i in 0..<5 {
            router.observePacket(
                makePacket(from: neighbor, to: localCallsign, timestamp: baseDate.addingTimeInterval(Double(i))),
                observedQuality: 250,
                direction: .incoming,
                timestamp: baseDate.addingTimeInterval(Double(i))
            )
        }

        let highQuality = router.currentNeighbors().first?.quality ?? 0
        XCTAssertGreaterThan(highQuality, 200, "Quality should be high after good observations")

        // Now observe with low quality repeatedly
        for i in 0..<10 {
            router.observePacket(
                makePacket(from: neighbor, to: localCallsign, timestamp: baseDate.addingTimeInterval(Double(10 + i))),
                observedQuality: 50,
                direction: .incoming,
                timestamp: baseDate.addingTimeInterval(Double(10 + i))
            )
        }

        let lowQuality = router.currentNeighbors().first?.quality ?? 0
        XCTAssertLessThan(lowQuality, highQuality, "Quality must decrease when observed link quality is poor")
        XCTAssertLessThan(lowQuality, 200, "Quality should converge toward observed value")
    }

    func testNeighborQualityDoesNotPegAt255() {
        let router = makeRouter()
        let neighbor = "W0ABC"
        let baseDate = Date(timeIntervalSince1970: 1_700_000_900)

        // Observe many packets with moderate quality
        for i in 0..<20 {
            router.observePacket(
                makePacket(from: neighbor, to: localCallsign, timestamp: baseDate.addingTimeInterval(Double(i))),
                observedQuality: 150,
                direction: .incoming,
                timestamp: baseDate.addingTimeInterval(Double(i))
            )
        }

        let quality = router.currentNeighbors().first?.quality ?? 0
        // With EWMA blending and moderate observed quality, should NOT hit 255
        XCTAssertLessThan(quality, 255, "Quality should not peg at 255 with moderate observed quality")
        XCTAssertGreaterThan(quality, 100, "Quality should be reasonable")
    }
}

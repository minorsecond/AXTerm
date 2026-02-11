//
//  RoutingFreshnessClassificationTests.swift
//  AXTermTests
//
//  Tests for integration of PacketClassification with routing freshness.
//  Written TDD-style: these tests must fail initially until production code is implemented.
//

import XCTest
@testable import AXTerm

@MainActor
final class RoutingFreshnessClassificationTests: XCTestCase {

    // MARK: - Classification Routing Refresh Properties

    func testDataProgressRefreshesNeighborAndRoute() {
        let classification = PacketClassification.dataProgress
        XCTAssertTrue(classification.refreshesNeighbor)
        XCTAssertTrue(classification.refreshesRoute)
    }

    func testRoutingBroadcastRefreshesRouteOnlyByDefault() {
        let classification = PacketClassification.routingBroadcast
        XCTAssertFalse(classification.refreshesNeighbor)
        XCTAssertTrue(classification.refreshesRoute)
    }

    func testUIBeaconWeaklyRefreshesNeighborButNotRouteByDefault() {
        let classification = PacketClassification.uiBeacon
        XCTAssertTrue(classification.refreshesNeighbor)
        XCTAssertFalse(classification.refreshesRoute)
    }

    func testAckOnlyDoesNotRefreshRouting() {
        let classification = PacketClassification.ackOnly
        XCTAssertFalse(classification.refreshesNeighbor)
        XCTAssertFalse(classification.refreshesRoute)
    }

    func testRetryOrDuplicateDoesNotRefreshRouting() {
        let classification = PacketClassification.retryOrDuplicate
        XCTAssertFalse(classification.refreshesNeighbor)
        XCTAssertFalse(classification.refreshesRoute)
    }

    func testSessionControlDoesNotRefreshRouting() {
        let classification = PacketClassification.sessionControl
        XCTAssertFalse(classification.refreshesNeighbor)
        XCTAssertFalse(classification.refreshesRoute)
    }

    func testUnknownDoesNotRefreshRouting() {
        let classification = PacketClassification.unknown
        XCTAssertFalse(classification.refreshesNeighbor)
        XCTAssertFalse(classification.refreshesRoute)
    }

    // MARK: - Mode Integration Tests

    func testClassicMode_RefreshesClassicRoutesOnly() {
        let integration = NetRomIntegration(localCallsign: "TEST0", mode: .classic)
        let baseTime = Date(timeIntervalSince1970: 1_700_100_000)

        // Seed a classic/broadcast route and an inferred route.
        let classicRoute = RouteInfo(destination: "W2XYZ", origin: "W1ABC", quality: 200, path: ["W1ABC", "W2XYZ"], lastUpdated: baseTime, sourceType: "broadcast")
        let inferredRoute = RouteInfo(destination: "W3QRS", origin: "W1ABC", quality: 180, path: ["W1ABC", "W3QRS"], lastUpdated: baseTime, sourceType: "inferred")
        integration.importRoutes([classicRoute, inferredRoute])

        let dataPacket = makePacket(frameType: .i, control: 0x00, controlByte1: 0x00, pid: 0xF0, info: Data([0x41]), fromCall: "W1ABC", toCall: "TEST0", timestamp: baseTime.addingTimeInterval(60))
        integration.observePacket(dataPacket, timestamp: dataPacket.timestamp)

        let routes = integration.currentRoutes()
        let updatedClassic = routes.first { $0.destination == "W2XYZ" }
        let updatedInferred = routes.first { $0.destination == "W3QRS" }

        XCTAssertEqual(updatedClassic?.lastUpdated, dataPacket.timestamp, "Classic/broadcast routes should refresh on dataProgress in classic mode.")
        XCTAssertEqual(updatedInferred?.lastUpdated, baseTime, "Inferred routes must not be refreshed in classic mode.")
    }

    func testInferenceMode_UpdatesInferredRoutesButNotClassic() {
        let integration = NetRomIntegration(localCallsign: "TEST0", mode: .inference)
        let baseTime = Date(timeIntervalSince1970: 1_700_100_100)

        let classicRoute = RouteInfo(destination: "W2XYZ", origin: "W1ABC", quality: 200, path: ["W1ABC", "W2XYZ"], lastUpdated: baseTime, sourceType: "broadcast")
        integration.importRoutes([classicRoute])

        // Digipeated packet should infer route to K9OUT via W1ABC.
        let inferredPacket = makePacket(frameType: .i, control: 0x00, controlByte1: 0x00, pid: 0xF0, info: Data([0x42]), fromCall: "K9OUT", toCall: "K8DST", via: ["W1ABC"], timestamp: baseTime.addingTimeInterval(30))
        integration.observePacket(inferredPacket, timestamp: inferredPacket.timestamp)

        let routes = integration.currentRoutes()
        let inferredRoute = routes.first { $0.destination == "K9OUT" }
        let unchangedClassic = routes.first { $0.destination == "W2XYZ" }

        XCTAssertEqual(inferredRoute?.lastUpdated, inferredPacket.timestamp, "Inferred routes should refresh on dataProgress evidence in inference mode.")
        XCTAssertEqual(unchangedClassic?.lastUpdated, baseTime, "Classic routes must not be refreshed in inference mode.")
    }

    func testHybridMode_RefreshesBothClassicAndInferredBySourceType() {
        let integration = NetRomIntegration(localCallsign: "TEST0", mode: .hybrid)
        let baseTime = Date(timeIntervalSince1970: 1_700_100_200)

        let classicRoute = RouteInfo(destination: "W2XYZ", origin: "W1ABC", quality: 200, path: ["W1ABC", "W2XYZ"], lastUpdated: baseTime, sourceType: "broadcast")
        let inferredRoute = RouteInfo(destination: "K9OUT", origin: "W1ABC", quality: 160, path: ["W1ABC", "K9OUT"], lastUpdated: baseTime, sourceType: "inferred")
        integration.importRoutes([classicRoute, inferredRoute])

        let dataPacket = makePacket(frameType: .i, control: 0x00, controlByte1: 0x00, pid: 0xF0, info: Data([0x43]), fromCall: "W1ABC", toCall: "TEST0", timestamp: baseTime.addingTimeInterval(20))
        integration.observePacket(dataPacket, timestamp: dataPacket.timestamp)

        let inferredPacket = makePacket(frameType: .i, control: 0x00, controlByte1: 0x00, pid: 0xF0, info: Data([0x44]), fromCall: "K9OUT", toCall: "K8DST", via: ["W1ABC"], timestamp: baseTime.addingTimeInterval(40))
        integration.observePacket(inferredPacket, timestamp: inferredPacket.timestamp)

        let routes = integration.currentRoutes()
        let updatedClassic = routes.first { $0.destination == "W2XYZ" }
        let updatedInferred = routes.first { $0.destination == "K9OUT" }

        XCTAssertEqual(updatedClassic?.lastUpdated, dataPacket.timestamp, "Classic/broadcast routes should refresh on dataProgress in hybrid mode.")
        XCTAssertEqual(updatedInferred?.lastUpdated, inferredPacket.timestamp, "Inferred routes should refresh via passive inference in hybrid mode.")
    }

    // MARK: - Test Helpers

    private func makePacket(
        frameType: FrameType,
        control: UInt8,
        controlByte1: UInt8? = nil,
        pid: UInt8?,
        info: Data,
        fromCall: String,
        toCall: String,
        via: [String] = [],
        timestamp: Date
    ) -> Packet {
        Packet(
            timestamp: timestamp,
            from: AX25Address(call: fromCall),
            to: AX25Address(call: toCall),
            via: via.map { AX25Address(call: $0, repeated: true) },
            frameType: frameType,
            control: control,
            controlByte1: controlByte1,
            pid: pid,
            info: info,
            rawAx25: Data()
        )
    }
}

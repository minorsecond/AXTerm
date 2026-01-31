//
//  RoutingFreshnessClassificationTests.swift
//  AXTermTests
//
//  Tests for integration of PacketClassification with routing freshness.
//  Written TDD-style: these tests must fail initially until production code is implemented.
//

import XCTest
@testable import AXTerm

final class RoutingFreshnessClassificationTests: XCTestCase {

    // MARK: - Classification Routing Refresh Properties

    /// dataProgress should refresh neighbor timestamps
    func testDataProgressRefreshesNeighborTimestamp() {
        let classification = PacketClassification.dataProgress
        XCTAssertTrue(classification.refreshesNeighbor)
    }

    /// dataProgress should refresh route timestamps
    func testDataProgressRefreshesRouteTimestamp() {
        let classification = PacketClassification.dataProgress
        XCTAssertTrue(classification.refreshesRoute)
    }

    /// routingBroadcast should refresh route timestamps
    func testRoutingBroadcastRefreshesRouteTimestamp() {
        let classification = PacketClassification.routingBroadcast
        XCTAssertTrue(classification.refreshesRoute)
    }

    /// routingBroadcast should NOT refresh neighbor timestamps (broadcasts don't indicate neighbor presence)
    func testRoutingBroadcastDoesNotRefreshNeighborTimestamp() {
        let classification = PacketClassification.routingBroadcast
        // Routing broadcasts update routes, not direct neighbor relationships
        // Neighbor presence is established by the underlying packet, not the broadcast content
        XCTAssertFalse(classification.refreshesNeighbor)
    }

    /// uiBeacon should have weak refresh for routes (configurable)
    func testUIBeaconWeaklyRefreshesRoutes() {
        let classification = PacketClassification.uiBeacon
        // UI frames provide weak evidence - one-way, no acknowledgement
        XCTAssertTrue(classification.refreshesRoute)  // Weak refresh is still a refresh
    }

    /// uiBeacon should weakly refresh neighbor (it indicates RF presence)
    func testUIBeaconWeaklyRefreshesNeighbor() {
        let classification = PacketClassification.uiBeacon
        XCTAssertTrue(classification.refreshesNeighbor)
    }

    /// ackOnly (RR/RNR) should NOT refresh neighbor timestamps
    func testAckOnlyDoesNotRefreshNeighborTimestamp() {
        let classification = PacketClassification.ackOnly
        // ACKs don't carry new data - they're flow control
        XCTAssertFalse(classification.refreshesNeighbor)
    }

    /// ackOnly should NOT refresh route timestamps
    func testAckOnlyDoesNotRefreshRouteTimestamp() {
        let classification = PacketClassification.ackOnly
        XCTAssertFalse(classification.refreshesRoute)
    }

    /// retryOrDuplicate should NOT refresh neighbor timestamps
    func testRetryOrDuplicateDoesNotRefreshNeighborTimestamp() {
        let classification = PacketClassification.retryOrDuplicate
        // Retries indicate link problems, not freshness
        XCTAssertFalse(classification.refreshesNeighbor)
    }

    /// retryOrDuplicate should NOT refresh route timestamps
    func testRetryOrDuplicateDoesNotRefreshRouteTimestamp() {
        let classification = PacketClassification.retryOrDuplicate
        XCTAssertFalse(classification.refreshesRoute)
    }

    /// sessionControl should NOT refresh neighbor timestamps (it's control, not data)
    func testSessionControlDoesNotRefreshNeighborTimestamp() {
        let classification = PacketClassification.sessionControl
        // Session control frames (SABM, UA, DISC, etc.) are control plane, not data
        XCTAssertFalse(classification.refreshesNeighbor)
    }

    /// sessionControl should NOT refresh route timestamps
    func testSessionControlDoesNotRefreshRouteTimestamp() {
        let classification = PacketClassification.sessionControl
        XCTAssertFalse(classification.refreshesRoute)
    }

    /// unknown classification should NOT refresh anything
    func testUnknownDoesNotRefreshAnything() {
        let classification = PacketClassification.unknown
        XCTAssertFalse(classification.refreshesNeighbor)
        XCTAssertFalse(classification.refreshesRoute)
    }

    // MARK: - Router Integration Tests

    /// Router should only refresh neighbor timestamp for data-carrying classifications
    func testRouterRefreshesNeighborOnlyForDataProgress() {
        let router = NetRomRouter(localCallsign: "TEST0", config: .default)
        let baseTime = Date(timeIntervalSince1970: 1000)

        // Initial observation to create neighbor
        let initialPacket = makePacket(
            frameType: .i,
            control: 0x00,
            controlByte1: 0x00,
            pid: 0xF0,
            info: Data([0x48, 0x65, 0x6C, 0x6C, 0x6F]),  // "Hello"
            fromCall: "W1ABC",
            toCall: "TEST0"
        )
        router.observePacketWithClassification(
            initialPacket,
            classification: .dataProgress,
            observedQuality: 200,
            direction: .incoming,
            timestamp: baseTime
        )

        // Verify neighbor was created
        let neighbors1 = router.currentNeighbors()
        XCTAssertEqual(neighbors1.count, 1)
        XCTAssertEqual(neighbors1.first?.lastSeen, baseTime)

        // ACK-only packet should NOT update timestamp
        let ackPacket = makePacket(
            frameType: .s,
            control: 0xA1,  // RR
            pid: nil,
            info: Data(),
            fromCall: "W1ABC",
            toCall: "TEST0"
        )
        let laterTime = baseTime.addingTimeInterval(60)
        router.observePacketWithClassification(
            ackPacket,
            classification: .ackOnly,
            observedQuality: 200,
            direction: .incoming,
            timestamp: laterTime
        )

        // Timestamp should NOT have changed
        let neighbors2 = router.currentNeighbors()
        XCTAssertEqual(neighbors2.first?.lastSeen, baseTime)  // Still original time

        // Data progress packet SHOULD update timestamp
        let dataPacket = makePacket(
            frameType: .i,
            control: 0x02,
            controlByte1: 0x40,
            pid: 0xF0,
            info: Data([0x57, 0x6F, 0x72, 0x6C, 0x64]),  // "World"
            fromCall: "W1ABC",
            toCall: "TEST0"
        )
        let evenLaterTime = baseTime.addingTimeInterval(120)
        router.observePacketWithClassification(
            dataPacket,
            classification: .dataProgress,
            observedQuality: 200,
            direction: .incoming,
            timestamp: evenLaterTime
        )

        // Timestamp SHOULD have updated
        let neighbors3 = router.currentNeighbors()
        XCTAssertEqual(neighbors3.first?.lastSeen, evenLaterTime)
    }

    /// Router should not create neighbor for ack-only packets
    func testRouterDoesNotCreateNeighborForAckOnly() {
        let router = NetRomRouter(localCallsign: "TEST0", config: .default)
        let baseTime = Date(timeIntervalSince1970: 1000)

        // ACK-only packet from unknown station should NOT create neighbor
        let ackPacket = makePacket(
            frameType: .s,
            control: 0xA1,  // RR
            pid: nil,
            info: Data(),
            fromCall: "W9NEW",
            toCall: "TEST0"
        )
        router.observePacketWithClassification(
            ackPacket,
            classification: .ackOnly,
            observedQuality: 200,
            direction: .incoming,
            timestamp: baseTime
        )

        // Should NOT have created a neighbor
        let neighbors = router.currentNeighbors()
        XCTAssertTrue(neighbors.isEmpty)
    }

    /// Router should not create neighbor for retry/duplicate packets
    func testRouterDoesNotCreateNeighborForRetry() {
        let router = NetRomRouter(localCallsign: "TEST0", config: .default)
        let baseTime = Date(timeIntervalSince1970: 1000)

        // REJ packet from unknown station should NOT create neighbor
        let rejPacket = makePacket(
            frameType: .s,
            control: 0x09,  // REJ
            pid: nil,
            info: Data(),
            fromCall: "W9NEW",
            toCall: "TEST0"
        )
        router.observePacketWithClassification(
            rejPacket,
            classification: .retryOrDuplicate,
            observedQuality: 200,
            direction: .incoming,
            timestamp: baseTime
        )

        let neighbors = router.currentNeighbors()
        XCTAssertTrue(neighbors.isEmpty)
    }

    // MARK: - Test Helpers

    private func makePacket(
        frameType: FrameType,
        control: UInt8,
        controlByte1: UInt8? = nil,
        pid: UInt8?,
        info: Data,
        fromCall: String = "TEST1",
        toCall: String = "TEST2"
    ) -> Packet {
        Packet(
            timestamp: Date(),
            from: AX25Address(call: fromCall),
            to: AX25Address(call: toCall),
            via: [],
            frameType: frameType,
            control: control,
            controlByte1: controlByte1,
            pid: pid,
            info: info,
            rawAx25: Data()
        )
    }
}

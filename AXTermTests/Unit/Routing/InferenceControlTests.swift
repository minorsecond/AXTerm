//
//  InferenceControlTests.swift
//  AXTermTests
//
//  Tests for control-aware inference confidence and retry penalties.
//

import XCTest
@testable import AXTerm

@MainActor
final class InferenceControlTests: XCTestCase {
    private func makeDigipeatedPacket(from: String, via: [String], timestamp: Date) -> Packet {
        Packet(
            timestamp: timestamp,
            from: AX25Address(call: from),
            to: AX25Address(call: "ANY"),
            via: via.map { AX25Address(call: $0, repeated: true) },
            frameType: .i,
            control: 0x00,
            controlByte1: 0x00,
            pid: 0xF0,
            info: Data([0x41]),
            rawAx25: Data([0x00])
        )
    }

    func testDataProgressCreatesInferredRoute() {
        let integration = NetRomIntegration(localCallsign: "TEST0", mode: .inference)
        let base = Date(timeIntervalSince1970: 1_700_400_000)

        let packet = makeDigipeatedPacket(from: "K9OUT", via: ["W1ABC"], timestamp: base)
        integration.observePacket(packet, timestamp: base)

        let routes = integration.currentRoutes()
        XCTAssertTrue(routes.contains { $0.destination == "K9OUT" && $0.origin == "W1ABC" && $0.sourceType == "inferred" })
    }

    func testRetryHeavyEvidenceReducesInferredConfidence() {
        let integration = NetRomIntegration(localCallsign: "TEST0", mode: .inference)
        let base = Date(timeIntervalSince1970: 1_700_400_100)

        let packet = makeDigipeatedPacket(from: "K9OUT", via: ["W1ABC"], timestamp: base)
        integration.observePacket(packet, timestamp: base)
        let initialQuality = integration.currentRoutes().first { $0.destination == "K9OUT" }?.quality ?? 0

        // Apply retry penalty
        integration.observePacket(packet, timestamp: base.addingTimeInterval(1), isDuplicate: true)
        let penalizedQuality = integration.currentRoutes().first { $0.destination == "K9OUT" }?.quality ?? 0

        XCTAssertLessThanOrEqual(penalizedQuality, initialQuality, "Retry-heavy evidence should not increase inferred confidence.")
    }

    func testAckOnlyDoesNotInferRoutes() {
        let integration = NetRomIntegration(localCallsign: "TEST0", mode: .inference)
        let base = Date(timeIntervalSince1970: 1_700_400_200)

        let ackPacket = Packet(
            timestamp: base,
            from: AX25Address(call: "K9OUT"),
            to: AX25Address(call: "ANY"),
            via: [AX25Address(call: "W1ABC", repeated: true)],
            frameType: .s,
            control: 0xA1, // RR
            pid: nil,
            info: Data(),
            rawAx25: Data()
        )

        integration.observePacket(ackPacket, timestamp: base)
        let routes = integration.currentRoutes()
        XCTAssertFalse(routes.contains { $0.destination == "K9OUT" }, "ACK-only frames should not infer new routes.")
    }
}

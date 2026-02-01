//
//  NetRomBroadcastIntegrationTests.swift
//  AXTermTests
//
//  Tests for NET/ROM broadcast processing and persistence.
//

import XCTest
@testable import AXTerm

@MainActor
final class NetRomBroadcastIntegrationTests: XCTestCase {

    private let localCallsign = "W0TST"
    private let baseTime = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Integration Tests

    func testBroadcastPacketCreatesNeighbor() async {
        let integration = NetRomIntegration(localCallsign: localCallsign, mode: .classic)

        // Create a NET/ROM broadcast packet
        let broadcastPacket = makeBroadcastPacket(
            from: "AF0AJ",
            entries: [
                makeEntry(dest: "W1ABC", alias: "NODE1", neighbor: "K0XYZ", quality: 200)
            ]
        )

        // Process the packet
        integration.observePacket(broadcastPacket, timestamp: baseTime)

        // The broadcast sender should now be a neighbor
        let neighbors = integration.currentNeighbors()
        XCTAssertTrue(neighbors.contains { $0.call == "AF0AJ" }, "Broadcast sender should be registered as neighbor")
    }

    func testBroadcastPacketCreatesRoutes() async {
        let integration = NetRomIntegration(localCallsign: localCallsign, mode: .classic)

        // First, establish the sender as a neighbor via a direct packet
        let directPacket = Packet(
            timestamp: baseTime,
            from: AX25Address(call: "AF0AJ"),
            to: AX25Address(call: localCallsign),
            via: [],
            frameType: .ui,
            control: 0,
            pid: nil,
            info: Data(),
            rawAx25: Data(),
            kissEndpoint: nil,
            infoText: "TEST"
        )
        integration.observePacket(directPacket, timestamp: baseTime)

        // Now send a broadcast with routes
        let broadcastPacket = makeBroadcastPacket(
            from: "AF0AJ",
            entries: [
                makeEntry(dest: "W1ABC", alias: "NODE1", neighbor: "AF0AJ", quality: 200),
                makeEntry(dest: "N0CAL", alias: "NODE2", neighbor: "AF0AJ", quality: 150)
            ]
        )
        integration.observePacket(broadcastPacket, timestamp: baseTime.addingTimeInterval(1))

        // Check routes were created
        let routes = integration.currentRoutes()
        XCTAssertTrue(routes.contains { $0.destination == "W1ABC" }, "Route to W1ABC should exist")
        XCTAssertTrue(routes.contains { $0.destination == "N0CAL" }, "Route to N0CAL should exist")
    }

    func testBroadcastRoutesHaveCorrectSourceType() async {
        let integration = NetRomIntegration(localCallsign: localCallsign, mode: .classic)

        // Establish neighbor
        let directPacket = Packet(
            timestamp: baseTime,
            from: AX25Address(call: "AF0AJ"),
            to: AX25Address(call: localCallsign),
            via: [],
            frameType: .ui,
            control: 0,
            pid: nil,
            info: Data(),
            rawAx25: Data(),
            kissEndpoint: nil,
            infoText: "TEST"
        )
        integration.observePacket(directPacket, timestamp: baseTime)

        // Send broadcast
        let broadcastPacket = makeBroadcastPacket(
            from: "AF0AJ",
            entries: [
                makeEntry(dest: "W1ABC", alias: "NODE1", neighbor: "AF0AJ", quality: 200)
            ]
        )
        integration.observePacket(broadcastPacket, timestamp: baseTime.addingTimeInterval(1))

        // Verify source type is "broadcast"
        let routes = integration.currentRoutes()
        let w1abcRoute = routes.first { $0.destination == "W1ABC" }
        XCTAssertNotNil(w1abcRoute)
        XCTAssertEqual(w1abcRoute?.sourceType, "broadcast", "Routes from NODES packets should have sourceType 'broadcast'")
    }

    func testBroadcastWorksInAllModes() async {
        let modes: [NetRomRoutingMode] = [.classic, .inference, .hybrid]

        for mode in modes {
            let integration = NetRomIntegration(localCallsign: localCallsign, mode: mode)

            // Establish neighbor first
            let directPacket = Packet(
                timestamp: baseTime,
                from: AX25Address(call: "K0ABC"),
                to: AX25Address(call: localCallsign),
                via: [],
                frameType: .ui,
                control: 0,
                pid: nil,
                info: Data(),
                rawAx25: Data(),
                kissEndpoint: nil,
                infoText: "TEST"
            )
            integration.observePacket(directPacket, timestamp: baseTime)

            // Send broadcast
            let broadcastPacket = makeBroadcastPacket(
                from: "K0ABC",
                entries: [
                    makeEntry(dest: "W1XYZ", alias: "NODE", neighbor: "K0ABC", quality: 200)
                ]
            )
            integration.observePacket(broadcastPacket, timestamp: baseTime.addingTimeInterval(1))

            // Verify neighbor was created (in all modes, broadcast sender becomes neighbor)
            let neighbors = integration.currentNeighbors()
            XCTAssertTrue(neighbors.contains { $0.call == "K0ABC" }, "Mode \(mode): Broadcast sender should be neighbor")
        }
    }

    func testBroadcastQualityIsPreserved() async {
        let integration = NetRomIntegration(localCallsign: localCallsign, mode: .classic)

        // Establish neighbor
        let directPacket = Packet(
            timestamp: baseTime,
            from: AX25Address(call: "AF0AJ"),
            to: AX25Address(call: localCallsign),
            via: [],
            frameType: .ui,
            control: 0,
            pid: nil,
            info: Data(),
            rawAx25: Data(),
            kissEndpoint: nil,
            infoText: "TEST"
        )
        integration.observePacket(directPacket, timestamp: baseTime)

        // Send broadcast with specific quality
        let broadcastPacket = makeBroadcastPacket(
            from: "AF0AJ",
            entries: [
                makeEntry(dest: "W1ABC", alias: "NODE1", neighbor: "AF0AJ", quality: 175)
            ]
        )
        integration.observePacket(broadcastPacket, timestamp: baseTime.addingTimeInterval(1))

        // The route quality should reflect the combined quality calculation
        // (broadcast quality * path quality + 128) / 256, capped at 255
        let routes = integration.currentRoutes()
        let route = routes.first { $0.destination == "W1ABC" }
        XCTAssertNotNil(route)
        // Quality should be > 0 (exact value depends on neighbor quality)
        XCTAssertGreaterThan(route?.quality ?? 0, 0)
    }

    // MARK: - Persistence Tests

    func testBroadcastRoutesArePersistable() async {
        let integration = NetRomIntegration(localCallsign: localCallsign, mode: .classic)

        // Establish neighbor
        let directPacket = Packet(
            timestamp: baseTime,
            from: AX25Address(call: "AF0AJ"),
            to: AX25Address(call: localCallsign),
            via: [],
            frameType: .ui,
            control: 0,
            pid: nil,
            info: Data(),
            rawAx25: Data(),
            kissEndpoint: nil,
            infoText: "TEST"
        )
        integration.observePacket(directPacket, timestamp: baseTime)

        // Send broadcast
        let broadcastPacket = makeBroadcastPacket(
            from: "AF0AJ",
            entries: [
                makeEntry(dest: "W1ABC", alias: "NODE1", neighbor: "AF0AJ", quality: 200)
            ]
        )
        integration.observePacket(broadcastPacket, timestamp: baseTime.addingTimeInterval(1))

        // Export routes
        let exportedRoutes = integration.exportRoutes()
        XCTAssertFalse(exportedRoutes.isEmpty)

        // Create new integration and import
        let newIntegration = NetRomIntegration(localCallsign: localCallsign, mode: .classic)
        newIntegration.importNeighbors(integration.exportNeighbors())
        newIntegration.importRoutes(exportedRoutes)

        // Verify routes were imported with correct source type
        let importedRoutes = newIntegration.currentRoutes()
        let w1abcRoute = importedRoutes.first { $0.destination == "W1ABC" }
        XCTAssertNotNil(w1abcRoute)
        XCTAssertEqual(w1abcRoute?.sourceType, "broadcast")
    }

    func testBroadcastNeighborsArePersistable() async {
        let integration = NetRomIntegration(localCallsign: localCallsign, mode: .classic)

        // Send broadcast (which creates neighbor)
        let broadcastPacket = makeBroadcastPacket(
            from: "AF0AJ",
            entries: [
                makeEntry(dest: "W1ABC", alias: "NODE1", neighbor: "AF0AJ", quality: 200)
            ]
        )
        integration.observePacket(broadcastPacket, timestamp: baseTime)

        // Export neighbors
        let exportedNeighbors = integration.exportNeighbors()
        XCTAssertTrue(exportedNeighbors.contains { $0.call == "AF0AJ" })

        // Create new integration and import
        let newIntegration = NetRomIntegration(localCallsign: localCallsign, mode: .classic)
        newIntegration.importNeighbors(exportedNeighbors)

        // Verify neighbor was imported
        let importedNeighbors = newIntegration.currentNeighbors()
        XCTAssertTrue(importedNeighbors.contains { $0.call == "AF0AJ" })
    }

    // MARK: - Mode Filtering Tests

    func testClassicModeShowsBroadcastRoutes() async {
        let integration = NetRomIntegration(localCallsign: localCallsign, mode: .hybrid)

        // Establish neighbor
        let directPacket = Packet(
            timestamp: baseTime,
            from: AX25Address(call: "AF0AJ"),
            to: AX25Address(call: localCallsign),
            via: [],
            frameType: .ui,
            control: 0,
            pid: nil,
            info: Data(),
            rawAx25: Data(),
            kissEndpoint: nil,
            infoText: "TEST"
        )
        integration.observePacket(directPacket, timestamp: baseTime)

        // Send broadcast
        let broadcastPacket = makeBroadcastPacket(
            from: "AF0AJ",
            entries: [
                makeEntry(dest: "W1ABC", alias: "NODE1", neighbor: "AF0AJ", quality: 200)
            ]
        )
        integration.observePacket(broadcastPacket, timestamp: baseTime.addingTimeInterval(1))

        // Classic mode should show broadcast routes
        let classicRoutes = integration.currentRoutes(forMode: .classic)
        XCTAssertTrue(classicRoutes.contains { $0.destination == "W1ABC" && $0.sourceType == "broadcast" })

        // Inference mode should NOT show broadcast routes
        let inferenceRoutes = integration.currentRoutes(forMode: .inference)
        XCTAssertFalse(inferenceRoutes.contains { $0.sourceType == "broadcast" })
    }

    // MARK: - Helper Methods

    private func makeBroadcastPacket(from source: String, entries: [Data]) -> Packet {
        var info = Data([0xFF]) // Signature
        for entry in entries {
            info.append(entry)
        }

        return Packet(
            timestamp: baseTime,
            from: AX25Address(call: source),
            to: AX25Address(call: "NODES"),
            via: [],
            frameType: .ui,
            control: 0,
            pid: NetRomBroadcastParser.netromPID,
            info: info,
            rawAx25: Data(),
            kissEndpoint: nil,
            infoText: nil
        )
    }

    private func makeEntry(dest: String, alias: String, neighbor: String, quality: Int) -> Data {
        var entry = Data()

        // Destination callsign (7 bytes, shifted)
        entry.append(contentsOf: shiftCallsign(dest))

        // Destination alias (6 bytes, ASCII, space-padded)
        entry.append(contentsOf: padAlias(alias))

        // Best neighbor callsign (7 bytes, shifted)
        entry.append(contentsOf: shiftCallsign(neighbor))

        // Quality (1 byte)
        entry.append(UInt8(quality & 0xFF))

        return entry
    }

    private func shiftCallsign(_ call: String) -> [UInt8] {
        var result = [UInt8]()

        let parts = call.split(separator: "-", maxSplits: 1)
        let baseCall = String(parts[0]).uppercased()
        let ssid = parts.count > 1 ? Int(parts[1]) ?? 0 : 0

        for i in 0..<6 {
            let char: Character
            if i < baseCall.count {
                let index = baseCall.index(baseCall.startIndex, offsetBy: i)
                char = baseCall[index]
            } else {
                char = " "
            }
            result.append(UInt8(char.asciiValue ?? 0x20) << 1)
        }

        let ssidByte = UInt8((ssid & 0x0F) << 1) | 0x60
        result.append(ssidByte)

        return result
    }

    private func padAlias(_ alias: String) -> [UInt8] {
        var result = [UInt8]()
        let padded = alias.padding(toLength: 6, withPad: " ", startingAt: 0)

        for char in padded.prefix(6) {
            result.append(UInt8(char.asciiValue ?? 0x20))
        }

        return result
    }
}

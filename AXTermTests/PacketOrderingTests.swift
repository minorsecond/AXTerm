//
//  PacketOrderingTests.swift
//  AXTermTests
//
//  Created by AXTerm on 2026-02-06.
//

import XCTest
@testable import AXTerm

@MainActor
final class PacketOrderingTests: XCTestCase {
    func testIncomingPacketsStaySortedNewestFirst() {
        let settings = makeSettings(persistHistory: false)
        let client = PacketEngine(maxPackets: 10, settings: settings)
        let base = Date()
        let packetA = Packet(id: UUID(), timestamp: base.addingTimeInterval(-10), from: AX25Address(call: "A"))
        let packetB = Packet(id: UUID(), timestamp: base.addingTimeInterval(-5), from: AX25Address(call: "B"))
        let packetC = Packet(id: UUID(), timestamp: base.addingTimeInterval(-7), from: AX25Address(call: "C"))

        client.handleIncomingPacket(packetA)
        client.handleIncomingPacket(packetB)
        client.handleIncomingPacket(packetC)

        XCTAssertEqual(client.packets.map(\.id), [packetB.id, packetC.id, packetA.id])
    }

    func testIncomingPacketsUseIdTiebreaker() {
        let settings = makeSettings(persistHistory: false)
        let client = PacketEngine(maxPackets: 10, settings: settings)
        let timestamp = Date()
        let lowerID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let higherID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let packetA = Packet(id: lowerID, timestamp: timestamp, from: AX25Address(call: "A"))
        let packetB = Packet(id: higherID, timestamp: timestamp, from: AX25Address(call: "B"))

        client.handleIncomingPacket(packetA)
        client.handleIncomingPacket(packetB)

        XCTAssertEqual(client.packets.map(\.id), [higherID, lowerID])
    }

    func testSelectionRemainsAfterInsert() {
        let settings = makeSettings(persistHistory: false)
        let client = PacketEngine(maxPackets: 10, settings: settings)
        let selectedID = UUID()
        let selectedPacket = Packet(id: selectedID, timestamp: Date(), from: AX25Address(call: "A"))

        client.handleIncomingPacket(selectedPacket)
        let selection: Set<Packet.ID> = [selectedID]

        client.handleIncomingPacket(Packet(id: UUID(), timestamp: Date().addingTimeInterval(1), from: AX25Address(call: "B")))

        let updatedSelection = PacketSelectionResolver.filteredSelection(selection, for: client.packets)
        XCTAssertEqual(updatedSelection, selection)
    }

    private func makeSettings(persistHistory: Bool) -> AppSettingsStore {
        let suiteName = "AXTermTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.set(persistHistory, forKey: AppSettingsStore.persistKey)
        return AppSettingsStore(defaults: defaults)
    }
}

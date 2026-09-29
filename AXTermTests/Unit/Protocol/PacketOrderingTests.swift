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
    func testIncomingPacketsStaySortedOldestFirst() {
        var packets: [Packet] = []
        let base = Date()
        let packetA = Packet(id: UUID(), timestamp: base.addingTimeInterval(-10), from: AX25Address(call: "A"))
        let packetB = Packet(id: UUID(), timestamp: base.addingTimeInterval(-5), from: AX25Address(call: "B"))
        let packetC = Packet(id: UUID(), timestamp: base.addingTimeInterval(-7), from: AX25Address(call: "C"))

        PacketOrdering.insert(packetA, into: &packets)
        PacketOrdering.insert(packetB, into: &packets)
        PacketOrdering.insert(packetC, into: &packets)

        XCTAssertEqual(packets.map(\.id), [packetA.id, packetC.id, packetB.id])
    }

    func testIncomingPacketsUseIdTiebreaker() {
        var packets: [Packet] = []
        let timestamp = Date()
        let lowerID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let higherID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let packetA = Packet(id: lowerID, timestamp: timestamp, from: AX25Address(call: "A"))
        let packetB = Packet(id: higherID, timestamp: timestamp, from: AX25Address(call: "B"))

        PacketOrdering.insert(packetA, into: &packets)
        PacketOrdering.insert(packetB, into: &packets)

        XCTAssertEqual(packets.map(\.id), [lowerID, higherID])
    }

    func testSelectionRemainsAfterInsert() {
        var packets: [Packet] = []
        let selectedID = UUID()
        let selectedPacket = Packet(id: selectedID, timestamp: Date(), from: AX25Address(call: "A"))

        PacketOrdering.insert(selectedPacket, into: &packets)
        let selection: Set<Packet.ID> = [selectedID]

        PacketOrdering.insert(Packet(id: UUID(), timestamp: Date().addingTimeInterval(1), from: AX25Address(call: "B")), into: &packets)

        let updatedSelection = PacketSelectionResolver.filteredSelection(selection, for: packets)
        XCTAssertEqual(updatedSelection, selection)
    }
}

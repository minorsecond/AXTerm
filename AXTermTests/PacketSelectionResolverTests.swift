//
//  PacketSelectionResolverTests.swift
//  AXTermTests
//
//  Created by Ross Wardrup on 1/30/26.
//

import XCTest
@testable import AXTerm

final class PacketSelectionResolverTests: XCTestCase {
    func testResolveSelectionUsesProvidedOrder() {
        let firstID = UUID()
        let secondID = UUID()
        let packets = [
            Packet(id: secondID, from: AX25Address(call: "N0CALL")),
            Packet(id: firstID, from: AX25Address(call: "W0ABC"))
        ]
        let selection: Set<Packet.ID> = [firstID, secondID]

        let resolved = PacketSelectionResolver.resolve(selection: selection, in: packets)

        XCTAssertEqual(resolved?.id, secondID)
    }

    func testResolveSelectionReturnsNilWhenMissing() {
        let packets = [Packet(id: UUID(), from: AX25Address(call: "N0CALL"))]
        let selection: Set<Packet.ID> = [UUID()]

        let resolved = PacketSelectionResolver.resolve(selection: selection, in: packets)

        XCTAssertNil(resolved)
    }

    func testFilteredSelectionRemovesMissingIDs() {
        let keptID = UUID()
        let droppedID = UUID()
        let packets = [Packet(id: keptID, from: AX25Address(call: "N0CALL"))]
        let selection: Set<Packet.ID> = [keptID, droppedID]

        let filtered = PacketSelectionResolver.filteredSelection(selection, for: packets)

        XCTAssertEqual(filtered, [keptID])
    }

    func testFilteredSelectionEmptyWhenSelectionCleared() {
        let packets = [Packet(id: UUID(), from: AX25Address(call: "N0CALL"))]
        let selection: Set<Packet.ID> = []

        let filtered = PacketSelectionResolver.filteredSelection(selection, for: packets)

        XCTAssertTrue(filtered.isEmpty)
    }

    func testFilteredSelectionPreservesSelectionWhenPacketsGrow() {
        let selectedID = UUID()
        let initialPackets = [
            Packet(id: selectedID, from: AX25Address(call: "N0CALL"))
        ]
        let selection: Set<Packet.ID> = [selectedID]
        let expandedPackets = initialPackets + [Packet(id: UUID(), from: AX25Address(call: "W0ABC"))]

        let filtered = PacketSelectionResolver.filteredSelection(selection, for: expandedPackets)

        XCTAssertEqual(filtered, selection)
    }

    func testFilteredSelectionPreservesSelectionWithInsertAtTop() {
        let selectedID = UUID()
        let existingPackets = [
            Packet(id: selectedID, from: AX25Address(call: "N0CALL"))
        ]
        let selection: Set<Packet.ID> = [selectedID]
        let packetsWithInsertion = [
            Packet(id: UUID(), from: AX25Address(call: "K1ABC"))
        ] + existingPackets

        let filtered = PacketSelectionResolver.filteredSelection(selection, for: packetsWithInsertion)

        XCTAssertEqual(filtered, selection)
    }
}

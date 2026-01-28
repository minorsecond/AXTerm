//
//  PacketInspectionCoordinatorTests.swift
//  AXTermTests
//
//  Created by Ross Wardrup on 2/1/26.
//

import XCTest
@testable import AXTerm

final class PacketInspectionCoordinatorTests: XCTestCase {
    func testInspectSelectedPacketReturnsSelectionWhenFound() {
        let id = UUID()
        let packets = [
            Packet(id: id, from: AX25Address(call: "N0CALL"))
        ]
        let selection: Set<Packet.ID> = [id]
        let coordinator = PacketInspectionCoordinator()

        let result = coordinator.inspectSelectedPacket(selection: selection, packets: packets)

        XCTAssertEqual(result, PacketInspectorSelection(id: id))
    }

    func testInspectSelectedPacketReturnsNilWhenMissing() {
        let packets = [Packet(id: UUID(), from: AX25Address(call: "N0CALL"))]
        let selection: Set<Packet.ID> = [UUID()]
        let coordinator = PacketInspectionCoordinator()

        let result = coordinator.inspectSelectedPacket(selection: selection, packets: packets)

        XCTAssertNil(result)
    }
}

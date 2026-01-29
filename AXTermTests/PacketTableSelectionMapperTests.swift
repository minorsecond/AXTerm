//
//  PacketTableSelectionMapperTests.swift
//  AXTermTests
//
//  Created by Ross Wardrup on 2/4/26.
//

import XCTest
@testable import AXTerm

final class PacketTableSelectionMapperTests: XCTestCase {
    func testIndexesForSelectionUsesRowOrdering() {
        let firstID = UUID()
        let secondID = UUID()
        let rows = [
            PacketRowViewModel(id: firstID, timeText: "", fromText: "", toText: "", viaText: "", typeIcon: "", typeTooltip: "", infoText: "", infoTooltip: "", isLowSignal: false),
            PacketRowViewModel(id: secondID, timeText: "", fromText: "", toText: "", viaText: "", typeIcon: "", typeTooltip: "", infoText: "", infoTooltip: "", isLowSignal: false)
        ]
        let mapper = PacketTableSelectionMapper(rows: rows)

        let indexes = mapper.indexes(for: [secondID])

        XCTAssertEqual(indexes, IndexSet(integer: 1))
    }

    func testSelectionForIndexesReturnsPacketIDs() {
        let firstID = UUID()
        let secondID = UUID()
        let rows = [
            PacketRowViewModel(id: firstID, timeText: "", fromText: "", toText: "", viaText: "", typeIcon: "", typeTooltip: "", infoText: "", infoTooltip: "", isLowSignal: false),
            PacketRowViewModel(id: secondID, timeText: "", fromText: "", toText: "", viaText: "", typeIcon: "", typeTooltip: "", infoText: "", infoTooltip: "", isLowSignal: false)
        ]
        let mapper = PacketTableSelectionMapper(rows: rows)

        let selection = mapper.selection(for: IndexSet([0, 1]))

        XCTAssertEqual(selection, [firstID, secondID])
    }

    func testIndexesStableAfterInsertAtTop() {
        let selectedID = UUID()
        let rows = [
            PacketRowViewModel(id: selectedID, timeText: "", fromText: "", toText: "", viaText: "", typeIcon: "", typeTooltip: "", infoText: "", infoTooltip: "", isLowSignal: false)
        ]
        let mapper = PacketTableSelectionMapper(rows: rows)
        let insertedRow = PacketRowViewModel(id: UUID(), timeText: "", fromText: "", toText: "", viaText: "", typeIcon: "", typeTooltip: "", infoText: "", infoTooltip: "", isLowSignal: false)
        let updatedMapper = PacketTableSelectionMapper(rows: [insertedRow] + rows)

        let originalIndexes = mapper.indexes(for: [selectedID])
        let updatedIndexes = updatedMapper.indexes(for: [selectedID])

        XCTAssertEqual(originalIndexes, IndexSet(integer: 0))
        XCTAssertEqual(updatedIndexes, IndexSet(integer: 1))
    }

    func testPacketIDForRowReturnsCorrectID() {
        let firstID = UUID()
        let rows = [
            PacketRowViewModel(id: firstID, timeText: "", fromText: "", toText: "", viaText: "", typeIcon: "", typeTooltip: "", infoText: "", infoTooltip: "", isLowSignal: false)
        ]
        let mapper = PacketTableSelectionMapper(rows: rows)

        XCTAssertEqual(mapper.packetID(for: 0), firstID)
        XCTAssertNil(mapper.packetID(for: 1))
    }
}

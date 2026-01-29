//
//  PacketTableSelectionMapper.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/4/26.
//

import Foundation

struct PacketRowViewModel: Identifiable, Hashable {
    let id: Packet.ID
    let timeText: String
    let fromText: String
    let toText: String
    let viaText: String
    let typeIcon: String
    let typeTooltip: String
    let infoText: String
    let infoTooltip: String
    let isLowSignal: Bool

    static func fromPacket(_ packet: Packet) -> PacketRowViewModel {
        PacketRowViewModel(
            id: packet.id,
            timeText: packet.timestamp.formatted(date: .omitted, time: .standard),
            fromText: packet.fromDisplay,
            toText: packet.toDisplay,
            viaText: packet.viaDisplay,
            typeIcon: packet.frameType.icon,
            typeTooltip: packet.frameType.displayName,
            infoText: packet.infoPreview,
            infoTooltip: packet.infoTooltip,
            isLowSignal: packet.isLowSignal
        )
    }
}

struct PacketTableSelectionMapper {
    let rows: [PacketRowViewModel]

    func indexes(for selection: Set<Packet.ID>) -> IndexSet {
        var indexes = IndexSet()
        for (index, row) in rows.enumerated() where selection.contains(row.id) {
            indexes.insert(index)
        }
        return indexes
    }

    func selection(for indexes: IndexSet) -> Set<Packet.ID> {
        var selection = Set<Packet.ID>()
        for index in indexes {
            guard rows.indices.contains(index) else { continue }
            selection.insert(rows[index].id)
        }
        return selection
    }

    func packetID(for row: Int) -> Packet.ID? {
        guard rows.indices.contains(row) else { return nil }
        return rows[row].id
    }
}

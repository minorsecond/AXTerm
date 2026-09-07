//
//  PacketTableSelectionMapper.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/4/26.
//

import Foundation

nonisolated struct PacketRowViewModel: Identifiable, Hashable {
    let id: Packet.ID
    let timeText: String
    let fromText: String
    let toText: String
    let viaText: String
    let typeLabel: String
    let typeTooltip: String
    let typeAccessibilityLabel: String
    let infoText: String
    let infoTooltip: String
    let isLowSignal: Bool
    /// Which radio decoded this frame — not which one the sender used. Nil
    /// with one radio, when the column does not exist.
    var radioName: String? = nil

    static func fromPacket(_ packet: Packet, radioNames: [RadioID: String] = [:]) -> PacketRowViewModel {
        let classification = packet.classification
        return PacketRowViewModel(
            id: packet.id,
            timeText: packet.timestamp.formatted(date: .omitted, time: .standard),
            fromText: packet.fromDisplay,
            toText: packet.toDisplay,
            viaText: packet.viaDisplay,
            typeLabel: classification.badge,
            typeTooltip: classification.tooltip,
            typeAccessibilityLabel: "Frame type: \(classification.badge). \(classification.tooltip)",
            infoText: packet.infoDisplay,
            infoTooltip: packet.infoTooltip,
            isLowSignal: packet.isLowSignal,
            radioName: radioNames.isEmpty ? nil : radioNames[packet.radioID ?? .primary]
        )
    }
}

nonisolated struct PacketTableSelectionMapper {
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

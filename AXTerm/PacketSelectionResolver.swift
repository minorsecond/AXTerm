//
//  PacketSelectionResolver.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/30/26.
//

import Foundation

nonisolated enum PacketSelectionResolver {
    static func resolve(selection: Set<Packet.ID>, in packets: [Packet]) -> Packet? {
        guard !selection.isEmpty else { return nil }
        return packets.first { selection.contains($0.id) }
    }

    static func filteredSelection(_ selection: Set<Packet.ID>, for packets: [Packet]) -> Set<Packet.ID> {
        guard !selection.isEmpty else { return [] }
        let validIDs = Set(packets.map(\.id))
        return selection.intersection(validIDs)
    }
}

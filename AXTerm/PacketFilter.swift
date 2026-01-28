//
//  PacketFilter.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import Foundation

enum PacketFilter {
    static func filter(
        packets: [Packet],
        search: String,
        filters: PacketFilters,
        stationCall: String?,
        pinnedIDs: Set<Packet.ID> = []
    ) -> [Packet] {
        packets.filter { packet in
            if let call = stationCall {
                guard packet.fromDisplay == call else { return false }
            }

            guard filters.allows(frameType: packet.frameType) else { return false }

            if filters.onlyWithInfo && packet.infoText == nil {
                return false
            }

            if filters.onlyPinned && !pinnedIDs.contains(packet.id) {
                return false
            }

            if !search.isEmpty {
                let searchLower = search.lowercased()
                let matches = packet.fromDisplay.lowercased().contains(searchLower) ||
                              packet.toDisplay.lowercased().contains(searchLower) ||
                              packet.viaDisplay.lowercased().contains(searchLower) ||
                              (packet.infoText?.lowercased().contains(searchLower) ?? false)
                guard matches else { return false }
            }

            return true
        }
    }
}

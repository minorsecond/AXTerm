//
//  PacketOrdering.swift
//  AXTerm
//
//  Created by AXTerm on 2/3/26.
//

import Foundation

enum PacketOrdering {
    static func shouldPrecede(_ lhs: Packet, _ rhs: Packet) -> Bool {
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp < rhs.timestamp
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    static func insertionIndex(for packet: Packet, in packets: [Packet]) -> Int {
        var lowerBound = 0
        var upperBound = packets.count
        while lowerBound < upperBound {
            let mid = (lowerBound + upperBound) / 2
            if shouldPrecede(packet, packets[mid]) {
                upperBound = mid
            } else {
                lowerBound = mid + 1
            }
        }
        return lowerBound
    }

    static func insert(_ packet: Packet, into packets: inout [Packet]) {
        let index = insertionIndex(for: packet, in: packets)
        packets.insert(packet, at: index)
    }
}

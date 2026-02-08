//
//  PacketEvent.swift
//  AXTerm
//
//  Created by AXTerm on 2026-02-18.
//

import Foundation

struct PacketEvent: Hashable, Sendable {
    let timestamp: Date
    let from: String?
    let to: String?
    let via: [String]
    let frameType: FrameType
    let infoTextPresent: Bool
    let payloadBytes: Int

    init(packet: Packet) {
        timestamp = packet.timestamp
        from = StationNormalizer.normalize(packet.fromDisplay)
        to = StationNormalizer.normalize(packet.toDisplay)
        via = packet.via.compactMap { StationNormalizer.normalize($0.display) }
        frameType = packet.frameType
        infoTextPresent = packet.infoText?.isEmpty == false
        payloadBytes = packet.info.count
    }
}

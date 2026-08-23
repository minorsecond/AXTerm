//
//  PacketEvent.swift
//  AXTerm
//
//  Created by AXTerm on 2026-02-18.
//

import Foundation

nonisolated struct PacketEvent: Hashable, Sendable {
    let timestamp: Date
    let from: String?
    let to: String?
    let via: [String]
    /// Digipeaters whose has-been-repeated (H) bit is set — the hops that actually
    /// retransmitted this frame, as opposed to merely being requested in the path.
    let repeatedVia: [String]
    let frameType: FrameType
    let infoTextPresent: Bool
    let payloadBytes: Int
    /// REJ or SREJ supervisory frame — the peer asked for a retransmit.
    let isRejectFrame: Bool

    init(packet: Packet) {
        timestamp = packet.timestamp
        from = StationNormalizer.normalize(packet.fromDisplay)
        to = StationNormalizer.normalize(packet.toDisplay)
        via = packet.via.compactMap { StationNormalizer.normalize($0.display) }
        repeatedVia = packet.via.filter(\.repeated).compactMap { StationNormalizer.normalize($0.display) }
        frameType = packet.frameType
        infoTextPresent = packet.infoText?.isEmpty == false
        payloadBytes = packet.info.count
        let sType = packet.controlFieldDecoded.sType
        isRejectFrame = sType == .REJ || sType == .SREJ
    }
}

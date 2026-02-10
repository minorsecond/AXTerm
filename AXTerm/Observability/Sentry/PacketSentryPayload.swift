//
//  PacketSentryPayload.swift
//  AXTerm
//
//  Created by AXTerm on 2026-01-29.
//

import Foundation

nonisolated struct PacketSentryPayload: Equatable {
    var frameType: String
    var byteCount: Int
    var from: String
    var to: String
    var viaCount: Int

    /// Optional sensitive fields.
    var infoText: String?
    var rawHex: String?

    static func make(packet: Packet, sendPacketContents: Bool) -> PacketSentryPayload {
        let base = PacketSentryPayload(
            frameType: packet.frameType.displayName,
            byteCount: packet.rawAx25.count,
            from: packet.fromDisplay,
            to: packet.toDisplay,
            viaCount: packet.via.count,
            infoText: nil,
            rawHex: nil
        )

        guard sendPacketContents else { return base }

        var withContents = base
        withContents.infoText = packet.infoText ?? ""
        withContents.rawHex = PayloadFormatter.hexString(packet.rawAx25)
        return withContents
    }

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "frameType": frameType,
            "byteCount": byteCount,
            "from": from,
            "to": to,
            "viaCount": viaCount,
        ]
        if let infoText {
            dict["infoText"] = infoText
        }
        if let rawHex {
            dict["rawHex"] = rawHex
        }
        return dict
    }
}


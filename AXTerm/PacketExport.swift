//
//  PacketExport.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/30/26.
//

import Foundation

struct PacketExport: Codable, Equatable {
    let id: UUID
    let timestamp: Date
    let from: String
    let to: String
    let via: [String]
    let frameType: String
    let pid: UInt8?
    let infoHex: String
    let infoASCII: String?
    let rawAx25Hex: String

    init(packet: Packet) {
        id = packet.id
        timestamp = packet.timestamp
        from = packet.fromDisplay
        to = packet.toDisplay
        via = packet.via.map { $0.display }
        frameType = packet.frameType.displayName
        pid = packet.pid
        infoHex = PayloadFormatter.hexString(packet.info)
        infoASCII = packet.infoText
        rawAx25Hex = PayloadFormatter.hexString(packet.rawAx25)
    }

    func jsonString() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? String(data: encoder.encode(self), encoding: .utf8)
    }

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    func writeJSON(to url: URL) throws {
        let data = try jsonData()
        try data.write(to: url, options: [.atomic])
    }
}

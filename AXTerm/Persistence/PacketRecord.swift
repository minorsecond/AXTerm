//
//  PacketRecord.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/1/26.
//

import Foundation
import GRDB

struct PacketRecord: Codable, FetchableRecord, PersistableRecord, Hashable {
    static let databaseTableName = "packets"

    var id: UUID
    var receivedAt: Date
    var ax25Timestamp: Date?
    var direction: String
    var source: String
    var fromCall: String
    var fromSSID: Int
    var toCall: String
    var toSSID: Int
    var viaPath: String
    var viaCount: Int
    var hasDigipeaters: Bool
    var frameType: String
    var controlHex: String
    var pid: Int?
    var infoLen: Int
    var isPrintableText: Bool
    var infoText: String?
    var infoASCII: String
    var infoHex: String
    var rawAx25Hex: String
    var portName: String?
    var pinned: Bool
    var tags: String?

    init(packet: Packet) {
        let from = packet.from ?? AX25Address(call: "UNKNOWN")
        let to = packet.to ?? AX25Address(call: "UNKNOWN")
        let viaPath = PacketEncoding.encodeViaPath(packet.via)
        let infoHex = PacketEncoding.encodeHex(packet.info)
        let rawHex = PacketEncoding.encodeHex(packet.rawAx25)
        let infoASCII = PacketEncoding.asciiString(packet.info)
        let printable = PacketEncoding.isPrintableText(packet.info)

        self.id = packet.id
        self.receivedAt = packet.timestamp
        self.ax25Timestamp = nil
        self.direction = "rx"
        self.source = "kiss"
        self.fromCall = from.call
        self.fromSSID = from.ssid
        self.toCall = to.call
        self.toSSID = to.ssid
        self.viaPath = viaPath
        self.viaCount = packet.via.count
        self.hasDigipeaters = !packet.via.isEmpty
        self.frameType = packet.frameType.rawValue
        self.controlHex = PacketEncoding.encodeControl(packet.control)
        self.pid = packet.pid.map { Int($0) }
        self.infoLen = packet.info.count
        self.isPrintableText = printable
        self.infoText = printable ? packet.infoText : nil
        self.infoASCII = infoASCII
        self.infoHex = infoHex
        self.rawAx25Hex = rawHex
        self.portName = nil
        self.pinned = false
        self.tags = nil
    }

    func toPacket() -> Packet {
        let from = AX25Address(call: fromCall, ssid: fromSSID)
        let to = AX25Address(call: toCall, ssid: toSSID)
        let via = PacketEncoding.decodeViaPath(viaPath)
        let info = PacketEncoding.decodeHex(infoHex)
        let raw = PacketEncoding.decodeHex(rawAx25Hex)
        let frame = FrameType(rawValue: frameType) ?? .unknown
        let control = PacketEncoding.decodeControl(controlHex)
        let pidValue = pid.flatMap { UInt8(clamping: $0) }
        return Packet(
            id: id,
            timestamp: receivedAt,
            from: from,
            to: to,
            via: via,
            frameType: frame,
            control: control,
            pid: pidValue,
            info: info,
            rawAx25: raw
        )
    }
}

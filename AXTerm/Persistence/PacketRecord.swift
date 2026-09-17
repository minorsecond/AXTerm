//
//  PacketRecord.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/1/26.
//

import Foundation
import GRDB

nonisolated struct PacketRecord: Codable, FetchableRecord, PersistableRecord, Hashable {
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
    var rawAx25Bytes: Data
    var infoBytes: Data
    var portName: String?
    /// The TCP endpoint of the link that heard the frame. Empty host and
    /// port 0 for a serial or Bluetooth link, which has none.
    var kissHost: String
    var kissPort: Int
    var pinned: Bool
    var tags: String?
    /// The radio that heard the frame. Optional in the record so a row read
    /// from a table that predates the column — a fixture, a database not yet
    /// migrated — still decodes; `toPacket()` reads nil as `RadioID.primary`,
    /// which is what every such row was.
    var radioID: String?
    /// The KISS port nibble the frame arrived with; nil reads as 0.
    var kissPortNibble: Int?
    /// The link as the operator would name it, for links with no host.
    var linkDescription: String?

    // AX.25 Control Field decoded columns
    var ax25FrameClass: String?     // "I", "S", "U", or "unknown"
    var ax25SType: String?          // "RR", "RNR", "REJ", "SREJ" (S-frames only)
    var ax25UType: String?          // "UI", "SABM", etc. (U-frames only)
    var ax25Ns: Int?                // N(S) for I-frames
    var ax25Nr: Int?                // N(R) for I/S frames
    var ax25Pf: Int?                // Poll/Final bit (0/1)
    var ax25Ctl0: Int?              // Raw first control byte
    var ax25Ctl1: Int?              // Raw second control byte (if present)
    var ax25IsExtended: Int?        // Extended mode flag (0/1)

    init(packet: Packet) {
        let endpoint = packet.kissEndpoint
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
        self.direction = packet.direction.rawValue
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
        self.rawAx25Bytes = packet.rawAx25
        self.infoBytes = packet.info
        self.portName = nil
        self.kissHost = endpoint?.host ?? ""
        self.kissPort = endpoint.map { Int($0.port) } ?? 0
        self.pinned = false
        self.tags = nil
        self.radioID = (packet.radioID ?? .primary).rawValue
        self.kissPortNibble = Int(packet.kissPort)
        self.linkDescription = packet.linkDescription

        // Decode control field
        let decoded = AX25ControlFieldDecoder.decode(control: packet.control, controlByte1: packet.controlByte1)
        self.ax25FrameClass = decoded.frameClass.rawValue
        self.ax25SType = decoded.sType?.rawValue
        self.ax25UType = decoded.uType?.rawValue
        self.ax25Ns = decoded.ns
        self.ax25Nr = decoded.nr
        self.ax25Pf = decoded.pf
        self.ax25Ctl0 = decoded.ctl0.map { Int($0) }
        self.ax25Ctl1 = decoded.ctl1.map { Int($0) }
        self.ax25IsExtended = decoded.isExtended ? 1 : 0
    }

    func toPacket() -> Packet {
        let from = AX25Address(call: fromCall, ssid: fromSSID)
        let to = AX25Address(call: toCall, ssid: toSSID)
        let via = PacketEncoding.decodeViaPath(viaPath)
        let info = infoBytes.isEmpty ? PacketEncoding.decodeHex(infoHex) : infoBytes
        let raw = rawAx25Bytes.isEmpty ? PacketEncoding.decodeHex(rawAx25Hex) : rawAx25Bytes
        let frame = FrameType(rawValue: frameType) ?? .unknown
        let control = PacketEncoding.decodeControl(controlHex)
        let controlByte1 = ax25Ctl1.map { UInt8(clamping: $0) }
        let pidValue = pid.flatMap { UInt8(clamping: $0) }
        // Failable on an empty host or port 0: a serial or Bluetooth frame
        // comes back with no TCP endpoint, as it should.
        let endpoint = KISSEndpoint(host: kissHost, port: UInt16(clamping: kissPort))
        return Packet(
            id: id,
            timestamp: receivedAt,
            from: from,
            to: to,
            via: via,
            frameType: frame,
            control: control,
            controlByte1: controlByte1,
            pid: pidValue,
            info: info,
            rawAx25: raw,
            kissEndpoint: endpoint,
            infoText: infoText,
            radioID: RadioID(rawValue: radioID ?? RadioID.primary.rawValue),
            kissPort: UInt8(clamping: kissPortNibble ?? 0),
            linkDescription: linkDescription
        )
    }
}

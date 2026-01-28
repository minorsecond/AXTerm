//
//  Packet.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import Foundation

/// Represents a decoded AX.25 packet
struct Packet: Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let from: AX25Address?
    let to: AX25Address?
    let via: [AX25Address]
    let frameType: FrameType
    let pid: UInt8?
    let info: Data
    let rawAx25: Data

    /// Info field as text if mostly printable ASCII
    var infoText: String? {
        guard !info.isEmpty else { return nil }
        let printableCount = info.filter { $0 >= 0x20 && $0 < 0x7F || $0 == 0x0A || $0 == 0x0D }.count
        let ratio = Double(printableCount) / Double(info.count)
        guard ratio >= 0.75 else { return nil }
        return String(data: info, encoding: .ascii)?.trimmingCharacters(in: .controlCharacters)
    }

    // MARK: - Display Helpers

    var fromDisplay: String {
        from?.display ?? "?"
    }

    var toDisplay: String {
        to?.display ?? "?"
    }

    var viaDisplay: String {
        guard !via.isEmpty else { return "" }
        return via.map { addr in
            addr.repeated ? "\(addr.display)*" : addr.display
        }.joined(separator: ",")
    }

    var typeDisplay: String {
        frameType.displayName
    }

    var infoPreview: String {
        if let text = infoText {
            let trimmed = text.replacingOccurrences(of: "\r", with: " ")
                              .replacingOccurrences(of: "\n", with: " ")
            if trimmed.count > 80 {
                return String(trimmed.prefix(77)) + "..."
            }
            return trimmed
        }
        if info.isEmpty {
            return ""
        }
        return "[\(info.count) bytes]"
    }

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        from: AX25Address? = nil,
        to: AX25Address? = nil,
        via: [AX25Address] = [],
        frameType: FrameType = .unknown,
        pid: UInt8? = nil,
        info: Data = Data(),
        rawAx25: Data = Data()
    ) {
        self.id = id
        self.timestamp = timestamp
        self.from = from
        self.to = to
        self.via = via
        self.frameType = frameType
        self.pid = pid
        self.info = info
        self.rawAx25 = rawAx25
    }
}

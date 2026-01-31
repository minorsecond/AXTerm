//
//  Packet.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import Foundation

/// Represents a decoded AX.25 packet
struct Packet: Identifiable, Hashable, Sendable {
    static let infoPreviewLimit: Int = 60

    let id: UUID
    let timestamp: Date
    let from: AX25Address?
    let to: AX25Address?
    let via: [AX25Address]
    let frameType: FrameType
    let control: UInt8
    let pid: UInt8?
    let info: Data
    /// Cached text decoding of `info` (if mostly printable ASCII).
    let infoText: String?
    let rawAx25: Data
    let kissEndpoint: KISSEndpoint?

    nonisolated static func computeInfoText(from info: Data) -> String? {
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
    
    var infoDisplay: String {
        // Check for NET/ROM broadcast first
        if let netromSummary = netRomBroadcastSummary {
            return netromSummary
        }
        if let text = infoText {
            return text
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
        }
        if info.isEmpty { return "" }
        return "[\(info.count) bytes]"
    }

    var infoPreview: String {
        // Check for NET/ROM broadcast first
        if let netromSummary = netRomBroadcastSummary {
            return netromSummary.wordSafeTruncate(limit: Self.infoPreviewLimit)
        }
        if let text = infoText {
            let trimmed = text.replacingOccurrences(of: "\r", with: " ")
                              .replacingOccurrences(of: "\n", with: " ")
            return trimmed.wordSafeTruncate(limit: Self.infoPreviewLimit)
        }
        if info.isEmpty {
            return ""
        }
        return "[\(info.count) bytes]"
    }

    /// Returns a human-readable summary if this is a NET/ROM broadcast packet.
    var netRomBroadcastSummary: String? {
        guard isNetRomBroadcast else { return nil }
        if let result = NetRomBroadcastParser.parse(packet: self) {
            let count = result.entries.count
            let routeWord = count == 1 ? "route" : "routes"
            return "NET/ROM broadcast: \(count) \(routeWord)"
        }
        return nil
    }

    /// Returns true if this packet is a NET/ROM routing broadcast (PID 0xCF to NODES).
    var isNetRomBroadcast: Bool {
        guard let pid = pid, pid == NetRomBroadcastParser.netromPID else { return false }
        guard let toCall = to?.call.uppercased(), toCall == "NODES" else { return false }
        return true
    }

    /// Returns parsed NET/ROM broadcast entries if this is a valid broadcast packet.
    var netRomBroadcastResult: NetRomBroadcastResult? {
        guard isNetRomBroadcast else { return nil }
        return NetRomBroadcastParser.parse(packet: self)
    }

    var infoTooltip: String {
        infoText ?? infoPreview
    }

    var isLowSignal: Bool {
        if info.isEmpty { return true }
        guard let text = infoText else { return false }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return normalized == "ID" || normalized.hasPrefix("ID ") || normalized.hasPrefix("ID:") || normalized.hasPrefix("BEACON")
    }

    var asciiPayload: String {
        PayloadFormatter.asciiString(info)
    }

    var hexPayload: String {
        PayloadFormatter.hexString(info)
    }

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        from: AX25Address? = nil,
        to: AX25Address? = nil,
        via: [AX25Address] = [],
        frameType: FrameType = .unknown,
        control: UInt8 = 0,
        pid: UInt8? = nil,
        info: Data = Data(),
        rawAx25: Data = Data(),
        kissEndpoint: KISSEndpoint? = nil,
        infoText: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.from = from
        self.to = to
        self.via = via
        self.frameType = frameType
        self.control = control
        self.pid = pid
        self.info = info
        self.infoText = infoText ?? Self.computeInfoText(from: info)
        self.rawAx25 = rawAx25
        self.kissEndpoint = kissEndpoint
    }
}

struct KISSEndpoint: Hashable, Sendable {
    let host: String
    let port: UInt16

    init?(host: String, port: UInt16) {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, port >= 1 else { return nil }
        self.host = trimmed
        self.port = port
    }
}

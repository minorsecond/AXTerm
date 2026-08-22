//
//  Packet.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import Foundation

/// Represents a decoded AX.25 packet
nonisolated struct Packet: Identifiable, Hashable, Sendable {
    static let infoPreviewLimit: Int = 60

    let id: UUID
    let timestamp: Date
    let from: AX25Address?
    let to: AX25Address?
    let via: [AX25Address]
    let frameType: FrameType
    let control: UInt8
    /// Second control byte (used for I-frames in modulo-8 mode)
    let controlByte1: UInt8?
    let pid: UInt8?
    let info: Data
    /// Cached text decoding of `info` (if mostly printable ASCII).
    let infoText: String?
    let rawAx25: Data
    let kissEndpoint: KISSEndpoint?

    /// True when every digipeater in the path has set its has-been-repeated (H)
    /// bit, or the path is empty (direct frame).
    ///
    /// AX.25 digipeating rules: a frame is not "delivered" until each digi in its
    /// list has actioned it. On a shared-audio attachment (e.g. TCP KISS into the
    /// digipeater's own TNC) we hear BOTH copies of every digipeated frame — the
    /// original in transit toward the digi (H=0) and the repeated copy (H=1).
    /// Acting on the in-transit copy double-processes every frame and, worse, can
    /// answer a frame the digi has not yet forwarded (field capture 2026-08-22:
    /// the pre-digipeat UA from KB5YZB-7 via DRLNOD was processed 2 s before the
    /// real, repeated copy arrived).
    var isFullyDigipeated: Bool {
        via.allSatisfy { $0.repeated }
    }

    nonisolated static func computeInfoText(from info: Data) -> String? {
        guard !info.isEmpty else { return nil }
        let printableCount = info.filter { $0 >= 0x20 && $0 < 0x7F || $0 == 0x0A || $0 == 0x0D }.count
        let ratio = Double(printableCount) / Double(info.count)
        guard ratio >= 0.75 else { return nil }
        return String(data: info, encoding: .ascii)?.trimmingCharacters(in: .controlCharacters)
    }

    // MARK: - Display Helpers

    /// Determines if this packet is a Command (AX.25 v2.0)
    var isCommand: Bool {
        // Command: Dest bit 7 = 1, Src bit 7 = 0
        // Response: Dest bit 7 = 0, Src bit 7 = 1
        // (In AX25Address, bit 7 is stored in the `repeated` property for src/dest)
        if to?.repeated == true && from?.repeated == false {
            return true
        }
        if to?.repeated == false && from?.repeated == true {
            return false
        }
        
        // V1.0 (both 0 or both 1), or unknown, guess based on frame type
        let decoded = controlFieldDecoded
        if decoded.frameClass == .I { return true }
        if decoded.frameClass == .U {
            if decoded.uType == .SABM || decoded.uType == .SABME || decoded.uType == .DISC || decoded.uType == .UI {
                return true
            }
        }
        return false // Defaults to response for RR, RNR, REJ, UA, DM, FRMR
    }

    var fromDisplay: String {
        from?.display ?? "?"
    }

    var toDisplay: String {
        to?.display ?? "?"
    }

    var viaDisplay: String {
        Packet.normalizedViaItems(from: via).joined(separator: ",")
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

    /// Decoded control field information
    var controlFieldDecoded: AX25ControlFieldDecoded {
        AX25ControlFieldDecoder.decode(control: control, controlByte1: controlByte1)
    }

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        from: AX25Address? = nil,
        to: AX25Address? = nil,
        via: [AX25Address] = [],
        frameType: FrameType = .unknown,
        control: UInt8 = 0,
        controlByte1: UInt8? = nil,
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
        self.controlByte1 = controlByte1
        self.pid = pid
        self.info = info
        self.infoText = infoText ?? Self.computeInfoText(from: info)
        self.rawAx25 = rawAx25
        self.kissEndpoint = kissEndpoint
    }

    static func normalizedViaItems(from via: [AX25Address]) -> [String] {
        guard !via.isEmpty else { return [] }

        var order: [String] = []
        var displayByKey: [String: String] = [:]
        var repeatedByKey: [String: Bool] = [:]

        for address in via {
            let key = "\(address.call)-\(address.ssid)"
            if displayByKey[key] == nil {
                displayByKey[key] = address.display
                order.append(key)
            }
            if address.repeated {
                repeatedByKey[key] = true
            }
        }

        return order.compactMap { key in
            guard let display = displayByKey[key] else { return nil }
            return (repeatedByKey[key] ?? false) ? "\(display)*" : display
        }
    }
}

nonisolated struct KISSEndpoint: Hashable, Sendable {
    let host: String
    let port: UInt16

    init?(host: String, port: UInt16) {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, port >= 1 else { return nil }
        self.host = trimmed
        self.port = port
    }
}

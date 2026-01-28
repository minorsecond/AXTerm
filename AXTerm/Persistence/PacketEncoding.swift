//
//  PacketEncoding.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/1/26.
//

import Foundation

enum PacketEncoding {
    static let printableThreshold: Double = 0.75
    static let separator: Character = ","
    static let repeatedMarker: Character = "*"

    static func encodeHex(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        return data.map { String(format: "%02X", $0) }.joined()
    }

    static func decodeHex(_ hex: String) -> Data {
        let cleaned = hex.filter { !$0.isWhitespace }
        guard cleaned.count % 2 == 0 else { return Data() }
        var data = Data()
        data.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let nextIndex = cleaned.index(index, offsetBy: 2)
            let byteString = cleaned[index..<nextIndex]
            if let byte = UInt8(byteString, radix: 16) {
                data.append(byte)
            } else {
                return Data()
            }
            index = nextIndex
        }
        return data
    }

    static func encodeControl(_ control: UInt8) -> String {
        String(format: "%02X", control)
    }

    static func decodeControl(_ hex: String) -> UInt8 {
        UInt8(hex, radix: 16) ?? 0
    }

    static func asciiString(_ data: Data) -> String {
        PayloadFormatter.asciiString(data)
    }

    static func isPrintableText(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        let printableCount = data.filter { $0 >= 0x20 && $0 < 0x7F || $0 == 0x0A || $0 == 0x0D }.count
        let ratio = Double(printableCount) / Double(data.count)
        return ratio >= printableThreshold
    }

    static func encodeViaPath(_ via: [AX25Address]) -> String {
        guard !via.isEmpty else { return "" }
        return via.map { address in
            address.repeated ? "\(address.display)\(repeatedMarker)" : address.display
        }.joined(separator: String(separator))
    }

    static func decodeViaPath(_ path: String) -> [AX25Address] {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return trimmed.split(separator: separator).compactMap { token in
            decodeAddressToken(String(token))
        }
    }

    static func decodeAddressToken(_ token: String) -> AX25Address? {
        let cleaned = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let repeated = cleaned.last == repeatedMarker
        let base = repeated ? String(cleaned.dropLast()) : cleaned
        let (call, ssid) = parseCallsign(base)
        guard !call.isEmpty else { return nil }
        return AX25Address(call: call, ssid: ssid, repeated: repeated)
    }

    static func parseCallsign(_ value: String) -> (call: String, ssid: Int) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", 0) }
        let parts = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
        let call = String(parts[0]).uppercased()
        var ssid = 0
        if parts.count > 1 {
            ssid = Int(parts[1]) ?? 0
        }
        ssid = max(0, min(15, ssid))
        return (call, ssid)
    }
}

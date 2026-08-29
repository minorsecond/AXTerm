//
//  AX25Digipeater.swift
//  AXTerm
//
//  Classic L2 digipeating, the service AXTerm never had: when a frame
//  is addressed via this station and our entry's H bit is clear, set
//  that one bit and retransmit the frame otherwise untouched. The H
//  bit IS the loop protection — our own repeat comes back with it set
//  and is ignored, exactly as the protocol intends.
//
//  Pure: raw bytes in, raw bytes (or nil) out. The engine decides when
//  to call it and how to transmit; a short dedup there absorbs the
//  case where two paths deliver the same original twice.
//

import Foundation

nonisolated enum AX25Digipeater {

    /// Returns the frame to retransmit — identical to the input except
    /// our digipeater entry's H bit — or nil when this frame is not
    /// ours to repeat.
    static func repeatFrame(_ raw: Data, myAddresses: [String]) -> Data? {
        let mine = Set(myAddresses.map { normalize($0) })
        guard !mine.isEmpty else { return nil }

        // dest(7) + src(7) minimum before any digi can exist.
        guard raw.count >= 16 else { return nil }
        let start = raw.startIndex

        // Never repeat our own transmissions.
        if let source = decodeAddress(raw, at: start + 7),
           mine.contains(source.display) {
            return nil
        }
        guard raw[start + 13] & 0x01 == 0 else { return nil } // no digis

        // Walk the digi list for the first entry whose H bit is clear —
        // the only station allowed to act. Everything before it has
        // repeated already; everything after waits its turn.
        var offset = start + 14
        while offset + 7 <= raw.endIndex {
            let ssidByte = raw[offset + 6]
            let repeated = ssidByte & 0x80 != 0
            if !repeated {
                guard let entry = decodeAddress(raw, at: offset),
                      mine.contains(entry.display) else { return nil }
                var out = raw
                out[offset + 6] |= 0x80
                return out
            }
            if ssidByte & 0x01 != 0 { return nil } // list ended, all repeated
            offset += 7
        }
        return nil
    }

    // MARK: - Address bytes

    private struct Decoded { let display: String }

    private static func decodeAddress(_ raw: Data, at offset: Data.Index) -> Decoded? {
        guard offset + 7 <= raw.endIndex else { return nil }
        var call = ""
        for i in 0..<6 {
            let character = Character(UnicodeScalar(raw[offset + i] >> 1))
            if character != " " { call.append(character) }
        }
        guard !call.isEmpty else { return nil }
        let ssid = (raw[offset + 6] >> 1) & 0x0F
        return Decoded(display: ssid == 0 ? call : "\(call)-\(ssid)")
    }

    private static func normalize(_ address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespaces).uppercased()
        return trimmed.hasSuffix("-0") ? String(trimmed.dropLast(2)) : trimmed
    }
}

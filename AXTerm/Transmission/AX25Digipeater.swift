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

    /// The full per-radio decision: repeat by explicit call/alias first
    /// (verbatim but our H bit), then the APRS New-N paradigm for a `WIDE1-1`
    /// fill-in or a `WIDEn-N` wide-area hop within the hop cap. Returns the
    /// frame to transmit, or nil when this frame is not ours to repeat.
    static func repeatFrame(_ raw: Data, myCall: AX25Address, aliases: [String],
                            fillIn: Bool, wideAreaMaxHops: Int) -> Data? {
        let names = [myCall.display] + aliases.map { normalize($0) }
        if let out = repeatFrame(raw, myAddresses: names) { return out }
        guard fillIn || wideAreaMaxHops > 0 else { return nil }
        return repeatWideN(raw, insert: myCall, fillIn: fillIn, wideAreaMaxHops: wideAreaMaxHops)
    }

    /// APRS `WIDEn-N` handling: at the first unused hop that is a `WIDEn-N`,
    /// insert our callsign (H set) as a trace and decrement N, marking the
    /// `WIDE` used when N reaches 0. Fill-in (`WIDE1-1`) needs `fillIn`;
    /// wide-area needs a remaining N within `wideAreaMaxHops`.
    static func repeatWideN(_ raw: Data, insert: AX25Address,
                            fillIn: Bool, wideAreaMaxHops: Int) -> Data? {
        guard raw.count >= 16 else { return nil }
        let start = raw.startIndex

        // Never repeat our own transmissions.
        if let source = decodeAddress(raw, at: start + 7),
           source.display == normalize(insert.display) { return nil }
        guard raw[start + 13] & 0x01 == 0 else { return nil }  // no digis

        // Loop guard: if our call is already anywhere in the path we have
        // repeated this once. Our own decremented `WIDEn-(N-1)` comes back
        // unused and would otherwise re-trigger us — and the dupe cache misses
        // it because the bytes changed. Refusing when we already appear is the
        // real WIDEn-N loop protection.
        var scan = start + 14
        while scan + 7 <= raw.endIndex {
            if let d = decodeAddress(raw, at: scan), d.display == normalize(insert.display) {
                return nil
            }
            if raw[scan + 6] & 0x01 != 0 { break }
            scan += 7
        }

        // Walk to the first unused hop, counting the whole path for the cap.
        var offset = start + 14
        var firstUnused: Data.Index?
        var digiCount = 0
        while offset + 7 <= raw.endIndex {
            digiCount += 1
            let ssidByte = raw[offset + 6]
            if firstUnused == nil, ssidByte & 0x80 == 0 { firstUnused = offset }
            if ssidByte & 0x01 != 0 { break }   // extension bit: last address
            offset += 7
        }
        // Count any remaining digis for the 8-address ceiling.
        while offset + 7 <= raw.endIndex, raw[offset + 6] & 0x01 == 0 {
            offset += 7; digiCount += 1
        }
        guard let hop = firstUnused,
              let (call, ssid) = decodeCallAndSSID(raw, at: hop),
              let n = widenDigit(call) else { return nil }
        let remaining = ssid
        guard remaining >= 1 else { return nil }
        if n == 1 { guard fillIn else { return nil } }
        else { guard wideAreaMaxHops > 0, remaining <= wideAreaMaxHops else { return nil } }

        let newN = remaining - 1
        let origExt = raw[hop + 6] & 0x01
        var newWideSSID: UInt8 = 0x60 | (UInt8(newN & 0x0F) << 1) | origExt
        if newN == 0 { newWideSSID |= 0x80 }        // WIDE spent → mark used

        var out = Data()
        out.append(raw[start..<hop])
        if digiCount < 8 {
            // Insert our call (H set, not last) as a trace before the WIDE.
            let mine = AX25Address(call: insert.call, ssid: insert.ssid, repeated: true)
            out.append(mine.encodeForAX25(isLast: false))
        }
        out.append(raw[hop..<(hop + 6)])
        out.append(newWideSSID)
        out.append(raw[(hop + 7)...])
        return out
    }

    /// `n` from a `WIDEn` callsign (1–7), or nil.
    static func widenDigit(_ call: String) -> Int? {
        let c = call.uppercased()
        guard c.count == 5, c.hasPrefix("WIDE"), let last = c.last,
              let n = last.wholeNumberValue, (1...7).contains(n) else { return nil }
        return n
    }

    private static func decodeCallAndSSID(_ raw: Data, at offset: Data.Index) -> (String, Int)? {
        guard offset + 7 <= raw.endIndex else { return nil }
        var call = ""
        for i in 0..<6 {
            let ch = Character(UnicodeScalar(raw[offset + i] >> 1))
            if ch != " " { call.append(ch) }
        }
        guard !call.isEmpty else { return nil }
        return (call, Int((raw[offset + 6] >> 1) & 0x0F))
    }

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

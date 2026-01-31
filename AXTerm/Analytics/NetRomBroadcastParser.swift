//
//  NetRomBroadcastParser.swift
//  AXTerm
//
//  Parser for NET/ROM L3 routing broadcasts (PID 0xCF, destination "NODES").
//
//  Supports two broadcast formats:
//
//  1. Standard NET/ROM format (21 bytes per entry):
//     - Bytes 0-6: Destination callsign (7 bytes, shifted AX.25)
//     - Bytes 7-12: Destination alias (6 bytes, ASCII)
//     - Bytes 13-19: Best neighbor callsign (7 bytes, shifted AX.25)
//     - Byte 20: Quality
//
//  2. TheNET X-1J alias-first format (20 bytes per entry):
//     - Bytes 0-5: Destination alias (6 bytes, ASCII)
//     - Bytes 6-12: Destination callsign (7 bytes, shifted AX.25)
//     - Bytes 13-18: Best neighbor alias (6 bytes, ASCII)
//     - Byte 19: Quality
//
//  The parser auto-detects the format by checking if the first 6 bytes are printable ASCII.
//

import Foundation

/// Result of parsing a single NET/ROM routing entry.
struct NetRomBroadcastEntry: Equatable {
    let destinationCallsign: String
    let destinationAlias: String
    let bestNeighborCallsign: String
    let quality: Int
}

/// Result of parsing a complete NET/ROM broadcast packet.
struct NetRomBroadcastResult: Equatable {
    let originCallsign: String
    let entries: [NetRomBroadcastEntry]
    let timestamp: Date
}

/// Parser for NET/ROM L3 routing broadcast packets.
struct NetRomBroadcastParser {

    /// NET/ROM broadcast signature byte.
    static let signatureByte: UInt8 = 0xFF

    /// NET/ROM PID value.
    static let netromPID: UInt8 = 0xCF

    /// Size of standard NET/ROM entry (21 bytes).
    static let standardEntrySize = 21

    /// Size of alias-first entry (20 bytes).
    static let aliasFirstEntrySize = 20

    /// Minimum valid broadcast size (signature + at least one entry of smaller format).
    static let minimumSize = 1 + aliasFirstEntrySize

    /// Parse a packet and extract NET/ROM broadcast routing entries if applicable.
    /// Returns nil if the packet is not a valid NET/ROM broadcast.
    static func parse(packet: Packet) -> NetRomBroadcastResult? {
        // Check for NET/ROM PID (0xCF = 207)
        guard let pid = packet.pid, pid == netromPID else {
            return nil
        }

        // Check destination is "NODES" (standard NET/ROM broadcast address)
        guard let toCall = packet.to?.call.uppercased(), toCall == "NODES" else {
            return nil
        }

        // Get the info field data
        let data = packet.info
        guard data.count >= minimumSize else {
            #if DEBUG
            print("[NETROM:PARSER] Packet too small: \(data.count) bytes, need at least \(minimumSize)")
            #endif
            return nil
        }

        // Verify signature byte
        guard data[0] == signatureByte else {
            #if DEBUG
            print("[NETROM:PARSER] Invalid signature byte: 0x\(String(format: "%02X", data[0])), expected 0xFF")
            #endif
            return nil
        }

        // Get origin callsign from packet source (used as next hop for alias-first format)
        guard let origin = packet.from?.display else {
            return nil
        }
        let normalizedOrigin = CallsignValidator.normalize(origin)

        // Detect format and parse entries
        let (isAliasFirst, hasOriginAlias) = detectFormat(data)

        #if DEBUG
        let formatDesc: String
        if isAliasFirst {
            formatDesc = "alias-first (20 bytes/entry)"
        } else if hasOriginAlias {
            formatDesc = "standard with origin alias (21 bytes/entry)"
        } else {
            formatDesc = "standard (21 bytes/entry)"
        }
        print("[NETROM:PARSER] Detected format: \(formatDesc)")
        #endif

        let entries: [NetRomBroadcastEntry]
        if isAliasFirst {
            entries = parseAliasFirstEntries(from: data, originCallsign: normalizedOrigin)
        } else if hasOriginAlias {
            entries = parseStandardEntriesWithOriginAlias(from: data)
        } else {
            entries = parseStandardEntries(from: data)
        }

        guard !entries.isEmpty else {
            #if DEBUG
            print("[NETROM:PARSER] No valid entries parsed from broadcast")
            #endif
            return nil
        }

        #if DEBUG
        print("[NETROM:PARSER] Parsed \(entries.count) routing entries from \(origin)")
        for entry in entries.prefix(5) {
            print("[NETROM:PARSER]   → \(entry.destinationCallsign) (\(entry.destinationAlias)) via \(entry.bestNeighborCallsign) quality=\(entry.quality)")
        }
        if entries.count > 5 {
            print("[NETROM:PARSER]   ... and \(entries.count - 5) more")
        }
        #endif

        return NetRomBroadcastResult(
            originCallsign: origin,
            entries: entries,
            timestamp: packet.timestamp
        )
    }

    // MARK: - Format Detection

    /// Detect the broadcast format.
    /// Returns: (isAliasFirst: Bool, hasOriginAlias: Bool)
    ///
    /// Possible formats:
    /// 1. Standard format (21 bytes/entry): [sig][callsign7][alias6][neighbor7][quality] per entry
    /// 2. Standard format with origin alias: [sig][originAlias6][entries...] where entries are standard
    /// 3. Alias-first format (20 bytes/entry): [sig][alias6][callsign7][neighborAlias6][quality] per entry
    private static func detectFormat(_ data: Data) -> (isAliasFirst: Bool, hasOriginAlias: Bool) {
        guard data.count > 13 else { return (false, false) }

        // Check if bytes 1-6 are printable ASCII (could be origin alias or alias-first entry)
        let first6ArePrintable = (1...6).allSatisfy { i in
            let byte = data[i]
            return byte >= 0x20 && byte <= 0x7E && byte < 0x80
        }

        if !first6ArePrintable {
            // Bytes 1-6 contain non-printable or shifted bytes - standard format, no origin alias
            return (isAliasFirst: false, hasOriginAlias: false)
        }

        // Bytes 1-6 are printable ASCII. Could be:
        // A) Origin alias followed by standard entries (bytes 7-13 would be shifted callsign)
        // B) Alias-first format (bytes 7-13 would be shifted callsign for destination)

        // Check byte 7 - in standard format with origin alias, this starts a shifted callsign
        // Shifted callsign bytes typically have values 0x60-0xFE (letters A-Z shifted are 0x82-0xB4)
        let byte7 = data[7]

        // Check if byte 7 looks like a shifted callsign byte
        // Shifted uppercase letters: 'A' (0x41) << 1 = 0x82, 'Z' (0x5A) << 1 = 0xB4
        // Shifted digits: '0' (0x30) << 1 = 0x60, '9' (0x39) << 1 = 0x72
        // Shifted space: ' ' (0x20) << 1 = 0x40
        let isShiftedByte = (byte7 >= 0x40 && byte7 <= 0xB4) || byte7 >= 0x80

        // In alias-first format, bytes 7-13 are the shifted callsign (same position)
        // The difference is what comes AFTER: alias-first has neighbor alias (ASCII), standard has neighbor callsign (shifted)

        // Check bytes after the first potential callsign (positions differ by format)
        // For origin-alias + standard: entry starts at byte 7, neighbor callsign at bytes 7+13=20
        // For alias-first: entry starts at byte 1, neighbor alias at bytes 1+13=14

        // Check if bytes 14-19 are printable ASCII (would indicate alias-first neighbor alias field)
        let neighborFieldIsPrintable = (14...19).allSatisfy { i in
            guard i < data.count else { return false }
            let byte = data[i]
            return byte >= 0x20 && byte <= 0x7E && byte < 0x80
        }

        // If neighbor field (bytes 14-19) is printable ASCII and byte 7 is shifted,
        // this is likely alias-first format (alias, then shifted callsign, then neighbor alias)
        if neighborFieldIsPrintable && isShiftedByte {
            // Check packet size to confirm
            let remaining = data.count - 1 // After signature
            if remaining % aliasFirstEntrySize == 0 {
                return (isAliasFirst: true, hasOriginAlias: false)
            }
        }

        // Check if this is standard format with origin alias
        // After origin alias (6 bytes), entries are 21 bytes each
        let remainingAfterOrigin = data.count - 7 // After signature + origin alias
        if remainingAfterOrigin > 0 && remainingAfterOrigin % standardEntrySize == 0 {
            return (isAliasFirst: false, hasOriginAlias: true)
        }

        // Fall back to checking packet size for alias-first without origin alias
        let remaining = data.count - 1
        if remaining % aliasFirstEntrySize == 0 {
            return (isAliasFirst: true, hasOriginAlias: false)
        }

        // Default to standard format
        return (isAliasFirst: false, hasOriginAlias: false)
    }

    /// Legacy detection function - kept for compatibility
    private static func detectAliasFirstFormat(_ data: Data) -> Bool {
        let (isAliasFirst, _) = detectFormat(data)
        return isAliasFirst
    }

    // MARK: - Standard Format Parsing (21 bytes per entry)

    private static func parseStandardEntries(from data: Data) -> [NetRomBroadcastEntry] {
        var entries: [NetRomBroadcastEntry] = []
        var offset = 1 // Skip signature

        while offset + standardEntrySize <= data.count {
            if let entry = parseStandardEntry(from: data, at: offset) {
                entries.append(entry)
            }
            offset += standardEntrySize
        }

        return entries
    }

    /// Parse standard format entries with an origin alias prefix.
    /// Format: [signature 1][origin alias 6][entries 21*N]
    private static func parseStandardEntriesWithOriginAlias(from data: Data) -> [NetRomBroadcastEntry] {
        var entries: [NetRomBroadcastEntry] = []
        var offset = 7 // Skip signature (1) + origin alias (6)

        #if DEBUG
        // Decode and log the origin alias
        if data.count >= 7 {
            let originAliasBytes = [UInt8](data[1..<7])
            let originAlias = decodeAlias(originAliasBytes)
            print("[NETROM:PARSER] Origin alias: '\(originAlias)'")
        }
        #endif

        while offset + standardEntrySize <= data.count {
            if let entry = parseStandardEntry(from: data, at: offset) {
                entries.append(entry)
            }
            offset += standardEntrySize
        }

        return entries
    }

    private static func parseStandardEntry(from data: Data, at offset: Int) -> NetRomBroadcastEntry? {
        let entryData = data.subdata(in: offset..<(offset + standardEntrySize))

        // Bytes 0-6: Destination callsign (shifted AX.25)
        let destCallsignBytes = [UInt8](entryData[0..<7])
        guard let destCallsign = decodeShiftedCallsign(destCallsignBytes) else {
            return nil
        }

        // Bytes 7-12: Destination alias (plain ASCII)
        let aliasBytes = [UInt8](entryData[7..<13])
        let alias = decodeAlias(aliasBytes)

        // Bytes 13-19: Best neighbor callsign (shifted AX.25)
        let neighborBytes = [UInt8](entryData[13..<20])
        guard let neighborCallsign = decodeShiftedCallsign(neighborBytes) else {
            return nil
        }

        // Byte 20: Quality
        let quality = Int(entryData[20])

        return NetRomBroadcastEntry(
            destinationCallsign: destCallsign,
            destinationAlias: alias,
            bestNeighborCallsign: neighborCallsign,
            quality: quality
        )
    }

    // MARK: - Alias-First Format Parsing (20 bytes per entry)

    private static func parseAliasFirstEntries(from data: Data, originCallsign: String) -> [NetRomBroadcastEntry] {
        var entries: [NetRomBroadcastEntry] = []
        var offset = 1 // Skip signature

        while offset + aliasFirstEntrySize <= data.count {
            if let entry = parseAliasFirstEntry(from: data, at: offset, originCallsign: originCallsign) {
                entries.append(entry)
            }
            offset += aliasFirstEntrySize
        }

        return entries
    }

    private static func parseAliasFirstEntry(from data: Data, at offset: Int, originCallsign: String) -> NetRomBroadcastEntry? {
        let entryData = data.subdata(in: offset..<(offset + aliasFirstEntrySize))

        // Bytes 0-5: Destination alias (plain ASCII)
        let aliasBytes = [UInt8](entryData[0..<6])
        let alias = decodeAlias(aliasBytes)

        // Bytes 6-12: Destination callsign (shifted AX.25)
        let destCallsignBytes = [UInt8](entryData[6..<13])
        guard let destCallsign = decodeShiftedCallsign(destCallsignBytes) else {
            #if DEBUG
            print("[NETROM:PARSER] Failed to decode dest callsign in alias-first entry at offset \(offset)")
            #endif
            return nil
        }

        // Bytes 13-18: Best neighbor alias (plain ASCII) - NOT a callsign!
        // For routing, we use the packet origin as the next hop
        let neighborAliasBytes = [UInt8](entryData[13..<19])
        let neighborAlias = decodeAlias(neighborAliasBytes)

        // Byte 19: Quality
        let quality = Int(entryData[19])

        #if DEBUG
        if !neighborAlias.isEmpty {
            print("[NETROM:PARSER] Entry for \(destCallsign): neighbor alias '\(neighborAlias)', using origin '\(originCallsign)' as next hop")
        }
        #endif

        return NetRomBroadcastEntry(
            destinationCallsign: destCallsign,
            destinationAlias: alias,
            bestNeighborCallsign: originCallsign, // Use packet source as next hop
            quality: quality
        )
    }

    // MARK: - Callsign Decoding

    /// Decode a shifted AX.25 callsign (7 bytes) to a normalized string.
    private static func decodeShiftedCallsign(_ bytes: [UInt8]) -> String? {
        guard bytes.count == 7 else { return nil }

        var callsign = ""
        for i in 0..<6 {
            let shifted = bytes[i]
            let char = shifted >> 1

            // Valid callsign characters: A-Z, 0-9, space (for padding)
            if char == 0x20 {
                // Space - end of callsign
                break
            } else if (char >= 0x41 && char <= 0x5A) || (char >= 0x30 && char <= 0x39) {
                // A-Z or 0-9
                callsign.append(Character(UnicodeScalar(char)))
            } else {
                // Invalid character
                return nil
            }
        }

        guard !callsign.isEmpty else { return nil }

        // 7th byte contains SSID in bits 1-4 (after shift)
        let ssidByte = bytes[6]
        let ssid = (ssidByte >> 1) & 0x0F

        if ssid > 0 {
            callsign += "-\(ssid)"
        }

        // Validate the result looks like a callsign
        guard CallsignValidator.isValidCallsign(callsign) else {
            return nil
        }

        return CallsignValidator.normalize(callsign)
    }

    /// Decode a 6-byte alias field (plain ASCII, space-padded).
    private static func decodeAlias(_ bytes: [UInt8]) -> String {
        var alias = ""
        for byte in bytes {
            if byte == 0x00 {
                break // Null terminator
            }
            if byte >= 0x20 && byte <= 0x7E {
                // Printable ASCII
                alias.append(Character(UnicodeScalar(byte)))
            }
        }
        return alias.trimmingCharacters(in: .whitespaces)
    }
}

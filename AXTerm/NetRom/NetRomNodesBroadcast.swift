//
//  NetRomNodesBroadcast.swift
//  AXTerm
//
//  Originating NET/ROM NODES broadcasts — telling the network what this
//  station can reach.
//
//  Until now AXTerm only *listened* to this protocol
//  (`NetRomBroadcastParser`). Speaking it is a different kind of act:
//  every neighbor that hears one of these writes K0EPI into its routing
//  table and may start sending traffic accordingly. Two rules follow,
//  and both are enforced here rather than left to the caller:
//
//   1. **Never advertise what we will not carry.** A node that
//      advertises a destination it cannot forward to is a black hole:
//      neighbors route traffic at it and the traffic dies. So with
//      forwarding off, the only thing advertised is this station
//      itself — "I exist, you can reach me", which is true and
//      harmless. Learned routes are advertised only when forwarding is
//      on, and only for hops we would actually use.
//   2. **Never advertise a route back to its own source.** Split
//      horizon: telling N "I can reach D" when our route to D *is* N
//      invites a loop.
//
//  Wire format is the standard 21-byte form with an origin alias, which
//  is what `NetRomBroadcastParser` reads back (validated by round-trip
//  tests through that parser):
//
//      byte  0       0xFF signature
//      bytes 1..6    origin alias, 6 bytes plain ASCII, space-padded
//      then N × 21 bytes:
//        bytes 0..6   destination callsign  (AX.25-shifted)
//        bytes 7..12  destination alias     (6 bytes plain ASCII)
//        bytes 13..19 best-neighbour call   (AX.25-shifted)
//        byte  20     quality 0…255
//
//  Carried in an AX.25 **UI** frame to "NODES" with PID 0xCF.
//

import Foundation

nonisolated enum NetRomNodesBroadcast {

    static let signature: UInt8 = 0xFF
    static let destinationCall = "NODES"
    static let aliasLength = 6
    static let entryLength = 21

    /// Classic limit: 11 entries keeps a frame at 238 bytes, inside the
    /// 256-byte NET/ROM packet size every implementation accepts.
    static let maxEntriesPerFrame = 11

    /// Quality a node advertises for itself. It *is* itself, so the path
    /// is perfect; each neighbor scales this by its own link quality.
    static let selfQuality: UInt8 = 255

    struct Entry: Equatable {
        let destination: AX25Address
        let alias: String
        let bestNeighbor: AX25Address
        let quality: UInt8
    }

    // MARK: - Alias field

    /// 6 bytes of plain ASCII, uppercased, space-padded — not shifted.
    /// Non-ASCII is dropped rather than mangled; an empty alias becomes
    /// all spaces, which the parser reads back as "".
    static func encodeAlias(_ alias: String) -> [UInt8] {
        let cleaned = alias.uppercased().unicodeScalars
            .filter { $0.value >= 0x20 && $0.value <= 0x7E }
            .prefix(aliasLength)
        var bytes = cleaned.map { UInt8($0.value) }
        while bytes.count < aliasLength { bytes.append(0x20) }
        return bytes
    }

    // MARK: - Encoding

    /// Encode entries into one or more broadcast payloads, each within
    /// `maxEntriesPerFrame`. Returns an empty array for no entries — a
    /// broadcast with nothing in it says nothing and wastes airtime.
    static func encode(originAlias: String, entries: [Entry]) -> [Data] {
        guard !entries.isEmpty else { return [] }
        return stride(from: 0, to: entries.count, by: maxEntriesPerFrame).map { start in
            let slice = entries[start..<min(start + maxEntriesPerFrame, entries.count)]
            var bytes: [UInt8] = [signature]
            bytes += encodeAlias(originAlias)
            for entry in slice {
                bytes += NetRomTransportWire.encodeCallsignField(entry.destination, lastBit: false)
                bytes += encodeAlias(entry.alias)
                bytes += NetRomTransportWire.encodeCallsignField(entry.bestNeighbor, lastBit: false)
                bytes.append(entry.quality)
            }
            return Data(bytes)
        }
    }

    // MARK: - What to advertise

    /// One learned route, reduced to what the advertisement needs.
    struct KnownRoute: Equatable {
        let destination: AX25Address
        let alias: String
        let nextHop: AX25Address
        let quality: UInt8
    }

    /// Build the advertisement for this station.
    ///
    /// - Parameters:
    ///   - forwarding: whether this station will actually carry transit
    ///     traffic. With it off, learned routes are withheld — see rule 1
    ///     in the file comment.
    ///   - routes: what this station has learned, best first.
    /// - Parameter callsignForAlias: alias → callsign, so a route the
    ///   table learned under a tactical name (EVANS) can still be
    ///   advertised under the callsign the wire field requires. Names
    ///   that cannot be resolved are skipped rather than encoded.
    static func advertisement(
        localNode: AX25Address,
        localAlias: String,
        forwarding: Bool,
        routes: [KnownRoute],
        limit: Int = maxEntriesPerFrame * 4,
        callsignForAlias: (String) -> String? = { _ in nil }
    ) -> [Entry] {
        // Always first, always true: this station exists and is itself.
        var entries: [Entry] = [
            Entry(destination: localNode,
                  alias: localAlias,
                  bestNeighbor: localNode,
                  quality: selfQuality)
        ]
        guard forwarding else { return entries }

        var seen: Set<String> = [localNode.display.uppercased()]
        for route in routes {
            guard entries.count < limit else { break }
            // A zero-quality route is not usable; advertising it invites
            // traffic we would only fail to deliver.
            guard route.quality > 0 else { continue }

            // The destination field on the wire is a *callsign*, and this
            // station's route table also holds alias-shaped destinations
            // (DRLNOD, EVANS — tactical names with no digit). Resolve
            // those to the callsign behind them; the tactical name still
            // travels in the entry's own alias field. What cannot be
            // resolved is skipped, because encoding it would emit bytes
            // every conforming parser throws away.
            let resolution = NetRomDestinationResolver.resolve(
                route.destination.display, callsignForAlias: callsignForAlias)
            guard CallsignValidator.isValidCallsign(resolution.address.display) else { continue }

            let key = resolution.address.display.uppercased()
            guard !seen.contains(key) else { continue }
            // Split horizon: never advertise a destination back toward
            // the neighbor we reach it through — compared after
            // resolution, so an alias and its callsign cannot slip past
            // each other.
            let hop = NetRomDestinationResolver.resolve(
                route.nextHop.display, callsignForAlias: callsignForAlias)
            guard hop.address.display.uppercased() != key else { continue }

            seen.insert(key)
            entries.append(Entry(
                destination: resolution.address,
                // Prefer the tactical name the route was learned under;
                // fall back to the alias the caller supplied.
                alias: resolution.requestedAlias ?? route.alias,
                bestNeighbor: localNode,   // *we* are the neighbor to use
                quality: route.quality
            ))
        }
        return entries
    }
}

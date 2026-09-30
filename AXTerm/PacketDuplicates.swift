import Foundation

/// Which packets are the same frame heard again by another path, the way
/// the terminal decides it, so the packet list can show the terminal's "+1".
///
/// A frame counts as a copy when the same sender, destination and payload
/// arrive within `window` of the last sighting by a different via path (a
/// digipeater repeating it). The same frame by the same path is a
/// retransmission, not a copy, and starts a new original. That matches
/// `PacketEngine`'s console duplicate check, which uses the same window.
nonisolated enum PacketDuplicates {
    /// How close together two sightings must be to be one frame.
    static let window: TimeInterval = 5

    enum Mark: Hashable, Sendable {
        /// The first sighting, heard this many more times by other paths.
        case heardAgain(Int)
        /// A later sighting of the frame whose first sighting is `original`.
        case copy(of: Packet.ID)
    }

    /// Marks for the packets that are part of a duplicate set, keyed by id.
    /// Packets heard once get no mark. `packets` are in arrival order.
    static func marks(for packets: [Packet]) -> [Packet.ID: Mark] {
        struct Sighting {
            let original: Packet.ID
            var at: Date
            var via: [String]
        }
        var recent: [Signature: Sighting] = [:]
        var copies: [Packet.ID: Int] = [:]
        var marks: [Packet.ID: Mark] = [:]

        for packet in packets where !packet.info.isEmpty {
            let signature = Signature(from: packet.fromDisplay.uppercased(),
                                      to: packet.toDisplay.uppercased(),
                                      info: packet.info)
            let via = Packet.normalizedViaItems(from: packet.via)
            if var seen = recent[signature],
               packet.timestamp.timeIntervalSince(seen.at) <= window,
               seen.via != via {
                marks[packet.id] = .copy(of: seen.original)
                copies[seen.original, default: 0] += 1
                seen.at = packet.timestamp
                seen.via = via
                recent[signature] = seen
            } else {
                recent[signature] = Sighting(original: packet.id, at: packet.timestamp, via: via)
            }
        }
        for (original, count) in copies {
            marks[original] = .heardAgain(count)
        }
        return marks
    }

    private struct Signature: Hashable {
        let from: String
        let to: String
        let info: Data
    }
}

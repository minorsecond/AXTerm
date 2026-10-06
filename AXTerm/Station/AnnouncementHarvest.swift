//
//  AnnouncementHarvest.swift
//  AXTerm
//

import Foundation

/// What the throttled packet sweep teaches the node directories, wherever
/// the operator happens to be.
///
/// Aliases are heard in ID beacons and NODES broadcasts, not in the page
/// that lists them. The Mac learned them only when the operator opened
/// Packets, Map or Nodes, so a node announced while the Nodes page was open
/// stayed off it until the operator left and came back (smoke run
/// 2026-10-03-1, 7.2 retest). The iPhone already harvested on its sweep;
/// both now share this.
@MainActor
enum AnnouncementHarvest {
    /// How many of the newest frames each sweep reads. Replays of frames
    /// already counted are ignored by the stores, so the overlap between
    /// sweeps costs a parse and nothing else.
    static let window = 200

    static func run(_ packets: [Packet], aliases: NodeAliasStore, capabilities: NodeCapabilityStore) {
        let recent = Array(packets.suffix(window))
        aliases.ingest(packets: recent)
        capabilities.ingest(packets: recent)
    }
}

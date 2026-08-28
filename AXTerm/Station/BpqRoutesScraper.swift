//
//  BpqRoutesScraper.swift
//  AXTerm
//
//  Reads a BPQ `ROUTES` table out of session prose, one line at a time.
//
//  Field capture 2026-08-28, KB5YZB-7 (YZBBPQ) answering `routes`:
//
//      Routes
//      > 1 KE0GB-7 192 91
//        1 VE3CGR-7 192 8
//
//  Each row is the node's own measurement of a *direct* neighbor — port,
//  callsign, quality (0–255), use count, with ">" marking the active route.
//  That is exactly the shape of a NET/ROM route record, which is what makes
//  ROUTES worth scraping on a channel where nobody broadcasts NODES.
//
//  Why stateful per peer: a bare "  1 VE3CGR-7 192 8" is indistinguishable
//  from a line inside a BBS message. Only the "Routes" header the node
//  printed a moment earlier makes it a routing claim, and lines arrive one
//  at a time (the terminal flushes per CR/LF). So the scraper arms on the
//  header and disarms on the first line that is not a row.
//
//  NODES tables deliberately produce nothing here. A NODES row names a
//  destination somewhere in the network with no quality and no path; its one
//  actionable fact — "connect through the teller" — already lives in the
//  alias directory, and that is the KA-Node/prompt-relay path. Feeding NODES
//  rows into the router would fabricate qualities.
//

import Foundation

nonisolated struct BpqRoutesScraper: Equatable, Sendable {

    /// One scraped row: "anchor claims a direct link to `neighbor`".
    struct HarvestedLink: Equatable, Sendable {
        /// The session peer that printed the table.
        var anchor: String
        var neighbor: String
        var port: Int
        /// The anchor's own figure, 0–255. Its opinion of its link, not ours.
        var quality: Int
        var count: Int
        /// Leading ">" — the route BPQ is currently using.
        var isActive: Bool
        var observedAt: Date
    }

    /// A table never takes a minute to print; an armed peer that has gone
    /// this long quiet was disarmed by silence, not by a non-row line.
    static let armedWindowSeconds: TimeInterval = 60

    private var armedPeers: [String: Date] = [:]

    /// Feed one transcript line from `peer`; returns a row when the line is
    /// one. Deliberately returns at most one row per call because the
    /// terminal delivers one line per call.
    mutating func ingest(line: String, peer: String, at time: Date) -> HarvestedLink? {
        let key = peer.uppercased()
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.uppercased() == "ROUTES" {
            armedPeers[key] = time
            return nil
        }

        guard let armedAt = armedPeers[key] else { return nil }
        guard time.timeIntervalSince(armedAt) <= Self.armedWindowSeconds else {
            armedPeers.removeValue(forKey: key)
            return nil
        }

        if let row = Self.parseRow(trimmed) {
            // Stay armed: rows keep coming until something else prints.
            armedPeers[key] = time
            return HarvestedLink(
                anchor: key,
                neighbor: row.call,
                port: row.port,
                quality: row.quality,
                count: row.count,
                isActive: row.active,
                observedAt: time
            )
        }

        // First non-row line ends the table — a prompt, the menu, a blank,
        // anything. Empty lines inside a table would also disarm, which is
        // fine: the next header re-arms for free.
        armedPeers.removeValue(forKey: key)
        return nil
    }

    /// `> 1 KE0GB-7 192 91` → (port 1, KE0GB-7, quality 192, count 91, active).
    /// Exposed for tests. The callsign half is validated by shape
    /// (CallsignQuery.isPlausible) and quality clamped to the wire range —
    /// a "row" failing either is prose that happened to look columnar.
    static func parseRow(_ line: String) -> (port: Int, call: String, quality: Int, count: Int, active: Bool)? {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        var active = false
        if text.hasPrefix(">") {
            active = true
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }

        let fields = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard fields.count == 4 else { return nil }
        guard let port = Int(fields[0]), port >= 0,
              let quality = Int(fields[2]), (0...255).contains(quality),
              let count = Int(fields[3]), count >= 0 else { return nil }

        let call = fields[1].uppercased()
        guard CallsignQuery.isPlausible(call) else { return nil }

        return (port: port, call: call, quality: quality, count: count, active: active)
    }
}

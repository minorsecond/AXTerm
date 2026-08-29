//
//  NetRomNodeShell.swift
//  AXTerm
//
//  The node level a NET/ROM circuit caller lands in — the piece that
//  makes the NODES broadcasts honest. Until now EPINOD advertised
//  itself and refused every CONREQ; with this shell behind the
//  acceptor, a caller gets a banner, the standard node questions
//  (NODES, ROUTES, MH, INFO), and BBS to drop into the mailbox.
//
//  Identity policy, decided 2026-08-29: understand every dialect,
//  speak our own. The banner says AXTerm — a BPQ costume would poison
//  the capability fingerprints other stations route by — but the
//  prompt uses the conventional ALIAS:CALL} grammar, because the node
//  capability it signals is now real, and the ROUTES table prints in
//  the exact shape our own BpqRoutesScraper harvests (test-pinned), so
//  other AXTerms can learn from us with the tools they already have.
//
//  No onward connects (`C`) yet: bridging an inbound circuit to an
//  outbound one couples two flow-control domains and deserves its own
//  careful landing. The shell says so honestly instead of trying.
//

import Foundation

nonisolated struct NetRomNodeShell {

    struct Snapshot {
        struct Route {
            var destination: String
            var alias: String
            var nextHop: String
            var quality: Int
        }
        struct Neighbor {
            var callsign: String
            var quality: Int
            var count: Int
        }
        struct Heard {
            var callsign: String
            var lastHeard: Date
        }
        var routes: [Route] = []
        var neighbors: [Neighbor] = []
        var heard: [Heard] = []
        var stationInfo: String = ""
        var bbsAvailable: Bool = false
    }

    enum Effect: Equatable {
        case disconnect
        case enterBBS
    }

    struct Output: Equatable {
        var lines: [String] = []
        var prompt: String?
        var effects: [Effect] = []
    }

    let nodeAlias: String
    let nodeCall: String
    let version: String
    let caller: String

    private var prompt: String { "\(nodeAlias):\(nodeCall)} " }

    func greeting() -> Output {
        Output(lines: ["\(version) Node \(nodeAlias):\(nodeCall)"],
               prompt: prompt)
    }

    mutating func handle(line: String, snapshot: Snapshot, now: Date) -> Output {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Output(prompt: prompt) }
        let parts = trimmed.split(separator: " ", maxSplits: 1)
        let verb = String(parts[0]).uppercased()

        switch verb {
        case "?", "H", "HELP":
            return Output(lines: help(snapshot), prompt: prompt)
        case "I", "INFO":
            return Output(lines: info(snapshot), prompt: prompt)
        case "N", "NODES":
            return Output(lines: nodes(snapshot), prompt: prompt)
        case "R", "ROUTES":
            return Output(lines: routes(snapshot), prompt: prompt)
        case "MH", "MHEARD", "J", "JHEARD", "HEARD":
            return Output(lines: heard(snapshot, now: now), prompt: prompt)
        case "BBS", "PMS", "MAIL":
            guard snapshot.bbsAvailable else {
                return Output(lines: ["The mailbox is not on the air."],
                              prompt: prompt)
            }
            return Output(lines: [], prompt: nil, effects: [.enterBBS])
        case "C", "CONNECT":
            return Output(
                lines: ["This node does not connect onward yet. "
                        + "Ask for NODES, ROUTES, MH, INFO or BBS."],
                prompt: prompt)
        case "B", "BYE", "Q", "QUIT":
            return Output(lines: ["73 de \(nodeAlias)"],
                          prompt: nil, effects: [.disconnect])
        default:
            return Output(
                lines: ["? \(verb) — NODES, ROUTES, MH, INFO"
                        + (snapshot.bbsAvailable ? ", BBS" : "")
                        + ", BYE"],
                prompt: prompt)
        }
    }

    private func help(_ snapshot: Snapshot) -> [String] {
        var lines = [
            "NODES   stations this node knows a route to",
            "ROUTES  neighbors heard directly, with link quality",
            "MH      stations heard here recently (also J)",
            "INFO    about this station",
        ]
        if snapshot.bbsAvailable {
            lines.append("BBS     enter the mailbox")
        }
        lines.append("BYE     disconnect")
        return lines
    }

    private func info(_ snapshot: Snapshot) -> [String] {
        var lines = ["\(version) Node \(nodeAlias):\(nodeCall)"]
        let trimmed = snapshot.stationInfo
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            lines.append(contentsOf: trimmed.components(separatedBy: "\n"))
        }
        return lines
    }

    /// ALIAS:CALL tokens, four to a line — the shape every node prints.
    private func nodes(_ snapshot: Snapshot) -> [String] {
        guard !snapshot.routes.isEmpty else { return ["No nodes known yet."] }
        let tokens = snapshot.routes
            .map { route -> String in
                route.alias.isEmpty
                    ? route.destination
                    : "\(route.alias):\(route.destination)"
            }
            .sorted()
        var lines = ["Nodes:"]
        var row: [String] = []
        for token in tokens {
            row.append(token.padding(toLength: max(16, token.count),
                                     withPad: " ", startingAt: 0))
            if row.count == 4 {
                lines.append(row.joined().trimmingCharacters(in: .whitespaces).isEmpty
                             ? "" : row.joined())
                row = []
            }
        }
        if !row.isEmpty { lines.append(row.joined()) }
        return lines.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ")) }
    }

    /// The exact table shape BpqRoutesScraper parses — header word
    /// "Routes", then `> port CALL quality count` rows — so a visiting
    /// AXTerm harvests us the way we harvest BPQ. Pinned by test.
    private func routes(_ snapshot: Snapshot) -> [String] {
        guard !snapshot.neighbors.isEmpty else {
            return ["Routes", "(no neighbors heard yet)"]
        }
        var lines = ["Routes"]
        for neighbor in snapshot.neighbors.sorted(by: { $0.quality > $1.quality }) {
            lines.append(String(format: "> 1 %@ %d %d",
                                neighbor.callsign.uppercased(),
                                min(255, max(0, neighbor.quality)),
                                max(0, neighbor.count)))
        }
        return lines
    }

    private func heard(_ snapshot: Snapshot, now: Date) -> [String] {
        guard !snapshot.heard.isEmpty else { return ["Nothing heard yet."] }
        var lines = ["Heard:"]
        for station in snapshot.heard.sorted(by: { $0.lastHeard > $1.lastHeard }).prefix(20) {
            let minutes = max(0, Int(now.timeIntervalSince(station.lastHeard) / 60))
            lines.append("\(station.callsign.uppercased())  \(minutes)m ago")
        }
        return lines
    }
}

/// Who gets in: the pure gate the endpoint's acceptor consults.
nonisolated enum NetRomInboundPolicy {

    /// Circuits multiplex over one neighbor link, but the channel under
    /// them is shared RF — three simultaneous callers is hospitality,
    /// thirty is a party the frequency did not agree to host.
    static let maxCallers = 3

    static func shouldAccept(enabled: Bool, activeCallers: Int) -> Bool {
        enabled && activeCallers < maxCallers
    }
}

//
//  UniversalSearch.swift
//  AXTerm
//
//  One query, every category the app knows. The toolbar search field
//  used to be a per-page filter wearing a universal costume: typing
//  "EPI" filtered whatever pane happened to be frontmost and said
//  nothing about the station profile, the directory entry, the route
//  and the mail thread that all matched (field ask 2026-08-29 07:07).
//  This is the pure half — the panel just renders what it returns.
//

import Foundation

nonisolated struct UniversalSearchResults: Equatable {

    enum Category: String, CaseIterable {
        case stations = "Stations Heard"
        case directory = "Node Directory"
        case routes = "NET/ROM Routes"
        case mail = "Mail"
        case packets = "Packets"
        case terminal = "Terminal Output"

        var icon: String {
            switch self {
            case .stations: return "antenna.radiowaves.left.and.right"
            case .directory: return "character.book.closed"
            case .routes: return "point.topleft.down.to.point.bottomright.curvepath"
            case .mail: return "envelope"
            case .packets: return "shippingbox"
            case .terminal: return "terminal"
            }
        }
    }

    /// Where clicking a result takes the operator.
    enum Destination: Equatable {
        case profile(String)
        case nodes(query: String)
        case routes
        case mail
        case packets
        case terminal
    }

    struct Row: Equatable, Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let destination: Destination
    }

    struct Section: Equatable, Identifiable {
        let category: Category
        let rows: [Row]
        /// Everything that matched, not just what fits — a panel that
        /// shows five and stays silent about the other fifteen lies.
        let totalCount: Int
        var id: Category { category }
    }

    var sections: [Section] = []
    var isEmpty: Bool { sections.isEmpty }
}

nonisolated enum UniversalSearchIndex {

    /// Rows shown per category. A taste, with the honest total beside it.
    static let rowCap = 5

    /// Queries shorter than this return nothing: one character matches
    /// half the world and reads as noise, not results.
    static let minimumQueryLength = 2

    static func search(
        _ query: String,
        stations: [(call: String, alias: String?, packets: Int, lastHeard: Date)] = [],
        directory: [NodeAliasDirectory.Entry],
        routes: [RouteInfo],
        packets: [(from: String, to: String, info: String)] = [],
        consoleLines: [ConsoleLine],
        mail: [WinlinkMessageSummary],
        now: Date
    ) -> UniversalSearchResults {
        let needle = query.trimmingCharacters(in: .whitespaces).uppercased()
        guard needle.count >= minimumQueryLength else { return UniversalSearchResults() }

        var sections: [UniversalSearchResults.Section] = []

        section(.stations, in: &sections, matching: stations, needle: needle,
                fields: { [$0.call, $0.alias] },
                row: { station in
                    let name = station.alias.map { "\(station.call) · \($0)" } ?? station.call
                    return UniversalSearchResults.Row(
                        id: "station-\(station.call)",
                        title: name,
                        subtitle: "\(station.packets) packets · heard "
                            + relative(station.lastHeard, now: now),
                        destination: .profile(station.call))
                })

        section(.directory, in: &sections, matching: directory, needle: needle,
                fields: { [$0.alias, $0.callsign] + $0.reachableVia },
                row: { entry in
                    let via = entry.reachableVia.prefix(3).joined(separator: ", ")
                    return UniversalSearchResults.Row(
                        id: "dir-\(entry.alias)",
                        title: "\(entry.alias):\(entry.callsign)",
                        subtitle: via.isEmpty
                            ? "resolves the name only — no route offered"
                            : "reachable via \(via)",
                        destination: .nodes(query: entry.alias))
                })

        section(.routes, in: &sections, matching: routes, needle: needle,
                fields: { [$0.destination, $0.origin] },
                row: { route in
                    UniversalSearchResults.Row(
                        id: "route-\(route.destination)-\(route.origin)",
                        title: "\(route.destination) via \(route.origin)",
                        subtitle: "quality \(route.quality) · \(route.sourceType) · "
                            + relative(route.lastUpdated, now: now),
                        destination: .routes)
                })

        section(.mail, in: &sections, matching: mail, needle: needle,
                fields: { [$0.subject, $0.fromAddr] + $0.toAddrs },
                row: { message in
                    UniversalSearchResults.Row(
                        id: "mail-\(message.mid)",
                        title: message.subject.isEmpty ? "(no subject)" : message.subject,
                        subtitle: "\(message.direction == .inbound ? "from" : "to") "
                            + "\(message.direction == .inbound ? message.fromAddr : message.toAddrs.joined(separator: ", ")) · "
                            + relative(message.date, now: now),
                        destination: .mail)
                })

        section(.packets, in: &sections, matching: packets.reversed(), needle: needle,
                fields: { [$0.from, $0.to, $0.info] },
                row: { packet in
                    UniversalSearchResults.Row(
                        id: "pkt-\(packet.from)-\(packet.to)-\(packet.info.prefix(24))",
                        title: "\(packet.from) → \(packet.to)",
                        subtitle: String(packet.info.prefix(80)),
                        destination: .packets)
                })

        section(.terminal, in: &sections, matching: consoleLines.reversed(), needle: needle,
                fields: { [$0.text, $0.from, $0.to] },
                row: { line in
                    UniversalSearchResults.Row(
                        id: "line-\(line.id)",
                        title: String(line.text.prefix(90)),
                        subtitle: [line.from, line.to].compactMap { $0 }
                            .joined(separator: " → ")
                            + " · " + relative(line.timestamp, now: now),
                        destination: .terminal)
                })

        return UniversalSearchResults(sections: sections)
    }

    // MARK: - Matching

    private static func section<T>(
        _ category: UniversalSearchResults.Category,
        in sections: inout [UniversalSearchResults.Section],
        matching items: some Collection<T>,
        needle: String,
        fields: (T) -> [String?],
        row: (T) -> UniversalSearchResults.Row
    ) {
        var prefixed: [UniversalSearchResults.Row] = []
        var contained: [UniversalSearchResults.Row] = []
        var total = 0
        for item in items {
            let upper = fields(item).compactMap { $0?.uppercased() }
            guard upper.contains(where: { $0.contains(needle) }) else { continue }
            total += 1
            // What the operator started typing outranks what merely
            // mentions it — but never past the cap, the panel shows a
            // taste and the total, not the haystack.
            if prefixed.count + contained.count < rowCap * 2 {
                if upper.contains(where: { $0.hasPrefix(needle) }) {
                    prefixed.append(row(item))
                } else {
                    contained.append(row(item))
                }
            }
        }
        guard total > 0 else { return }
        let rows = Array((prefixed + contained).prefix(rowCap))
        sections.append(.init(category: category, rows: rows, totalCount: total))
    }

    private static func relative(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 90 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h ago" }
        return "\(Int(seconds / 86_400)) d ago"
    }
}

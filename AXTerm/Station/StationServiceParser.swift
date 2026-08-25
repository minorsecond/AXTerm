import Foundation

/// What a station says it runs.
///
/// Most networks have no NET/ROM `NODES` broadcast to listen for, but almost
/// every node, BBS and digipeater identifies itself anyway — the ID frame is
/// a licence requirement and operators fill it with a service list. That list
/// is a directory the network publishes about itself, over the air, needing
/// no internet and no central registry.
///
/// `NodeAliasParser` already reads these frames, but only to resolve tactical
/// aliases, so it deliberately discards any token whose name is a callsign.
/// That threw away the most direct declarations in the frame: in
/// `KB5YZB/R YZBBPQ/D KB5YZB-1/B KB5YZB-7/N`, the two tokens naming callsigns
/// are precisely the ones saying "KB5YZB-1 is a BBS" and "KB5YZB-7 is a node".
nonisolated enum StationServiceParser {

    /// The single-letter codes used in ID service lists.
    ///
    /// Conventions vary between stacks, so unknown letters are kept verbatim
    /// rather than guessed at — a station saying `/X` means something, and
    /// silently dropping it would lose a fact.
    enum Service: String, Equatable, Sendable, CaseIterable {
        case node = "N"
        case bbs = "B"
        case digipeater = "D"
        case relay = "R"
        case gateway = "G"

        var label: String {
            switch self {
            case .node: return "NET/ROM node"
            case .bbs: return "Bulletin board"
            case .digipeater: return "Digipeater"
            case .relay: return "Relay"
            case .gateway: return "Gateway"
            }
        }
    }

    /// One thing a station declared about itself.
    struct Declaration: Equatable, Sendable {
        /// The station running it, always a callsign.
        var callsign: String
        var service: Service
        /// The tactical name, when the declaration used one.
        var alias: String?
        /// The text it came from, so the operator can check the claim.
        var sourceText: String
    }

    /// Reads an ID or beacon payload.
    ///
    /// - Parameters:
    ///   - text: the frame's information field.
    ///   - source: the transmitting callsign, which owns any alias-form token.
    static func parse(_ text: String, source: String) -> [Declaration] {
        let owner = CallsignValidator.normalize(source)
        var result: [Declaration] = []
        var seen = Set<String>()

        for token in text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0.isNewline }) {
            let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:()"))
            let parts = cleaned.split(separator: "/")
            guard parts.count == 2, parts[1].count == 1 else { continue }
            let name = String(parts[0]).uppercased()
            guard let service = Service(rawValue: String(parts[1]).uppercased()) else { continue }

            // A name that is itself a callsign declares that callsign's
            // service directly — `KB5YZB-1/B`. Anything else is a tactical
            // alias belonging to whoever sent the frame.
            let declared: Declaration
            if CallsignValidator.isValidCallsign(name) {
                declared = Declaration(callsign: name, service: service,
                                       alias: nil, sourceText: text)
            } else if NodeAliasParser.isPlausibleAlias(name), !owner.isEmpty {
                declared = Declaration(callsign: owner, service: service,
                                       alias: name, sourceText: text)
            } else {
                continue
            }

            let key = "\(declared.callsign)|\(service.rawValue)"
            guard seen.insert(key).inserted else { continue }
            result.append(declared)
        }

        result += parseFreeText(text, source: owner, existing: &seen)
        return result
    }

    /// The prose form some beacons use.
    ///
    /// `Denver Water Amateur Radio Club (DWARC) — Digipeat Alias = DWARC;
    /// Node:KD0SSP-7; PBBS:KD0SSP-1` says exactly what the slash form says,
    /// in words. Operators write beacons for humans, so a directory built
    /// only from the slash form misses stations that are announcing loudly.
    private static func parseFreeText(_ text: String, source: String,
                                      existing seen: inout Set<String>) -> [Declaration] {
        let upper = text.uppercased()
        var result: [Declaration] = []

        // "NODE:CALL", "PBBS:CALL", "BBS:CALL" — a label, a colon, a callsign.
        let labels: [(String, Service)] = [
            ("PBBS:", .bbs), ("BBS:", .bbs), ("NODE:", .node),
            ("DIGI:", .digipeater), ("GATEWAY:", .gateway), ("RMS:", .gateway),
        ]
        for (label, service) in labels {
            var searchRange = upper.startIndex..<upper.endIndex
            while let found = upper.range(of: label, range: searchRange) {
                searchRange = found.upperBound..<upper.endIndex
                let tail = upper[found.upperBound...]
                    .prefix(while: { $0.isLetter || $0.isNumber || $0 == "-" })
                let candidate = String(tail).trimmingCharacters(in: .whitespaces)
                guard CallsignValidator.isValidCallsign(candidate) else { continue }
                let key = "\(candidate)|\(service.rawValue)"
                guard seen.insert(key).inserted else { continue }
                result.append(Declaration(callsign: candidate, service: service,
                                          alias: nil, sourceText: text))
            }
        }
        return result
    }
}

import Foundation

/// Reading the two list commands a Kantronics KA-Node offers.
///
/// The node prompt states its whole command set: `ENTER COMMAND: B,C,J,N,
/// or Help ?` — Bye, Connect, JHeard, Nodes. Two of those produce lists
/// worth reading:
///
/// * **N (Nodes)** — what this node calls other nodes: an alias, the
///   callsign behind it in parentheses, and when it last heard from them.
///   `IVAN (W1VAN-2) 06/04/2026 07:36:16`.
/// * **J (JHeard)** — stations this node heard *directly*, callsign and
///   time, no alias column. `W1VAN 08/31/2026 04:54:36`.
///
/// The distinction matters more than it looks. `N` is a *directory*: names
/// this node has learned for stations, some of which it may only know
/// second-hand. `J` is a *measurement*: RF this node's own receiver
/// demodulated, so every entry is one hop from that node's antenna.
///
/// What may be believed from either is narrow, and deliberately so — see
/// `yieldsNetRomRoutes`.
nonisolated enum KaNodeOutput {

    /// A KA-Node has no layer 3: no routing table, no circuits, nothing to
    /// carry a NET/ROM connection. Its lists are evidence about what can be
    /// reached *through* it with a `C` command — a prompt relay — and never
    /// a route. Synthesising NET/ROM routes from them is precisely how the
    /// app would fabricate paths through stations that cannot route, which
    /// `NodeCapability` exists to prevent.
    static let yieldsNetRomRoutes = false

    /// One row of the `N` list.
    struct NodeEntry: Equatable, Sendable {
        /// The name this node uses, when it is a real name. Nil when the
        /// alias column merely repeats the callsign, or is empty.
        let alias: String?
        let callsign: String
        /// The node's own clock, in the node's own zone. Kept as text: the
        /// zone is not knowable from here, and reading it as local time
        /// would place stations hours into the future or the past.
        let reportedAt: String

        static func parse(_ line: String) -> NodeEntry? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let open = trimmed.firstIndex(of: "("),
                  let close = trimmed.firstIndex(of: ")"),
                  open < close else { return nil }

            let callsign = String(trimmed[trimmed.index(after: open)..<close])
                .trimmingCharacters(in: .whitespaces)
            guard CallsignValidator.isValidRoutingNode(callsign) else { return nil }

            // The alias column sits before the parenthesis, and a trailing
            // `*` marks the node's own channel rather than being part of
            // the name.
            var alias = String(trimmed[trimmed.startIndex..<open])
                .trimmingCharacters(in: .whitespaces)
            while alias.hasSuffix("*") { alias.removeLast() }
            alias = alias.trimmingCharacters(in: .whitespaces)
            // One token, or this is not a list row. The KA-Node's own
            // connect banner — `###CONNECTED TO NODE DRLNOD(KE0NCQ)
            // CHANNEL A` — is a parenthesised callsign preceded by prose,
            // and without this it files KE0NCQ as a directory entry.
            guard !alias.contains(" ") else { return nil }

            let stamp = String(trimmed[trimmed.index(after: close)...])
                .trimmingCharacters(in: .whitespaces)
            guard KaNodeOutput.looksLikeATimestamp(stamp) else { return nil }

            return NodeEntry(
                alias: Self.meaningfulAlias(alias, for: callsign),
                callsign: callsign.uppercased(),
                reportedAt: stamp)
        }

        /// An "alias" that is just the callsign again — or the callsign's
        /// SSID tail, as `-7*` beside `(KA9QJT-1)` — names nothing. Storing
        /// it would put junk in the alias directory, and a wrong alias is
        /// worse than no alias: it is what the operator would type.
        private static func meaningfulAlias(_ alias: String, for callsign: String) -> String? {
            let normalized = alias.uppercased()
            guard !normalized.isEmpty else { return nil }
            // A bare SSID fragment left over from a truncated column.
            guard !normalized.hasPrefix("-") else { return nil }
            guard CallsignValidator.isValidRoutingNode(normalized) else { return nil }
            // Compare *stations*, not strings. `AA0QC-7` beside `(AA0QC)`
            // is the same operator on another SSID, not a name for them —
            // and a wrong alias is worse than none, because it is what the
            // operator would type into the connect bar.
            let aliasBase = Callsign(normalized)?.base ?? normalized
            let callsignBase = Callsign(callsign)?.base ?? callsign.uppercased()
            guard aliasBase != callsignBase else { return nil }
            return normalized
        }
    }

    /// One row of the `J` list: a station this node's own receiver heard.
    struct HeardEntry: Equatable, Sendable {
        let callsign: String
        /// The node's clock, verbatim. See `NodeEntry.reportedAt`.
        let reportedAt: String

        static func parse(_ line: String) -> HeardEntry? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // A node-list row carries a parenthesised callsign; a heard row
            // never does. Without this check the two lists mix, and a
            // node's second-hand directory gets filed as RF this node
            // actually heard.
            guard !trimmed.contains("("), !trimmed.contains(")") else { return nil }

            let fields = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2 else { return nil }

            let callsign = String(fields[0]).uppercased()
            guard CallsignValidator.isValidRoutingNode(callsign) else { return nil }

            let stamp = fields.dropFirst().joined(separator: " ")
            guard KaNodeOutput.looksLikeATimestamp(stamp) else { return nil }

            return HeardEntry(callsign: callsign, reportedAt: stamp)
        }

    }

    /// `MM/DD/YYYY HH:MM:SS`, checked for shape only. The point is to
    /// refuse prose that happens to start with something callsign-like,
    /// not to validate a calendar — the node's clock is its own business.
    fileprivate static func looksLikeATimestamp(_ text: String) -> Bool {
        let parts = text.split(separator: " ")
        guard parts.count == 2 else { return false }
        let date = parts[0].split(separator: "/")
        let time = parts[1].split(separator: ":")
        guard date.count == 3, time.count == 3 else { return false }
        return (date + time).allSatisfy { $0.allSatisfy(\.isNumber) }
    }
}

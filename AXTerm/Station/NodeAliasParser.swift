import Foundation
import Combine

/// Resolves NET/ROM-style node aliases — `DRLNOD`, `HORSE`, `EATON` — to
/// the callsign that operates them.
///
/// An alias is a tactical name, not a licence, so no callsign directory
/// will ever have one. But stations *announce* their aliases in plain
/// text, in ID beacons this receiver is already storing:
///
///     KE0NCQ/R DRL/D DRLBBS/B DRLNOD/N
///     W1VAN/R W1VAN-7/D HORSE/N
///     NODE: YZBBPQ:KB5YZB-7, Aurora, CO Area BPQ Packet Node
///
/// Once `DRLNOD` is known to be `KE0NCQ`, the existing chain does the
/// rest: callsign → directory → position. That turns a via-path entry
/// that was previously an opaque string into a point on the map.
///
/// Parsing only; the caller decides what to keep. Every claim here comes
/// from a station's own announcement about itself, which is the strongest
/// evidence available for something a directory cannot know.
nonisolated enum NodeAliasParser {

    /// What a station said it provides.
    struct Announcement: Equatable, Sendable {
        /// The tactical name, e.g. `DRLNOD`.
        var alias: String
        /// The callsign operating it, e.g. `KE0NCQ`.
        var callsign: String
        /// Single-letter service code as announced: `N` node, `B` BBS,
        /// `D` digipeater, `G` gateway, `R` relay. Kept verbatim rather
        /// than interpreted — conventions vary between stacks.
        var service: String
    }

    /// Parses one beacon or ID payload.
    ///
    /// - Parameters:
    ///   - text: the frame's information field.
    ///   - source: the transmitting callsign, used when the payload
    ///     names services without repeating whose they are.
    static func parse(_ text: String, source: String) -> [Announcement] {
        let nodeForm = parseNodeForm(text)
        if !nodeForm.isEmpty { return nodeForm }
        let table = parseNodeTable(text)
        if !table.isEmpty { return table }
        return parseServiceList(text, source: source)
    }

    // MARK: - `ALIAS:CALLSIGN` table form

    /// A node's own nodes table, as `N` returns it.
    ///
    ///     DRLNOD:KE0NCQ-2  EVANS:KC0LDY-10  HORSE:KN6VV-1
    ///
    /// The single highest-yield source of alias knowledge there is: one command
    /// to one node names its whole view of the network, where beacons name one
    /// station at a time and only when they happen to transmit.
    ///
    /// Which half is the callsign is decided by *shape*, not by position. BPQ's
    /// own prompt is the pair the other way round (`K0EPI-7:DRLNOD}`), and a
    /// parser that trusted the order would record every node's prompt as an
    /// alias pointing at the wrong station.
    static func parseNodeTable(_ text: String) -> [Announcement] {
        var result: [Announcement] = []
        var seen = Set<String>()

        for token in text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0.isNewline }) {
            // `}` ends the node prompt; anything carrying it is the banner
            // rather than a table entry.
            let cleaned = token.trimmingCharacters(
                in: CharacterSet(charactersIn: "},.;()[]"))
            let parts = cleaned.split(separator: ":")
            guard parts.count == 2 else { continue }

            let left = String(parts[0]).uppercased()
            let right = String(parts[1]).uppercased()
            let leftIsCall = CallsignQuery.isPlausible(left)
            let rightIsCall = CallsignQuery.isPlausible(right)

            // Exactly one side must look like a callsign. Both means we cannot
            // tell which is which by shape alone; neither means it is not a
            // node pair at all.
            let alias: String
            let callsign: String
            switch (leftIsCall, rightIsCall) {
            case (false, true): alias = left; callsign = right
            case (true, false): alias = right; callsign = left
            case (true, true):
                // Callsign-shaped on both sides — `2RZBPQ:VK2RZ-7`,
                // `5EBBS:AE5E-3`. Aliases that open with a digit read as
                // callsigns to any shape test, and skipping the pair silently
                // dropped two of the eleven nodes KB5YZB-7 listed on
                // 2026-08-27. An SSID breaks the tie: a node's callsign in
                // these tables carries one and a tactical alias never does.
                let leftHasSSID = left.contains("-")
                let rightHasSSID = right.contains("-")
                guard leftHasSSID != rightHasSSID else { continue }
                if rightHasSSID { alias = left; callsign = right }
                else { alias = right; callsign = left }
            case (false, false): continue
            }

            guard isPlausibleAlias(alias) else { continue }
            guard seen.insert(alias).inserted else { continue }
            // No service claim. A node's table lists everything the network
            // knows how to reach — BBSes, chat servers, RMS gateways, DX
            // clusters — not only nodes, and the table says which is which
            // nowhere. Stamping every row `N` made `BVJBBS`, a BBS, report
            // itself a NET/ROM node on the evidence of an identification it
            // never sent (2026-08-27). The name often hints at the role, but a
            // suffix convention is not an observation.
            result.append(Announcement(alias: alias, callsign: callsign, service: ""))
        }
        return result
    }

    // MARK: - `CALL/R ALIAS/D ALIAS/N` form

    /// The common ID form: the station's callsign, then one `NAME/type`
    /// token per service it offers.
    ///
    /// Tokens whose name is itself a callsign (`KB5YZB-1/B`) are skipped:
    /// those are SSIDs of the same licence, not aliases, and recording
    /// them as aliases would make a callsign resolve to itself.
    private static func parseServiceList(_ text: String, source: String) -> [Announcement] {
        let owner = CallsignQuery.normalize(source)
        guard !owner.isEmpty else { return [] }

        var result: [Announcement] = []
        var seen = Set<String>()
        for token in text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0.isNewline }) {
            let parts = token.split(separator: "/")
            guard parts.count == 2, parts[1].count == 1 else { continue }
            let name = String(parts[0]).uppercased()
            let service = String(parts[1]).uppercased()
            guard service.first?.isLetter == true else { continue }
            // A name that is a callsign is an SSID of this station, not
            // a tactical alias.
            guard !CallsignQuery.isPlausible(name) else { continue }
            guard isPlausibleAlias(name) else { continue }
            guard seen.insert(name).inserted else { continue }
            result.append(Announcement(alias: name, callsign: owner, service: service))
        }
        return result
    }

    // MARK: - `NODE: ALIAS:CALLSIGN, description` form

    /// BPQ-style node identification, which names the callsign directly
    /// and so does not depend on the frame's source.
    private static func parseNodeForm(_ text: String) -> [Announcement] {
        let upper = text.uppercased()
        guard let range = upper.range(of: "NODE:") else { return [] }
        let remainder = upper[range.upperBound...]
            .split(separator: ",", maxSplits: 1).first ?? ""
        let pair = remainder.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard pair.count == 2 else { return [] }

        let alias = String(pair[0]).trimmingCharacters(in: .whitespaces)
        let callsign = String(pair[1]).trimmingCharacters(in: .whitespaces)
        guard isPlausibleAlias(alias), CallsignQuery.isPlausible(callsign) else { return [] }
        return [Announcement(alias: alias, callsign: callsign, service: "N")]
    }

    // MARK: - Validation

    /// A tactical alias is 2–6 characters of letters and digits.
    ///
    /// Deliberately permissive about *shape* and strict about length:
    /// aliases are arbitrary names, so the only reliable filter is the
    /// six-character field they travel in. Anything longer is prose that
    /// happened to contain a slash.
    static func isPlausibleAlias(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces).uppercased()
        guard (2...6).contains(trimmed.count) else { return false }
        guard !fieldLabels.contains(trimmed) else { return false }
        return trimmed.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    /// Words that name a *kind* of service rather than a particular one.
    ///
    /// Beacons are prose, and prose contains colon pairs that are not table
    /// rows: `Digipeat Alias = DWARC; Node:KD0SSP-7; PBBS:KD0SSP-1` reads to a
    /// table parser as the aliases `NODE` and `PBBS`. They are field labels —
    /// "my node is…", "my PBBS is…" — and KD0SSP's own name for its node is
    /// DWARC, elsewhere in the same sentence.
    ///
    /// Worth excluding rather than tolerating because an alias is a *global
    /// key*: every station that beacons `Node:` would take the name in turn,
    /// so `NODE` would resolve to whoever transmitted most recently. A real
    /// tactical alias is a place or club abbreviation, and none of these are.
    private static let fieldLabels: Set<String> = [
        "NODE", "NODES", "BBS", "PBBS", "MBOX", "DIGI", "ALIAS",
        "RMS", "MAIL", "CHAT", "NET", "DX", "PORT", "USERS", "INFO"
    ]
}

/// Accumulated alias knowledge, newest announcement winning.
///
/// A node can be renamed or a callsign reassigned, so the most recent
/// announcement is taken as current rather than the first one heard.
nonisolated struct NodeAliasDirectory: Equatable, Sendable {

    struct Entry: Equatable, Sendable, Codable {
        var alias: String
        var callsign: String
        var service: String
        var heardAt: Date
        /// How many times this pairing has been announced — repeated
        /// evidence for the same claim.
        var announcements: Int

        /// Every node that has listed this station, and when it last did.
        ///
        /// This is the practical half of the directory. An alias is hearsay
        /// unless you know who said it — `AGNODE` came from KB5YZB-7's node
        /// table, not from K1AJD-4 itself — and more than that, the node that
        /// listed a station is the node to connect *through* to reach it. A
        /// row with no teller resolves a name and offers no way in.
        ///
        /// Plural because two nodes listing the same station are two routes,
        /// and keeping only the latest threw one away. Dated because a node's
        /// table is a claim that ages: one that listed this station an hour ago
        /// is a better bet than one that listed it in June.
        var tellers: [String: Date] = [:]

        /// The most recent node to list this station, for callers wanting one
        /// name. Nil when nothing has ever claimed to reach it.
        var learnedFrom: String? {
            tellers.max { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                return lhs.key > rhs.key   // deterministic on equal timestamps
            }?.key
        }

        /// Tellers newest first — the order to try them in.
        var reachableVia: [String] {
            tellers.sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }.map(\.key)
        }

        /// Records that `teller` listed this station, keeping the later of
        /// the two dates so a replayed old frame never ages a fresh claim.
        mutating func noteTeller(_ teller: String, at time: Date) {
            let key = teller.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !key.isEmpty else { return }
            // A node listing itself says nothing about how to reach it.
            guard key != callsign.uppercased(), key != alias.uppercased() else { return }
            if let known = tellers[key], known >= time { return }
            tellers[key] = time
        }

        private enum CodingKeys: String, CodingKey {
            case alias, callsign, service, heardAt, announcements, tellers
            /// Pre-multi-teller storage held a single optional name.
            case learnedFrom
        }

        init(alias: String, callsign: String, service: String,
             heardAt: Date, announcements: Int, tellers: [String: Date] = [:]) {
            self.alias = alias
            self.callsign = callsign
            self.service = service
            self.heardAt = heardAt
            self.announcements = announcements
            self.tellers = tellers
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            alias = try container.decode(String.self, forKey: .alias)
            callsign = try container.decode(String.self, forKey: .callsign)
            service = try container.decode(String.self, forKey: .service)
            heardAt = try container.decode(Date.self, forKey: .heardAt)
            announcements = try container.decode(Int.self, forKey: .announcements)

            if let stored = try container.decodeIfPresent(
                [String: Date].self, forKey: .tellers) {
                tellers = stored
            } else if let legacy = try container.decodeIfPresent(
                String.self, forKey: .learnedFrom), !legacy.isEmpty {
                // One teller, and the only timestamp we have for it is when the
                // claim itself was last heard. Close enough to be useful and
                // honest about being an upper bound.
                //
                // Same self-teller rule as `noteTeller`, which this path used to
                // bypass: KE0NCQ's own ID announced DRLNOD, so the legacy source
                // was KE0NCQ, and importing it read "reach via KE0NCQ" — connect
                // to the station to reach the station.
                let teller = legacy.uppercased()
                tellers = (teller == callsign.uppercased() || teller == alias.uppercased())
                    ? [:] : [legacy: heardAt]
            } else {
                tellers = [:]
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(alias, forKey: .alias)
            try container.encode(callsign, forKey: .callsign)
            try container.encode(service, forKey: .service)
            try container.encode(heardAt, forKey: .heardAt)
            try container.encode(announcements, forKey: .announcements)
            try container.encode(tellers, forKey: .tellers)
        }
    }

    private(set) var entries: [String: Entry] = [:]

    init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    /// Records an announcement. Later announcements replace earlier ones
    /// for the same alias.
    mutating func record(_ announcement: NodeAliasParser.Announcement,
                         at time: Date,
                         from source: String? = nil) {
        let key = announcement.alias.uppercased()
        let existing = entries[key]
        let sameClaim = existing?.callsign == announcement.callsign
        let told = source?.trimmingCharacters(in: .whitespaces).uppercased()

        // A frame we have already counted is not new evidence for anything.
        //
        // Stored beacons are re-swept every time the operator opens Packets,
        // Map or Nodes, and each sweep used to re-count every beacon still in
        // retention. KE0NCQ beacons often, so DRLNOD reached "heard ×1708" —
        // a tally of how many times the page had been opened, presented as
        // corroboration (2026-08-27). Announcements strictly newer than what is
        // stored are genuinely new; anything at or before it is a replay.
        //
        // Attribution is the exception: a node listing this station is a way
        // to reach it, and that is worth knowing even when the claim itself is
        // one we have already counted.
        if let existing, time <= existing.heardAt {
            if let told, !told.isEmpty {
                entries[key]?.noteTeller(told, at: time)
            }
            return
        }

        var updated = Entry(
            alias: key,
            callsign: announcement.callsign.uppercased(),
            service: announcement.service,
            heardAt: time,
            announcements: sameClaim ? (existing?.announcements ?? 0) + 1 : 1,
            // A station that changed which callsign it claims has invalidated
            // what the old tellers said, so their routes do not carry over.
            tellers: sameClaim ? (existing?.tellers ?? [:]) : [:])
        if let told, !told.isEmpty {
            updated.noteTeller(told, at: time)
        }
        entries[key] = updated
    }

    func callsign(for alias: String) -> String? {
        entries[alias.trimmingCharacters(in: .whitespaces).uppercased()]?.callsign
    }

    func entry(for alias: String) -> Entry? {
        entries[alias.trimmingCharacters(in: .whitespaces).uppercased()]
    }

    var allEntries: [Entry] {
        entries.values.sorted { ($0.alias) < ($1.alias) }
    }

    // MARK: - Reverse: callsign → the names it answers to

    /// Every alias announced for a callsign, node roles first.
    ///
    /// Usually one. A station that runs several services announces one name
    /// per service — `KE0NCQ/R DRL/D DRLBBS/B DRLNOD/N` is a digipeater, a BBS
    /// and a node on the same licence — so the answer is a list, not a name.
    func aliases(for callsign: String) -> [Entry] {
        // Deliberately not CallsignQuery.normalize: that strips the SSID, and
        // here the SSID is the whole distinction. One licence runs several
        // services on separate SSIDs and names each of them — KE0NCQ answers
        // to DRLNOD on -7 and DRLBBS on -1. Folding the SSID away would hand
        // back every service a station runs when asked about one of them.
        let key = callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty else { return [] }
        return entries.values
            .filter { $0.callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == key }
            .sorted { lhs, rhs in
                // A node name is the one that turns up in via paths and connect
                // targets, so it is the one worth showing when there is room
                // for one. Ties fall back to the alias for a stable order.
                let lhsNode = lhs.service.uppercased() == "N"
                let rhsNode = rhs.service.uppercased() == "N"
                if lhsNode != rhsNode { return lhsNode }
                return lhs.alias < rhs.alias
            }
    }

    /// Entries worth forgetting: no way to reach them, and nothing here has
    /// ever seen the station.
    ///
    /// Deliberately two conditions. "No teller" alone is the wrong criterion —
    /// an entry can be unroutable and still earn its keep resolving a name for
    /// a map pin or a via-path label, which is what `EATON → W2CRS` does. And
    /// "never heard on air" alone is meaningless in a network where BPQ nodes
    /// link over AXIP: half the useful destinations are behind IP tunnels and
    /// will never reach this receiver.
    ///
    /// Together they mean something real: nothing can be done with this row,
    /// and nothing else is using it. It is also cheap to be wrong about — if a
    /// node lists the station again it comes back *with* a teller, which is the
    /// form that was worth having.
    ///
    /// - Parameter knownCallsigns: every callsign this station knows of, from
    ///   any source. Compared without SSIDs, since hearing `N0HI-7` is reason
    ///   enough to keep a name for `N0HI-1`.
    func forgettable(knownCallsigns: Set<String>) -> [Entry] {
        let known = Set(knownCallsigns.map { CallsignQuery.normalize($0) })
        return entries.values
            .filter { $0.tellers.isEmpty }
            .filter { !known.contains(CallsignQuery.normalize($0.callsign)) }
            .sorted { $0.alias < $1.alias }
    }

    /// Nodes that have listed this station under any of its names, freshest
    /// first — the order to try them in.
    ///
    /// Union across aliases because a station can be listed under several
    /// (`DRLBBS` and `DRLNOD` are one licence), and a node that named any of
    /// them knows how to get there.
    /// Dated teller claims for a destination named by alias or callsign,
    /// newest first. The connect planner ranks a relay by how recently a
    /// node listed the destination, so it needs the date, not just the name.
    func tellerClaims(for destination: String) -> [(teller: String, claimedAt: Date)] {
        let key = destination.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty else { return [] }
        var freshest: [String: Date] = [:]
        for entry in entries.values
        where entry.callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == key
            || entry.alias.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == key {
            for (teller, when) in entry.tellers
            where (freshest[teller] ?? .distantPast) < when {
                freshest[teller] = when
            }
        }
        return freshest.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key < $1.key
        }.map { (teller: $0.key, claimedAt: $0.value) }
    }

    func tellers(forCallsign callsign: String) -> [String] {
        let key = callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty else { return [] }
        var freshest: [String: Date] = [:]
        for entry in entries.values
        where entry.callsign.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() == key {
            for (teller, when) in entry.tellers
            where (freshest[teller] ?? .distantPast) < when {
                freshest[teller] = when
            }
        }
        return freshest.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key < $1.key
        }.map(\.key)
    }

    /// Everything each node has claimed it can reach, keyed by that node.
    ///
    /// An entry appears under *every* node that listed it, so the lists
    /// overlap. That is the fact: two nodes both carrying the same eighty
    /// stations are two ways in, and the question this answers — "if I
    /// connect to this node, what can I ask it for" — is not affected by
    /// which node happened to announce most recently.
    ///
    /// Shared by the sidebar's per-node counts and the Nodes page's route
    /// filter so the number on the row and the rows on the page cannot
    /// disagree, which they did: filing each station under its freshest
    /// teller alone reported one node as reaching a single station when its
    /// table listed eighty-eight (2026-08-27).
    func entriesByTeller() -> [String: [Entry]] {
        var grouped: [String: [Entry]] = [:]
        for entry in entries.values {
            for teller in entry.tellers.keys {
                grouped[teller.uppercased(), default: []].append(entry)
            }
        }
        return grouped.mapValues { $0.sorted { $0.alias < $1.alias } }
    }

    /// Everything one node has claimed it can reach, by alias.
    func entries(reachableVia teller: String) -> [Entry] {
        let key = teller.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty else { return [] }
        return entries.values
            .filter { $0.tellers.keys.contains { $0.uppercased() == key } }
            .sorted { $0.alias < $1.alias }
    }

    /// Destinations the network claims are reachable, and through whom.
    ///
    /// Keyed by both names, because the operator types whichever one they saw:
    /// `AGCHAT` and `K1AJD-5` are the same destination. The alias is the more
    /// useful key of the two — sent unresolved, a BPQ node looks it up in its
    /// own table — but nothing stops someone typing the callsign.
    func connectRoutes() -> [String: [String]] {
        var result: [String: [String]] = [:]
        for entry in entries.values where !entry.tellers.isEmpty {
            result[entry.alias.uppercased()] = entry.reachableVia
        }
        // Callsign keys are unioned across every alias resolving to them, so a
        // station listed under two names offers both nodes as ways in.
        for callsign in Set(entries.values.map { $0.callsign.uppercased() }) {
            let via = tellers(forCallsign: callsign)
            if !via.isEmpty { result[callsign] = via }
        }
        return result
    }

    /// The station's *other* name, whichever one you already have.
    ///
    /// Rows in the sidebar and addresses in a packet header hold whatever the
    /// AX.25 address field carried, and that is sometimes the alias (DRLNOD)
    /// and sometimes the callsign (N0HI-7). Asking which it is, then picking
    /// the matching lookup, is a step every display would otherwise repeat.
    /// Returns nil when the name is unknown or is the only one we have.
    func otherName(for identifier: String) -> String? {
        let key = identifier.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty else { return nil }
        if let behind = callsign(for: key), behind.uppercased() != key { return behind }
        if let name = preferredAlias(for: key), name.uppercased() != key { return name }
        return nil
    }

    /// Every station's other name, both directions, built in one pass.
    ///
    /// `otherName(for:)` scans the whole directory per call, which is fine for
    /// one station and wrong for a list: the sidebar would multiply 29 rows by
    /// a directory that grows with every node table harvested, on every render.
    /// Callers naming a list build this once instead.
    func otherNames() -> [String: String] {
        var result: [String: String] = [:]
        for entry in entries.values {
            let alias = entry.alias.uppercased()
            let callsign = entry.callsign.uppercased()
            guard alias != callsign else { continue }
            result[alias] = entry.callsign
            // A licence running several services keeps the node name, matching
            // `preferredAlias`. First writer wins otherwise, so the comparison
            // is against what is already there rather than unconditional.
            if entry.service.uppercased() == "N" || result[callsign] == nil {
                result[callsign] = entry.alias
            }
        }
        return result
    }

    /// The single name to show beside a callsign, if it has one.
    func preferredAlias(for callsign: String) -> String? {
        aliases(for: callsign).first?.alias
    }
}

/// Observable alias knowledge, fed by received frames and persisted.
///
/// Kept in `UserDefaults` rather than the database on purpose: it is a
/// dictionary of a dozen short strings, and a migration would cost more
/// than it is worth. It still survives restarts, which is what matters —
/// an alias learned while the network was up stays resolvable when it is
/// not.
@MainActor
final class NodeAliasStore: ObservableObject {

    /// Service declarations heard in ID and beacon frames, keyed
    /// `callsign|serviceCode`.
    @Published private(set) var serviceDeclarations: [String: ServiceRecord] = [:]

    @Published private(set) var directory = NodeAliasDirectory()

    private let defaults: UserDefaults
    private let key = "station.nodeAliases"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    /// Bumped when stored entries carry a field this version cannot trust.
    private let repairKey = "station.nodeAliases.repairedV3"

    private func load() {
        guard let data = defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode(
                [String: NodeAliasDirectory.Entry].self, from: data)
        else { return }
        directory = NodeAliasDirectory(entries: entries)
        repairInflatedCountsIfNeeded()
    }

    /// Drops stored fields this version knows were never observed.
    ///
    /// Every stored count is a real count plus an unknowable number of
    /// re-sweeps, and there is no way to separate them — so no stored count is
    /// trustworthy, including the ones that happen to read 1. Rather than leave
    /// a number on screen that the tooltip describes as corroboration and that
    /// actually measures page visits, the evidence restarts from now and
    /// re-accumulates correctly. The alias claims themselves are untouched:
    /// those are still good, and losing them would lose real knowledge.
    private func repairInflatedCountsIfNeeded() {
        guard !defaults.bool(forKey: repairKey) else { return }
        defaults.set(true, forKey: repairKey)
        guard !directory.entries.isEmpty else { return }
        directory = NodeAliasDirectory(
            entries: directory.entries
                .filter { NodeAliasParser.isPlausibleAlias($0.key) }
                .mapValues { entry in
                var reset = entry
                reset.announcements = 1
                // A station is not a route to itself. `noteTeller` refuses
                // these, but storage written between the two changes recorded
                // them directly — KE0NCQ's own ID announced DRLNOD, and the
                // entry read "reach via KE0NCQ".
                reset.tellers = entry.tellers.filter {
                    $0.key.uppercased() != entry.callsign.uppercased()
                        && $0.key.uppercased() != entry.alias.uppercased()
                }
                // A service claim harvested from a node table was never
                // observed — the table says what a node can reach, not what
                // each station is. Entries carrying a teller other than
                // themselves came from a table; a station's own ID is not a
                // teller, so its declared services survive.
                if !reset.tellers.isEmpty { reset.service = "" }
                return reset
            })
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(directory.entries) else { return }
        defaults.set(data, forKey: key)
    }

    /// Forgets entries that offer no route and name nothing this station knows.
    ///
    /// Returns how many went, so the caller can say so rather than leaving the
    /// operator to guess whether anything happened.
    @discardableResult
    func forget(knownCallsigns: Set<String>) -> Int {
        let doomed = directory.forgettable(knownCallsigns: knownCallsigns)
        guard !doomed.isEmpty else { return 0 }
        var remaining = directory.entries
        for entry in doomed { remaining.removeValue(forKey: entry.alias.uppercased()) }
        directory = NodeAliasDirectory(entries: remaining)
        save()
        return doomed.count
    }

    /// Learns from one frame. Cheap enough to call per packet.
    func ingest(text: String, source: String, at time: Date = Date()) {
        let found = NodeAliasParser.parse(text, source: source)
        guard !found.isEmpty else { return }
        var updated = directory
        for announcement in found {
            updated.record(announcement, at: time, from: source)
        }
        guard updated != directory else { return }
        directory = updated
        save()
    }

    /// Learns from a batch of received frames.
    ///
    /// Only ID and beacon destinations are inspected: those are where a
    /// station announces what it offers. Reading every frame would cost
    /// more and teach nothing extra.
    static let announcementDestinations: Set<String> = ["ID", "BEACON", "NODES", "NODE"]

    func ingest(packets: [Packet]) {
        for packet in packets {
            guard let text = packet.infoText, !text.isEmpty else { continue }
            guard let destination = packet.to?.call.uppercased(),
                  Self.announcementDestinations.contains(destination) else { continue }
            guard let source = packet.from?.display else { continue }
            ingest(text: text, source: source, at: packet.timestamp)
            ingestServices(text: text, source: source, at: packet.timestamp)
        }
    }

    /// What each station said it runs.
    ///
    /// Kept beside the alias directory because it comes from the same frames,
    /// but answering a different question: aliases resolve a tactical name to
    /// a callsign, this records that a callsign runs a BBS. Most networks
    /// never broadcast NET/ROM `NODES`, so these ID frames are the only
    /// directory the network publishes about itself — and they arrive over
    /// the air, needing no internet.
    private func ingestServices(text: String, source: String, at time: Date) {
        for declaration in StationServiceParser.parse(text, source: source) {
            let key = "\(declaration.callsign)|\(declaration.service.rawValue)"
            if var existing = serviceDeclarations[key] {
                existing.lastHeard = time
                existing.timesHeard += 1
                serviceDeclarations[key] = existing
            } else {
                serviceDeclarations[key] = ServiceRecord(
                    declaration: declaration, firstHeard: time,
                    lastHeard: time, timesHeard: 1)
            }
        }
    }

    /// A declaration, with how often it has been repeated.
    ///
    /// Repetition matters: an ID frame heard once could be a decode error,
    /// while the same claim every ten minutes for a week is the network
    /// describing itself reliably.
    nonisolated struct ServiceRecord: Equatable, Sendable {
        var declaration: StationServiceParser.Declaration
        var firstHeard: Date
        var lastHeard: Date
        var timesHeard: Int
    }

    /// Everything heard, keyed callsign|service.
    var declaredServices: [StationServiceParser.Declaration] {
        serviceDeclarations.values.map(\.declaration)
    }

    /// The full records, for a directory view.
    var serviceRecords: [ServiceRecord] {
        serviceDeclarations.values.sorted {
            ($1.timesHeard, $0.declaration.callsign) < ($0.timesHeard, $1.declaration.callsign)
        }
    }
}

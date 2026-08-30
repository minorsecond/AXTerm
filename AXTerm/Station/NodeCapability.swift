//
//  NodeCapability.swift
//  AXTerm
//
//  Which node software a station runs — and therefore whether it can route
//  NET/ROM — as far as its own output proves.
//
//  The question matters because "node" is not one thing. DRLNOD (KE0NCQ)
//  greets with `###CONNECTED TO NODE DRLNOD(KE0NCQ) CHANNEL A` and offers
//  `ENTER COMMAND: B,C,J,N, or Help ?` — a Kantronics KA-Node, a connectable
//  relay with no L3 at all. KB5YZB-7 greets with a "Network Node Server"
//  banner and a full BPQ menu — a real NET/ROM stack. Both call themselves
//  nodes; only one can carry a NET/ROM circuit. Route synthesis from scraped
//  tables (see HarvestedRoutePolicy) must be gated on this distinction, or
//  the app fabricates routes through stations that cannot route.
//
//  Evidence discipline follows NodeProfile.NetRomDeclaration: every verdict
//  is earned by a specific observed line, kept verbatim so the UI can quote
//  it, and a station whose evidence conflicts gets no verdict rather than a
//  guess. ID-beacon `/N` service declarations are deliberately never
//  consulted here — "claims to be a node" is a declared-tier service fact,
//  not capability evidence.
//

import Combine
import Foundation

/// The software family behind a remote "node", as proven by its own output.
nonisolated enum NodeSoftwareFamily: String, Codable, Sendable {
    /// Kantronics KA-Node: connectable prompt relay and digipeater.
    /// CANNOT route NET/ROM — no L3, no routing table, no circuits.
    case kaNode
    /// BPQ32 / LinBPQ: full NET/ROM stack.
    case bpq
    /// Proven NET/ROM-capable by a routing broadcast, family unknown.
    case netromOther

    var label: String {
        switch self {
        case .kaNode: return "KA-Node"
        case .bpq: return "BPQ node"
        case .netromOther: return "NET/ROM node"
        }
    }
}

/// One piece of software-fingerprint evidence, kept verbatim for the UI.
nonisolated struct NodeSoftwareObservation: Equatable, Sendable, Codable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        /// PID 0xCF UI frame to NODES — ground truth. Nothing but a
        /// NET/ROM stack sends one.
        case nodesBroadcast
        /// "NETWORK NODE SERVER" in a session greeting.
        case bpqBanner
        /// A `CALL:ALIAS}` command prompt — the BPQ prompt shape.
        case bpqPrompt
        /// A menu line listing the BPQ command set (CONNECT/NODES/ROUTES/…).
        case bpqMenu
        /// "ENTER COMMAND: B,C,J,N" — the Kantronics command set. The bare
        /// words "ENTER COMMAND" are not enough; other software prints a
        /// generic prompt too, but only Kantronics offers exactly B,C,J,N.
        case kaNodeMenu
        /// "###CONNECTED TO NODE X(CALL) CHANNEL A" — the KA-Node link
        /// banner, with its distinctive CHANNEL suffix.
        case kaNodeLinkBanner
        /// RelayLegWitness saw the station dial outward under a borrowed
        /// SSID of our own callsign. Corroborating only — never sufficient
        /// for a verdict on its own, because a crossband arrangement can
        /// produce a similar shape.
        case borrowedSsidDial
    }

    var kind: Kind
    var observedAt: Date
    /// The line that earned the observation, truncated — shown to the
    /// operator so the verdict is auditable, never re-parsed.
    var sourceText: String
}

/// Recognizes software fingerprints in one transcript line. Pure, stateless,
/// and deliberately conservative: nil is the answer for the overwhelmingly
/// common case of an ordinary line, and shared phrasings are not
/// fingerprints — "###LINK MADE" is printed by both families and proves
/// nothing about which one spoke.
nonisolated enum NodeSoftwareClassifier {

    /// Whole words whose presence (three or more on one line) marks a BPQ
    /// command menu. Three, because BBS help text or chat can legitimately
    /// mention one or two of them.
    private static let bpqMenuWords: Set<String> = ["CONNECT", "NODES", "ROUTES", "PORTS", "BYE"]

    static func classify(line: String) -> NodeSoftwareObservation.Kind? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let upper = trimmed.uppercased()

        if upper.contains("NETWORK NODE SERVER") {
            return .bpqBanner
        }
        // Field capture 2026-08-28: "ENTER COMMAND: B,C,J,N, or Help ?"
        if upper.contains("ENTER COMMAND"), upper.contains("B,C,J,N") {
            return .kaNodeMenu
        }
        // Field capture 2026-08-28: "###CONNECTED TO NODE DRLNOD(KE0NCQ)
        // CHANNEL A". Both substrings required — BPQ also prints "###"-style
        // status lines, but never the Kantronics CHANNEL suffix.
        if upper.contains("###CONNECTED TO NODE"), upper.contains("CHANNEL") {
            return .kaNodeLinkBanner
        }
        if isBpqPrompt(upper) {
            return .bpqPrompt
        }
        if isBpqMenu(upper) {
            return .bpqMenu
        }
        return nil
    }

    /// The BPQ command prompt — an `ALIAS:CALL}` / `CALL:ALIAS}` pair
    /// followed by `}` — as the leading token of a line.
    ///
    /// Two things real BPQ does that the first cut of this check missed,
    /// both caught by a live scrape against the docker rig (2026-08-29):
    ///
    ///  1. The callsign sits on the RIGHT: nodes print `TSTNOD:BPQTST-7}`,
    ///     `YZBBPQ:KB5YZB-7}` — alias first. Deciding by `isPlausible(left)`
    ///     alone never fired on a real prompt, so the anchor never earned a
    ///     BPQ verdict and every scraped ROUTES row was refused. Which half
    ///     is the callsign is decided by shape, not position — as the old
    ///     comment already claimed it should be.
    ///  2. BPQ glues the prompt to the command it just echoed
    ///     (`…} Routes`), so the whole line is not the bare prompt. The
    ///     prompt is still the leading whitespace-delimited token, so test
    ///     that, not the entire line.
    private static func isBpqPrompt(_ upper: String) -> Bool {
        guard let token = upper.split(separator: " ").first,
              token.hasSuffix("}") else { return false }
        let parts = token.dropLast().split(separator: ":")
        guard parts.count == 2 else { return false }
        let a = String(parts[0])
        let b = String(parts[1])
        // One half is a plausible callsign, the other a plausible alias —
        // in whichever order this BPQ prints them.
        return (CallsignQuery.isPlausible(a) && NodeAliasParser.isPlausibleAlias(b))
            || (CallsignQuery.isPlausible(b) && NodeAliasParser.isPlausibleAlias(a))
    }

    private static func isBpqMenu(_ upper: String) -> Bool {
        let words = Set(
            upper.split(whereSeparator: { !$0.isLetter }).map(String.init)
        )
        return words.intersection(bpqMenuWords).count >= 3
    }

    /// The station tokens an observation's own words name — nil for
    /// anonymous lines (menus, bare prompts we could not parse).
    ///
    /// Identity travels with the words, not the link. During a prompt relay
    /// every downstream node's output rides the L2 peer's frames, and until
    /// 2026-08-28 the harvester credited that peer: DRLNOD's record ended
    /// up holding "Welcome to YZBBPQ:KB5YZB-7 Network Node Server" as its
    /// own BPQ banner, the verdict became a conflict, and a poisoned teller
    /// claim slipped past the KA-Node filter (18:39 field capture). A
    /// banner that names a station was necessarily spoken by that station,
    /// however its bytes arrived.
    static func namedStations(in observation: NodeSoftwareObservation) -> Set<String>? {
        let upper = observation.sourceText.uppercased()
        switch observation.kind {
        case .bpqBanner, .bpqPrompt:
            // "Welcome to YZBBPQ:KB5YZB-7 …" / "YZBBPQ:KB5YZB-7}" — the
            // ALIAS:CALL pair names the node both ways.
            return firstMatchTokens(
                pattern: "([A-Z][A-Z0-9-]{1,8}):([A-Z0-9][A-Z0-9-]{1,8})", in: upper)
        case .kaNodeLinkBanner:
            // "###CONNECTED TO NODE DRLNOD(KE0NCQ) CHANNEL A" — the node's
            // name, with its callsign in parentheses when it prints one.
            return firstMatchTokens(
                pattern: "NODE ([A-Z0-9-]{2,9})(?:\\(([A-Z0-9-]{2,9})\\))?", in: upper)
        case .nodesBroadcast, .bpqMenu, .kaNodeMenu, .borrowedSsidDial:
            return nil
        }
    }

    private static func firstMatchTokens(pattern: String, in upper: String) -> Set<String>? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: upper, range: NSRange(upper.startIndex..., in: upper))
        else { return nil }
        var tokens: Set<String> = []
        for group in 1..<match.numberOfRanges {
            guard let range = Range(match.range(at: group), in: upper) else { continue }
            tokens.insert(String(upper[range]))
        }
        return tokens.isEmpty ? nil : tokens
    }
}

/// Everything observed about node software, with derived verdicts.
///
/// Verdicts recompute from evidence every time rather than being stored —
/// storing a conclusion invites it to outlive the rules that produced it.
nonisolated struct NodeCapabilityDirectory: Equatable, Sendable, Codable {

    struct Entry: Equatable, Sendable, Codable {
        var callsign: String
        /// Newest observation per kind. Bounded by the size of Kind, and
        /// replay-proof: re-seeing the same banner refreshes `observedAt`
        /// and nothing else — the verdict is derived, so re-counting cannot
        /// inflate anything (unlike the alias announcement counter, which
        /// needed a repair pass for exactly that).
        var observations: [NodeSoftwareObservation]
        var firstObserved: Date
        var lastObserved: Date
    }

    private(set) var entries: [String: Entry] = [:]

    init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    mutating func record(
        _ kind: NodeSoftwareObservation.Kind,
        callsign: String,
        sourceText: String,
        at time: Date
    ) {
        let key = CallsignValidator.normalize(callsign)
        guard !key.isEmpty else { return }
        let observation = NodeSoftwareObservation(
            kind: kind,
            observedAt: time,
            sourceText: String(sourceText.prefix(120))
        )
        if var entry = entries[key] {
            if let index = entry.observations.firstIndex(where: { $0.kind == kind }) {
                if time >= entry.observations[index].observedAt {
                    entry.observations[index] = observation
                }
            } else {
                entry.observations.append(observation)
            }
            entry.lastObserved = max(entry.lastObserved, time)
            entries[key] = entry
        } else {
            entries[key] = Entry(
                callsign: key,
                observations: [observation],
                firstObserved: time,
                lastObserved: time
            )
        }
    }

    private static let bpqKinds: Set<NodeSoftwareObservation.Kind> = [.bpqBanner, .bpqPrompt, .bpqMenu]
    private static let kaKinds: Set<NodeSoftwareObservation.Kind> = [.kaNodeMenu, .kaNodeLinkBanner]

    /// The verdict lattice, ground truth on top:
    /// - a NODES broadcast proves NET/ROM capability outright;
    /// - else BPQ fingerprints prove BPQ (which routes);
    /// - else KA fingerprints alone prove a KA-Node (which does not);
    /// - conflicting fingerprints without ground truth get no verdict —
    ///   refusing to guess is the point of keeping evidence.
    /// `.borrowedSsidDial` never decides anything by itself.
    func family(for callsign: String) -> NodeSoftwareFamily? {
        guard let entry = entries[CallsignValidator.normalize(callsign)] else { return nil }
        let own = CallsignValidator.normalize(entry.callsign)

        // An observation whose own words name a *different* station is not
        // evidence about this one, however it arrived — during a prompt
        // relay, downstream banners ride the link peer's frames. Field
        // capture 2026-08-28 18:39: KB5YZB-7's banner filed under DRLNOD
        // turned its verdict into a conflict and let a poisoned teller
        // claim through. Anonymous lines are kept.
        let observations = entry.observations.filter { obs in
            guard let named = NodeSoftwareClassifier.namedStations(in: obs) else { return true }
            return named.contains(own)
        }
        let kinds = Set(observations.map(\.kind))
        let hasBpq = !kinds.isDisjoint(with: Self.bpqKinds)
        let hasKa = !kinds.isDisjoint(with: Self.kaKinds)
        if kinds.contains(.nodesBroadcast) {
            return hasBpq ? .bpq : .netromOther
        }
        // Identity-bearing evidence outranks anonymous: a menu with no name
        // in it is exactly the line a relay can mis-attribute, while a
        // banner that names this station was necessarily spoken by it.
        let identityBpq = observations.contains {
            NodeSoftwareClassifier.namedStations(in: $0) != nil && Self.bpqKinds.contains($0.kind)
        }
        let identityKa = observations.contains {
            NodeSoftwareClassifier.namedStations(in: $0) != nil && Self.kaKinds.contains($0.kind)
        }
        if identityBpq != identityKa { return identityBpq ? .bpq : .kaNode }
        if hasBpq && hasKa { return nil }
        if hasBpq { return .bpq }
        if hasKa { return .kaNode }
        return nil
    }

    /// Can this station carry a NET/ROM circuit? Nil means "unknown", and
    /// callers gating harvested routes must treat unknown as no —
    /// second-hand routing knowledge needs positive proof of an anchor.
    func canRouteNetRom(_ callsign: String) -> Bool? {
        switch family(for: callsign) {
        case .bpq, .netromOther: return true
        case .kaNode: return false
        case nil: return nil
        }
    }

    /// Prose for tooltips: which line earned the verdict, quoted.
    func evidence(for callsign: String) -> String? {
        let key = CallsignValidator.normalize(callsign)
        guard let entry = entries[key] else { return nil }
        let byKind = Dictionary(uniqueKeysWithValues: entry.observations.map { ($0.kind, $0) })

        guard let verdict = family(for: callsign) else {
            let kinds = Set(entry.observations.map(\.kind))
            if !kinds.isDisjoint(with: Self.bpqKinds), !kinds.isDisjoint(with: Self.kaKinds) {
                return "Its output shows both BPQ and KA-Node fingerprints — no verdict until it sends something decisive (like a NODES broadcast)."
            }
            return nil
        }

        switch verdict {
        case .bpq:
            if byKind[.nodesBroadcast] != nil {
                return "It sent a NET/ROM routing broadcast and greets like BPQ. BPQ routes NET/ROM."
            }
            let quote = byKind[.bpqBanner] ?? byKind[.bpqMenu] ?? byKind[.bpqPrompt]
            if let quote {
                return "Its session output identified BPQ node software (\"\(quote.sourceText)\"). BPQ routes NET/ROM."
            }
            return "Its session output identified BPQ node software. BPQ routes NET/ROM."
        case .netromOther:
            return "It sent a NET/ROM routing broadcast (PID 0xCF to NODES). Only a NET/ROM stack does that."
        case .kaNode:
            let quote = byKind[.kaNodeMenu] ?? byKind[.kaNodeLinkBanner]
            if let quote {
                return "Its session output is a Kantronics KA-Node (\"\(quote.sourceText)\"). A KA-Node relays connections but cannot route NET/ROM."
            }
            return "Its session output is a Kantronics KA-Node. A KA-Node relays connections but cannot route NET/ROM."
        }
    }
}

/// Observable capability knowledge, fed by session lines and received
/// frames, persisted the same way NodeAliasStore is: `UserDefaults`,
/// because this is a handful of short strings per station and a database
/// migration would cost more than it is worth. The verdict is re-earnable
/// from the next session banner, so even a lost store costs one connect.
@MainActor
final class NodeCapabilityStore: ObservableObject {

    @Published private(set) var directory = NodeCapabilityDirectory()

    private let defaults: UserDefaults
    private let key = "station.nodeCapabilities"

    init(defaults: UserDefaults = AppEnvironment.defaults) {
        self.defaults = defaults
        load()
        loadBorrowedLegs()
    }

    private func load() {
        guard let data = defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode(
                [String: NodeCapabilityDirectory.Entry].self, from: data)
        else { return }
        directory = NodeCapabilityDirectory(entries: entries)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(directory.entries) else { return }
        defaults.set(data, forKey: key)
    }

    /// Learns from one connected-session transcript line. Cheap enough to
    /// call per line: the classifier answers nil for ordinary text without
    /// allocating.
    func ingest(line: String, peer: String, at time: Date = Date()) {
        guard let kind = NodeSoftwareClassifier.classify(line: line) else { return }
        var updated = directory
        updated.record(kind, callsign: peer, sourceText: line.trimmingCharacters(in: .whitespacesAndNewlines), at: time)
        guard updated != directory else { return }
        directory = updated
        save()
    }

    /// Learns ground truth from received frames: a PID 0xCF frame to NODES
    /// is a routing broadcast, and nothing but a NET/ROM stack sends one.
    /// Only that gate is checked — parsing the broadcast is the router's
    /// job, and capability needs only the fact that it happened.
    func ingest(packets: [Packet]) {
        var updated = directory
        for packet in packets {
            guard packet.pid == 0xCF,
                  packet.to?.call.uppercased() == "NODES",
                  let source = packet.from?.display else { continue }
            updated.record(
                .nodesBroadcast,
                callsign: source,
                sourceText: "NET/ROM routing broadcast (PID 0xCF to NODES)",
                at: packet.timestamp
            )
        }
        guard updated != directory else { return }
        directory = updated
        save()
    }

    func canRouteNetRom(_ callsign: String) -> Bool? {
        directory.canRouteNetRom(callsign)
    }

    // MARK: - Borrowed relay legs

    /// Which node each borrowed SSID belongs to: `"K0EPI-6" → "DRLNOD"`.
    ///
    /// When a node is asked to connect onward it dials as the *operator*,
    /// under a free SSID of their callsign — so the station list grows an
    /// entry that looks like a stranger transmitting under the operator's
    /// licence (field question 2026-08-28 18:53). RelayLegWitness identifies
    /// the borrower off the SABM; this map remembers it so the UI can say
    /// "that station is DRLNOD dialing out as you" for as long as the entry
    /// lingers in the sidebar.
    @Published private(set) var borrowedLegs: [String: String] = [:]

    private var legsKey: String { "station.borrowedRelayLegs" }

    /// A node was witnessed dialing `hop` under `leg`, an SSID of our own
    /// callsign. Records the corroborating `.borrowedSsidDial` observation
    /// on the node (never decisive by itself — a crossband arrangement can
    /// produce the same shape) and remembers the leg→node identity.
    func recordBorrowedLeg(_ leg: String, node: String, toward hop: String,
                           at time: Date = Date()) {
        var updated = directory
        updated.record(.borrowedSsidDial, callsign: node,
                       sourceText: "SABM as \(leg.uppercased()) toward \(hop.uppercased())",
                       at: time)
        if updated != directory {
            directory = updated
            save()
        }
        let legKey = leg.trimmingCharacters(in: .whitespaces).uppercased()
        let owner = CallsignValidator.normalize(node)
        guard !legKey.isEmpty, !owner.isEmpty, borrowedLegs[legKey] != owner else { return }
        borrowedLegs[legKey] = owner
        if let data = try? JSONEncoder().encode(borrowedLegs) {
            defaults.set(data, forKey: legsKey)
        }
    }

    /// The node this callsign is a dial-out leg of, or nil for any station
    /// never witnessed as one.
    func borrowedLegOwner(_ callsign: String) -> String? {
        borrowedLegs[callsign.trimmingCharacters(in: .whitespaces).uppercased()]
    }

    fileprivate func loadBorrowedLegs() {
        guard let data = defaults.data(forKey: legsKey),
              let legs = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        borrowedLegs = legs
    }
}

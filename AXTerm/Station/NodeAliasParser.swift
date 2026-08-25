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
        return nodeForm.isEmpty ? parseServiceList(text, source: source) : nodeForm
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
        return trimmed.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }
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
    }

    private(set) var entries: [String: Entry] = [:]

    init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    /// Records an announcement. Later announcements replace earlier ones
    /// for the same alias.
    mutating func record(_ announcement: NodeAliasParser.Announcement, at time: Date) {
        let key = announcement.alias.uppercased()
        let existing = entries[key]
        let sameClaim = existing?.callsign == announcement.callsign
        entries[key] = Entry(
            alias: key,
            callsign: announcement.callsign.uppercased(),
            service: announcement.service,
            heardAt: time,
            announcements: sameClaim ? (existing?.announcements ?? 0) + 1 : 1)
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

    private func load() {
        guard let data = defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode(
                [String: NodeAliasDirectory.Entry].self, from: data)
        else { return }
        directory = NodeAliasDirectory(entries: entries)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(directory.entries) else { return }
        defaults.set(data, forKey: key)
    }

    /// Learns from one frame. Cheap enough to call per packet.
    func ingest(text: String, source: String, at time: Date = Date()) {
        let found = NodeAliasParser.parse(text, source: source)
        guard !found.isEmpty else { return }
        var updated = directory
        for announcement in found {
            updated.record(announcement, at: time)
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

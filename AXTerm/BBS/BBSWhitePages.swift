//
//  BBSWhitePages.swift
//  AXTerm
//
//  Who a callsign belongs to: name, location, home BBS — and where each of
//  those facts came from.
//

import Foundation

/// One operator's directory entry.
///
/// White Pages is the oldest piece of shared infrastructure in packet radio and
/// the easiest to get wrong, because it mixes two very different kinds of fact:
/// what an operator *told* you, and what you *worked out* from their traffic.
/// A name is always the former. A home BBS is usually the latter, guessed from
/// a `@` in a message header.
///
/// Keeping them apart is the whole design. Every field carries its own source
/// and timestamp, self-reported always beats inferred, and the mailbox can
/// always say why it believes something — the same standard the routing
/// metrics are held to (CLAUDE.md §8, §11).
nonisolated struct WhitePagesEntry: Equatable, Sendable, Identifiable {

    /// How a field came to be known, weakest to strongest.
    enum Source: String, Equatable, Sendable, CaseIterable {
        /// Derived from traffic — a `@BBS` in a header, a path, a beacon.
        case observed
        /// Carried in a message this station handled.
        case fromMessage
        /// The licence record, via the callsign directory AXTerm already
        /// keeps. More reliable than anything inferred from traffic and less
        /// reliable than the operator: a licence carries a legal name and a
        /// mailing address, and people go by something shorter and transmit
        /// from somewhere else.
        case licenceRecord
        /// The operator typed it at the prompt. Nothing outranks this.
        case selfReported

        var rank: Int {
            switch self {
            case .observed: 0
            case .fromMessage: 1
            case .licenceRecord: 2
            case .selfReported: 3
            }
        }

        /// Shown beside the value, in words rather than a category name.
        var explanation: String {
            switch self {
            case .observed: "worked out from traffic"
            case .fromMessage: "taken from a message"
            case .licenceRecord: "from the licence record"
            case .selfReported: "told to this station"
            }
        }
    }

    /// A value and its provenance. Never stored as a bare string: a directory
    /// that cannot say where a fact came from cannot be corrected safely.
    struct Field: Equatable, Sendable {
        var value: String
        var source: Source
        var updatedAt: Date
    }

    /// Which fields an entry can hold. Named so the shell can take
    /// `N`/`NH`/`NQ`/`NZ` and the store can key rows without a column each.
    /// The four fields, and deliberately only four.
    ///
    /// This is the classic White Pages record every FBB mailbox has published
    /// for decades, and the reason to stop here is the medium. Packet is
    /// unencrypted broadcast: anything `I <call>` prints is heard by everyone
    /// in range with a receiver, logged by anyone who cares to, and cannot be
    /// taken back. A street address, a phone number or an email is a different
    /// class of thing from a town and a callsign — and a mailbox that offers
    /// to collect them is inviting people to put them on the air.
    ///
    /// A field that is never asked for cannot be leaked, so the answer is not
    /// to collect them carefully. It is not to collect them.
    enum Key: String, Equatable, Sendable, CaseIterable {
        case name
        case qth
        case homeBBS
        case zip

        /// The command that sets it, for help text and confirmations.
        var command: String {
            switch self {
            case .name: "N"
            case .qth: "NQ"
            case .homeBBS: "NH"
            case .zip: "NZ"
            }
        }

        var label: String {
            switch self {
            case .name: "Name"
            case .qth: "Location"
            case .homeBBS: "Home BBS"
            case .zip: "Postcode"
            }
        }

        /// Asked, in order, when a caller first arrives.
        static let registration: [Key] = [.name, .qth, .zip, .homeBBS]

        /// What the guided flow asks.
        var question: String {
            switch self {
            case .name: "Your name"
            case .qth: "Your town and state"
            case .zip: "Your postcode"
            case .homeBBS: "Your home BBS (if you have one)"
            }
        }
    }

    var callsign: String
    var fields: [Key: Field]

    var id: String { callsign }

    init(callsign: String, fields: [Key: Field] = [:]) {
        self.callsign = callsign.uppercased()
        self.fields = fields
    }

    func value(_ key: Key) -> String? { fields[key]?.value }

    var isEmpty: Bool { fields.isEmpty }

    /// The most recent moment anything here was learned.
    var lastUpdated: Date? { fields.values.map(\.updatedAt).max() }
}

extension WhitePagesEntry {

    /// Whether a newly learned field replaces what is already known.
    ///
    /// Deliberately **not** last-writer-wins. An operator who typed their name
    /// last year still knows it better than a guess made from a header this
    /// morning, and a directory that lets inference overwrite testimony
    /// degrades every time it is used.
    ///
    /// - Stronger source always wins.
    /// - Weaker source never wins, however recent.
    /// - Equal source: the newer value stands, because people move and rename.
    static func replaces(_ candidate: Field, existing: Field?) -> Bool {
        guard let existing else { return true }
        if candidate.source.rank != existing.source.rank {
            return candidate.source.rank > existing.source.rank
        }
        return candidate.updatedAt >= existing.updatedAt
    }

    /// Applies a learned field under the rule above, returning whether it
    /// changed anything.
    @discardableResult
    mutating func learn(_ key: Key, value: String, source: Source, at date: Date) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty value clears a field only when the operator says so
        // themselves; inference must never delete testimony by falling silent.
        guard !trimmed.isEmpty else {
            guard source == .selfReported, fields[key] != nil else { return false }
            fields[key] = nil
            return true
        }
        let candidate = Field(value: trimmed, source: source, updatedAt: date)
        guard Self.replaces(candidate, existing: fields[key]) else { return false }
        fields[key] = candidate
        return true
    }

    /// One line per known field, for the `I CALL` reply.
    ///
    /// Provenance is shown, not hidden: a caller reading their own entry should
    /// be able to see that the home BBS was guessed and correct it.
    func report() -> [String] {
        guard !isEmpty else { return ["Nothing on file for \(callsign)."] }
        var lines = ["White pages: \(callsign)"]
        for key in Key.allCases {
            guard let field = fields[key] else { continue }
            let marker = field.source == .selfReported ? "" : "  (\(field.source.explanation))"
            lines.append("  \(key.label): \(field.value)\(marker)")
        }
        return lines
    }
}

extension WhitePagesEntry {

    /// What a licence record can contribute to a directory entry.
    ///
    /// Only the two fields a licence actually answers. A home BBS is a packet
    /// fact and a postcode is a mailing detail the operator may not want on
    /// the air, so neither is taken from here — filling a field with something
    /// weakly related is how a directory stops being worth reading.
    static func fields(from record: CallsignRecord) -> [(Key, String)] {
        var fields: [(Key, String)] = []

        if let name = record.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            fields.append((.name, name))
        }

        // "Denver, CO" rather than either half alone: a locality with no state
        // is ambiguous across the country, and a state alone says nothing a
        // callsign prefix did not.
        let locality = record.locality?.trimmingCharacters(in: .whitespaces) ?? ""
        let state = record.state?.trimmingCharacters(in: .whitespaces) ?? ""
        let qth = [locality, state].filter { !$0.isEmpty }.joined(separator: ", ")
        if !qth.isEmpty { fields.append((.qth, qth)) }

        return fields
    }

    /// Merges a licence record under the usual rule — so anything the operator
    /// has told us survives, and anything guessed from traffic is improved.
    @discardableResult
    mutating func learn(from record: CallsignRecord, at date: Date) -> Bool {
        var changed = false
        for (key, value) in Self.fields(from: record) {
            if learn(key, value: value, source: .licenceRecord, at: date) { changed = true }
        }
        return changed
    }
}

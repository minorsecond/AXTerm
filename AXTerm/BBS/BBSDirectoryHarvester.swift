//
//  BBSDirectoryHarvester.swift
//  AXTerm
//
//  Recognising white pages facts in another station's output.
//

import Foundation

/// Pulls directory facts out of a BBS session the operator is already having.
///
/// The distinction that makes this reasonable: nothing here *asks* another
/// system for anything. Querying a neighbouring BBS to harvest its database
/// would spend their channel on our convenience. Reading structure out of
/// bytes that arrived because the operator went there themselves costs nobody
/// anything, and throwing that away is just waste.
///
/// Everything found is recorded as `observed` — the weakest provenance —
/// because it is a guess about another system's display format, and it is
/// offered to the operator rather than applied. A parser that silently filled
/// a directory from pattern matches would be a way to quietly poison it.
nonisolated struct BBSDirectoryHarvester {

    /// One fact, with enough context for the operator to judge it.
    struct Candidate: Equatable, Sendable, Identifiable {
        var callsign: String
        var key: WhitePagesEntry.Key
        var value: String
        /// The line it came from, shown when offering it. An operator deciding
        /// whether to trust a parse needs to see what was parsed.
        var evidence: String

        var id: String { "\(callsign)|\(key.rawValue)|\(value)" }
    }

    /// Labels seen in the wild for each field, lowercased and stripped of
    /// punctuation. Deliberately short: a synonym list that guesses widely is
    /// how a "phone" column becomes somebody's name.
    private static let labels: [(WhitePagesEntry.Key, Set<String>)] = [
        (.name, ["name"]),
        (.qth, ["qth", "location", "city", "town"]),
        (.zip, ["zip", "zipcode", "postcode", "postalcode"]),
        (.homeBBS, ["homebbs", "home", "bbs"])
    ]

    /// Scans a stretch of a session for facts.
    ///
    /// Two shapes only, both unambiguous without knowing the software's column
    /// layout:
    ///
    /// 1. **`CALL @ BBS`** — the FBB convention for "this operator's home BBS",
    ///    appearing in list output, message headers and send prompts. Adjacency
    ///    is the whole signal, so no column positions are assumed.
    /// 2. **`Label: value`** under a subject callsign — what a white pages
    ///    reply looks like on most systems, and what AXTerm's own `I` prints.
    ///
    /// Anything else is left alone. A parser that tries to understand every
    /// BBS's output will be wrong somewhere, and wrong here means a false fact
    /// about a real person.
    static func candidates(in lines: [String]) -> [Candidate] {
        var found: [Candidate] = []
        var subject: String?

        for line in lines {
            found.append(contentsOf: homeBBSMentions(in: line))
            found.append(contentsOf: hierarchicalRecord(in: line))

            if let callsign = subjectCallsign(in: line) {
                subject = callsign
                continue
            }
            if let subject, let candidate = labelled(line, for: subject) {
                found.append(candidate)
            }
        }

        // Same fact seen twice in one session is one fact.
        var seen = Set<String>()
        return found.filter { seen.insert($0.id).inserted }
    }

    // MARK: - CALL @ BBS

    private static func homeBBSMentions(in line: String) -> [Candidate] {
        // Normalised so "K0EPI @ K0NTS", "K0EPI @K0NTS" and "K0EPI@K0NTS" are
        // one case rather than three.
        let tokens = line
            .replacingOccurrences(of: "@", with: " @ ")
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)

        var found: [Candidate] = []
        for (index, token) in tokens.enumerated() where token == "@" {
            guard index > 0, index + 1 < tokens.count else { continue }
            let who = clean(tokens[index - 1])
            let bbs = clean(tokens[index + 1])
            // The right-hand side is a bare callsign on a small network and a
            // hierarchical address on a real one — `K0NTS.#NCO.CO.USA.NOAM`.
            // Both mean the same field.
            let home = isCallsign(bbs) ? bbs : hierarchicalAddress(bbs)
            guard let home, isCallsign(who), who != home else { continue }
            found.append(Candidate(
                callsign: BBSMessage.baseCall(who),
                key: .homeBBS,
                value: home,
                evidence: line.trimmingCharacters(in: .whitespaces)))
        }
        return found
    }

    // MARK: - Hierarchical addresses

    /// The `I <call>` reply on FBB and BPQ: a callsign, then its hierarchical
    /// address.
    ///
    ///     KB5YZB  KB5YZB.#NCO.CO.USA.NOAM
    ///
    /// This *is* the home BBS field on a real network — it is what you put
    /// after the `@` to route mail to somebody — so it goes there whole rather
    /// than being taken apart. Splitting out "CO" would trade the useful string
    /// for a worse one.
    private static func hierarchicalRecord(in line: String) -> [Candidate] {
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard tokens.count >= 2 else { return [] }

        let subject = clean(tokens[0])
        guard isCallsign(subject) else { return [] }

        for token in tokens.dropFirst() {
            guard let address = hierarchicalAddress(token) else { continue }
            return [Candidate(callsign: BBSMessage.baseCall(subject),
                              key: .homeBBS,
                              value: address,
                              evidence: line.trimmingCharacters(in: .whitespaces))]
        }
        return []
    }

    /// `CALL.#REGION.STATE.COUNTRY.CONTINENT`, with the region optional and
    /// shorter forms allowed — networks differ on how many levels they use.
    ///
    /// Anchored on the first component being a callsign, which is what keeps a
    /// domain name or a sentence with a full stop in it from qualifying.
    static func hierarchicalAddress(_ token: String) -> String? {
        let value = clean(token)
        guard value.contains(".") else { return nil }

        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...6).contains(parts.count) else { return nil }
        guard isCallsign(String(parts[0])) else { return nil }

        for part in parts.dropFirst() {
            // `#NCO` is a regional designator; everything else is a plain
            // state, country or continent code.
            let body = part.hasPrefix("#") ? String(part.dropFirst()) : String(part)
            guard (1...8).contains(body.count),
                  body.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        }
        return value
    }

    // MARK: - Labelled records

    /// A line that names whose record follows.
    ///
    /// Either AXTerm's own header, or a line that is nothing but a callsign —
    /// which is how most systems introduce a record.
    private static func subjectCallsign(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if let colon = trimmed.firstIndex(of: ":") {
            let head = trimmed[trimmed.startIndex..<colon]
                .trimmingCharacters(in: .whitespaces).lowercased()
            if head.contains("white pages") || head == "callsign" || head == "call" {
                let tail = clean(String(trimmed[trimmed.index(after: colon)...]))
                return isCallsign(tail) ? BBSMessage.baseCall(tail) : nil
            }
        }

        let bare = clean(trimmed)
        guard !bare.contains(" "), isCallsign(bare) else { return nil }
        return BBSMessage.baseCall(bare)
    }

    private static func labelled(_ line: String, for subject: String) -> Candidate? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let rawLabel = line[line.startIndex..<colon]
        let value = String(line[line.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value.count <= 64 else { return nil }

        let label = rawLabel.lowercased().filter { $0.isLetter }
        guard let key = labels.first(where: { $0.1.contains(label) })?.0 else { return nil }

        // A home BBS is a callsign; anything else in that field is a parse gone
        // wrong, and one wrong fact is worse than the several it came with.
        if key == .homeBBS && !isCallsign(clean(value)) { return nil }

        return Candidate(callsign: subject, key: key, value: value,
                         evidence: line.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Recognising a callsign

    private static func clean(_ token: String) -> String {
        token.trimmingCharacters(in: CharacterSet(charactersIn: " \t.,;()[]<>\"'"))
            .uppercased()
    }

    /// Conservative on purpose: a token that merely looks wordlike must not
    /// become a callsign, because every fact here is about a real person.
    static func isCallsign(_ token: String) -> Bool {
        let value = token.uppercased()
        guard value.count >= 3, value.count <= 9 else { return false }
        let base = value.split(separator: "-").first.map(String.init) ?? value
        guard base.count >= 3, base.count <= 6 else { return false }
        guard base.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
        // Every amateur callsign has at least one digit and ends in letters.
        guard base.contains(where: \.isNumber), base.contains(where: \.isLetter) else {
            return false
        }
        guard base.last?.isLetter == true else { return false }
        if value.contains("-") {
            let parts = value.split(separator: "-")
            guard parts.count == 2, let ssid = Int(parts[1]), (0...15).contains(ssid) else {
                return false
            }
        }
        return true
    }
}

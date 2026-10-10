import Foundation

/// How a decoded APRS line is drawn in the terminal.
///
/// A busy APRS channel fills the console with beacons, and each one used to
/// spell out everything: the AX.25 destination, the raw coordinates, a branch
/// icon for the path, a list of digipeaters, the radio. Most of that is noise
/// on most lines. The destination of a Mic-E frame is position data, not an
/// address, and the coordinates repeat what "52.1 mi S" already says. These
/// rules decide what earns a place on the row. Everything left off stays in
/// the row's tooltip, so nothing is lost.
///
/// Only decoded APRS lines change. A connected-mode session line is drawn as
/// it always was.
nonisolated enum ConsoleAPRSPresentation {

    /// Whether the row prints the AX.25 destination.
    ///
    /// Not on a decoded line. APRS puts no address there: it is the sending
    /// software's name (`APMI06`), or for Mic-E the latitude itself
    /// (`S8UQVU`). A message's addressee is in its text, and the line says
    /// "To K0EPI-2" already.
    static func showsDestination(_ line: ConsoleLine, rawAPRS: Bool) -> Bool {
        line.aprs == nil || rawAPRS
    }

    /// The one chip that says how a frame reached us.
    enum PathChip: Equatable, Sendable {
        /// Nothing to say: our own transmission, or not an APRS line.
        case none
        /// We heard the sender's own transmitter. `requested` is the path it
        /// asked for, which nobody had used yet when we heard it.
        case direct(requested: [String])
        /// We heard a digipeater's transmitter. `station` is the last one that
        /// repeated it, `hops` how many stations repeated it in all.
        case heardVia(station: String, hops: Int, path: [String])
    }

    static func pathChip(for line: ConsoleLine, ownCallsigns: Set<String>) -> PathChip {
        guard line.aprs != nil, let from = line.from else { return .none }
        let sender = CallsignValidator.normalize(from)
        let repeated = line.repeatedDigis
        let unused = line.via.filter { !$0.hasSuffix("*") }

        if repeated.isEmpty {
            // Our own transmission says nothing about how it was heard.
            let ours = Set(ownCallsigns.map(CallsignValidator.normalize))
            return ours.contains(sender) ? .none : .direct(requested: line.via)
        }

        // The stations that put it on the air again, leaving out the routing
        // aliases they marked used and the sender itself.
        let stations = repeated.filter {
            !isGenericAlias($0) && CallsignValidator.normalize($0) != sender
        }
        guard let heard = stations.last else {
            // Every used entry was the sender or an alias. An RF alias alone
            // (`WIDE2*` from a digi that does not insert its call) still means
            // a digipeater. `TCPIP*` and the like mark the internet leg, not
            // a transmitter, so with only those the sender was heard direct.
            if let alias = repeated.last(where: isRFAlias) {
                return .heardVia(station: alias, hops: 1, path: line.via)
            }
            return .direct(requested: unused)
        }
        return .heardVia(station: heard, hops: stations.count, path: line.via)
    }

    /// Where any of `bases` appears in `text` as a whole callsign, with or
    /// without an SSID, for highlighting our own calls inside a message.
    static func callsignRanges(in text: String, bases: Set<String>) -> [Range<String.Index>] {
        guard !bases.isEmpty else { return [] }
        func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "-" }
        var ranges: [Range<String.Index>] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard isWordCharacter(text[index]) else {
                index = text.index(after: index)
                continue
            }
            var end = index
            while end < text.endIndex, isWordCharacter(text[end]) { end = text.index(after: end) }
            let word = text[index..<end].uppercased()
            let base = word.split(separator: "-").first.map(String.init) ?? word
            if bases.contains(base) { ranges.append(index..<end) }
            index = end
        }
        return ranges
    }

    /// An alias a digipeater answers to on the air.
    private static func isRFAlias(_ entry: String) -> Bool {
        guard isGenericAlias(entry) else { return false }
        let base = entry.uppercased()
        return base.hasPrefix("WIDE") || base.hasPrefix("TRACE") || base.hasPrefix("RELAY")
    }

    /// A path entry that names a routing rule rather than a station:
    /// `WIDE2`, `TRACE1`, `TCPIP`, a `qAR` construct. A digipeater marks these
    /// used, but they do not say whose transmitter was heard.
    static func isGenericAlias(_ entry: String) -> Bool {
        var text = entry.uppercased()
        while text.hasSuffix("*") { text.removeLast() }
        let base = text.split(separator: "-").first.map(String.init) ?? text
        if ["RELAY", "TCPIP", "TCPXX", "NOGATE", "RFONLY", "ECHO", "GATE"].contains(base) { return true }
        // q constructs: qAR, qAC, qAS and the rest added by APRS-IS.
        if base.count == 3, base.hasPrefix("QA") { return true }
        for prefix in ["WIDE", "TRACE"] where base.hasPrefix(prefix) {
            if base.dropFirst(prefix.count).allSatisfy(\.isNumber) { return true }
        }
        return false
    }
}

/// The per-line radio tag, which appears only when the console holds lines
/// from more than one radio.
nonisolated enum ConsoleRadioTags {
    struct Tag: Equatable, Sendable {
        let name: String
        /// Index into the tag palette. Fixed by the radio's place among all
        /// named radios, so a radio keeps its color when another goes quiet.
        let colorIndex: Int
    }

    static func tags(radioNames: [RadioID: String], heard: Set<RadioID>) -> [RadioID: Tag] {
        let present = radioNames.keys.filter(heard.contains)
        guard present.count >= 2 else { return [:] }
        let ordered = radioNames.keys.sorted(by: RadioID.deterministicOrder)
        var tags: [RadioID: Tag] = [:]
        for id in present {
            guard let name = radioNames[id], let index = ordered.firstIndex(of: id) else { continue }
            tags[id] = Tag(name: name, colorIndex: index)
        }
        return tags
    }
}

/// Whether a row's message fits beside its time and callsigns, or drops to a
/// second row under them where it gets the full width.
nonisolated enum ConsoleRowArrangement: Equatable, Sendable {
    case singleRow
    case messageBelow

    static func choose(leadingWidth: CGFloat, messageWidth: CGFloat,
                       available: CGFloat, spacing: CGFloat) -> ConsoleRowArrangement {
        leadingWidth + spacing + messageWidth <= available ? .singleRow : .messageBelow
    }
}

/// How a line involves this station, strongest first.
nonisolated enum ConsoleMineHighlight: Equatable, Sendable {
    case none
    /// Someone else's frame with one of our callsigns in its text.
    case mentionsYou
    /// Someone else's frame that our digipeater repeated.
    case relayedByYou
    /// Sent by one of our callsigns, heard directly or as we transmitted it.
    case fromYou
    /// Our own frame, heard back off a digipeater.
    case yourFrameRepeated(by: String)
    /// An APRS message, ack, reject or query addressed to one of our callsigns.
    case toYou

    ///
    /// Matched on the base callsign, like the MINE filter: K0EPI-2 on the Mac
    /// and K0EPI-3 on the phone are the same operator. Only decoded APRS
    /// lines: in a connected session every line is to you, and tinting the
    /// whole transcript would say nothing.
    static func of(_ line: ConsoleLine, myCallsign: String, ownCallsigns: Set<String>) -> ConsoleMineHighlight {
        guard let digest = line.aprs, let from = line.from else { return .none }
        let mine = Set(([myCallsign] + Array(ownCallsigns)).map(baseCallsign).filter { !$0.isEmpty })
        guard !mine.isEmpty else { return .none }

        if mine.contains(baseCallsign(from)) {
            if case .heardVia(let digi, _, _) = ConsoleAPRSPresentation.pathChip(for: line, ownCallsigns: []) {
                return .yourFrameRepeated(by: digi)
            }
            return .fromYou
        }
        if let addressee = addressee(of: digest), mine.contains(baseCallsign(addressee)) {
            return .toYou
        }
        if line.repeatedDigis.contains(where: { mine.contains(baseCallsign($0)) }) {
            return .relayedByYou
        }
        let words = line.text.uppercased().split { !($0.isLetter || $0.isNumber || $0 == "-") }
        if words.contains(where: { mine.contains(baseCallsign(String($0))) }) {
            return .mentionsYou
        }
        return .none
    }

    private static func addressee(of digest: APRSDigest) -> String? {
        switch digest {
        case .relayed(_, let inner):
            return addressee(of: inner)
        case .message(let inbound):
            switch inbound {
            case .message(let addressee, _, _), .ack(let addressee, _),
                 .reject(let addressee, _), .directedQuery(let addressee, _, _):
                return addressee
            case .bulletin, .generalQuery:
                return nil
            }
        default:
            return nil
        }
    }

    private static func baseCallsign(_ address: String) -> String {
        var text = address.trimmingCharacters(in: .whitespaces).uppercased()
        while text.hasSuffix("*") { text.removeLast() }
        return String(text.split(separator: "-").first ?? "")
    }
}

/// A beacon that says exactly what the same station's previous one said.
nonisolated struct BeaconRepeat: Equatable, Sendable {
    /// 2 for the first repeat, 3 for the next, and so on.
    let ordinal: Int
    /// When the station first sent this content in the current run.
    let since: Date
}

/// Finds repeat beacons, remembering each line's signature so a rebuild does
/// not format every line in the history again.
final class BeaconRepeatIndex {
    private var signatures: [UUID: String] = [:]

    /// What a line says, for comparison with the same station's last line.
    /// Nil for lines that never count as repeats.
    ///
    /// The decoded words, not the bytes: a position with a timestamp in it
    /// changes every time while saying the same thing. Messages are left
    /// out, because a message sent again is a retry worth seeing, and so is
    /// telemetry, whose sequence number changes every frame anyway.
    static func signature(of line: ConsoleLine) -> String? {
        guard let digest = line.aprs, let from = line.from else { return nil }
        switch digest {
        case .message, .telemetry:
            return nil
        case .relayed(_, let inner):
            if case .message = inner { return nil }
            if case .telemetry = inner { return nil }
        case .position, .weather, .object, .status:
            break
        }
        return from.uppercased() + "|" + APRSDigestLine.text(for: digest)
    }

    /// Copies closer together than this are one transmission heard twice,
    /// direct and off a digipeater or off two digipeaters. The same window
    /// APRS digipeaters use to drop duplicates.
    static let duplicateWindow: TimeInterval = 30

    func repeats(in groups: [ConsoleLineGroup]) -> [UUID: BeaconRepeat] {
        var known: [UUID: String] = [:]
        var last: [String: (signature: String, ordinal: Int, since: Date, heard: Date)] = [:]
        var repeats: [UUID: BeaconRepeat] = [:]

        for group in groups {
            let line = group.primary
            let signature: String?
            if let cached = signatures[line.id] {
                signature = cached
            } else {
                signature = Self.signature(of: line)
            }
            guard let signature, let from = line.from?.uppercased() else { continue }
            known[line.id] = signature

            if let previous = last[from], previous.signature == signature {
                if line.timestamp.timeIntervalSince(previous.heard) < Self.duplicateWindow {
                    // Another copy of the transmission just counted.
                    if previous.ordinal > 1 {
                        repeats[group.id] = BeaconRepeat(ordinal: previous.ordinal, since: previous.since)
                    }
                    continue
                }
                let ordinal = previous.ordinal + 1
                repeats[group.id] = BeaconRepeat(ordinal: ordinal, since: previous.since)
                last[from] = (signature, ordinal, previous.since, line.timestamp)
            } else {
                last[from] = (signature, 1, line.timestamp, line.timestamp)
            }
        }
        // Only what is still in the console, so the cache cannot outgrow it.
        signatures = known
        return repeats
    }
}

/// What arrived while the reader was scrolled up.
nonisolated enum ConsoleUnseen {
    struct Count: Equatable, Sendable {
        var total = 0
        var forYou = 0
    }

    ///
    /// By time rather than by row: the console trims its oldest lines when
    /// it is full, and the last row seen may be gone by the time the reader
    /// comes back.
    static func count(_ groups: [ConsoleLineGroup], after lastSeen: Date?,
                      isForYou: (ConsoleLine) -> Bool) -> Count {
        guard let lastSeen else { return Count() }
        var count = Count()
        // Newest last, so walk back until the reader's place.
        for group in groups.reversed() {
            guard group.primary.timestamp > lastSeen else { break }
            count.total += 1
            if isForYou(group.primary) { count.forYou += 1 }
        }
        return count
    }
}

import Foundation

/// Everything a console row needs to know that does not depend on how it is
/// drawn.
///
/// The Mac draws the console with an AppKit table and the iPhone and iPad
/// with SwiftUI. Both read their links, highlights, chips and tooltips from
/// here, so the two cannot drift apart.
struct ConsoleRowEnvironment {
    var fontSize: Double = 11
    /// The base call for "mine", which matches every SSID of it.
    var localCallsign: String = ""
    /// Every address this station's radios transmit as.
    var ownCallsigns: Set<String> = []
    /// Whether a tapped callsign goes anywhere. Without it callsigns stay text.
    var linksCallsigns = false
    var linksFileNames = false
    var knownFileNames: Set<String> = []
    var radioTags: [RadioID: ConsoleRadioTags.Tag] = [:]
    var observer: GreatCircle.Point?
    var distanceInMiles = true
    var showsRawAPRS = false
    var heardCallsigns: Set<String> = []
    var telemetryDefinitions: [String: APRSTelemetry.Definition] = [:]
    /// The message going out, dimmed where it is not acknowledged yet.
    var outgoing: ConsoleOutgoingProgress?

    /// The addresses whose digipeated copies are our own echo.
    var echoCallsigns: Set<String> {
        ownCallsigns.isEmpty ? [localCallsign] : ownCallsigns
    }

    /// Our base callsigns, for picking them out inside a message.
    var mineBases: Set<String> {
        Set(([localCallsign] + Array(ownCallsigns)).compactMap { address -> String? in
            let base = address.uppercased().split(separator: "-").first.map(String.init) ?? ""
            return base.isEmpty ? nil : base
        })
    }

    /// A fingerprint of everything here that can change how a row reads.
    var version: Int {
        var hasher = Hasher()
        hasher.combine(layoutVersion)
        hasher.combine(decorationVersion)
        return hasher.finalize()
    }

    /// What can only restyle a row's text: which words are links. A change
    /// here redraws the rows on screen and leaves every height alone.
    var decorationVersion: Int {
        var hasher = Hasher()
        hasher.combine(outgoing)
        hasher.combine(linksCallsigns)
        hasher.combine(linksFileNames)
        hasher.combine(knownFileNames.count)
        hasher.combine(heardCallsigns.count)
        return hasher.finalize()
    }

    /// What can change what a row says or how big it is: the text size, the
    /// chips (our callsigns, the radio tags), the decoded sentence.
    var layoutVersion: Int {
        var hasher = Hasher()
        hasher.combine(fontSize)
        hasher.combine(localCallsign)
        hasher.combine(ownCallsigns.sorted())
        hasher.combine(radioTags.count)
        for (id, tag) in radioTags.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            hasher.combine(id.rawValue)
            hasher.combine(tag.name)
            hasher.combine(tag.colorIndex)
        }
        hasher.combine(observer?.latitude)
        hasher.combine(observer?.longitude)
        hasher.combine(distanceInMiles)
        hasher.combine(showsRawAPRS)
        hasher.combine(telemetryDefinitions.count)
        return hasher.finalize()
    }
}

/// What one line says and how it involves us, worked out once.
struct ConsoleLineFacts {
    let line: ConsoleLine
    let environment: ConsoleRowEnvironment
    /// Every path the line's copies were heard by.
    let allViaPaths: [[String]]
    let duplicateCount: Int

    init(line: ConsoleLine, environment: ConsoleRowEnvironment,
         allViaPaths: [[String]] = [], duplicateCount: Int = 0) {
        self.line = line
        self.environment = environment
        self.allViaPaths = allViaPaths
        self.duplicateCount = duplicateCount
    }

    /// Decoded APRS, drawn by the shorter rules in `ConsoleAPRSPresentation`.
    var isDecodedAPRS: Bool { line.aprs != nil && !environment.showsRawAPRS }

    /// A digipeated copy of our own frame.
    var isDigipeatEcho: Bool {
        line.isDigipeatEcho(localCallsigns: environment.echoCallsigns)
    }

    var mine: ConsoleMineHighlight {
        guard isDecodedAPRS else { return .none }
        return ConsoleMineHighlight.of(line, myCallsign: environment.localCallsign,
                                       ownCallsigns: environment.ownCallsigns)
    }

    var pathChip: ConsoleAPRSPresentation.PathChip {
        ConsoleAPRSPresentation.pathChip(for: line, ownCallsigns: environment.echoCallsigns)
    }

    var repeatAttribution: ConsoleLine.RepeatAttribution? {
        line.repeatAttribution(localCallsigns: environment.echoCallsigns)
    }

    func repeatHelp(_ attribution: ConsoleLine.RepeatAttribution) -> String {
        let digis = attribution.digis.joined(separator: ", ")
        switch attribution {
        case .ourFrameEchoed:
            return "Our own frame, repeated back by \(digis)."
        case .heardVia:
            // This copy came off the digi's transmitter, so it says nothing
            // about whether the originating station is audible here.
            return "Heard as \(digis)'s retransmission, not from "
                 + "\(line.from ?? "the sender") directly."
        }
    }

    /// Every path this frame was heard by, one per line.
    var pathLines: String {
        let paths = allViaPaths.isEmpty ? (line.via.isEmpty ? [] : [line.via]) : allViaPaths
        if paths.isEmpty { return "" }
        if paths.count == 1 { return "via " + paths[0].joined(separator: " \u{2192} ") }
        return paths.enumerated().map { index, path in
            "Path \(index + 1): " + path.joined(separator: " \u{2192} ")
        }.joined(separator: "\n")
    }

    /// The tooltip for the old path icon on non-APRS lines.
    var digiPathTooltip: String {
        let paths = allViaPaths.isEmpty ? [line.via] : allViaPaths
        if paths.count == 1 { return "via " + paths[0].joined(separator: " \u{2192} ") }
        return paths.enumerated().map { index, path in
            "Path \(index + 1): " + path.joined(separator: " \u{2192} ")
        }.joined(separator: "\n")
    }

    /// The path chip's words and tooltip, or nil when it has nothing to say.
    var pathChipText: (text: String, help: String, heardVia: Bool)? {
        let sender = line.from ?? "the sender"
        switch pathChip {
        case .none:
            return nil
        case .direct(let requested):
            let help = "Heard directly from \(sender)'s own transmitter."
                + (requested.isEmpty ? "" : "\nPath requested: \(requested.joined(separator: ","))")
                + (duplicateCount > 0 ? "\n" + pathLines : "")
            return ("direct", help, false)
        case .heardVia(let station, let hops, _):
            let help = "Heard from \(station)'s transmitter, not \(sender)'s directly."
                + (hops > 1 ? " \(hops) stations repeated it." : "") + "\n" + pathLines
            return (hops > 1 ? "\(station) \u{00B7} \(hops) hops" : station, help, true)
        }
    }

    /// The sending station's telemetry definition, if it has sent one.
    var telemetryDefinition: APRSTelemetry.Definition? {
        guard let from = line.from else { return nil }
        // A relayed frame's telemetry is its source's, not the gateway's.
        let owner = line.aprs?.originator(heardFrom: from) ?? from
        return environment.telemetryDefinitions[CallsignValidator.normalize(owner)]
    }

    /// The decoded sentence for an APRS line, or the text as sent.
    var messageText: String {
        guard isDecodedAPRS, let digest = line.aprs else { return line.text }
        return APRSDigestLine.text(for: digest, observer: environment.observer,
                                   inMiles: environment.distanceInMiles,
                                   definition: telemetryDefinition, coordinates: .whenNoDistance)
    }

    /// What `messageText` depends on beyond the line itself, for caching it.
    var messageTextVersion: Int {
        var hasher = Hasher()
        hasher.combine(isDecodedAPRS)
        hasher.combine(environment.observer?.latitude)
        hasher.combine(environment.observer?.longitude)
        hasher.combine(environment.distanceInMiles)
        hasher.combine(telemetryDefinition.map { String(describing: $0) })
        return hasher.finalize()
    }

    /// Everything in the text worth making clickable: web and email
    /// addresses, which go to the system, and callsigns and file names,
    /// which stay in the app.
    func linkTargets(in text: String, fileNameIndex: FileNameIndex?) -> [(range: Range<String.Index>, url: URL)] {
        var targets = CallsignScanner.webLinks(in: text)
        if environment.linksCallsigns {
            for hit in CallsignScanner.links(in: text, heard: environment.heardCallsigns) {
                guard let url = ConsoleCallsignLink.url(for: hit.callsign) else { continue }
                targets.append((hit.range, url))
            }
        }
        // Only in what another station sent: our own `D` line needs no link.
        if environment.linksFileNames, line.kind == .packet, let from = line.from,
           !environment.echoCallsigns.contains(from.uppercased()) {
            let hits = fileNameIndex?.names(in: text, known: environment.knownFileNames)
                ?? FileNameScanner.names(in: text, known: environment.knownFileNames)
            for hit in hits
            where !targets.contains(where: { $0.range.overlaps(hit.range) }) {
                guard let url = ConsoleFileLink.url(for: hit.name) else { continue }
                targets.append((hit.range, url))
            }
        }
        return targets
    }

    /// Our own callsigns inside the text, on decoded lines.
    func mentions(in text: String) -> [Range<String.Index>] {
        isDecodedAPRS ? ConsoleAPRSPresentation.callsignRanges(in: text, bases: environment.mineBases) : []
    }

    /// What arrived byte for byte, for a decoded line's tooltip, after the
    /// destination, path and coordinates the shorter row left off.
    var rawHelp: String {
        guard let info = line.aprsInfo else { return line.text }
        var lead: [String] = []
        if let to = line.to {
            lead.append("To \(to)" + (line.via.isEmpty ? "" : " via \(line.viaDisplay)"))
        }
        if let digest = line.aprs, let place = APRSDigestLine.coordinates(of: digest) {
            lead.append("Position \(place)")
        }
        // Printable characters as themselves and everything else as hex: the
        // bytes that matter most in a Mic-E frame are the ones that are not
        // text.
        let body = info.map { byte -> String in
            (byte >= 0x20 && byte < 0x7F)
                ? String(UnicodeScalar(byte))
                : String(format: "<%02X>", byte)
        }.joined()
        let raw = "As received (\(info.count) bytes):\n\(body)"
        return lead.isEmpty ? raw : lead.joined(separator: "\n") + "\n\n" + raw
    }

    /// What class of line this is, which sets the color of its left edge.
    enum Category: Equatable {
        case error, system, id, beacon, mail, data, prompt, other
    }

    var category: Category {
        switch line.kind {
        case .error: return .error
        case .system: return .system
        case .packet:
            switch line.messageType {
            case .id: return .id
            case .beacon: return .beacon
            case .mail: return .mail
            case .data: return .data
            case .prompt: return .prompt
            case .message, nil: return .other
            }
        }
    }

    var categoryTooltip: String {
        switch category {
        case .error: return "Error: An error or warning message"
        case .system: return "System: Connection status or application notification"
        case .id: return "ID: Station identification broadcast"
        case .beacon: return "Beacon: Periodic status broadcast"
        case .mail: return "Mail: Message notification"
        case .data: return "Data: Content being transferred"
        case .prompt: return "Command: Session control or prompt"
        case .other: return "Other: Unclassified packet"
        }
    }

    /// Whether the message steps back to the secondary color: system and
    /// error lines always, and a repeat beacon so what changed stands out.
    func messageIsSecondary(beaconRepeat: BeaconRepeat?) -> Bool {
        switch line.kind {
        case .system, .error: return true
        case .packet: return beaconRepeat != nil && isDecodedAPRS
        }
    }

    /// The hue a callsign is drawn in, so the same station keeps one color.
    static func callsignHue(_ callsign: String) -> Double {
        Double(abs(callsign.hashValue) % 256) / 255.0
    }
}

/// How much of the message we are sending has been acknowledged, drawn on
/// its own line in the history (retest 2026-10-10, finding 9): the
/// acknowledged part in full color, the rest dimmed from `dimFrom`, a UTF-16
/// offset into the line's text.
nonisolated struct ConsoleOutgoingProgress: Equatable, Hashable {
    let lineID: UUID
    let dimFrom: Int

    /// Where the dimmed part starts, or nil when nothing is left to dim.
    /// Plain text dims what is not acknowledged yet, cut between
    /// characters. An AXDP message dims the whole line: the other station
    /// sees it only when it has all arrived.
    static func dimFrom(text: String, ackedBytes: Int, viaAXDP: Bool) -> Int? {
        if viaAXDP { return 0 }
        guard ackedBytes < text.utf8.count else { return nil }
        var bytes = 0
        var offset = 0
        for character in text {
            let size = character.utf8.count
            if bytes + size > ackedBytes { break }
            bytes += size
            offset += character.utf16.count
        }
        return offset
    }

    /// The line of the message: the newest one we sent to `to` with its
    /// text.
    static func lineID(in lines: [ConsoleLine], text: String, from: Set<String>, to: String) -> UUID? {
        let senders = Set(from.map { $0.uppercased() })
        return lines.last { line in
            line.text == text
                && senders.contains((line.from ?? "").uppercased())
                && (line.to ?? "").uppercased() == to.uppercased()
        }?.id
    }
}

//
//  ConsoleLine.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import Foundation

/// Represents a line in the console view
nonisolated struct ConsoleLine: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case system
        case error
        case packet
    }

    /// What a line is about, which is what decides whether hiding a radio in
    /// the sidebar should hide it.
    ///
    /// The distinction that matters is not system-versus-packet. It is whether
    /// a *radio* owns the line at all. "Connected to IC-705" and "Frame sent
    /// successfully" describe a radio and belong to it; a database migration
    /// or a settings change describes the app and belongs to nobody. Before
    /// this existed, `radioID` was nil for both, so the filter could not tell
    /// "the app is talking" from "we do not know which radio", and resolved it
    /// by showing every system line whatever was hidden.
    enum Subject: Equatable, Hashable, Sendable {
        /// The app itself. No radio owns it, so no radio filter hides it.
        case app
        /// One or more radios. More than one when a shared TNC carries several
        /// on a single byte stream: that link coming up is news for every
        /// radio on it, so the line shows while any of them is visible.
        case radios(Set<RadioID>)
        /// A radio we cannot name — a line from before the emitter knew, or
        /// one reloaded without its attribution. Treated as the primary
        /// radio's, exactly as an unattributed packet line is, so it hides
        /// with the primary instead of quietly slipping past the filter.
        case unnamedRadio

        /// One named radio, the common case.
        static func radio(_ id: RadioID) -> Subject { .radios([id]) }

        /// From an optional id: a line that knows its radio belongs to it, and
        /// one that does not is unattributed rather than the app's.
        static func radio(_ id: RadioID?) -> Subject {
            id.map { .radios([$0]) } ?? .unnamedRadio
        }
    }

    /// Message type for packet-based console lines
    enum MessageType: String, Hashable, Sendable {
        case id       // Station identification
        case beacon   // Beacon message
        case mail     // Mail notification
        case data     // Actual content/data being transferred (the interesting stuff)
        case prompt   // BBS/node prompts and session protocol messages
        case message  // Fallback for unclassified messages
    }

    let id: UUID
    let kind: Kind
    let timestamp: Date
    let from: String?
    let to: String?
    let text: String
    /// Digipeater path (if any)
    let via: [String]
    /// Message type for packets (nil for system/error lines)
    let messageType: MessageType?
    /// Signature for duplicate detection (from+to+normalized_text)
    let contentSignature: String?
    /// Whether this is a duplicate of a recently seen packet (received via different path)
    let isDuplicate: Bool
    /// What this line is about, for the per-radio filter.
    let subject: Subject

    /// The radio this line is attributed to, when exactly one owns it. Drives
    /// the per-line radio badge, which only means something when there is a
    /// single radio to name — a line from a shared TNC belongs to every radio
    /// on that stream, and naming one of them would be a guess.
    var radioID: RadioID? {
        guard case .radios(let ids) = subject, ids.count == 1 else { return nil }
        return ids.first
    }
    /// The information field as it arrived, kept only when it decoded as APRS.
    ///
    /// Bytes rather than `text`, because `text` comes from `Packet.infoText`,
    /// which trims control characters and gives up entirely on anything under
    /// three-quarters printable — which is what a Mic-E payload is. Decoding
    /// from the string would miss exactly the frames that most need decoding.
    /// Kept so a line reloaded from the database decodes the same way a live
    /// one does, rather than the transcript changing character at a restart.
    let aprsInfo: Data?
    /// What the frame means, decoded once when the line is built.
    ///
    /// Stored rather than computed: `body` runs for every visible row on every
    /// pass of the console's update, and re-parsing a Mic-E position there
    /// would be work per row per render on a list that grows all day
    /// (CLAUDE.md §12).
    let aprs: APRSDigest?

    init(
        id: UUID = UUID(),
        kind: Kind = .packet,
        timestamp: Date = Date(),
        from: String? = nil,
        to: String? = nil,
        text: String,
        via: [String] = [],
        messageType: MessageType? = nil,
        isDuplicate: Bool = false,
        subject: Subject = .app,
        aprsInfo: Data? = nil
    ) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.from = from
        self.to = to
        self.text = text
        self.via = via
        self.isDuplicate = isDuplicate
        self.subject = subject

        let digest = aprsInfo.flatMap { APRSDigest.parse(destination: to ?? "", info: $0) }
        self.aprs = digest
        self.aprsInfo = digest == nil ? nil : aprsInfo

        // Auto-detect message type for packets if not explicitly provided
        if let messageType = messageType {
            self.messageType = messageType
        } else if let digest {
            // What the frame turned out to be beats what its text looks like:
            // `detectMessageType` files anything over ten characters as DATA,
            // which is every APRS beacon, and left no way to quiet a busy
            // channel without hiding the messages too.
            self.messageType = digest.messageClass
        } else if kind == .packet {
            // Detect message type even if 'to' is nil (use empty string as fallback)
            self.messageType = Self.detectMessageType(text: text, to: to ?? "")
        } else {
            self.messageType = nil
        }

        // Compute content signature for duplicate detection
        if kind == .packet, let from = from, let to = to {
            let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            self.contentSignature = "\(from.uppercased())|\(to.uppercased())|\(normalizedText)"
        } else {
            self.contentSignature = nil
        }
    }

    // MARK: - Formatting Helpers

    /// Whether this station is one of the three parties to the line: sender,
    /// addressee, or a digipeater that carried it.
    ///
    /// Matched on the base callsign, so every SSID this operator runs counts
    /// — K0EPI-7 on the terminal and K0EPI-10 on Winlink are the same person
    /// at the same desk, and a filter that showed one and hid the other would
    /// be a worse answer to "what am I doing" than no filter.
    ///
    /// Deliberately looser than `CoverageEstimate`, which matches the full
    /// address because it is making a measurement claim about one
    /// transmitter. This only decides what to draw.
    func involvesStation(_ callsign: String) -> Bool {
        let base = Self.base(of: callsign)
        guard !base.isEmpty else { return false }
        if let from, Self.base(of: from) == base { return true }
        if let to, Self.base(of: to) == base { return true }
        // A frame we digipeated went out of our transmitter, whoever it was
        // addressed to.
        return via.contains { Self.base(of: $0) == base }
    }

    /// Callsign without SSID or the `*` has-been-repeated marker.
    private static func base(of address: String) -> String {
        var text = address.trimmingCharacters(in: .whitespaces).uppercased()
        while text.hasSuffix("*") { text.removeLast() }
        return String(text.split(separator: "-").first ?? "")
    }

    /// True when the line was heard as a digipeated copy (any via marked `*` —
    /// the H bit was set, so what we heard was the digipeater's transmitter).
    var heardViaDigipeater: Bool {
        via.contains { $0.hasSuffix("*") }
    }

    /// The digipeaters that actually repeated this frame (H-bit set), without
    /// the `*` marker — e.g. ["DRLNOD"] for a copy heard off DRLNOD's
    /// transmitter. Empty for TX-time lines and direct frames.
    var repeatedDigis: [String] {
        via.filter { $0.hasSuffix("*") }.map { String($0.dropLast()) }
    }

    /// Why this copy reached us — when it did not reach us directly.
    ///
    /// Hearing a station's own transmitter and hearing a digipeater repeat it
    /// are different facts, and for a beacon they arrive as two rows a second
    /// apart with identical text. Without this the operator cannot tell "I
    /// hear KB5YZB-7" from "DRLNOD hears KB5YZB-7", which is most of what a
    /// beacon is for (2026-08-31).
    enum RepeatAttribution: Equatable, Sendable {
        /// Someone else's frame, reaching us off a digipeater's transmitter.
        case heardVia([String])
        /// Our own frame coming back. Carries no new content — the transmit
        /// line already showed it — but proves the digi relayed us.
        case ourFrameEchoed([String])

        var digis: [String] {
            switch self {
            case let .heardVia(digis), let .ourFrameEchoed(digis): return digis
            }
        }
    }

    /// Nil when the frame reached us directly, which needs no explanation.
    func repeatAttribution(localCallsign: String) -> RepeatAttribution? {
        let digis = repeatedDigis
        guard !digis.isEmpty else { return nil }
        return isDigipeatEcho(localCallsign: localCallsign)
            ? .ourFrameEchoed(digis)
            : .heardVia(digis)
    }

    /// True when this line is a digipeated copy of the local station's own
    /// transmission — the digi repeating our frame back at us. These carry no
    /// new content (the TX-time line already shows the frame), but seeing them
    /// confirms the digipeater actually relayed us.
    func isDigipeatEcho(localCallsign: String) -> Bool {
        guard heardViaDigipeater, let from else { return false }
        let local = CallsignValidator.normalize(localCallsign)
        guard !local.isEmpty else { return false }
        return CallsignValidator.normalize(from) == local
    }

    /// Hashed on identity alone.
    ///
    /// The synthesised conformance would need every member to be `Hashable`,
    /// and `APRSDigest` is not — `APRSObjectReport` is only `Equatable`. A
    /// UUID is a better hash for this type anyway: two lines with the same
    /// text a second apart are different lines, and hashing the whole struct
    /// walked several strings per bucket lookup.
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var timestampString: String {
        TimeDisplay.timeString(timestamp)
    }

    var formattedLine: String {
        var parts: [String] = [timestampString]
        if let from = from {
            if let to = to {
                parts.append("\(from)>\(to):")
            } else {
                parts.append("\(from):")
            }
        }
        parts.append(text)
        return parts.joined(separator: " ")
    }

    // MARK: - Convenience Initializers

    /// A notice about the app: migrations, settings, lifecycle. Never hidden
    /// by the per-radio filter, because no radio owns it.
    static func system(_ text: String) -> ConsoleLine {
        ConsoleLine(kind: .system, text: text, subject: .app)
    }

    /// A notice about a radio: its link, its transmissions, what it heard back.
    /// Hides with that radio. `radios` empty means "a radio, but we cannot say
    /// which" — see `Subject.unnamedRadio`.
    static func system(_ text: String, radios: Set<RadioID>) -> ConsoleLine {
        ConsoleLine(kind: .system, text: text,
                    subject: radios.isEmpty ? .unnamedRadio : .radios(radios))
    }

    /// Errors are never filtered by radio — see `passesRadioFilter` — so this
    /// takes no subject. A radio failing while hidden still has to say so.
    static func error(_ text: String) -> ConsoleLine {
        ConsoleLine(kind: .error, text: text, subject: .app)
    }

    static func packet(
        from: String,
        to: String,
        text: String,
        timestamp: Date = Date(),
        via: [String] = [],
        isDuplicate: Bool = false,
        messageType: MessageType? = nil,
        radioID: RadioID? = nil,
        aprsInfo: Data? = nil
    ) -> ConsoleLine {
        // Normalize via path for console display so repeated digis like
        // "W0ARP-7,W0ARP-7*" collapse to a single "W0ARP-7*" entry. This keeps
        // the console, tests, and packet model consistent.
        let normalizedVia = normalizedViaItems(from: via)
        return ConsoleLine(
            kind: .packet,
            timestamp: timestamp,
            from: from,
            to: to,
            text: text,
            via: normalizedVia,
            // Left to the initialiser, which classifies from the decoded frame
            // when there is one and falls back to the text when there is not.
            messageType: messageType,
            isDuplicate: isDuplicate,
            // A received frame knows the radio that heard it. One that does
            // not is legacy, and hides with the primary rather than escaping
            // the filter — the same rule the Packets table and the map use.
            subject: .radio(radioID),
            aprsInfo: aprsInfo
        )
    }

    /// Detect message type from packet text content and destination
    private static func detectMessageType(text: String, to: String) -> MessageType {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let normalizedTo = to.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        // ID messages: destination is "ID", or text starts with "ID", "ID ...", "ID:..."
        if normalizedTo == "ID" || normalizedText == "ID" || normalizedText.hasPrefix("ID ") || normalizedText.hasPrefix("ID:") {
            return .id
        }

        // CQ broadcasts: destination is usually "CQ", or text is CQ
        if normalizedTo == "CQ" || normalizedText == "CQ" || normalizedText.hasPrefix("CQ ") {
            return .data
        }

        // Beacon messages: destination is "BEACON" or text starts with "BEACON"
        if normalizedTo == "BEACON" || normalizedText.hasPrefix("BEACON") {
            return .beacon
        }

        // Mail messages: "Mail for:", "MAIL:", etc.
        if normalizedText.hasPrefix("MAIL FOR:") || normalizedText.hasPrefix("MAIL:") || normalizedText.hasPrefix("MAIL ") {
            return .mail
        }

        // If it has substantial content, it's likely actual data
        if text.trimmingCharacters(in: .whitespacesAndNewlines).count > 10 {
            return .data
        }

        return .message
    }

    /// Display string for the via path
    var viaDisplay: String {
        Self.normalizedViaItems(from: via).joined(separator: ",")
    }

    private static func normalizedViaItems(from via: [String]) -> [String] {
        guard !via.isEmpty else { return [] }

        var order: [String] = []
        var displayByKey: [String: String] = [:]
        var repeatedByKey: [String: Bool] = [:]

        for item in via {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let isRepeated = trimmed.hasSuffix("*")
            let base = isRepeated ? String(trimmed.dropLast()) : trimmed
            let key = base.uppercased()

            if displayByKey[key] == nil {
                displayByKey[key] = base
                order.append(key)
            }
            if isRepeated {
                repeatedByKey[key] = true
            }
        }

        return order.compactMap { key in
            guard let display = displayByKey[key] else { return nil }
            return (repeatedByKey[key] ?? false) ? "\(display)*" : display
        }
    }
}

extension ConsoleLine {
    /// Whether this line survives the per-radio filter.
    ///
    /// Three rules, in order:
    ///
    /// 1. **Errors always show.** Hiding a radio in the sidebar is a view
    ///    filter, not an operational disable: the radio is still on the air
    ///    with our callsign on it whether or not we are looking at it. A link
    ///    that drops, a PTT that is refused, a port that is lost — those have
    ///    to reach the operator from a hidden radio exactly as from a visible
    ///    one.
    /// 2. **App notices always show**, because no radio owns them and there is
    ///    nothing for the filter to match them against.
    /// 3. **Everything else belongs to its radios** and hides with them — a
    ///    received frame, a transmitted one, a link coming up, a reply heard.
    ///    A line from a shared TNC belongs to every radio on that stream and
    ///    survives while any of them is visible.
    ///
    /// Our own transmissions are *not* exempt. They were, and it put this view
    /// at odds with the Packets table, which has always hidden them with their
    /// radio (`PacketFilter`) — and it produced half a conversation: hide a
    /// radio and you saw what you sent on it but not the answer.
    func passesRadioFilter(hidden: Set<RadioID>, myCallsign: String) -> Bool {
        if hidden.isEmpty { return true }
        if kind == .error { return true }
        switch subject {
        case .app:
            return true
        case .radios(let ids):
            return !ids.isSubset(of: hidden)
        case .unnamedRadio:
            return !hidden.contains(.primary)
        }
    }
}

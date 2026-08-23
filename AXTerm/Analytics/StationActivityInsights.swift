//
//  StationActivityInsights.swift
//  AXTerm
//
//  Pure calculators that turn a timeframe's packets into operator-facing
//  insight: what each station *is* (role inference), what kind of traffic the
//  channel carries by hour, who consumes the airtime, and which connected-mode
//  sessions were observed on channel.
//
//  Classification is built on protocol facts and inferred station roles —
//  never on guessing at message content:
//  - Node: transmits NET/ROM routing broadcasts (UI frames to "NODES").
//  - BBS: announces mail (UI to "MAIL") or sends an SID software banner
//    (e.g. "[BPQ-6.0.24-B1FWIHJM$]") in connected-mode data — a
//    protocol-defined marker exchanged by mailbox-capable software.
//  - Digipeater: observed actually repeating frames (H bit set).
//  - Connected user: participates in I-frame sessions.
//
//  "Keyboard chat" vs "BBS/node traffic" is then a property of who the
//  session is with: I-frames touching a Node/BBS station are infrastructure
//  traffic; I-frames between two regular stations are keyboard QSOs.
//

import Foundation

// MARK: - Roles

nonisolated enum StationRole: String, CaseIterable, Hashable, Sendable {
    case node
    case bbs
    case digipeater
    case connectedUser

    var displayName: String {
        switch self {
        case .node: return "Node"
        case .bbs: return "BBS"
        case .digipeater: return "Digi"
        case .connectedUser: return "Keyboarder"
        }
    }
}

nonisolated enum StationRoleInference {
    /// SID banner exchanged by BBS/node software at session start, e.g.
    /// "[BPQ-6.0.24-B1FWIHJM$]" or "[FBB-7.011-AB1FHMRX$]".
    private static let sidBannerRegex = try? NSRegularExpression(
        pattern: #"^\[[A-Za-z0-9]+-[^\[\]]*\$\]"#
    )

    static func inferRoles(
        packets: [Packet],
        identityMode: StationIdentityMode
    ) -> [String: Set<StationRole>] {
        var roles: [String: Set<StationRole>] = [:]

        func key(_ display: String?) -> String? {
            guard let display, CallsignValidator.isValidRoutingNode(display) else { return nil }
            return CallsignParser.identityKey(for: display, mode: identityMode)
        }

        for packet in packets {
            let fromKey = key(packet.from?.display)
            let toDisplay = packet.to.map { CallsignValidator.normalize($0.display) }

            if let fromKey {
                if packet.frameType == .ui, toDisplay == "NODES" {
                    roles[fromKey, default: []].insert(.node)
                }
                if packet.frameType == .ui, toDisplay == "MAIL" {
                    roles[fromKey, default: []].insert(.bbs)
                }
                if packet.frameType == .i {
                    roles[fromKey, default: []].insert(.connectedUser)
                    if let text = packet.infoText, isSIDBanner(text) {
                        roles[fromKey, default: []].insert(.bbs)
                    }
                }
            }
            if packet.frameType == .i, let toKey = key(packet.to?.display) {
                roles[toKey, default: []].insert(.connectedUser)
            }
            for via in packet.via where via.repeated {
                if let digiKey = key(via.display) {
                    roles[digiKey, default: []].insert(.digipeater)
                }
            }
        }

        return roles
    }

    static func isSIDBanner(_ text: String) -> Bool {
        guard let sidBannerRegex else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return sidBannerRegex.firstMatch(in: trimmed, options: [], range: range) != nil
    }
}

// MARK: - Traffic classes

nonisolated enum TrafficClass: String, CaseIterable, Hashable, Sendable {
    /// I-frames between two stations with no infrastructure role.
    case chat
    /// I-frames where an endpoint is an inferred Node or BBS.
    case bbsNode
    /// UI frames: beacons, IDs, APRS-style unconnected traffic.
    case beacon
    /// NET/ROM routing broadcasts (UI to NODES).
    case routing
    /// Supervisory and unnumbered control frames.
    case overhead

    var displayName: String {
        switch self {
        case .chat: return "Chat"
        case .bbsNode: return "BBS/Node"
        case .beacon: return "Beacons"
        case .routing: return "Routing"
        case .overhead: return "Control"
        }
    }
}

nonisolated enum TrafficClassifier {
    static func classify(
        packet: Packet,
        roles: [String: Set<StationRole>],
        identityMode: StationIdentityMode
    ) -> TrafficClass {
        let toNormalized = packet.to.map { CallsignValidator.normalize($0.display) }

        if packet.frameType == .ui {
            if toNormalized == "NODES" { return .routing }
            return .beacon
        }
        if packet.frameType == .i {
            func hasInfrastructureRole(_ display: String?) -> Bool {
                guard let display else { return false }
                let key = CallsignParser.identityKey(for: display, mode: identityMode)
                let stationRoles = roles[key] ?? []
                return stationRoles.contains(.node) || stationRoles.contains(.bbs)
            }
            if hasInfrastructureRole(packet.from?.display) || hasInfrastructureRole(packet.to?.display) {
                return .bbsNode
            }
            return .chat
        }
        return .overhead
    }
}

// MARK: - Activity by hour

nonisolated struct ActivityByHourProfile: Equatable, Sendable {
    /// 24 entries, index = local hour, counts per traffic class.
    let hours: [[TrafficClass: Int]]

    var totalCount: Int {
        hours.reduce(0) { $0 + $1.values.reduce(0, +) }
    }

    static let empty = ActivityByHourProfile(hours: Array(repeating: [:], count: 24))
}

nonisolated enum ActivityByHourCalculator {
    static func profile(
        packets: [Packet],
        roles: [String: Set<StationRole>],
        identityMode: StationIdentityMode,
        calendar: Calendar
    ) -> ActivityByHourProfile {
        var hours: [[TrafficClass: Int]] = Array(repeating: [:], count: 24)
        for packet in packets {
            let hour = calendar.component(.hour, from: packet.timestamp)
            guard hour >= 0 && hour < 24 else { continue }
            let trafficClass = TrafficClassifier.classify(packet: packet, roles: roles, identityMode: identityMode)
            hours[hour][trafficClass, default: 0] += 1
        }
        return ActivityByHourProfile(hours: hours)
    }
}

// MARK: - Airtime ranking

nonisolated struct AirtimeEntry: Equatable, Sendable, Identifiable {
    let callsign: String
    let airtimeSeconds: Double
    var id: String { callsign }
}

nonisolated enum AirtimeRanking {
    /// Airtime per station: the sender pays for its transmission, and every
    /// digipeater that repeated the frame (H bit) pays for its retransmission.
    static func rank(
        packets: [Packet],
        identityMode: StationIdentityMode,
        limit: Int
    ) -> [AirtimeEntry] {
        guard limit > 0 else { return [] }
        var airtime: [String: Double] = [:]

        for packet in packets {
            let frameAirtime = AnalyticsStyle.Channel.frameAirtimeSeconds(payloadBytes: packet.info.count)
            if let from = packet.from?.display, CallsignValidator.isValidRoutingNode(from) {
                airtime[CallsignParser.identityKey(for: from, mode: identityMode), default: 0] += frameAirtime
            }
            for via in packet.via where via.repeated {
                let display = via.display
                guard CallsignValidator.isValidRoutingNode(display) else { continue }
                airtime[CallsignParser.identityKey(for: display, mode: identityMode), default: 0] += frameAirtime
            }
        }

        return airtime
            .map { AirtimeEntry(callsign: $0.key, airtimeSeconds: $0.value) }
            .sorted { lhs, rhs in
                if lhs.airtimeSeconds != rhs.airtimeSeconds { return lhs.airtimeSeconds > rhs.airtimeSeconds }
                return lhs.callsign < rhs.callsign
            }
            .prefix(limit)
            .map { $0 }
    }
}

// MARK: - Observed sessions

nonisolated struct SessionObservation: Equatable, Sendable, Identifiable {
    let stationA: String
    let stationB: String
    let start: Date
    /// nil while the session was still active at the end of the window.
    let end: Date?
    let frameCount: Int
    let iFrameCount: Int
    let byteCount: Int
    let viaDigipeaters: [String]
    /// False for connect attempts that were never answered (SABM retries with no
    /// UA, data, or supervisory response — including DM-refused attempts).
    let wasEstablished: Bool

    var id: String { "\(stationA)|\(stationB)|\(start.timeIntervalSinceReferenceDate)" }

    var duration: TimeInterval? {
        end.map { $0.timeIntervalSince(start) }
    }
}

nonisolated enum SessionObservationCalculator {
    /// A pair with no traffic for this long is considered disconnected even
    /// without an observed DISC (we may simply have missed it).
    static let inactivityGapSeconds: TimeInterval = 600

    static func sessions(
        packets: [Packet],
        identityMode: StationIdentityMode,
        windowEnd: Date
    ) -> [SessionObservation] {
        struct PairKey: Hashable {
            let a: String
            let b: String
            init(_ x: String, _ y: String) {
                if x <= y { a = x; b = y } else { a = y; b = x }
            }
        }
        struct OpenSession {
            var initiator: String
            var responder: String
            var start: Date
            var lastActivity: Date
            var frameCount = 0
            var iFrameCount = 0
            var byteCount = 0
            var viaDigipeaters: Set<String> = []
            var sawConnectionControl = false
            var sFrameCount = 0
            /// True once the link demonstrably carried a real session: a UA, any
            /// data, or supervisory flow. A pure SABM/DM exchange never sets it.
            var established = false
        }

        var open: [PairKey: OpenSession] = [:]
        var finished: [SessionObservation] = []

        func qualifies(_ s: OpenSession) -> Bool {
            // Emit real sessions: an observed connect, actual data, or sustained
            // supervisory polling (an idle connected link). A stray frame or two
            // is not a session.
            s.sawConnectionControl || s.iFrameCount > 0 || s.sFrameCount >= 4
        }

        func close(_ key: PairKey, at end: Date?) {
            guard let s = open.removeValue(forKey: key) else { return }
            guard qualifies(s) else { return }
            finished.append(SessionObservation(
                stationA: s.initiator,
                stationB: s.responder,
                start: s.start,
                end: end,
                frameCount: s.frameCount,
                iFrameCount: s.iFrameCount,
                byteCount: s.byteCount,
                viaDigipeaters: s.viaDigipeaters.sorted(),
                wasEstablished: s.established
            ))
        }

        let sorted = packets.sorted { $0.timestamp < $1.timestamp }

        for packet in sorted {
            guard packet.frameType != .ui else { continue }
            guard let fromDisplay = packet.from?.display,
                  let toDisplay = packet.to?.display,
                  CallsignValidator.isValidRoutingNode(fromDisplay),
                  CallsignValidator.isValidRoutingNode(toDisplay) else { continue }

            let from = CallsignParser.identityKey(for: fromDisplay, mode: identityMode)
            let to = CallsignParser.identityKey(for: toDisplay, mode: identityMode)
            guard from != to else { continue }
            let key = PairKey(from, to)

            let decoded = packet.controlFieldDecoded
            let isConnect = decoded.uType == .SABM || decoded.uType == .SABME
            let isDisconnect = decoded.uType == .DISC || decoded.uType == .DM

            // Inactivity splits sessions even without an observed DISC.
            if let existing = open[key],
               packet.timestamp.timeIntervalSince(existing.lastActivity) > inactivityGapSeconds {
                close(key, at: existing.lastActivity)
            }

            if isConnect {
                // AX.25 retries SABM on its T1 timer when nobody answers: a SABM
                // while the pair is still UNestablished is a retry of the same
                // attempt, not a new session. Only a SABM after an established
                // session genuinely starts a new one.
                if var existing = open[key], !existing.established {
                    existing.frameCount += 1
                    existing.lastActivity = packet.timestamp
                    existing.sawConnectionControl = true
                    open[key] = existing
                    continue
                }
                if open[key] != nil {
                    close(key, at: packet.timestamp)
                }
                open[key] = OpenSession(
                    initiator: from,
                    responder: to,
                    start: packet.timestamp,
                    lastActivity: packet.timestamp,
                    frameCount: 1,
                    sawConnectionControl: true
                )
                continue
            }

            var session = open[key] ?? OpenSession(
                initiator: from,
                responder: to,
                start: packet.timestamp,
                lastActivity: packet.timestamp
            )
            session.frameCount += 1
            session.lastActivity = packet.timestamp
            if packet.frameType == .i {
                session.iFrameCount += 1
                session.byteCount += packet.info.count
                session.established = true
            }
            if packet.frameType == .s {
                session.sFrameCount += 1
                session.established = true
            }
            if decoded.uType == .UA {
                session.established = true
            }
            for via in packet.via where via.repeated {
                if CallsignValidator.isValidRoutingNode(via.display) {
                    session.viaDigipeaters.insert(CallsignParser.identityKey(for: via.display, mode: identityMode))
                }
            }
            open[key] = session

            if isDisconnect {
                // A DM to an unestablished attempt is a refusal, not a session
                // ending: keep accumulating so a SABM/DM ping-pong stays one row.
                if session.established {
                    close(key, at: packet.timestamp)
                } else if decoded.uType == .DISC {
                    close(key, at: packet.timestamp)
                }
            }
        }

        // Window end: quiet pairs closed at last activity, active pairs left open.
        for key in Array(open.keys) {
            if let s = open[key], windowEnd.timeIntervalSince(s.lastActivity) > inactivityGapSeconds {
                close(key, at: s.lastActivity)
            } else {
                close(key, at: nil)
            }
        }

        return finished.sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start > rhs.start }
            return lhs.id < rhs.id
        }
    }
}

// MARK: - Station directory

/// One row of the station directory. Deliberately a standalone model so a
/// future station-profile system (user notes, past connections, messages) can
/// key off the same identity and roles.
nonisolated struct StationDirectoryEntry: Equatable, Sendable, Identifiable {
    let callsign: String
    let roles: Set<StationRole>
    let firstHeard: Date
    let lastHeard: Date
    let frameCount: Int
    let airtimeSeconds: Double

    var id: String { callsign }

    /// Display roles: a station with no inferred role that only transmits
    /// unconnected frames is a beacon-only station. "Keyboarder" is shown only
    /// for stations with no infrastructure role — a Node or BBS participates in
    /// connected sessions *as the service*, which is not evidence a human ever
    /// typed (e.g. a node whose only I-frames are answering inbound connects).
    var roleBadges: [String] {
        if roles.isEmpty { return ["Beacon"] }
        let isInfrastructure = roles.contains(.node) || roles.contains(.bbs) || roles.contains(.digipeater)
        let order: [StationRole] = [.node, .bbs, .digipeater, .connectedUser]
        return order
            .filter { roles.contains($0) }
            .filter { !(isInfrastructure && $0 == .connectedUser) }
            .map(\.displayName)
    }
}

nonisolated enum StationDirectoryBuilder {
    static func build(
        packets: [Packet],
        roles: [String: Set<StationRole>],
        identityMode: StationIdentityMode
    ) -> [StationDirectoryEntry] {
        struct Accumulator {
            var firstHeard: Date
            var lastHeard: Date
            var frameCount = 0
            var airtimeSeconds: Double = 0
        }
        var accumulators: [String: Accumulator] = [:]

        for packet in packets {
            guard let from = packet.from?.display, CallsignValidator.isValidRoutingNode(from) else { continue }
            let key = CallsignParser.identityKey(for: from, mode: identityMode)
            var acc = accumulators[key] ?? Accumulator(firstHeard: packet.timestamp, lastHeard: packet.timestamp)
            acc.firstHeard = min(acc.firstHeard, packet.timestamp)
            acc.lastHeard = max(acc.lastHeard, packet.timestamp)
            acc.frameCount += 1
            acc.airtimeSeconds += AnalyticsStyle.Channel.frameAirtimeSeconds(payloadBytes: packet.info.count)
            accumulators[key] = acc
        }

        return accumulators
            .map { key, acc in
                StationDirectoryEntry(
                    callsign: key,
                    roles: roles[key] ?? [],
                    firstHeard: acc.firstHeard,
                    lastHeard: acc.lastHeard,
                    frameCount: acc.frameCount,
                    airtimeSeconds: acc.airtimeSeconds
                )
            }
            .sorted { lhs, rhs in
                if lhs.lastHeard != rhs.lastHeard { return lhs.lastHeard > rhs.lastHeard }
                return lhs.callsign < rhs.callsign
            }
    }
}

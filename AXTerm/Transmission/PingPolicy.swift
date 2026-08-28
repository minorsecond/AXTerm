//
//  PingPolicy.swift
//  AXTerm
//
//  Whether to put a probe on the air, and at whom.
//
//  The protocol part of pinging a station is trivial — one U-frame out,
//  one back. Everything difficult is restraint. A shared channel has one
//  transmitter's worth of room at a time, the stations being probed did
//  not ask to be, and an automatic prober that is even slightly too eager
//  is indistinguishable from a station jamming the frequency with
//  politeness.
//
//  So the decision lives here, apart from the timer and the radio, as a
//  pure function over what is known. Every rule in it exists to answer
//  "should this transmission happen at all", and the default answer is
//  no.
//
//  The rules, in the order they say no:
//    - outside the operator's chosen hours
//    - the channel was busy a moment ago
//    - a session is running; someone's traffic is not ours to interrupt
//    - the hourly budget is spent
//    - too soon after the last probe of any station
//    - too soon after the last probe of *this* station
//    - this station has ignored us before, so wait longer each time
//
//  A station that answers is not proof of anything except that radio
//  works in both directions at this moment. It is not a route, it is not
//  a promise to route, and nothing here should be read as one.
//

import Foundation

nonisolated enum PingPolicy {

    /// Where a candidate came from, which is also how sure we are that
    /// probing it is reasonable.
    enum Source: String, Codable, Equatable, CaseIterable {
        /// Heard directly, no digipeaters. Probing tells us whether the
        /// path works the other way too, which is the useful unknown.
        case heardDirect
        /// Never heard here, but somebody nearby was calling it. Probing
        /// asks "can I reach what my neighbours reach" — more speculative,
        /// and off by default for that reason.
        case calledByOthers
    }

    struct Candidate: Equatable {
        let call: String
        let source: Source
        /// When this station was last heard, or last called for. Only used
        /// to prefer fresher candidates.
        let lastActivity: Date
    }

    /// What has happened to this station's probes so far.
    struct History: Codable, Equatable {
        var lastProbed: Date?
        var lastAnswered: Date?
        var consecutiveSilences: Int = 0

        init(lastProbed: Date? = nil, lastAnswered: Date? = nil, consecutiveSilences: Int = 0) {
            self.lastProbed = lastProbed
            self.lastAnswered = lastAnswered
            self.consecutiveSilences = consecutiveSilences
        }
    }

    struct Settings: Equatable {
        var enabled: Bool = false
        /// Local hours, inclusive start, exclusive end. Equal values mean
        /// "any hour" — a window of zero length would otherwise be the
        /// only setting that silently disables the feature.
        var windowStartHour: Int = 8
        var windowEndHour: Int = 22
        /// Floor between any two probes, whoever they are for. The channel
        /// budget, in one number.
        var minSecondsBetweenProbes: Int = 120
        /// Floor between two probes of the same station.
        var stationCooldownMinutes: Int = 60
        /// Ceiling on transmissions per hour, whatever the other numbers
        /// would allow.
        var maxProbesPerHour: Int = 12
        var sources: Set<Source> = [.heardDirect]
        /// How long the channel must have been quiet. Not CSMA — the TNC
        /// does that — but courtesy: a probe in the middle of somebody's
        /// exchange is a collision waiting to be blamed on them.
        var quietAfterTrafficSeconds: Int = 10
    }

    /// The state of the world a decision is made against.
    struct Conditions {
        var now: Date
        /// Last time *any* probe went out.
        var lastProbeAt: Date?
        /// Probe timestamps within the trailing hour.
        var probesInLastHour: [Date]
        /// When the channel last carried anything.
        var lastTrafficAt: Date?
        /// Callsigns this station currently holds a session with. They are
        /// already answering us; probing them is noise for no information.
        var connectedPeers: Set<String>
    }

    enum Decision: Equatable {
        case probe(String)
        case hold(String)
    }

    /// Longest a silent station's cooldown may grow to. Past a day the
    /// backoff has made its point, and a station that came back on the
    /// air deserves another try.
    static let maxBackoff: TimeInterval = 24 * 60 * 60

    static func decide(
        candidates: [Candidate],
        histories: [String: History],
        settings: Settings,
        conditions: Conditions
    ) -> Decision {
        guard settings.enabled else { return .hold("pinging is off") }
        guard isWithinWindow(conditions.now, settings: settings) else {
            return .hold("outside the chosen hours")
        }
        if let lastTraffic = conditions.lastTrafficAt,
           conditions.now.timeIntervalSince(lastTraffic)
            < TimeInterval(settings.quietAfterTrafficSeconds) {
            return .hold("the channel is busy")
        }
        guard conditions.connectedPeers.isEmpty else {
            return .hold("a session is running")
        }
        let recent = conditions.probesInLastHour.filter {
            conditions.now.timeIntervalSince($0) < 3600
        }
        guard recent.count < settings.maxProbesPerHour else {
            return .hold("hourly budget spent")
        }
        if let lastProbe = conditions.lastProbeAt,
           conditions.now.timeIntervalSince(lastProbe)
            < TimeInterval(settings.minSecondsBetweenProbes) {
            return .hold("too soon after the last probe")
        }

        let eligible = candidates
            .filter { settings.sources.contains($0.source) }
            .filter { !conditions.connectedPeers.contains(normalize($0.call)) }
            .filter { isDue($0, histories: histories, settings: settings, now: conditions.now) }

        guard !eligible.isEmpty else { return .hold("nothing is due") }

        // Longest un-probed first, and never probed counts as longest.
        // Ties broken by callsign so the same inputs always pick the same
        // station — a prober that varies with dictionary order is one
        // nobody can reason about from a log.
        let chosen = eligible.min { lhs, rhs in
            let lhsProbed = histories[normalize(lhs.call)]?.lastProbed ?? .distantPast
            let rhsProbed = histories[normalize(rhs.call)]?.lastProbed ?? .distantPast
            if lhsProbed != rhsProbed { return lhsProbed < rhsProbed }
            return normalize(lhs.call) < normalize(rhs.call)
        }
        guard let chosen else { return .hold("nothing is due") }
        return .probe(normalize(chosen.call))
    }

    /// How long this station must be left alone, given how it has
    /// answered before.
    ///
    /// Doubling per silence, not per probe: a station that answers resets
    /// to the plain cooldown. The asymmetry is the point — being heard
    /// costs nothing, being ignored should cost progressively more.
    static func backoff(for history: History?, settings: Settings) -> TimeInterval {
        let base = TimeInterval(max(1, settings.stationCooldownMinutes) * 60)
        guard let history, history.consecutiveSilences > 0 else { return base }
        let doublings = min(history.consecutiveSilences, 12)
        return min(base * pow(2, Double(doublings)), maxBackoff)
    }

    private static func isDue(
        _ candidate: Candidate,
        histories: [String: History],
        settings: Settings,
        now: Date
    ) -> Bool {
        let history = histories[normalize(candidate.call)]
        guard let lastProbed = history?.lastProbed else { return true }
        return now.timeIntervalSince(lastProbed) >= backoff(for: history, settings: settings)
    }

    /// Hour-of-day window, wrapping over midnight.
    static func isWithinWindow(_ date: Date, settings: Settings,
                               calendar: Calendar = .current) -> Bool {
        let start = settings.windowStartHour
        let end = settings.windowEndHour
        if start == end { return true }
        let hour = calendar.component(.hour, from: date)
        if start < end { return hour >= start && hour < end }
        // 22 → 06: late evening through to morning.
        return hour >= start || hour < end
    }

    static func normalize(_ call: String) -> String {
        call.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}

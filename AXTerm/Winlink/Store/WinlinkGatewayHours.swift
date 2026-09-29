import Foundation

/// When a gateway actually answers, derived from this station's own
/// session log.
///
/// A gateway's advertised hours are 24/7; its real behaviour is not.
/// Terrain, band conditions, local noise, and the operator's own
/// schedule combine into a pattern that only shows up in history — and
/// it is exactly what you want when planning a portable activation
/// around a battery, or deciding whether a silent frequency means the
/// path is dead or merely that it is 06:00.
///
/// Bucketing is by **local** hour on purpose: an operator plans against
/// a wristwatch, not UTC. The definitions of "counts as evidence" and
/// "answered" come from `WinlinkLinkQuality` so the Link column and this
/// profile can never disagree.
nonisolated struct WinlinkGatewayHours: Equatable, Sendable {

    struct Hour: Equatable, Sendable, Identifiable {
        /// Local hour, 0–23.
        var hour: Int
        var attempts: Int
        var answered: Int

        var id: Int { hour }

        /// Nil rather than zero when nothing was ever tried — "never
        /// attempted" and "attempted and failed" are different facts and
        /// must not render alike.
        var answerRate: Double? {
            attempts > 0 ? Double(answered) / Double(attempts) : nil
        }

        var label: String { String(format: "%02d:00", hour) }
    }

    /// The gateway this profile describes, or empty for all gateways.
    var callsign: String
    /// Always 24 entries, hour 0 first, including hours never tried.
    var hours: [Hour]

    var totalAttempts: Int { hours.reduce(0) { $0 + $1.attempts } }
    var totalAnswered: Int { hours.reduce(0) { $0 + $1.answered } }

    /// Below this many attempts overall, any pattern is noise.
    static let minimumTotalAttempts = 8
    /// Attempts needed in one hour before that hour is worth reporting.
    static let minimumHourAttempts = 2

    // MARK: - Building

    static func profile(logs: [WinlinkSessionLogRecord],
                        callsign: String = "",
                        calendar: Calendar = .current) -> WinlinkGatewayHours {
        let wanted = callsign.trimmingCharacters(in: .whitespaces).uppercased()
        var attempts = Array(repeating: 0, count: 24)
        var answered = Array(repeating: 0, count: 24)

        for log in logs {
            guard WinlinkLinkQuality.isLinkEvidence(log) else { continue }
            if !wanted.isEmpty, log.gatewayCallsign.uppercased() != wanted { continue }
            let hour = calendar.component(.hour, from: log.startedAt)
            guard hour >= 0, hour < 24 else { continue }
            attempts[hour] += 1
            if WinlinkLinkQuality.wasAnswered(log) { answered[hour] += 1 }
        }

        return WinlinkGatewayHours(
            callsign: wanted,
            hours: (0..<24).map { Hour(hour: $0, attempts: attempts[$0], answered: answered[$0]) })
    }

    // MARK: - Reading the pattern

    /// Hours with enough attempts to mean something, best first.
    var rankedHours: [Hour] {
        hours
            .filter { $0.attempts >= Self.minimumHourAttempts }
            .sorted {
                ($0.answerRate ?? 0, $0.attempts) > ($1.answerRate ?? 0, $1.attempts)
            }
    }

    /// Hours tried repeatedly that never once answered. More actionable
    /// than the best hours: it tells you when not to bother.
    var deadHours: [Hour] {
        hours
            .filter { $0.attempts >= Self.minimumHourAttempts && $0.answered == 0 }
            .sorted { $0.hour < $1.hour }
    }

    /// True when there is too little history to claim a pattern.
    var isTooThin: Bool { totalAttempts < Self.minimumTotalAttempts }

    /// One honest sentence. Says "not enough data" when that is the
    /// truth, rather than dressing three sessions up as a schedule.
    var headline: String {
        guard totalAttempts > 0 else {
            return "No sessions logged yet."
        }
        guard !isTooThin else {
            return "Only \(totalAttempts) session\(totalAttempts == 1 ? "" : "s") logged \u{2014} not enough to show a pattern yet."
        }
        guard let best = rankedHours.first, let rate = best.answerRate, rate > 0 else {
            return "\(totalAttempts) sessions logged, none answered."
        }
        var text = "Answers best around \(best.label) (\(best.answered) of \(best.attempts))."
        let dead = deadHours
        if !dead.isEmpty {
            let list = dead.map(\.label).joined(separator: ", ")
            text += " Never answered at \(list)."
        }
        return text
    }
}

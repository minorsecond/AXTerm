import Foundation

/// Noticing that a link the operator wants open has stayed shut.
///
/// The gap this fills is exactly the one 2026-09-18 left. The KISS socket to
/// Direwolf failed once at about 20:20 and never came back, and the app said
/// nothing about it for eight hours. What it *did* say, twenty times, was that
/// a frame could not be sent — a symptom of the outage, reported at error
/// level, which buried the outage itself.
///
/// So: a send that fails because the link is down is a breadcrumb, and the
/// link being down is the event. One per outage, because a node broadcasting
/// every half hour into a dead socket should not produce sixteen of them.
///
/// Pure and time-injected, so the whole rule can be tested without waiting ten
/// minutes for anything.
nonisolated struct LinkOutageWatch: Equatable {

    /// How long a wanted link may be down before it is worth saying so.
    ///
    /// Long enough that an ordinary reconnect — a TNC power-cycled, a Pi
    /// rebooted, the backoff working as designed — finishes without anyone
    /// being told, and short enough that a station which is actually off the
    /// air is noticed inside one NET/ROM broadcast interval.
    static let defaultReportAfter: TimeInterval = 10 * 60

    let reportAfter: TimeInterval

    /// When each currently-down link went down. A link that is up is absent.
    private(set) var downSince: [String: Date] = [:]
    /// Links already reported for their current outage.
    private(set) var reported: Set<String> = []

    init(reportAfter: TimeInterval = LinkOutageWatch.defaultReportAfter) {
        self.reportAfter = reportAfter
    }

    /// Record where a link stands. Coming up clears its outage and its report,
    /// so the next one is reported afresh.
    mutating func observe(_ key: String, isUp: Bool, now: Date) {
        if isUp {
            downSince[key] = nil
            reported.remove(key)
        } else if downSince[key] == nil {
            downSince[key] = now
        }
    }

    /// Stop watching everything: every link was closed on purpose.
    mutating func removeAll() {
        downSince.removeAll()
        reported.removeAll()
    }

    /// Stop watching a link entirely — the operator closed it, or removed the
    /// radio. A link nobody wants open is not an outage.
    mutating func forget(_ key: String) {
        downSince[key] = nil
        reported.remove(key)
    }

    /// Restart every clock without reporting anything.
    ///
    /// Called on wake. The machine was asleep, so the links were down for a
    /// reason that is already accounted for, and counting that time toward an
    /// outage would hand the operator an alert about their own lid.
    mutating func reset(now: Date) {
        for key in downSince.keys { downSince[key] = now }
        reported.removeAll()
    }

    /// Links that have now been down long enough to be worth saying so, each
    /// one once, with how long it has been.
    mutating func due(now: Date) -> [(key: String, down: TimeInterval)] {
        var out: [(key: String, down: TimeInterval)] = []
        // Sorted so two links falling due in the same pass report in a fixed
        // order; determinism over a dictionary's whim (CLAUDE.md §13).
        for key in downSince.keys.sorted() {
            guard let since = downSince[key], !reported.contains(key) else { continue }
            let down = now.timeIntervalSince(since)
            guard down >= reportAfter else { continue }
            reported.insert(key)
            out.append((key: key, down: down))
        }
        return out
    }
}

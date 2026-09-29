import Foundation

/// Whether a station's transmission is evidence that it answered our query.
///
/// **A general query has no answer, only a coincidence you can measure.** The
/// reply to `?APRSP` is an ordinary broadcast position report: no addressee, no
/// reference to the query, byte-identical in kind to the beacon the station was
/// going to send anyway. So "did they answer?" cannot be read off the frame —
/// it can only be inferred from timing, and only for stations whose ordinary
/// timing is slow enough for the coincidence to be unlikely.
///
/// A tracker beaconing every few seconds will always transmit inside the
/// listening window and proves nothing by doing so. A digipeater that beacons
/// every ten minutes transmitting fifteen seconds after our query is a
/// different matter. This is the arithmetic that separates the two, so the
/// results panel can stop counting the first kind as replies.
nonisolated enum APRSAnswerEvidence {

    enum Verdict: String, Sendable, Equatable {
        /// Transmitted far sooner than its own habit predicts. Not proof — a
        /// station may beacon early for its own reasons — but improbable
        /// enough to report.
        case answered
        /// Heard inside the window, but it was going to transmit anyway.
        case unproven
    }

    /// How much slower than the elapsed time a station's own cadence has to be
    /// before its transmission counts as an answer.
    ///
    /// Four: a routine beacon landing in a window of `t` seconds has roughly a
    /// `t / interval` chance of doing so by luck, so a station whose interval
    /// is four times the elapsed time had at most a one-in-four chance of
    /// coinciding. Tighter would discard slow-but-not-that-slow stations;
    /// looser would start calling coincidences replies, which is the thing
    /// this exists to stop.
    static let improbabilityFactor: Double = 4

    /// - Parameters:
    ///   - elapsed: seconds between our query and their transmission.
    ///   - typicalInterval: how often that station normally transmits. Nil when
    ///     we have not heard it often enough to know, which is not evidence of
    ///     anything either way.
    static func verdict(elapsed: TimeInterval, typicalInterval: TimeInterval?) -> Verdict {
        guard elapsed >= 0, let interval = typicalInterval, interval > 0 else { return .unproven }
        // A station heard once a minute answering after two seconds is far
        // better evidence than the ratio alone suggests, but the ratio is the
        // honest part; the rest is taste.
        return interval >= elapsed * improbabilityFactor ? .answered : .unproven
    }

    /// A station's usual gap between transmissions, from the gaps we have seen.
    ///
    /// The median rather than the mean: one long silence while a mobile is
    /// parked would drag an average out to something that calls every
    /// subsequent beacon an answer.
    static func typicalInterval(of times: [Date]) -> TimeInterval? {
        guard times.count >= 3 else { return nil }
        let sorted = times.sorted()
        let gaps = zip(sorted, sorted.dropFirst()).map { $1.timeIntervalSince($0) }
        guard !gaps.isEmpty else { return nil }
        let ordered = gaps.sorted()
        let middle = ordered.count / 2
        return ordered.count.isMultiple(of: 2)
            ? (ordered[middle - 1] + ordered[middle]) / 2
            : ordered[middle]
    }
}

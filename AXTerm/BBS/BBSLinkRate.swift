import Foundation

/// The rate a mailbox quotes a caller (park rehearsal 2026-10-08, finding
/// 35). The listing quoted a 5 KB file at under a minute from the caller's
/// last download, about 80 B/s, while the link was running stop-and-wait
/// with 64-byte frames and took five. A quote is no faster than the live
/// link can carry.
nonisolated enum BBSLinkRate {
    /// What the link carries now: a window of frames per round trip. Nil
    /// until a round trip has been measured.
    static func capacity(window: Int, paclen: Int, srtt: Double?) -> Double? {
        guard let srtt, srtt.isFinite, srtt > 0, window > 0, paclen > 0 else { return nil }
        return Double(window * paclen) / srtt
    }

    /// The caller's measured rate (else the link default), held to what the
    /// live link carries.
    static func quoted(measured: Double?, fallback: Double, capacity: Double?) -> Double {
        let base = measured ?? fallback
        guard let capacity else { return base }
        return min(base, capacity)
    }

    /// A session's capacity from its live K, paclen and round trip.
    static func capacity(of session: AX25Session) -> Double? {
        capacity(window: session.liveWindowSize, paclen: session.livePaclen, srtt: session.timers.srtt)
    }
}

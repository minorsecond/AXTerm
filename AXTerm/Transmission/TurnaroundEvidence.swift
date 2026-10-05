import Foundation

/// Whether this station's replies are being lost to the other station's
/// transmitter staying keyed after its own frames.
///
/// Live RF test 2026-09-30: an IC-705 keyed through Warbler kept an
/// unmodulated carrier on the air about 0.7 s after each frame. A TNC's
/// carrier detect listens for tones, so the TNC4 at the other end treated the
/// channel as clear and answered inside that window, and the 705 never heard
/// the start of the reply. The retries got through, because T1 sends them
/// seconds later, long after the 705 had unkeyed. Raising the TNC4's TX delay
/// to 800 ms fixed it.
///
/// AXTerm leaves TX delay to the operator (spec §7.7.1). This type collects
/// the evidence for a hint and nothing else; it changes no timing.
///
/// The evidence is this session's own I-frames. For each one AXTerm already
/// knows when it went out, whether it was acknowledged, and whether it had to
/// be sent again (the same marks Karn's algorithm uses). Added here is how
/// long after the last frame heard from the station each one was handed to the
/// modem. Frames sent within a second of hearing the station are
/// *turnaround* frames; frames sent two seconds or more after are *later*
/// frames. A frame that had to be sent again, by T1, REJ or SREJ, was missed.
/// One that was acknowledged before any resend was heard.
///
/// Only the first I-frame of a burst counts. Frames handed over together go
/// out in one transmission, so only the first sits right behind the station's
/// own transmission, and under go-back-N the rest are resent whenever the
/// first is lost, heard or not. Counting them would make every burst look
/// like several losses.
///
/// S-frames are not counted. Whether an RR was heard can only be guessed from
/// what the peer does next, and nearly every RR is a turnaround frame, so
/// there would be nothing to compare it with. A station that is mostly
/// receiving therefore collects little evidence; the hint needs this
/// station's own I-frames.
///
/// Both kinds of frame cross the same channel, so plain loss spreads over
/// both. The hint appears only when turnaround frames are missed far more
/// often than later ones, by enough that chance would almost never split them
/// that way. A one-sided Fisher exact test on the two counts gives that
/// chance.
nonisolated struct TurnaroundEvidence: Sendable, Equatable {

    /// When a frame went out, relative to the last frame heard from the station.
    enum Timing: Sendable, Equatable {
        case turnaround
        case later
    }

    /// The thresholds, with the reasons for each.
    struct Rules: Sendable, Equatable {
        /// A frame handed to the modem within this long of hearing the station
        /// is a turnaround frame. AXTerm answers within milliseconds; the TNC
        /// then waits its own persistence slots, which this does not see.
        var turnaroundWithin: TimeInterval = 1.0
        /// A frame handed over at least this long after is a later frame. T1
        /// retries come several seconds after, and no transmitter tail seen in
        /// practice runs past a second and a half.
        var laterAfter: TimeInterval = 2.0
        /// Frames handed over closer together than this after another I-frame
        /// share its transmission and are not counted.
        var burstSpacing: TimeInterval = 0.25
        /// The most recent frames kept for each kind.
        var samplesKept: Int = 40
        /// Frames older than this are forgotten. A transmitter tail does not
        /// change by itself during a session, but the operator may change the
        /// TX delay, or the other station its radio.
        var maxAge: TimeInterval = 30 * 60
        /// At least this many of each kind before the hint can appear.
        var minimumTurnaround: Int = 12
        var minimumLater: Int = 8
        /// The hint appears when at least half the turnaround frames were
        /// missed, at most one later frame in five was, and losses unrelated
        /// to timing would split them that unevenly 1 time in 2,000 or less.
        /// The minimums and this test come from simulating plain loss of 10%
        /// to 70% over 400-frame sessions: fewer than 1 in 100 such sessions
        /// ever showed the hint. With three turnaround frames in five lost and
        /// one later frame in ten, it showed after a median of about 50 frames.
        var turnaroundMissedToShow: Double = 0.5
        var laterMissedToShow: Double = 0.2
        var chanceToShow: Double = 0.0005
        /// Once shown, the hint stays until fewer than 35% of turnaround frames
        /// are missed, more than 35% of later frames are, or there are no
        /// longer enough of either. The gap between showing and clearing keeps
        /// it from flickering at the threshold.
        var turnaroundMissedToClear: Double = 0.35
        var laterMissedToClear: Double = 0.35

        static let standard = Rules()
    }

    /// The counts behind the hint.
    struct Tally: Sendable, Equatable {
        var turnaroundSent = 0
        var turnaroundMissed = 0
        var laterSent = 0
        var laterMissed = 0

        var turnaroundMissRate: Double {
            turnaroundSent == 0 ? 0 : Double(turnaroundMissed) / Double(turnaroundSent)
        }

        var laterMissRate: Double {
            laterSent == 0 ? 0 : Double(laterMissed) / Double(laterSent)
        }

        /// How likely losses that had nothing to do with timing would leave
        /// at least this many of the turnaround frames among the missed ones.
        var chance: Double {
            TurnaroundEvidence.chance(missedOf: turnaroundMissed, drawn: turnaroundSent,
                                      totalMissed: turnaroundMissed + laterMissed,
                                      total: turnaroundSent + laterSent)
        }
    }

    /// The hint appearing or clearing, with the counts at that moment.
    enum Change: Sendable, Equatable {
        case appeared(Tally)
        case cleared(Tally)
    }

    private struct Attempt: Sendable, Equatable {
        let sentAt: TimeInterval
        /// Nil when the frame is not a sample: it followed another in the same
        /// burst, fell between the two kinds, or nothing had been heard yet.
        let timing: Timing?
    }

    private struct Sample: Sendable, Equatable {
        let sentAt: TimeInterval
        let timing: Timing
        let missed: Bool
    }

    let rules: Rules

    /// When the last frame from the station was heard.
    private(set) var lastHeardAt: TimeInterval?

    /// Whether the hint is showing.
    private(set) var isShowing = false

    /// When the last I-frame, new or resent, was handed to the modem.
    private var lastSentAt: TimeInterval?

    /// The latest time any event carried; old samples age out against it.
    private var now: TimeInterval?

    /// The latest send of each outstanding I-frame, by N(S).
    private var outstanding: [Int: Attempt] = [:]

    /// Frames whose fate is known, oldest first.
    private var samples: [Sample] = []

    init(rules: Rules = .standard) {
        self.rules = rules
    }

    var tally: Tally {
        var tally = Tally()
        for sample in samples {
            switch sample.timing {
            case .turnaround:
                tally.turnaroundSent += 1
                if sample.missed { tally.turnaroundMissed += 1 }
            case .later:
                tally.laterSent += 1
                if sample.missed { tally.laterMissed += 1 }
            }
        }
        return tally
    }

    // MARK: - Evidence

    /// A frame from the station was heard.
    mutating func noteHeard(at time: TimeInterval) -> Change? {
        advance(to: time)
        lastHeardAt = time
        return evaluate()
    }

    /// An I-frame was handed to the modem, for the first time or again. A
    /// frame sent again means the previous send was missed.
    mutating func noteSent(ns: Int, at time: TimeInterval) -> Change? {
        advance(to: time)
        if let previous = outstanding[ns] {
            resolve(previous, missed: true)
        }
        let firstOfBurst = lastSentAt.map { time - $0 >= rules.burstSpacing } ?? true
        lastSentAt = time
        outstanding[ns] = Attempt(sentAt: time, timing: firstOfBurst ? timing(at: time) : nil)
        return evaluate()
    }

    /// The station acknowledged an I-frame before it had to be sent again.
    mutating func noteAcknowledged(ns: Int) -> Change? {
        guard let attempt = outstanding.removeValue(forKey: ns) else { return nil }
        resolve(attempt, missed: false)
        return evaluate()
    }

    /// The send buffer was cleared (link reset or teardown). Nothing will say
    /// what became of the frames still outstanding, so they are dropped.
    mutating func forgetOutstanding() {
        outstanding.removeAll()
    }

    /// A new connection. Forgets everything except when the station was last
    /// heard: the UA or SABM that opens a link is heard just before this.
    mutating func reset() -> Change? {
        let tally = self.tally
        let wasShowing = isShowing
        outstanding.removeAll()
        samples.removeAll()
        lastSentAt = nil
        isShowing = false
        return wasShowing ? .cleared(tally) : nil
    }

    // MARK: - Internals

    private mutating func advance(to time: TimeInterval) {
        now = max(now ?? time, time)
    }

    private func timing(at time: TimeInterval) -> Timing? {
        guard let heard = lastHeardAt else { return nil }
        let gap = time - heard
        if gap >= 0 && gap < rules.turnaroundWithin { return .turnaround }
        if gap >= rules.laterAfter { return .later }
        return nil
    }

    private mutating func resolve(_ attempt: Attempt, missed: Bool) {
        guard let timing = attempt.timing else { return }
        samples.append(Sample(sentAt: attempt.sentAt, timing: timing, missed: missed))
        if samples.filter({ $0.timing == timing }).count > rules.samplesKept,
           let oldest = samples.firstIndex(where: { $0.timing == timing }) {
            samples.remove(at: oldest)
        }
    }

    private mutating func evaluate() -> Change? {
        if let now {
            samples.removeAll { now - $0.sentAt > rules.maxAge }
        }
        let tally = self.tally
        let enough = tally.turnaroundSent >= rules.minimumTurnaround
            && tally.laterSent >= rules.minimumLater
        if !isShowing {
            guard enough,
                  tally.turnaroundMissRate >= rules.turnaroundMissedToShow,
                  tally.laterMissRate <= rules.laterMissedToShow,
                  tally.chance <= rules.chanceToShow
            else { return nil }
            isShowing = true
            return .appeared(tally)
        }
        guard !enough
                || tally.turnaroundMissRate < rules.turnaroundMissedToClear
                || tally.laterMissRate > rules.laterMissedToClear
        else { return nil }
        isShowing = false
        return .cleared(tally)
    }

    /// One-sided Fisher exact test: drawing `drawn` frames from `total`, of
    /// which `totalMissed` were missed, the chance of drawing at least
    /// `missedOf` missed ones. 1 when there is nothing to compare.
    static func chance(missedOf: Int, drawn: Int, totalMissed: Int, total: Int) -> Double {
        guard total > 0, drawn > 0, drawn < total else { return 1 }
        let heard = total - totalMissed
        let lowest = max(missedOf, drawn - heard, 0)
        let highest = min(drawn, totalMissed)
        guard lowest <= highest else { return 0 }
        let denominator = logChoose(total, drawn)
        var sum = 0.0
        for x in lowest...highest {
            sum += exp(logChoose(totalMissed, x) + logChoose(heard, drawn - x) - denominator)
        }
        return min(1, sum)
    }

    private static func logChoose(_ n: Int, _ k: Int) -> Double {
        logFactorial(n) - logFactorial(k) - logFactorial(n - k)
    }

    /// log(n!) for n up to twice the default samples kept, the most a tally holds.
    private static let logFactorials: [Double] = {
        var table = [0.0]
        for i in 1...80 { table.append(table[i - 1] + log(Double(i))) }
        return table
    }()

    private static func logFactorial(_ n: Int) -> Double {
        if n < logFactorials.count { return logFactorials[n] }
        var sum = logFactorials[logFactorials.count - 1]
        for i in logFactorials.count...n { sum += log(Double(i)) }
        return sum
    }
}

/// The words for the turnaround hint, shown under the connection strip.
nonisolated enum TurnaroundHint {

    /// The hint itself. `station` is the station whose frames this one hears
    /// last: the peer on a direct link, the first digipeater otherwise.
    static func message(station: String, txDelayMs: Int?) -> String {
        let delay = txDelayMs.map { "this radio's TX delay (now \($0) ms)" } ?? "this radio's TX delay"
        return "Replies right after \(station) transmits are being missed, while later "
            + "retries get through. Its transmitter may stay keyed briefly after each frame. "
            + "Raising \(delay) or shortening that station's transmit tail usually fixes it."
    }

    /// The tooltip: the counts the hint rests on and what else could cause them.
    static func help(station: String, tally: TurnaroundEvidence.Tally) -> String {
        "Of the last \(CountPhrase.of(tally.turnaroundSent, "I-frame")) this station sent "
            + "within a second of hearing \(station), \(tally.turnaroundMissed) had to be sent "
            + "again. Of the last \(tally.laterSent) sent 2 seconds or more after hearing it, "
            + "\(tally.laterMissed) had to be sent again. \(chancePhrase(tally.chance)) "
            + "Only the first frame of each transmission is counted. Another station that "
            + "transmits as soon as the channel clears can cause the same pattern. This "
            + "clears when replies right after \(station) get through again. "
            + "See AXTERM-TRANSMISSION-SPEC.md §7.7.1."
    }

    private static func chancePhrase(_ chance: Double) -> String {
        if chance < 1e-6 {
            return "Losses unrelated to timing would split this unevenly less than 1 time in a million."
        }
        let odds = 1 / max(chance, 1e-6)
        if odds < 1.5 {
            return "Losses unrelated to timing would often split like this."
        }
        return "Losses unrelated to timing would split this unevenly about 1 time in "
            + "\(roundedOdds(odds))."
    }

    /// Two significant figures, grouped: 2,300 rather than 2,317.
    private static func roundedOdds(_ odds: Double) -> String {
        let magnitude = pow(10, floor(log10(odds)) - 1)
        let rounded = Int((odds / magnitude).rounded() * magnitude)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: rounded)) ?? "\(rounded)"
    }
}

// MARK: - Session wiring

nonisolated extension AX25Session {

    /// The station whose frames this one hears last before replying, and so the
    /// one that must hear the reply: the first digipeater on a digipeated link
    /// (frames from the peer arrive through it), otherwise the peer.
    var turnaroundStation: String {
        path.digis.first?.display ?? remoteAddress.display
    }

    func noteTurnaroundHeard(at time: TimeInterval) {
        report(turnaroundEvidence.noteHeard(at: time))
    }

    func noteTurnaroundSent(ns: Int, at time: TimeInterval) {
        report(turnaroundEvidence.noteSent(ns: ns, at: time))
    }

    func noteTurnaroundAcknowledged(ns: Int) {
        report(turnaroundEvidence.noteAcknowledged(ns: ns))
    }

    func forgetTurnaroundOutstanding() {
        turnaroundEvidence.forgetOutstanding()
    }

    func resetTurnaroundEvidence() {
        report(turnaroundEvidence.reset())
    }

    /// A breadcrumb each time the hint appears or clears, with the counts.
    private func report(_ change: TurnaroundEvidence.Change?) {
        guard let change else { return }
        let (message, tally): (String, TurnaroundEvidence.Tally)
        switch change {
        case .appeared(let t): (message, tally) = ("Turnaround hint shown: replies right after the station are missed", t)
        case .cleared(let t): (message, tally) = ("Turnaround hint cleared", t)
        }
        TxLog.warning(.session, message, [
            "session": String(id.uuidString.prefix(8)),
            "peer": remoteAddress.display,
            "station": turnaroundStation,
            "turnaroundSent": tally.turnaroundSent,
            "turnaroundMissed": tally.turnaroundMissed,
            "laterSent": tally.laterSent,
            "laterMissed": tally.laterMissed,
            "chance": String(format: "%.2g", tally.chance)
        ])
    }
}

extension AX25SessionManager {

    /// A frame from `source` reached this station. Called by the coordinator
    /// for every connected-mode frame addressed to us, before the frame is
    /// handled, so a reply built while handling it is timed from this moment.
    func noteFrameHeard(from source: AX25Address, path: DigiPath, radio: RadioID) {
        let session = existingSession(for: source, path: path, radio: radio)
            ?? connectedSession(withPeer: source, radio: radio)
        session?.noteTurnaroundHeard(at: clock.currentTime)
        // Our transmission is over: bring the on-air estimate back (spec 7.3).
        if let session { peerHeard(session) }
    }
}

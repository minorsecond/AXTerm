import Foundation
import Combine

/// What happened to the pings this station sent.
///
/// A ping used to be fire-and-forget: one frame went out and the operator was
/// left watching a channel, with no way to tell an answer from the next beacon
/// or from silence. This holds the other half — what was asked, when, and what
/// came back — so the map can say *waiting*, *answered* or *no answer* instead
/// of nothing at all.
///
/// It deliberately distinguishes two kinds of answer, because APRS provides
/// two very different kinds of evidence:
///
/// - A **directed reply** — the station sent *us* a message (`?VER` and
///   `?APRSD` are answered that way). Proof: it heard us, it decided to
///   answer, and it addressed us by name.
/// - A **position** arriving after a `?APRSP`. Not proof of anything on its
///   own, because it is an ordinary broadcast beacon; only its timing can
///   suggest it (see `APRSAnswerEvidence`).
///
/// It also tracks a third thing, which is not an answer at all but is the
/// other half of "no answer": whether the station **repeated one of our own
/// frames**. Digipeating happens in the AX.25 layer — a station matches its
/// callsign in the via path and retransmits, without parsing the payload —
/// while answering a query happens in an APRS application that has to read the
/// information field and find its own name in the addressee. Plenty of
/// software does the first and not the second, so "it digipeated me and then
/// ignored my ping" is ordinary rather than contradictory. When we can see it,
/// saying so beats reporting bare silence.
@MainActor
final class APRSPingTracker: ObservableObject {

    enum Outcome: Equatable, Sendable {
        case waiting
        /// They sent us a directed reply. Proof.
        case confirmed
        /// They transmitted improbably soon after the ping. Evidence, not proof.
        case likely
        /// The window closed with nothing that could be attributed to us.
        case silent
    }

    /// What came back, when something did.
    ///
    /// The distinction the wording turns on. `?VER`, `?APRSD`, `?APRST` and
    /// `?APRSM` are answered *with a message*, so a message arriving during
    /// one is the answer. `?APRSP`, `?APRSS` and `?APRSO` are answered with an
    /// ordinary broadcast, so a message arriving during one is the station
    /// talking to us about something else — proof it hears us, and not an
    /// answer to what was asked. K0EPI-4, 2026-09-09: a hand-typed "Howdy"
    /// landed 40 s after a `?APRSP` and was reported as having answered it.
    enum Reply: Equatable, Sendable {
        case none
        /// A message addressed to us, in the form this query is answered in.
        case answeredQuery
        /// A message addressed to us that cannot be this query's answer.
        case addressedUs
    }

    struct Ping: Identifiable, Equatable, Sendable {
        var callsign: String
        var query: String
        /// How far it was sent. A direct query carries no digipeater path, so
        /// there is nothing for a digipeater to repeat and the absence of
        /// digipeat evidence means nothing at all.
        var reach: APRSProbeReach = .direct
        var sentAt: Date
        var outcome: Outcome = .waiting
        var answeredAt: Date?
        /// It put one of our frames back on the air while we were listening.
        /// Proof of reception, and deliberately separate from `outcome`: it
        /// says nothing about whether the query was answered.
        var heardUs: Bool = false
        /// What the station sent back, if anything. Kept apart from `outcome`
        /// because "it hears us" and "it answered the question" are different
        /// findings and only one of them is what the operator asked for.
        var reply: Reply = .none
        var id: String { callsign }
    }

    /// How long an answer is waited for.
    ///
    /// A directed query is answered immediately by anything that answers at
    /// all — Xastir transmits its reply on receipt — so this is generous
    /// rather than tuned: it covers a digipeated round trip and a station on a
    /// slow duty cycle without leaving a ping "waiting" long enough to be
    /// forgotten about.
    static let window: TimeInterval = 120

    @Published private(set) var pings: [Ping] = []

    var now: () -> Date = Date.init

    /// A station's typical transmission gap, for judging an unaddressed reply.
    var beaconInterval: ((String) -> TimeInterval?)?

    /// Whether a callsign is one this station transmits as. Needed to tell our
    /// own frame coming back out of a digipeater from anyone else's traffic —
    /// the two look identical apart from the source address.
    var isOurs: ((String) -> Bool)?

    private var cancellable: AnyCancellable?
    private var expiryTimer: Timer?

    /// Watch the channel for evidence. Every frame from a station we pinged is
    /// a candidate answer; whether it counts is `APRSAnswerEvidence`'s
    /// business, not the subscription's.
    func follow(_ packets: AnyPublisher<Packet, Never>) {
        // Hopped to main deliberately. `PacketEngine.packetInsertSubject` fires
        // on whatever thread decoded the frame, and this class publishes
        // `pings` to SwiftUI — mutating it from the decode thread produces
        // "Publishing changes from background threads is not allowed" and, in
        // principle, a torn read. `SessionCoordinator` hops the same publisher
        // for the same reason.
        cancellable = packets
            .receive(on: DispatchQueue.main)
            .sink { [weak self] packet in
            guard let self, let from = packet.from?.display else { return }
            // Our own frame, arriving back out of a digipeater. Never an
            // answer — the source is us — but every digipeater marked used on
            // it demonstrably received us, which is the one thing a silent
            // ping otherwise leaves unknown.
            if self.isOurs?(from) == true {
                for hop in packet.via where hop.repeated {
                    self.noteDigipeat(by: hop.display, at: packet.timestamp)
                }
                return
            }
            self.noteTransmission(from: from, at: packet.timestamp)
        }
    }

    /// Close out pings nobody answered. A ping that stays "waiting" for ever
    /// is the same silence it was before, dressed as progress.
    func startExpiry(interval: TimeInterval = 5) {
        expiryTimer?.invalidate()
        expiryTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.expire() }
        }
    }

    func record(ping callsign: String, query: String, reach: APRSProbeReach = .direct) {
        let call = callsign.uppercased()
        pings.removeAll { $0.callsign == call }
        pings.append(Ping(callsign: call, query: query, reach: reach, sentAt: now()))
    }

    func outcome(for callsign: String) -> Ping? {
        pings.first { $0.callsign == callsign.uppercased() }
    }

    /// A station sent us something addressed to us. Proof it hears us —
    /// which is not the same as proof it answered.
    ///
    /// Whether it counts as an answer is decided by the query, not by the
    /// frame: only a query that is *answered with a message* can be answered
    /// by one. Anything else addressed to us during a `?APRSP` is traffic from
    /// the station, and reporting it as the answer credits the query with
    /// evidence it did not produce.
    func noteDirectedReply(from callsign: String) {
        let call = callsign.uppercased()
        guard let index = pings.firstIndex(where: { $0.callsign == call }) else { return }
        // An unrecognised query token is treated as message-answered: every
        // query AXTerm sends is in the table, so a token that is not can only
        // be one typed by hand, and inventing a reason to disbelieve the
        // answer would be worse than taking it at face value.
        let expectsMessage = APRSDirectedQuery(rawValue: pings[index].query)?.answer != .broadcast
        pings[index].reply = expectsMessage ? .answeredQuery : .addressedUs
        resolve(call, as: .confirmed)
    }

    /// When each station was last seen repeating one of our frames.
    ///
    /// Kept apart from the pings because it answers a different question and
    /// outlives them: a ping asks "did you answer *this*", while this says
    /// "this station puts our traffic back on the air", which is the plainest
    /// proof of reception there is and stays true between pings.
    @Published private(set) var repeaters: [String: Date] = [:]

    /// The last time a station repeated one of our frames, if ever.
    func repeatedUs(_ callsign: String) -> Date? {
        repeaters[callsign.uppercased()]
    }

    /// A station put one of our own frames back on the air.
    ///
    /// Recorded against a ping only while that ping is still inside its
    /// window, so the row says "it heard *this*" rather than "it heard us at
    /// some point". The outcome is left alone: digipeating is not answering,
    /// and reporting it as one would be the same overclaiming this tracker
    /// exists to stop.
    func noteDigipeat(by callsign: String, at when: Date? = nil) {
        let call = callsign.uppercased()
        let at = when ?? now()
        // Recorded unconditionally: reception is reception whether or not a
        // ping happens to be outstanding.
        if at > repeaters[call] ?? .distantPast { repeaters[call] = at }
        guard let index = pings.firstIndex(where: { $0.callsign == call }),
              at.timeIntervalSince(pings[index].sentAt) <= Self.window,
              at >= pings[index].sentAt
        else { return }
        pings[index].heardUs = true
    }

    /// A station transmitted — anything at all. Only counts as an answer when
    /// its own cadence makes the timing improbable.
    func noteTransmission(from callsign: String, at when: Date? = nil) {
        let call = callsign.uppercased()
        guard let index = pings.firstIndex(where: { $0.callsign == call }),
              pings[index].outcome == .waiting else { return }
        let at = when ?? now()
        let verdict = APRSAnswerEvidence.verdict(
            elapsed: at.timeIntervalSince(pings[index].sentAt),
            typicalInterval: beaconInterval?(call))
        guard verdict == .answered else { return }
        pings[index].outcome = .likely
        pings[index].answeredAt = at
    }

    /// Close out pings whose window has run out. Call on a timer.
    func expire() {
        let t = now()
        for index in pings.indices where pings[index].outcome == .waiting {
            if t.timeIntervalSince(pings[index].sentAt) > Self.window {
                pings[index].outcome = .silent
            }
        }
    }

    private func resolve(_ callsign: String, as outcome: Outcome) {
        let call = callsign.uppercased()
        guard let index = pings.firstIndex(where: { $0.callsign == call }),
              pings[index].outcome == .waiting || pings[index].outcome == .likely
        else { return }
        pings[index].outcome = outcome
        pings[index].answeredAt = now()
    }
}

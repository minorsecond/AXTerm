import Foundation
import Combine

/// The "who can hear me" probe, Xastir-style. It transmits **one** unaddressed
/// general query (`?APRS?`) and then listens: every APRS station that answers
/// within the window can hear us, classified direct (heard with no digipeater)
/// or via a digipeater. This is a flood, not a directed poll — we don't aim it
/// at anyone, so plain AX.25 nodes/BBSes (which never answer an APRS query) are
/// never bothered, and one transmission does the work of dozens.
///
/// The scope (all / infrastructure / moving) is a **view filter** on the
/// results, not something we can aim a broadcast at: a general query solicits
/// everyone in earshot, so the honest design is flood once, filter what you
/// show.
///
/// Caveat inherent to the flood model: a station's routine position beacon that
/// lands inside the listening window looks the same as a solicited reply. The
/// window keeps that unlikely for normal beacon rates; fast Mic-E movers are
/// noisier. Directed `?APRSP` (the map's Ping) remains the clean per-station
/// test.
///
/// Pure of radio detail: it transmits through `floodQuery` and reads the heard
/// APRS stations through `aprsStations`, so the whole sweep runs
/// deterministically in tests.
final class APRSReachabilityProbe: ObservableObject {

    enum Status: String, Sendable { case idle, listening, done }

    /// A station that answered the general query within the window.
    struct Responder: Identifiable, Equatable, Sendable {
        var callsign: String
        var respondedAt: Date
        var direct: Bool
        var stationClass: APRSStationClass
        /// Whether this transmission is evidence of an answer at all, or just
        /// a station that beacons often enough to land in any window. See
        /// `APRSAnswerEvidence`.
        var evidence: APRSAnswerEvidence.Verdict = .unproven
        var id: String { callsign }
    }

    /// How often each station normally transmits, by callsign, sampled when
    /// the query goes out. Supplied by the app because it comes from the
    /// packet log, which this type deliberately knows nothing about.
    var beaconIntervals: (() -> [String: TimeInterval])?

    /// A snapshot of one currently-heard APRS station, supplied by the app.
    /// Only real APRS stations (a decoded position/symbol) appear here — never
    /// plain packet nodes.
    struct HeardStation: Equatable, Sendable {
        var callsign: String
        var lastHeard: Date?
        var direct: Bool
        var stationClass: APRSStationClass
    }

    @Published private(set) var status: Status = .idle
    /// The result filter. Changing it re-filters the view without re-flooding.
    @Published var scope: APRSProbeScope = .all
    @Published private(set) var sentAt: Date?
    @Published private(set) var responders: [Responder] = []
    /// Which question was asked, so the results can say what they answer.
    @Published private(set) var query: APRSGeneralQuery = .all
    /// How far the last question was asked. A digipeated query is answered by
    /// stations that cannot hear us at all, so the results must not be read as
    /// earshot — see `APRSProbeReach`.
    @Published private(set) var reach: APRSProbeReach = .direct
    /// Set when the last `start` couldn't put the query on the air, so the UI
    /// says that instead of listening for replies that can never arrive.
    /// Either no radio took the frame, or a radio took it and then failed to
    /// key (see `transmitDidFail`).
    @Published private(set) var transmitFailed = false
    /// Why the transmission failed, when the radio told us. Nil when the
    /// failure was simply that no APRS radio was connected.
    @Published private(set) var transmitFailureReason: String?

    var now: () -> Date = Date.init
    /// Transmit one unaddressed general query on every connected radio;
    /// returns whether it reached the air (false = no radio up). Set by the
    /// app layer.
    var floodQuery: ((APRSGeneralQuery, APRSProbeReach) -> Bool)?
    /// The APRS stations currently in the heard list — real positions only.
    /// Read repeatedly to fold in replies and to know who was already out
    /// there (the "silent" comparison).
    var aprsStations: (() -> [HeardStation])?

    /// How long after the flood a reply still counts.
    let responseWindow: TimeInterval = 120

    /// How long after the flood a link error still counts as being about
    /// *our* transmission.
    ///
    /// A KISS link's send completes when the frame is queued — for a hardware
    /// TNC that is genuinely all anyone can know, and for the built-in modem
    /// the keying happens later still, on the DSP thread. So a failure to key
    /// arrives after we have already been told the send succeeded. The modem
    /// gives PTT two seconds to confirm and the CI-V key-down/key-up pair can
    /// take a little over that, so five seconds covers the whole failure path
    /// with margin while staying far short of the two-minute listen.
    let transmitFaultWindow: TimeInterval = 5

    private var timer: Timer?
    /// The APRS stations known when we flooded — the baseline the "silent"
    /// list is measured against.
    private var baseline: [HeardStation] = []

    /// Each station's usual gap between transmissions when we asked.
    private var intervals: [String: TimeInterval] = [:]

    // MARK: - Control

    /// Send the general query and start listening. Any prior run is cancelled.
    /// `scope` sets the initial result filter.
    func start(query: APRSGeneralQuery = .all, scope: APRSProbeScope = .all,
               reach: APRSProbeReach = .direct) {
        cancel()
        self.query = query
        self.scope = scope
        self.reach = reach
        responders = []
        // Put the query on the air first; if nothing is connected, don't
        // pretend to listen — say we couldn't transmit.
        guard (floodQuery?(query, reach) ?? false) else {
            transmitFailed = true
            transmitFailureReason = nil
            sentAt = nil
            status = .idle
            return
        }
        transmitFailed = false
        transmitFailureReason = nil
        sentAt = now()
        intervals = beaconIntervals?() ?? [:]
        baseline = aprsStations?() ?? []
        status = .listening
        // Fold immediately (unlikely to have replies yet), then poll.
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        if status == .listening { status = .idle }
    }

    /// The radio reported a fault just after we transmitted: the query did not
    /// reach the air, whatever the queued send said.
    ///
    /// This is the correction to an unavoidable optimism. `floodQuery` can only
    /// report that a radio *accepted* the frame; the IC-705 over Wi-Fi accepted
    /// one and then failed to key on CI-V, and the probe sat there saying
    /// "Listening…" for replies to a query that never went out. Rather than
    /// read the fault text — the modem owns that wording, not us — anything the
    /// link reports within `transmitFaultWindow` of our own transmission is
    /// taken to be about our transmission. Being wrong that way costs a
    /// spurious "couldn't transmit" the operator can retry; being wrong the
    /// other way is the silent lie this exists to stop.
    func transmitDidFail(_ reason: String) {
        guard status == .listening, let sent = sentAt else { return }
        guard now().timeIntervalSince(sent) <= transmitFaultWindow else { return }
        cancel()
        transmitFailed = true
        transmitFailureReason = reason
        sentAt = nil
        responders = []
        status = .idle
    }

    // MARK: - Sweep step (also the deterministic test entry point)

    /// One step: fold in any APRS station heard since the flood, and finish
    /// when the response window has elapsed.
    func tick() {
        guard let sent = sentAt else { return }
        let t = now()

        for station in aprsStations?() ?? [] {
            guard let lastHeard = station.lastHeard, lastHeard > sent else { continue }
            let call = station.callsign.uppercased()
            // Their first transmission after the query is the one that
            // carries the evidence: a later one is just the next beacon.
            let verdict = APRSAnswerEvidence.verdict(
                elapsed: lastHeard.timeIntervalSince(sent),
                typicalInterval: intervals[call])
            if let i = responders.firstIndex(where: { $0.callsign == call }) {
                responders[i].respondedAt = lastHeard
                responders[i].direct = station.direct
                responders[i].stationClass = station.stationClass
            } else {
                responders.append(Responder(callsign: call, respondedAt: lastHeard,
                                            direct: station.direct,
                                            stationClass: station.stationClass,
                                            evidence: verdict))
            }
        }

        if t.timeIntervalSince(sent) >= responseWindow {
            timer?.invalidate()
            timer = nil
            status = .done
        }
    }

    // MARK: - Results (scope is a view filter)

    /// Responders in a scope, newest reply first.
    func responders(in scope: APRSProbeScope) -> [Responder] {
        responders
            .filter { scope.includes($0.stationClass) }
            .sorted { $0.respondedAt > $1.respondedAt }
    }

    var scopedResponders: [Responder] { responders(in: scope) }

    /// Responders whose timing actually says they answered, rather than
    /// stations that beacon often enough to land in any window.
    var scopedAnsweringResponders: [Responder] {
        scopedResponders.filter { $0.evidence == .answered }
    }
    var scopedDirectResponders: [Responder] { scopedResponders.filter(\.direct) }

    /// APRS stations that were already out there when we flooded but haven't
    /// answered within the window — filtered to the current scope. These were
    /// reachable to *us* before; their silence now is the interesting signal.
    var scopedSilent: [String] {
        let answered = Set(responders.map(\.callsign))
        return baseline
            .filter { scope.includes($0.stationClass)
                && !answered.contains($0.callsign.uppercased()) }
            .map { $0.callsign.uppercased() }
            .sorted()
    }
}

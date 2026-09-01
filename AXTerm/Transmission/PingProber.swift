//
//  PingProber.swift
//  AXTerm
//
//  Asking a station whether it can hear us, without connecting to it.
//
//  Two frames, in order of politeness:
//
//    XID  — AX.25 2.2 §4.3.3.7. A 2.2 station answers XID; an older one
//           answers DM or FRMR, and either is proof it heard us. AXTerm
//           already sends this before every connect, so the exchange is
//           one the network sees from this station routinely.
//    DISC — §6.3.4: a station with no link answers DM. Universal, works
//           on stacks that ignore XID entirely, and disturbs nothing,
//           because there is no link to disconnect. Sent only when XID
//           goes unanswered.
//
//  Never SABM: connecting to find out whether a station is there is the
//  thing this exists to avoid.
//
//  What an answer proves is narrow and worth stating: radio works in both
//  directions, right now, at these two stations. Not that the far end will
//  route for us, not that it will accept a connection, and not that the
//  path will still be there in an hour.
//
//  Whether to transmit at all is `PingPolicy`'s decision, not this
//  object's. This one only carries it out.
//

import Foundation
import Combine

/// `nonisolated` deliberately, and not for concurrency reasons: an
/// implicitly MainActor-isolated class gets an isolated deinit, which
/// aborts in libmalloc under the test runner on this toolchain. The same
/// note is on `SessionCoordinator`'s transport adapter, for the same
/// reason. Everything here runs on the main run loop regardless — the
/// timer is scheduled there and the radio callbacks arrive there.
// `@unchecked Sendable` for the reason stated above: everything here runs
// on the main run loop, so the weak capture in the timer's `@Sendable`
// closure is confined in practice. The compiler cannot check a convention;
// the convention is the one this class already documents.
nonisolated final class PingProber: ObservableObject, @unchecked Sendable {

    /// What a probe learned. Persisted, because the useful thing is the
    /// pattern over days, not the last result.
    struct Record: Codable, Equatable {
        var call: String
        var lastProbed: Date?
        var lastAnswered: Date?
        /// Round trip of the last answered probe.
        var lastRTT: TimeInterval?
        /// What answered: "XID", "DM", "FRMR", "UA".
        var lastAnswerKind: String?
        var consecutiveSilences: Int = 0
        var probes: Int = 0
        var answers: Int = 0

        var history: PingPolicy.History {
            PingPolicy.History(lastProbed: lastProbed, lastAnswered: lastAnswered,
                               consecutiveSilences: consecutiveSilences)
        }
    }

    /// A probe on the air, waiting.
    private struct Outstanding {
        let call: String
        let sentAt: Date
        /// Whether the DISC fallback has already been tried.
        var escalated: Bool
    }

    /// Announced by hand: a property wrapper cannot be `nonisolated`, and
    /// this class has to be (see above). `objectWillChange` fires where
    /// `@Published` did, and nothing observes the projected value.
    private(set) var records: [String: Record] = [:] {
        willSet { objectWillChange.send() }
    }

    /// How long to wait for an answer before escalating from XID to DISC,
    /// and again before calling it silence. Generous: a node answers when
    /// the channel lets it, and on a busy frequency that is seconds.
    static let answerTimeout: TimeInterval = 12

    var settings: PingPolicy.Settings = .init()

    /// Send one frame. Returns whether it reached the radio.
    var sendFrame: ((OutboundFrame) -> Bool)?
    /// This station's address, for building probes.
    var localAddress: (() -> AX25Address)?
    /// Stations heard directly, and stations others were heard calling.
    var candidateProvider: (() -> [PingPolicy.Candidate])?
    /// Peers with a live session — never probed, and their traffic is not
    /// ours to interrupt.
    var connectedPeers: (() -> Set<String>)?
    /// When the channel last carried anything at all.
    var lastTrafficAt: (() -> Date?)?
    /// Operator-facing note.
    var onNote: ((String) -> Void)?
    /// An XID probe drew a definitive firmware answer: (callsign,
    /// unsupported). DM or FRMR answering XID means a pre-2.2 stack
    /// (unsupported: true); an XID answer means v2.2 (false). Fired only
    /// for the XID probe — DM answering the DISC fallback is the *normal*
    /// §6.3.4 reply and says nothing about XID.
    var onXIDVerdict: ((String, Bool) -> Void)?

    private var outstanding: Outstanding?
    private var probeTimestamps: [Date] = []
    private var timer: Timer?
    private let defaults: UserDefaults
    private static let storageKey = "ping.records"

    init(defaults: UserDefaults = AppEnvironment.defaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = stored
        }
    }

    // MARK: - Scheduling

    func apply(settings: PingPolicy.Settings) {
        self.settings = settings
        timer?.invalidate()
        timer = nil
        guard settings.enabled else {
            outstanding = nil
            return
        }
        // Ticking often and deciding rarely. The policy holds the floor on
        // spacing; the tick only has to be frequent enough to notice a
        // quiet moment on the channel.
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func tick(now: Date = Date()) {
        expireOutstanding(now: now)
        guard outstanding == nil else { return }

        let decision = PingPolicy.decide(
            candidates: candidateProvider?() ?? [],
            histories: records.mapValues(\.history),
            settings: settings,
            conditions: PingPolicy.Conditions(
                now: now,
                lastProbeAt: probeTimestamps.last,
                probesInLastHour: probeTimestamps,
                lastTrafficAt: lastTrafficAt?(),
                connectedPeers: connectedPeers?() ?? [],
                localCallsign: localAddress?().display ?? "",
                spacingJitter: Double.random(in: 0...1)))

        guard case let .probe(call) = decision else { return }
        send(.xid, to: call, now: now)
    }

    /// Probe one station now, regardless of policy. The operator asked;
    /// the restraint rules are for the automatic pass.
    func probeNow(_ call: String, at now: Date = Date()) {
        let key = PingPolicy.normalize(call)
        guard outstanding == nil else { return }
        send(.xid, to: key, now: now)
    }

    private enum ProbeKind { case xid, disc }

    private func send(_ kind: ProbeKind, to call: String, now: Date) {
        guard let localAddress = localAddress?() else { return }
        let peer = CallsignNormalizer.toAddress(call)
        let frame: OutboundFrame
        switch kind {
        case .xid:
            frame = AX25FrameBuilder.buildXID(
                from: localAddress, to: peer,
                parameters: AX25XIDParameters(), isCommand: true)
        case .disc:
            frame = AX25FrameBuilder.buildDISC(from: localAddress, to: peer)
        }
        guard sendFrame?(frame) == true else { return }

        if case .xid = kind {
            probeTimestamps.append(now)
            probeTimestamps = probeTimestamps.filter { now.timeIntervalSince($0) < 3600 }
            outstanding = Outstanding(call: call, sentAt: now, escalated: false)
            var record = records[call] ?? Record(call: call)
            record.lastProbed = now
            record.probes += 1
            records[call] = record
            persist()
        } else {
            outstanding?.escalated = true
        }
    }

    // MARK: - Answers

    /// A U-frame arrived from a station we are probing.
    ///
    /// - Returns: true when the frame was a probe answer and the session
    ///   layer should not act on it. A DM to a station we hold no session
    ///   with means nothing to that layer, but XID would start a
    ///   negotiation for a link nobody asked to open.
    @discardableResult
    func noteAnswer(from call: String, uType: AX25UType?, hasSession: Bool,
                    at now: Date = Date()) -> Bool {
        let key = PingPolicy.normalize(call)
        guard let pending = outstanding, pending.call == key, !hasSession else { return false }
        guard let uType, [.XID, .DM, .FRMR, .UA].contains(uType) else { return false }

        var record = records[key] ?? Record(call: key)
        let rtt = now.timeIntervalSince(pending.sentAt)
        record.lastAnswered = now
        record.lastRTT = rtt
        record.lastAnswerKind = uType.rawValue
        record.consecutiveSilences = 0
        record.answers += 1
        records[key] = record
        outstanding = nil
        persist()

        // The answer to an XID probe is a firmware fingerprint worth
        // keeping: the session layer can skip its own XID dance for a
        // station that already said no (or refresh one that said yes).
        if !pending.escalated {
            switch uType {
            case .DM, .FRMR: onXIDVerdict?(key, true)
            case .XID: onXIDVerdict?(key, false)
            default: break
            }
        }

        onNote?(String(format: "%@ answered in %.1f s (%@) — it hears this station.",
                       key, rtt, uType.rawValue))
        return true
    }

    private func expireOutstanding(now: Date) {
        guard let pending = outstanding else { return }
        guard now.timeIntervalSince(pending.sentAt) >= Self.answerTimeout else { return }

        if !pending.escalated {
            // XID went unanswered. That is not silence yet: a pre-2.2 stack
            // may simply discard it, where a DISC it must answer.
            send(.disc, to: pending.call, now: now)
            outstanding = Outstanding(call: pending.call, sentAt: now, escalated: true)
            return
        }
        var record = records[pending.call] ?? Record(call: pending.call)
        record.consecutiveSilences += 1
        records[pending.call] = record
        outstanding = nil
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    /// Newest first, for display.
    var recent: [Record] {
        records.values
            .filter { $0.lastProbed != nil }
            .sorted { ($0.lastProbed ?? .distantPast) > ($1.lastProbed ?? .distantPast) }
    }
}

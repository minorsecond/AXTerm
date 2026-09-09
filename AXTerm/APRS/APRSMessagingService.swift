import Foundation
import Combine

/// A frame the service wants transmitted: a ready APRS info field, the
/// addressee/tocall it goes to, the digipeater path, and the radio.
struct APRSOutbound: Equatable, Sendable {
    var info: String
    /// Who this is for. **Not** the AX.25 destination — an APRS frame's
    /// destination is always the sending software's tocall, and the addressee
    /// lives in the information field. This is here so the transmit layer can
    /// pick the radio that station was last heard on, and so a log line can
    /// say who we were talking to. Empty for a broadcast.
    var addressee: String
    var path: [String]
    var radioID: String?
}

/// The live state of APRS messaging: the persisted message log, the auto-ACK
/// and auto-query-response behaviour, and the outgoing ACK/retry ladder. Pure
/// of any transmit or radio detail — it emits `APRSOutbound` values through an
/// injected `send` closure and takes inbound facts as a plain `InboundContext`,
/// so the whole thing is driven deterministically in tests.
final class APRSMessagingService: ObservableObject {

    /// How much AXTerm answers on its own (mirrors the operator's choice).
    enum AutoReply: String, Sendable, CaseIterable {
        case full      // auto-ACK messages AND auto-answer directed queries
        case ackOnly   // auto-ACK messages, ignore queries
        case manual    // never transmit without the operator pressing send
    }

    /// Facts about an inbound message-class frame the engine hands in.
    struct InboundContext {
        var sender: String          // the other station, call+SSID
        var ourCalls: [String]      // our callsigns, to test "addressed to us"
        var radioID: String?        // which radio heard it (reply on the same)
        var replyPath: [String]     // digipeater path for our reply
        var viaDirect: Bool         // heard direct (no digi repeated)
        var receivedAt: Date
        /// The AX.25 destination the frame arrived on — the sender's tocall.
        /// Only `?APRST` needs it, and only because Xastir's answer quotes the
        /// whole received path back, destination included.
        var destination: String = ""
        /// Every digipeater in the received frame, in the order they appear,
        /// used or not. Distinct from `replyPath`, which is the *used* ones
        /// reversed for our reply.
        var viaPath: [String] = []
    }

    @Published private(set) var messages: [APRSMessageRecord] = []

    var autoReply: AutoReply = .full
    /// A live source for the auto-reply mode, so a Settings change takes effect
    /// at once. When set it wins over `autoReply` (which tests still set).
    var autoReplyProvider: (() -> AutoReply)?
    private var effectiveAutoReply: AutoReply { autoReplyProvider?() ?? autoReply }
    /// Transmit a prepared frame. Set by the app layer.
    var send: ((APRSOutbound) -> Void)?
    var now: () -> Date = Date.init
    /// Our APRS position info field for a `?APRSP` answer, or nil if unknown.
    var positionInfo: () -> String? = { nil }
    /// The APRS tocall our position answers are addressed to.
    /// A short version string for `?APRSV` / `?VER`.
    var versionInfo: () -> String = { "AXTerm" }
    /// Stations we have heard directly, for `?APRSD`.
    var heardDirect: () -> [String] = { [] }
    /// The objects this station owns, as info fields ready to transmit, for
    /// `?APRSO`. Most urgent first — see `objectAnswers`.
    var ownObjects: () -> [String] = { [] }

    private let store: APRSMessageStore
    private var seq: Int
    private var retryTimer: Timer?

    /// Retransmit ladder (seconds). Attempt 1 is the initial send; each entry
    /// is the wait *before* the next attempt. After the last, the message
    /// fails. Deliberately conservative — a shared channel is not ours to hammer.
    private let retryDelays: [TimeInterval] = [30, 60, 120, 240, 480]

    init(store: APRSMessageStore) {
        self.store = store
        let existing = (try? store.all()) ?? []
        self.messages = existing
        // Continue message numbers past whatever is already on disk.
        let used = existing.compactMap { Int($0.number ?? "") }
        self.seq = (used.max() ?? 0) + 1
    }

    /// Begin the ack-retry sweep. Idempotent; call once after wiring `send`.
    func startRetryTimer(interval: TimeInterval = 15) {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runRetries() }
        }
    }

    // MARK: - Reads

    var unreadCount: Int {
        messages.filter { $0.direction == .incoming && !$0.isRead }.count
    }

    /// Whether a station is confirmed to hear us: any message to it was acked,
    /// which on a connectionless channel is the round-trip proof. `direct`
    /// reports whether the acked exchange was heard without a digipeater.
    struct Reachability: Equatable { var confirmed: Bool; var direct: Bool; var at: Date? }

    func reachability(of peer: String) -> Reachability {
        let p = peer.uppercased()
        let acked = messages.filter {
            $0.direction == .outgoing && $0.peer.uppercased() == p && $0.state == .acked
        }
        guard let latest = acked.max(by: { ($0.ackedAt ?? .distantPast) < ($1.ackedAt ?? .distantPast) }) else {
            return Reachability(confirmed: false, direct: false, at: nil)
        }
        return Reachability(confirmed: true, direct: latest.viaDirect, at: latest.ackedAt)
    }

    func markThreadRead(_ peer: String) {
        try? store.markThreadRead(peer: peer, at: now())
        reload()
    }

    // MARK: - Inbound

    /// A station addressed us directly — a message, an ack, or an answer to a
    /// query. Proof it heard us, and the only unambiguous kind APRS offers, so
    /// the ping tracker is told about it.
    var onDirectedTraffic: ((String) -> Void)?

    /// Ingest a parsed inbound message-class frame.
    func receive(_ parsed: APRSMessage.Inbound, context ctx: InboundContext) {
        switch parsed {
        case let .ack(addressee, number):
            guard APRSMessage.isAddressedToUs(addressee, ours: ctx.ourCalls) else { return }
            onDirectedTraffic?(ctx.sender)
            resolveAck(peer: ctx.sender, number: number, direct: ctx.viaDirect)

        case let .reject(addressee, number):
            guard APRSMessage.isAddressedToUs(addressee, ours: ctx.ourCalls) else { return }
            resolveReject(peer: ctx.sender, number: number)

        case let .message(addressee, text, number):
            guard APRSMessage.isAddressedToUs(addressee, ours: ctx.ourCalls) else { return }
            onDirectedTraffic?(ctx.sender)
            receiveMessage(addressee: addressee, text: text, number: number, ctx: ctx)

        case let .directedQuery(addressee, query):
            guard APRSMessage.isAddressedToUs(addressee, ours: ctx.ourCalls) else { return }
            receiveQuery(addressee: addressee, query: query, ctx: ctx)

        case let .bulletin(id, text):
            storeBulletin(id: id, text: text, ctx: ctx)

        case let .generalQuery(text):
            answerGeneralQuery(text, ctx: ctx)
        }
    }

    /// Answer another station's general query — after a random delay.
    ///
    /// **The delay is the protocol.** A general query is unaddressed, so every
    /// station in earshot answers the same frame at the same moment; without a
    /// spread they collide and nobody's answer arrives. Bob Bruninga's rule is
    /// a random 0–120 s, and Xastir implements exactly that by pushing its own
    /// next posit out to a random point in that window (`db.c`,
    /// `process_query`). Answering instantly is worse than not answering: it
    /// guarantees a collision with everyone else who did the same.
    ///
    /// Coalescing falls out of it. A second query arriving while an answer is
    /// pending does not schedule a second answer — the one already queued
    /// serves both, which is why Xastir mutates a posit time rather than
    /// queueing replies.
    ///
    /// Only `?APRS?` is answered. `?WX?` asks for a weather report and this
    /// station is not a weather station (Xastir leaves that one unimplemented
    /// for the same reason); `?IGATE?` asks for igate statistics we do not
    /// keep.
    private func answerGeneralQuery(_ text: String, ctx: InboundContext) {
        guard effectiveAutoReply == .full else { return }
        // Ours, coming back off a digipeater: answering it would be a station
        // holding a conversation with itself.
        guard !APRSMessage.isAddressedToUs(ctx.sender, ours: ctx.ourCalls) else { return }
        // Case matters. The spec's query tokens are uppercase, and Xastir
        // treats any other case as an illegal query and refuses it rather than
        // guessing what was meant.
        guard text.hasPrefix(APRSMessage.generalQueryAllInfo) else { return }
        guard pendingGeneralAnswer == nil, let position = positionInfo() else { return }
        pendingGeneralAnswer = PendingAnswer(
            due: now().addingTimeInterval(TimeInterval.random(in: 0...Self.generalQueryWindow)),
            out: APRSOutbound(info: position, addressee: ctx.sender,
                              path: ctx.replyPath, radioID: ctx.radioID))
    }

    /// The window a general-query answer is spread across, per APRS 1.01 and
    /// Xastir's implementation of it.
    static let generalQueryWindow: TimeInterval = 120

    private struct PendingAnswer {
        var due: Date
        var out: APRSOutbound
    }

    private var pendingGeneralAnswer: PendingAnswer?

    /// Transmit a general-query answer whose delay has run out. Called from
    /// the same sweep as the ack retries, so it needs no timer of its own.
    private func flushGeneralAnswer() {
        guard let pending = pendingGeneralAnswer, pending.due <= now() else { return }
        pendingGeneralAnswer = nil
        emit(pending.out)
    }

    private func receiveMessage(addressee: String, text: String, number: String?,
                                ctx: InboundContext) {
        // A re-send of a message we already hold: re-ACK so the sender stops,
        // but do not store or notify twice.
        if let number, (try? store.incoming(peer: ctx.sender, number: number)) != nil {
            if effectiveAutoReply != .manual { emitAck(to: ctx.sender, number: number, ctx: ctx) }
            return
        }
        let rec = APRSMessageRecord(
            direction: .incoming, kind: .message, localCall: addressee, peer: ctx.sender,
            text: text, number: number, radioID: ctx.radioID, path: ctx.replyPath,
            viaDirect: ctx.viaDirect, createdAt: ctx.receivedAt, state: .received,
            isRead: false)
        persist(rec)
        if let number, effectiveAutoReply != .manual { emitAck(to: ctx.sender, number: number, ctx: ctx) }
    }

    private func receiveQuery(addressee: String, query: String, ctx: InboundContext) {
        // Log the query for visibility even in manual mode.
        persist(APRSMessageRecord(
            direction: .incoming, kind: .query, localCall: addressee, peer: ctx.sender,
            text: query, radioID: ctx.radioID, path: ctx.replyPath, viaDirect: ctx.viaDirect,
            createdAt: ctx.receivedAt, state: .received, isRead: true))

        guard effectiveAutoReply == .full else { return }
        // Uppercase only, as the spec writes them. Xastir logs anything else
        // as an illegal query and does not answer it, and guessing at case is
        // how a station ends up answering something it was not asked.
        let q = query
        if q.hasPrefix("?APRST") || q.hasPrefix("?PING") {
            // A trace, not a position. `?APRST` asks "how did my frame reach
            // you", and answering it with a beacon answers a different
            // question — one the asker could have got from `?APRSP`.
            emitMessage(to: ctx.sender, text: traceAnswer(ctx), ctx: ctx)
        } else if q.hasPrefix("?APRSP") {
            if let pos = positionInfo() {
                // A position report is a broadcast even when a directed query
                // prompted it, but the asker still decides which radio it
                // leaves on.
                emit(APRSOutbound(info: pos, addressee: ctx.sender,
                                  path: ctx.replyPath, radioID: ctx.radioID))
            }
        } else if q.hasPrefix("?APRSV") || q.hasPrefix("?VER") {
            emitMessage(to: ctx.sender, text: versionInfo(), ctx: ctx)
        } else if q.hasPrefix("?APRSO") {
            // An object report is a broadcast even when a directed query
            // prompted it — the same shape as the `?APRSP` answer above. Every
            // station in range files it, not just the one who asked, which is
            // the point: this is how an incident map stays discoverable
            // without anybody re-beaconing on a timer.
            //
            // Xastir marks this query "NOT IMPLEMENTED YET" (`db.c`), so in
            // practice the asker will be another AXTerm more often than not.
            let all = ownObjects()
            let sending = Self.objectAnswers(all)
            for info in sending {
                emit(APRSOutbound(info: info, addressee: ctx.sender,
                                  path: ctx.replyPath, radioID: ctx.radioID))
            }
            if let note = Self.objectAnswerNote(total: all.count, sent: sending.count) {
                emitMessage(to: ctx.sender, text: note, ctx: ctx)
            }
        } else if q.hasPrefix("?APRSD") {
            // "Directs=" then a space before *each* callsign, so a station list
            // reads "Directs= W0ARP N0CALL-9" with the leading space. Xastir
            // builds it that way (`db.c`: snprintf "Directs=" then strncat " "
            // then the call, per station) and a real 2.1.8 on the test rig
            // transmits ":ORACLE-1 :Directs= ORACLE-1 ORACLE-2". We were
            // joining with a separator instead, losing the first space.
            for line in Self.directsAnswers(heardDirect()) {
                emitMessage(to: ctx.sender, text: line, ctx: ctx)
            }
        }
    }

    /// The answer to `?APRSD`, split across as many messages as the list needs.
    ///
    /// "Directs=" then a space before *each* callsign, so a list reads
    /// `Directs= W0ARP N0CALL-9` with the leading space. Xastir builds it that
    /// way (`db.c`: "Directs=" then `strncat " "` then the call) and a real
    /// 2.1.8 on the test rig transmits `:ORACLE-1 :Directs= ORACLE-1 ORACLE-2`.
    ///
    /// It also **continues into a second message** rather than truncating —
    /// captured on the rig, where eight stations came back as
    /// `Directs= 147.285CO AD1CT AID KK0X-10 N2XGL-1 ORACLE-1` followed by
    /// `Directs= SIMLA WT0R-9`. We used to cut the string at ch.14's
    /// 67-character limit, which can slice a callsign in half: `W0ARP-10`
    /// arriving as `W0AR` is not a shorter answer, it is a wrong one naming a
    /// station that was never heard. So the packing is by callsign, never by
    /// character.
    ///
    /// Xastir breaks earlier than the limit (at 53 characters in that capture,
    /// where 66 would still have fitted) — its own buffer, not a rule in the
    /// specification, so we pack to the limit the specification gives.
    ///
    /// Capped at `directsMessageLimit` messages: a busy station hears more
    /// than anyone asking `?APRSD` wants transmitted at them, and a shared
    /// channel is not ours to fill.
    static func directsAnswers(_ calls: [String], limit: Int = directsMessageLimit) -> [String] {
        var lines: [String] = []
        var current = "Directs="
        for call in calls where !call.isEmpty {
            let addition = " " + call
            if current.count + addition.count > APRSMessage.maxTextLength {
                guard current != "Directs=" else { continue }   // a call too long to ever fit
                lines.append(current)
                if lines.count >= limit { return lines }
                current = "Directs="
            }
            current += addition
        }
        if current != "Directs=" || lines.isEmpty { lines.append(current) }
        return lines
    }

    /// How many `Directs=` messages one query may draw.
    static let directsMessageLimit = 3

    /// How many stations to offer the packer. Three messages hold roughly this
    /// many ordinary callsigns; asking for more would only be silently dropped
    /// by the message budget, and a station that has heard fifty others is not
    /// answering a useful question by naming all of them.
    static let directsStationLimit = 16

    /// How many objects one `?APRSO` answer will transmit.
    ///
    /// Each object is its own frame, so an unbounded answer turns somebody's
    /// one-frame question into a minute of everybody's airtime. Eight is about
    /// six seconds at 1200 baud.
    static let objectsPerQueryLimit = 8

    /// The objects to transmit in answer to `?APRSO`.
    ///
    /// The order is the caller's and it matters: `APRSObjectStore.live()` sorts
    /// most urgent first, which is what makes truncating safe. Truncation is
    /// never silent — `objectAnswerNote` says how many were left behind,
    /// because a cap that drops things quietly reports success while answering
    /// the question wrong.
    static func objectAnswers(_ objects: [String],
                              limit: Int = objectsPerQueryLimit) -> [String] {
        Array(objects.prefix(limit))
    }

    /// What to say in words alongside the object frames, or nil when the
    /// frames said everything.
    ///
    /// Owning none still gets an answer. Silence is what a station that has
    /// never heard of `?APRSO` sends, and the asker cannot tell the two apart;
    /// Xastir answers an empty `?APRSD` with a bare "Directs=" for the same
    /// reason.
    static func objectAnswerNote(total: Int, sent: Int) -> String? {
        if total == 0 { return "No objects" }
        if total > sent { return "\(sent) of \(total) objects sent" }
        return nil
    }

    /// The answer to `?APRST` / `?PING?`: the path the query travelled to
    /// reach us.
    ///
    /// `PATH= <sender>><destination>[,<every via, in order>]`, which is what a
    /// real Xastir 2.1.8 puts on the air — captured on the test rig, not
    /// inferred from the source:
    ///
    ///     :ORACLE-1 :PATH= ORACLE-1>APZAXT
    ///     :ORACLE-2 :PATH= ORACLE-2>APZAXT,RELAY,WIDE2-1
    ///
    /// The destination is part of it, and unused digipeaters are listed too —
    /// both of which this originally got wrong, because reading `db.c` showed
    /// only `"PATH= %s>%s"` and left what Xastir passes as `path` to guess.
    /// See `AXTermTests/Fixtures/xastir-oracle.json`.
    private func traceAnswer(_ ctx: InboundContext) -> String {
        var path = ctx.destination
        if !ctx.viaPath.isEmpty {
            path += "," + ctx.viaPath.joined(separator: ",")
        }
        return String("PATH= \(ctx.sender)>\(path)".prefix(APRSMessage.maxTextLength))
    }

    /// The `?APRST` answer, for tests that compare it against a real Xastir's.
    /// A seam rather than making `traceAnswer` internal: the format is the
    /// thing under test and it should stay unreachable from the app.
    static func traceAnswerForTesting(_ ctx: InboundContext) -> String {
        let path = ctx.viaPath.isEmpty
            ? ctx.destination
            : ctx.destination + "," + ctx.viaPath.joined(separator: ",")
        return String("PATH= \(ctx.sender)>\(path)".prefix(APRSMessage.maxTextLength))
    }

    private func storeBulletin(id: String, text: String, ctx: InboundContext) {
        // Bulletins are keyed by (sender, bulletin id) so a re-issue updates
        // in place rather than piling up.
        let rowID = "bln:\(ctx.sender.uppercased()):\(id)"
        persist(APRSMessageRecord(
            id: rowID, direction: .incoming, kind: .bulletin, localCall: id, peer: ctx.sender,
            text: text, radioID: ctx.radioID, viaDirect: ctx.viaDirect,
            createdAt: ctx.receivedAt, state: .received, isRead: false))
    }

    private func resolveAck(peer: String, number: String, direct: Bool) {
        // Only a message still awaiting ack resolves — a late ack must not
        // revive a message that already failed the retry ladder.
        guard var rec = try? store.outgoing(peer: peer, number: number), rec.state == .sent else { return }
        rec.state = .acked
        rec.ackedAt = now()
        rec.nextRetryAt = nil
        // Record whether this confirmation came back direct — the reachability
        // signal is only as good as the copy that carried the ack.
        rec.viaDirect = direct
        persist(rec)
    }

    private func resolveReject(peer: String, number: String) {
        guard var rec = try? store.outgoing(peer: peer, number: number), rec.state == .sent else { return }
        rec.state = .failed
        rec.nextRetryAt = nil
        persist(rec)
    }

    // MARK: - Outbound

    /// Send a text message. A numbered message is tracked for ACK and retried;
    /// an unnumbered one is fire-and-forget. Returns the stored record.
    @discardableResult
    func sendMessage(to peer: String, text: String, from localCall: String,
                     path: [String], radioID: String?, requestAck: Bool = true) -> APRSMessageRecord {
        let number = requestAck ? nextNumber() : nil
        let rec = APRSMessageRecord(
            direction: .outgoing, kind: .message, localCall: localCall, peer: peer,
            text: text, number: number, radioID: radioID, path: path,
            createdAt: now(), state: .sent, attempts: 1,
            nextRetryAt: number != nil ? now().addingTimeInterval(retryDelays[0]) : nil,
            isRead: true)
        persist(rec)
        emit(APRSOutbound(info: APRSMessage.messageInfo(to: peer, text: text, number: number),
                          addressee: peer, path: path, radioID: radioID))
        return rec
    }

    /// Send a directed query (e.g. `?APRSP`) to a station. Unnumbered.
    func sendQuery(_ query: String, to peer: String, from localCall: String,
                   path: [String], radioID: String?) {
        persist(APRSMessageRecord(
            direction: .outgoing, kind: .query, localCall: localCall, peer: peer,
            text: query, radioID: radioID, path: path, createdAt: now(),
            state: .sent, isRead: true))
        emit(APRSOutbound(info: APRSMessage.directedQueryInfo(to: peer, query: query),
                          addressee: peer, path: path, radioID: radioID))
    }

    /// Retransmit overdue messages and fail those past the ladder. Call on a
    /// timer.
    func runRetries() {
        flushGeneralAnswer()
        let due = (try? store.duePending(now: now())) ?? []
        for var rec in due {
            if rec.attempts >= retryDelays.count {
                rec.state = .failed
                rec.nextRetryAt = nil
                persist(rec)
                continue
            }
            rec.attempts += 1
            rec.nextRetryAt = now().addingTimeInterval(retryDelays[min(rec.attempts - 1, retryDelays.count - 1)])
            persist(rec)
            emit(APRSOutbound(info: APRSMessage.messageInfo(to: rec.peer, text: rec.text, number: rec.number),
                              addressee: rec.peer, path: rec.path, radioID: rec.radioID))
        }
    }

    // MARK: - Helpers

    private func emitAck(to peer: String, number: String, ctx: InboundContext) {
        emit(APRSOutbound(info: APRSMessage.ackInfo(to: peer, number: number),
                          addressee: peer, path: ctx.replyPath, radioID: ctx.radioID))
    }

    private func emitMessage(to peer: String, text: String, ctx: InboundContext) {
        emit(APRSOutbound(info: APRSMessage.messageInfo(to: peer, text: text, number: nil),
                          addressee: peer, path: ctx.replyPath, radioID: ctx.radioID))
    }

    private func emit(_ out: APRSOutbound) { send?(out) }

    private func nextNumber() -> String {
        let n = seq
        seq = seq >= 99999 ? 1 : seq + 1
        return String(n)
    }

    /// Persist a record and mirror it into the published array.
    private func persist(_ rec: APRSMessageRecord) {
        try? store.upsert(rec)
        if let i = messages.firstIndex(where: { $0.id == rec.id }) {
            messages[i] = rec
        } else {
            messages.append(rec)
            messages.sort { $0.createdAt < $1.createdAt }
        }
    }

    private func reload() {
        messages = (try? store.all()) ?? messages
    }
}

import Foundation

/// The client-side B2F mail-exchange state machine.
///
/// Pure sans-IO design, mirroring `AX25StateMachine`: the owner feeds
/// events (`connected`, `bytesReceived`, timer expiries) and executes the
/// returned actions (send bytes, arm timers, persist results). All wire
/// formatting/parsing is delegated to the codec types; this file owns
/// only the conversation flow:
///
///     connect → banner/SID/;PQ/prompt → handshake + our proposals →
///     FS answers → our bodies → … → FF → their proposals → our FS →
///     their bodies → … → FF/FQ → disconnect
///
/// The engine never touches the transport, so scripted-dialog tests can
/// drive complete sessions with bytes split at arbitrary boundaries.
nonisolated final class B2FSessionEngine {

    // MARK: - Public types

    /// Which half of the conversation this engine plays.
    ///
    /// `initiator` calls a gateway: it waits for the remote banner, then
    /// handshakes and proposes. `answering` is the peer-to-peer half —
    /// it speaks first, then listens, because in B2F the station that
    /// just handshook proposes first.
    ///
    /// The roles are far less different than they look: everything after
    /// the handshake is already symmetric, and the second half of an
    /// initiator session *is* answering behaviour. Only the opening
    /// differs.
    enum Role: Sendable, Equatable {
        /// Calls an RMS gateway. Requires infrastructure.
        case initiator
        /// Answers an inbound connection. Works with no infrastructure at
        /// all, which is the point.
        case answering
    }

    struct Config {
        var myCallsign: String
        var password: String?
        var sid: WinlinkSID
        var role: Role
        var outbound: [PreparedOutbound]
        /// Compressed body prefixes saved from interrupted sessions, keyed
        /// by MID. When the gateway re-proposes one of these, the FS answer
        /// requests a resume from the saved offset instead of a restart.
        var partialInbound: [String: PartialInboundBody]

        init(myCallsign: String, password: String? = nil,
             sid: WinlinkSID = .axterm(version: "1.0"),
             role: Role = .initiator,
             outbound: [PreparedOutbound] = [],
             partialInbound: [String: PartialInboundBody] = [:]) {
            self.myCallsign = myCallsign
            self.password = password
            self.sid = sid
            self.role = role
            self.outbound = outbound
            self.partialInbound = partialInbound
        }
    }

    /// A partially received compressed message body from an earlier session.
    /// `compressedSize` is the total size the original proposal announced —
    /// a re-proposal with a different size is a different encoding of the
    /// message and the prefix must not be stitched onto it.
    struct PartialInboundBody: Equatable, Sendable {
        var data: Data
        var compressedSize: Int
    }

    /// An outbound message pre-compressed by the caller (compression is
    /// CPU work that does not belong inside the state machine).
    struct PreparedOutbound {
        var message: WinlinkB2Message
        /// `LZHUF.encodeB2F(message.encode())`
        var compressed: Data
        var uncompressedSize: Int
    }

    enum TimerKind: String, Sendable {
        case banner    // waiting for SID + prompt after connect
        case response  // waiting for FS / FC / FF / FQ lines
        case binary    // waiting for the next byte of a binary body
    }

    enum Event {
        case connected
        case bytesReceived(Data)
        case timerFired(TimerKind)
        case linkDisconnected
        case abortRequested
    }

    enum Action: Equatable {
        case send(Data)
        case startTimer(TimerKind, seconds: Int)
        case cancelTimer(TimerKind)
        case outboundAccepted(mid: String, offset: Int)
        case outboundRejected(mid: String)
        case outboundDeferred(mid: String)
        /// The body bytes for this MID have been handed to the transport.
        case outboundBodySent(mid: String)
        case messageFullyReceived(WinlinkB2Message, compressedSize: Int)
        /// `bytesReceived` counts the whole body, including `resumedFrom`
        /// bytes stitched in from an earlier interrupted session. Rate and
        /// ETA displays must subtract `resumedFrom` — those bytes cost no
        /// airtime here.
        case receiveProgress(mid: String, bytesReceived: Int, totalBytes: Int, resumedFrom: Int)
        /// The session is ending with this body incomplete; persist the
        /// prefix so the next exchange can resume with `FS !offset`.
        case savePartialBody(mid: String, compressedSize: Int, data: Data)
        /// A fully assembled body failed to decode. Persist it verbatim for
        /// offline analysis: the failure costs a whole re-download to
        /// reproduce, so throwing the evidence away means waiting for it to
        /// happen again.
        case captureCorruptBody(mid: String, resumedFrom: Int, declaredSize: Int, data: Data)
        /// A stored partial for this MID is no longer usable (message
        /// completed, stitch failed, or the re-proposal changed size).
        case discardPartialBody(mid: String)
        case requestDisconnect
        case complete(WinlinkExchangeSummary)
        case fail(reason: String)
    }

    enum State: Equatable {
        case idle
        case awaitingBanner
        /// Answering role only: our banner is out, waiting for the
        /// caller's `;FW:` and SID.
        case awaitingCallerHandshake
        case awaitingProposalAnswer
        case awaitingRemoteProposals
        case receivingBodies
        case closing
        case closed
        case failed
    }

    // MARK: - State

    private(set) var state: State = .idle
    private(set) var remoteSID: WinlinkSID?

    private let config: Config
    private var lineBuffer = Data()
    private var swallowNextLF = false
    /// The most recent "*** ..." advisory from the gateway/CMS — the
    /// human-readable reason when the remote end drops the link.
    private var lastGatewayNotice: String?
    /// Set when the gateway advertises pending mail for us (";PM:" lines).
    /// Drives the implicit-turnover rule after an all-declined FS.
    private var remoteHasPendingMail = false
    private var challenge: String?
    private var handshakeSent = false
    private var sentFF = false

    /// Outbound messages not yet proposed, in order.
    private var pendingOutbound: [PreparedOutbound]
    /// The batch currently proposed and awaiting an FS answer.
    private var proposedBatch: [PreparedOutbound] = []

    /// Remote proposals collected while parsing their FC block.
    private var remoteFCLines: [String] = []
    private var remoteProposals: [B2FProposal.Proposal] = []
    /// One accepted remote proposal plus the saved prefix (empty for a
    /// fresh transfer) its continuation stitches onto.
    private struct IncomingTransfer {
        var proposal: B2FProposal.Proposal
        var prefix: Data
    }
    /// Accepted remote proposals still to be received, in order.
    private var incomingQueue: [IncomingTransfer] = []
    private var blockParser: FBBBlockCodec.Parser?
    /// Set when the binary stream itself is corrupt (bad EOT checksum or
    /// framing error) — the bytes we hold are then suspect and must not be
    /// saved as a resume prefix.
    private var binaryStreamCorrupt = false

    private var summary = WinlinkExchangeSummary()

    /// What this session has moved so far. A session that dies mid-body
    /// still transferred everything up to that point, and the session log
    /// has to record it — a gateway that reliably shifts 25 kB before
    /// hitting its cap is a useful link, not a zero.
    var currentSummary: WinlinkExchangeSummary { summary }

    init(config: Config) {
        self.config = config
        self.pendingOutbound = config.outbound
    }

    // MARK: - Event handling

    func handle(_ event: Event) -> [Action] {
        switch event {
        case .connected:
            guard state == .idle else { return [] }
            guard config.role == .answering else {
                state = .awaitingBanner
                return [.startTimer(.banner, seconds: 90)]
            }
            // The answering station speaks first — the caller has
            // nothing to handshake against until it does. No `;PQ:`
            // challenge: P2P carries no CMS account to authenticate
            // against, and demanding a password no one can verify would
            // just break the exchange.
            state = .awaitingCallerHandshake
            return [
                sendText(config.sid.rendered + "\r" + config.myCallsign + ">\r"),
                .startTimer(.banner, seconds: 90),
            ]

        case .bytesReceived(let data):
            summary.bytesReceived += data.count
            return consume(data)

        case .timerFired(let kind):
            return handleTimeout(kind)

        case .linkDisconnected:
            switch state {
            case .closing, .closed:
                state = .closed
                return []
            case .failed:
                return []
            default:
                if let notice = lastGatewayNotice {
                    return failSession("the gateway closed the link: \(notice)")
                }
                return failSession("link disconnected mid-session")
            }

        case .abortRequested:
            switch state {
            case .closed, .failed, .closing:
                return []
            case .receivingBodies:
                // Can't interrupt binary politely; just drop the link —
                // but keep what already arrived for a resume next session.
                let capture = partialCaptureActions()
                summary.aborted = true
                state = .closing
                return capture + [.requestDisconnect]
            default:
                summary.aborted = true
                state = .closing
                return [sendText("FQ\r"), .requestDisconnect]
            }
        }
    }

    // MARK: - Byte-stream demultiplexing

    private func consume(_ data: Data) -> [Action] {
        var actions = [Action]()
        var remainder = data

        // A CRLF pair may straddle chunks (or a mode switch): if the last
        // consumed byte was a bare CR, a leading LF here belongs to it.
        if swallowNextLF {
            swallowNextLF = false
            if remainder.first == 0x0a {
                remainder = remainder.dropFirst()
            }
        }

        while !remainder.isEmpty {
            if state == .receivingBodies {
                remainder = consumeBinary(remainder, into: &actions)
            } else {
                remainder = consumeLines(remainder, into: &actions)
            }
            if state == .failed || state == .closed { break }
        }
        return actions
    }

    /// Line mode: append to the buffer, then process each complete line.
    /// Returns unconsumed bytes when the engine switched to binary mode.
    private func consumeLines(_ data: Data, into actions: inout [Action]) -> Data {
        lineBuffer.append(data)

        while state != .receivingBodies, state != .failed, state != .closed {
            if let lineEnd = lineBuffer.firstIndex(where: { $0 == 0x0d || $0 == 0x0a }) {
                let lineData = lineBuffer.prefix(upTo: lineEnd)
                var rest = lineBuffer.suffix(from: lineBuffer.index(after: lineEnd))
                // Swallow the LF of a CRLF pair — or remember to if the LF
                // has not arrived yet.
                if lineBuffer[lineEnd] == 0x0d {
                    if rest.first == 0x0a {
                        rest = rest.dropFirst()
                    } else if rest.isEmpty {
                        swallowNextLF = true
                    }
                }
                lineBuffer = Data(rest)
                let line = String(data: lineData, encoding: .isoLatin1) ?? ""
                actions.append(contentsOf: processLine(line))
            } else if state == .awaitingBanner, isPromptPending() {
                // The `>` prompt frequently arrives without a line ending.
                lineBuffer.removeAll()
                actions.append(contentsOf: handlePrompt())
            } else {
                break
            }
        }

        if state == .receivingBodies {
            // Whatever is left in the buffer belongs to the binary stream.
            let leftover = lineBuffer
            lineBuffer.removeAll()
            return leftover
        }
        return Data()
    }

    private func isPromptPending() -> Bool {
        guard remoteSID != nil else { return false }
        guard let last = lineBuffer.last(where: { $0 != 0x20 }) else { return false }
        return last == UInt8(ascii: ">")
    }

    private func consumeBinary(_ data: Data, into actions: inout [Action]) -> Data {
        guard let parser = blockParser else {
            actions.append(contentsOf: failSession("internal: binary mode without a parser"))
            return Data()
        }

        // Gateways can interject text at a block boundary — most notably
        // "*** <error>" before dropping the link. Treat anything that is
        // not SOH there as a line: collect through the buffer and process
        // it (which surfaces the real failure reason instead of a framing
        // error).
        if parser.isAtBlockBoundary, let first = data.first, first != 0x01 {
            lineBuffer.append(data)
            while let lineEnd = lineBuffer.firstIndex(where: { $0 == 0x0d || $0 == 0x0a }) {
                let lineData = lineBuffer.prefix(upTo: lineEnd)
                var rest = lineBuffer.suffix(from: lineBuffer.index(after: lineEnd))
                if lineBuffer[lineEnd] == 0x0d {
                    if rest.first == 0x0a {
                        rest = rest.dropFirst()
                    } else if rest.isEmpty {
                        swallowNextLF = true
                    }
                }
                lineBuffer = Data(rest)
                let line = String(data: lineData, encoding: .isoLatin1) ?? ""
                actions.append(contentsOf: processLine(line))
                if state == .failed || state == .closed { return Data() }
            }
            return Data()
        }

        // The parser consumes everything fed to it; feed byte-wise from a
        // buffer so trailing line-mode bytes (after EOT) are preserved.
        var index = data.startIndex
        while index < data.endIndex {
            let byte = data[index]
            index = data.index(after: index)
            for event in parser.feed(Data([byte])) {
                switch event {
                case .header(_, let offset):
                    actions.append(contentsOf: reconcileHeaderOffset(offset))
                    if state == .failed { return Data() }
                    actions.append(.startTimer(.binary, seconds: 120))
                case .progress:
                    if let current = incomingQueue.first {
                        if Self.prefixIsFromADifferentCompression(
                            parser.partialPayload, prefix: current.prefix) {
                            binaryStreamCorrupt = true  // nothing on hand can stitch
                            actions.append(contentsOf: failSession(
                                "gateway resumed \(current.proposal.mid) from a "
                                + "different compression of the body — the saved "
                                + "prefix cannot be stitched and has been discarded; "
                                + "the next exchange downloads from zero"))
                            return Data()
                        }
                        let contribution = Self.sessionContribution(
                            parser.partialPayload, prefix: current.prefix)
                        actions.append(.receiveProgress(
                            mid: current.proposal.mid,
                            bytesReceived: current.prefix.count + contribution.count,
                            totalBytes: current.proposal.compressedSize,
                            resumedFrom: current.prefix.count))
                    }
                    actions.append(.startTimer(.binary, seconds: 120))
                case .completed(let payload):
                    actions.append(contentsOf: finishIncomingMessage(payload))
                    return Data(data[index...])
                case .checksumFailure:
                    binaryStreamCorrupt = true
                    // The FBB checksum is one running sum over the whole
                    // transfer, verified only at EOT, so it cannot say
                    // *where* the stream went wrong — and the prefix has
                    // to be thrown away with it. Record the shape of the
                    // failure instead: AX.25 puts an FCS on every frame,
                    // so a corrupt byte stream points at framing,
                    // duplicate delivery, or a bad resume stitch rather
                    // than at RF bit errors.
                    actions.append(contentsOf: failSession(
                        checksumFailureDetail(transfer: incomingQueue.first)))
                    return Data()
                case .protocolError(let reason):
                    binaryStreamCorrupt = true
                    actions.append(contentsOf: failSession("binary framing error: \(reason)"))
                    return Data()
                }
            }
        }
        return Data()
    }

    // MARK: - Line handling

    private func processLine(_ rawLine: String) -> [Action] {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { return [] }

        // CMS advisories arrive as "*** ..." lines. A client-type or
        // authentication rejection is terminal — fail with the real reason
        // instead of waiting for the silent disconnect that follows.
        if line.hasPrefix("***") {
            let notice = line.drop(while: { $0 == "*" }).trimmingCharacters(in: .whitespaces)
            if !notice.isEmpty { lastGatewayNotice = notice }
            let lowered = notice.lowercased()
            let terminalMarkers = [
                "unknown client", "not allowed", "invalid password",
                "login fail", "unexpected response", "disconnecting",
            ]
            if terminalMarkers.contains(where: { lowered.contains($0) }) {
                return failSession("the CMS refused the connection: \(notice)")
            }
            return []
        }

        // ";PM: <call> <mid> <size> <from> <subject>" — the gateway is
        // advertising mail queued for us. Remember it: it changes the
        // turnover rules below.
        if line.uppercased().hasPrefix(";PM:") {
            remoteHasPendingMail = true
            return []
        }

        // Handshake lines are noise outside the state that wants them.
        // `;FW:` and `;PR:` arrive immediately before the caller's first
        // proposal, so they must not be mistaken for one.
        let upper = line.uppercased()
        if upper.hasPrefix(";FW:") || upper.hasPrefix(";PR:") {
            return []
        }

        switch state {
        case .awaitingBanner:
            return processBannerLine(line)
        case .awaitingCallerHandshake:
            return processCallerHandshakeLine(line)
        case .awaitingProposalAnswer:
            return processProposalAnswerLine(line)
        case .awaitingRemoteProposals:
            return processRemoteProposalLine(line)
        case .closing:
            return []  // stray banner text while the DISC settles
        default:
            return []
        }
    }

    private func processBannerLine(_ line: String) -> [Action] {
        if let sid = WinlinkSID.parse(line) {
            remoteSID = sid
            return []
        }
        if line.uppercased().hasPrefix(";PQ:") {
            challenge = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            return []
        }
        if line.hasSuffix(">"), remoteSID != nil {
            return handlePrompt()
        }
        // MOTD, ;SQ:, node banners… all ignorable.
        return []
    }

    /// Answering role: the caller's SID is the only thing we need. Once
    /// it arrives the conversation is symmetric with the second half of
    /// an initiator session, so hand straight over to the existing
    /// proposal machinery.
    private func processCallerHandshakeLine(_ line: String) -> [Action] {
        guard let sid = WinlinkSID.parse(line) else { return [] }
        remoteSID = sid
        guard sid.supportsB2F else {
            var actions: [Action] = [sendText("FQ\r")]
            actions.append(contentsOf: failSession(
                "caller \(sid.product) does not support the B2F protocol (SID features: \(sid.features))"))
            return actions
        }
        handshakeSent = true
        state = .awaitingRemoteProposals
        return [.cancelTimer(.banner), .startTimer(.response, seconds: 120)]
    }

    private func handlePrompt() -> [Action] {
        guard !handshakeSent else { return [] }
        guard let sid = remoteSID else { return [] }

        guard sid.supportsB2F else {
            var actions: [Action] = [sendText("FQ\r")]
            actions.append(contentsOf: failSession(
                "gateway \(sid.product) does not support the B2F protocol (SID features: \(sid.features))"))
            return actions
        }

        handshakeSent = true
        var text = ";FW: \(config.myCallsign)\r"
        text += config.sid.rendered + "\r"
        if let challenge, let password = config.password, !password.isEmpty {
            text += ";PR: \(WinlinkSecureLogin.response(challenge: challenge, password: password))\r"
        }

        var actions: [Action] = [.cancelTimer(.banner)]
        actions.append(sendText(text))
        actions.append(contentsOf: sendNextProposalBatchOrFF())
        return actions
    }

    private func sendNextProposalBatchOrFF() -> [Action] {
        if pendingOutbound.isEmpty {
            sentFF = true
            state = .awaitingRemoteProposals
            return [sendText("FF\r"), .startTimer(.response, seconds: 120)]
        }

        proposedBatch = Array(pendingOutbound.prefix(B2FProposal.maxProposalsPerBlock))
        pendingOutbound.removeFirst(proposedBatch.count)

        let proposals = proposedBatch.map { outbound in
            B2FProposal.Proposal(
                kind: .encapsulatedMessage,
                mid: outbound.message.mid,
                uncompressedSize: outbound.uncompressedSize,
                compressedSize: outbound.compressed.count)
        }
        state = .awaitingProposalAnswer
        return [sendText(B2FProposal.renderBlock(proposals)), .startTimer(.response, seconds: 120)]
    }

    private func processProposalAnswerLine(_ line: String) -> [Action] {
        let upper = line.uppercased()
        if upper == "FQ" {
            return completeSession(disconnectRequested: false)
        }
        if upper.hasPrefix("FS") {
            guard let answers = B2FProposal.parseAnswers(line), answers.count == proposedBatch.count else {
                return failSession("unparseable FS answer for \(proposedBatch.count) proposals: \(line)")
            }
            var actions: [Action] = [.cancelTimer(.response)]

            for (outbound, answer) in zip(proposedBatch, answers) {
                let mid = outbound.message.mid
                switch answer {
                case .accept:
                    actions.append(.outboundAccepted(mid: mid, offset: 0))
                    actions.append(.send(FBBBlockCodec.encode(
                        title: outbound.message.subject, offset: 0, payload: outbound.compressed)))
                    summary.bytesSent += outbound.compressed.count
                    actions.append(.outboundBodySent(mid: mid))
                    summary.sentMIDs.append(mid)
                case .acceptFromOffset(let offset):
                    let bounded = min(offset, outbound.compressed.count)
                    actions.append(.outboundAccepted(mid: mid, offset: bounded))
                    actions.append(.send(FBBBlockCodec.encode(
                        title: outbound.message.subject, offset: bounded, payload: outbound.compressed)))
                    summary.bytesSent += outbound.compressed.count - bounded
                    actions.append(.outboundBodySent(mid: mid))
                    summary.sentMIDs.append(mid)
                case .reject:
                    actions.append(.outboundRejected(mid: mid))
                    summary.rejectedMIDs.append(mid)
                case .defer_:
                    actions.append(.outboundDeferred(mid: mid))
                    summary.deferredMIDs.append(mid)
                }
            }
            let batchTransferredNothing = !answers.contains {
                if case .accept = $0 { return true }
                if case .acceptFromOffset = $0 { return true }
                return false
            }
            proposedBatch = []

            // FBB implicit turnover: when an FS answer accepts nothing,
            // a CMS with pending mail takes the turn immediately — its FC
            // proposals follow the FS in the same burst, without waiting
            // for our FF. Sending FF then collides with the proposal and
            // the CMS aborts with "Unexpected response to proposal"
            // (observed on the air). So: nothing accepted + nothing more
            // to offer + remote advertised mail → just start listening.
            if batchTransferredNothing, pendingOutbound.isEmpty, remoteHasPendingMail {
                sentFF = true
                state = .awaitingRemoteProposals
                actions.append(.startTimer(.response, seconds: 120))
                return actions
            }

            actions.append(contentsOf: sendNextProposalBatchOrFF())
            return actions
        }
        // Stray text (e.g. late MOTD) — ignore.
        return []
    }

    private func processRemoteProposalLine(_ line: String) -> [Action] {
        let upper = line.uppercased()

        if upper.hasPrefix("FC") {
            remoteFCLines.append(line)
            return [.startTimer(.response, seconds: 120)]
        }

        if upper.hasPrefix("F>") {
            return processRemoteBlockEnd(line)
        }

        if upper == "FF" {
            // Remote has no (more) traffic. Everything we had is already
            // proposed, so the session is over.
            return completeSession(disconnectRequested: true)
        }

        if upper == "FQ" {
            return completeSession(disconnectRequested: false)
        }

        if upper.hasPrefix("FS") {
            return failSession("unexpected FS while awaiting remote proposals")
        }

        // ;PM: pending-message advisories and other chatter are ignorable.
        return []
    }

    private func processRemoteBlockEnd(_ line: String) -> [Action] {
        let checksumHex = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        guard B2FProposal.validateBlockChecksum(fcLines: remoteFCLines, checksumHex: checksumHex) else {
            return failSession("remote proposal block checksum mismatch")
        }

        remoteProposals = []
        for fcLine in remoteFCLines {
            guard let proposal = B2FProposal.Proposal.parse(fcLine) else {
                return failSession("unparseable remote proposal: \(fcLine)")
            }
            remoteProposals.append(proposal)
        }
        remoteFCLines = []

        guard !remoteProposals.isEmpty else {
            return failSession("remote sent an empty proposal block")
        }

        var answers = [B2FProposal.Answer]()
        var preambleActions = [Action]()
        incomingQueue = []
        for proposal in remoteProposals {
            // Sanity-check sizes; a hostile or corrupt proposal must not
            // make us buffer unbounded data.
            let acceptable = proposal.kind == .encapsulatedMessage
                && proposal.compressedSize >= 6
                && proposal.compressedSize <= 4 * 1024 * 1024
            guard acceptable else {
                answers.append(.reject)
                continue
            }

            // Resume: a saved prefix from an interrupted session lets us
            // ask for the remainder only (FS !offset). The prefix is valid
            // only for the same MID at the same compressed size.
            if let partial = config.partialInbound[proposal.mid] {
                if partial.compressedSize == proposal.compressedSize,
                   !partial.data.isEmpty,
                   partial.data.count < proposal.compressedSize {
                    answers.append(.acceptFromOffset(partial.data.count))
                    incomingQueue.append(IncomingTransfer(proposal: proposal, prefix: partial.data))
                    continue
                }
                // Stale or oversized partial — start over and drop it.
                preambleActions.append(.discardPartialBody(mid: proposal.mid))
            }
            answers.append(.accept)
            incomingQueue.append(IncomingTransfer(proposal: proposal, prefix: Data()))
        }

        let fsLine = "FS " + answers.map(\.rendered).joined() + "\r"
        var actions: [Action] = preambleActions + [.cancelTimer(.response), sendText(fsLine)]

        if incomingQueue.isEmpty {
            // Rejected everything; remote will follow with FF or more proposals.
            actions.append(.startTimer(.response, seconds: 120))
        } else {
            state = .receivingBodies
            blockParser = FBBBlockCodec.Parser()
            actions.append(.startTimer(.binary, seconds: 120))
        }
        return actions
    }

    // MARK: - Incoming message completion

    /// Describes a checksum failure in terms an operator (and a bug
    /// report) can act on.
    ///
    /// The distinction that matters is whether a resume was involved. A
    /// fresh transfer failing checksum points at the link delivering
    /// corrupt or duplicated bytes; a resumed one points first at the
    /// stitch, because the prefix came from a different session and only
    /// the SOH offset vouches for it.
    private func checksumFailureDetail(transfer: IncomingTransfer?) -> String {
        guard let transfer else {
            return "binary block checksum failure (no transfer in progress)"
        }
        let mid = transfer.proposal.mid
        let total = transfer.proposal.compressedSize
        if transfer.prefix.isEmpty {
            return "binary block checksum failure on \(mid) — the \(total)-byte body "
                + "arrived complete but its FBB checksum does not match, so some "
                + "byte of it is wrong. Every AX.25 frame carries its own FCS, so "
                + "this points at duplicate or out-of-order delivery rather than "
                + "at radio noise. Nothing was saved; the next exchange restarts it."
        }
        return "binary block checksum failure on \(mid) — \(transfer.prefix.count) bytes "
            + "resumed from an earlier session plus this session's continuation do not "
            + "checksum to a valid \(total)-byte body. The saved prefix is the prime "
            + "suspect and has been discarded; the next exchange downloads from zero."
    }

    /// The bytes a resumed session actually adds to the body.
    ///
    /// On a resume (`FS !offset`) the gateway re-sends the six-byte LZHUF
    /// wire header (CRC16 + uncompressed length) before continuing the
    /// stream at the offset — field capture 2026-08-24, 6KFOMF87WJ8T: the
    /// header bytes sat verbatim at all four resume seams. Appending them
    /// corrupts the stream *and* inflates the saved byte count, so the
    /// next resume asks six bytes too far ahead and the gateway skips six
    /// real bytes: four resumes injected 24 junk bytes and lost 18 real
    /// ones, and no retry could converge.
    ///
    /// The re-sent header is recognized by exact match against the stored
    /// prefix, so a sender that resumes without re-sending one is still
    /// stitched verbatim. (A true continuation that happens to begin with
    /// those same six bytes is a 2^-48 coincidence — and the LZHUF CRC16
    /// still arbitrates the result.)
    private static func sessionContribution(_ sessionBytes: Data, prefix: Data) -> Data {
        let header = LZHUF.wireHeaderSize
        guard prefix.count >= header, sessionBytes.count >= header,
              sessionBytes.prefix(header) == prefix.prefix(header) else {
            return sessionBytes
        }
        return Data(sessionBytes.dropFirst(header))
    }

    /// True when a resumed stream opens with a wire header that declares
    /// the same uncompressed length as the stored prefix but a different
    /// CRC16: the gateway restarted from a different compression of the
    /// body, and nothing we hold can ever stitch to it. Detecting it here
    /// — six bytes in — beats downloading the whole body into a stream
    /// that was doomed from byte one.
    private static func prefixIsFromADifferentCompression(
        _ sessionBytes: Data, prefix: Data
    ) -> Bool {
        let header = LZHUF.wireHeaderSize
        guard prefix.count >= header, sessionBytes.count >= header else { return false }
        let sessionHead = sessionBytes.prefix(header)
        let prefixHead = prefix.prefix(header)
        guard sessionHead != prefixHead else { return false }
        return Data(sessionHead.dropFirst(2)) == Data(prefixHead.dropFirst(2))
    }

    /// Aligns our saved prefix with the offset the gateway's SOH header
    /// actually declares. Gateways may ignore a resume request and restart
    /// from 0 (drop the prefix), or resume earlier than asked (trim it).
    /// An offset beyond what we hold leaves a gap nothing can fill.
    private func reconcileHeaderOffset(_ offset: Int) -> [Action] {
        guard let index = incomingQueue.indices.first else { return [] }
        let transfer = incomingQueue[index]
        if offset == transfer.prefix.count { return [] }

        if offset < transfer.prefix.count {
            incomingQueue[index].prefix = transfer.prefix.prefix(offset)
            // The stored partial no longer matches what this session will
            // stitch; the completed message (or the next interruption)
            // re-persists the correct bytes.
            return offset == 0 ? [.discardPartialBody(mid: transfer.proposal.mid)] : []
        }
        binaryStreamCorrupt = true  // nothing received is stitchable
        return failSession(
            "gateway resumed \(transfer.proposal.mid) at byte \(offset) but only \(transfer.prefix.count) bytes are on hand")
    }

    /// Explains a decode failure in terms that separate the candidates.
    ///
    /// FBB's own framing checksum is a single 8-bit sum verified at EOT, so
    /// it passes roughly one corrupt stream in 256 — reaching this point
    /// with "the framing was fine" proves very little. LZHUF's CRC16 is the
    /// real integrity check, and which of the two failure modes it reports
    /// points in opposite directions:
    ///
    /// * CRC16 mismatch — the bytes are wrong. With a resumed prefix, the
    ///   stitch is the first suspect; without one, delivery is.
    /// * size mismatch — the CRC16 passed, so the bytes are right and the
    ///   decompressor is at fault.
    private static func describeDecodeFailure(
        mid: String,
        error: Error,
        prefixBytes: Int,
        sessionBytes: Int,
        declaredSize: Int,
        body: Data
    ) -> String {
        var text = "failed to decode incoming message \(mid): \(error)"
        text += " — \(body.count) bytes assembled"
        if declaredSize != body.count {
            text += " against \(declaredSize) proposed"
        }
        if prefixBytes > 0 {
            text += "; \(prefixBytes) resumed from an earlier session plus "
                + "\(sessionBytes) received now, so the saved prefix is the "
                + "first suspect and has been discarded"
        } else {
            text += "; nothing was resumed, so the corruption arrived in this "
                + "session — FBB's 8-bit block sum is weak enough to pass a "
                + "damaged stream that CRC16 then catches"
        }
        if case LZHUF.DecodeError.decodedSizeMismatch = error {
            text += ". The CRC16 passed, so the compressed bytes are correct "
                + "and the fault is in decompression, not on the link."
        }
        return text
    }

    private func finishIncomingMessage(_ payload: Data) -> [Action] {
        guard !incomingQueue.isEmpty else {
            return failSession("internal: completed a body with an empty incoming queue")
        }
        let transfer = incomingQueue.removeFirst()
        let proposal = transfer.proposal
        let sessionBytes = Self.sessionContribution(payload, prefix: transfer.prefix)
        let fullPayload = transfer.prefix + sessionBytes

        let message: WinlinkB2Message
        do {
            let decompressed = try LZHUF.decodeB2F(fullPayload)
            message = try WinlinkB2Message.parse(decompressed)
        } catch {
            // A complete body that fails to decode is corrupt end to end —
            // nothing here is worth saving, and a stitched one proves the
            // saved prefix bad, so drop it for a clean restart next time.
            binaryStreamCorrupt = true
            var actions = [Action]()
            if !transfer.prefix.isEmpty {
                actions.append(.discardPartialBody(mid: proposal.mid))
            }
            // Keep the bytes. This failure is not reproducible on demand —
            // it costs a full re-download to see again — and the numbers
            // below cannot say whether the saved prefix or this session's
            // continuation is at fault. The body itself can.
            actions.append(.captureCorruptBody(
                mid: proposal.mid,
                resumedFrom: transfer.prefix.count,
                declaredSize: proposal.compressedSize,
                data: fullPayload))
            actions.append(contentsOf: failSession(
                Self.describeDecodeFailure(
                    mid: proposal.mid,
                    error: error,
                    prefixBytes: transfer.prefix.count,
                    sessionBytes: sessionBytes.count,
                    declaredSize: proposal.compressedSize,
                    body: fullPayload)))
            return actions
        }

        summary.receivedMIDs.append(message.mid)
        var actions: [Action] = [
            .cancelTimer(.binary),
            .messageFullyReceived(message, compressedSize: fullPayload.count),
        ]
        if config.partialInbound[proposal.mid] != nil {
            actions.append(.discardPartialBody(mid: proposal.mid))
        }

        if incomingQueue.isEmpty {
            // Batch drained — the transfer hands the turn to us (FBB: the
            // station that just received the messages speaks next). Propose
            // our remaining traffic or send FF; the classic trace is
            // "…data… → FF → FQ". Waiting silently here left the gateway
            // holding a turn we never took until it gave up and DISCed
            // (field capture 2026-08-24, CMS via W0ARP-10, ~70 s idle).
            // A remote that volunteers FF/FQ anyway still lands in
            // awaitingRemoteProposals, where both complete the session.
            blockParser = nil
            actions.append(contentsOf: sendNextProposalBatchOrFF())
        } else {
            blockParser = FBBBlockCodec.Parser()
            actions.append(.startTimer(.binary, seconds: 120))
        }
        return actions
    }

    // MARK: - Session termination

    private func completeSession(disconnectRequested: Bool) -> [Action] {
        state = .closing
        var actions: [Action] = [
            .cancelTimer(.banner), .cancelTimer(.response), .cancelTimer(.binary),
        ]
        if disconnectRequested {
            actions.append(sendText("FQ\r"))
        }
        actions.append(.requestDisconnect)
        actions.append(.complete(summary))
        return actions
    }

    private func handleTimeout(_ kind: TimerKind) -> [Action] {
        switch (state, kind) {
        case (.awaitingBanner, .banner):
            return failSession("timed out waiting for the gateway banner")
        case (.awaitingCallerHandshake, .banner):
            // A caller that connects and says nothing must not hold the
            // channel: in an emergency the frequency is shared.
            return failSession("timed out waiting for the caller's handshake")
        case (.awaitingProposalAnswer, .response), (.awaitingRemoteProposals, .response):
            return failSession(config.role == .answering
                ? "timed out waiting for the caller's response"
                : "timed out waiting for the gateway's response")
        case (.receivingBodies, .binary):
            return failSession("timed out waiting for message data")
        default:
            return []  // stale timer from a state we already left
        }
    }

    /// Actions that persist the in-flight body prefix when the session is
    /// ending mid-transfer — or throw away a prefix the stream just proved
    /// wrong.
    private func partialCaptureActions() -> [Action] {
        guard state == .receivingBodies,
              let transfer = incomingQueue.first else { return [] }

        if binaryStreamCorrupt {
            // The bytes on hand are suspect, so none of them may be saved.
            // Crucially, a prefix *already in the store* must be deleted
            // too: it was stitched into the stream that just failed its
            // checksum, so resuming from it again reproduces the same
            // failure at the same offset, forever. Restarting from zero
            // costs one download; keeping a poisoned prefix costs every
            // future one.
            return transfer.prefix.isEmpty
                ? []
                : [.discardPartialBody(mid: transfer.proposal.mid)]
        }

        guard let parser = blockParser else { return [] }
        let sessionBytes = parser.partialPayload
        // Fewer than six bytes into a resumed stream is ambiguous: they may
        // be a re-sent wire header still mid-arrival, or real stream bytes.
        // Stitching a guess would poison the prefix; the stored prefix is
        // still good on its own, so save nothing new and keep it.
        if transfer.prefix.count >= LZHUF.wireHeaderSize,
           !sessionBytes.isEmpty, sessionBytes.count < LZHUF.wireHeaderSize {
            return []
        }
        let data = transfer.prefix + Self.sessionContribution(sessionBytes, prefix: transfer.prefix)
        guard !data.isEmpty, data.count < transfer.proposal.compressedSize else { return [] }
        return [.savePartialBody(
            mid: transfer.proposal.mid,
            compressedSize: transfer.proposal.compressedSize,
            data: data)]
    }

    private func failSession(_ reason: String) -> [Action] {
        let capture = partialCaptureActions()
        state = .failed
        summary.failureReason = reason
        return capture + [
            .cancelTimer(.banner), .cancelTimer(.response), .cancelTimer(.binary),
            .fail(reason: reason),
            .requestDisconnect,
        ]
    }

    private func sendText(_ text: String) -> Action {
        let data = Data(text.unicodeScalars.map { UInt8($0.value & 0xff) })
        summary.bytesSent += data.count
        return .send(data)
    }
}

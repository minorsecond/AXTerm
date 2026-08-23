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

    struct Config {
        var myCallsign: String
        var password: String?
        var sid: WinlinkSID
        var outbound: [PreparedOutbound]

        init(myCallsign: String, password: String? = nil,
             sid: WinlinkSID = .axterm(version: "1.0"),
             outbound: [PreparedOutbound] = []) {
            self.myCallsign = myCallsign
            self.password = password
            self.sid = sid
            self.outbound = outbound
        }
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
        case receiveProgress(mid: String, bytesReceived: Int, totalBytes: Int)
        case requestDisconnect
        case complete(WinlinkExchangeSummary)
        case fail(reason: String)
    }

    enum State: Equatable {
        case idle
        case awaitingBanner
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
    /// Accepted remote proposals still to be received, in order.
    private var incomingQueue: [B2FProposal.Proposal] = []
    private var blockParser: FBBBlockCodec.Parser?

    private var summary = WinlinkExchangeSummary()

    init(config: Config) {
        self.config = config
        self.pendingOutbound = config.outbound
    }

    // MARK: - Event handling

    func handle(_ event: Event) -> [Action] {
        switch event {
        case .connected:
            guard state == .idle else { return [] }
            state = .awaitingBanner
            return [.startTimer(.banner, seconds: 90)]

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
                // Can't interrupt binary politely; just drop the link.
                summary.aborted = true
                state = .closing
                return [.requestDisconnect]
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

        // The parser consumes everything fed to it; feed byte-wise from a
        // buffer so trailing line-mode bytes (after EOT) are preserved.
        var index = data.startIndex
        while index < data.endIndex {
            let byte = data[index]
            index = data.index(after: index)
            for event in parser.feed(Data([byte])) {
                switch event {
                case .header:
                    actions.append(.startTimer(.binary, seconds: 120))
                case .progress(let count):
                    if let current = incomingQueue.first {
                        actions.append(.receiveProgress(
                            mid: current.mid,
                            bytesReceived: count,
                            totalBytes: current.compressedSize))
                    }
                    actions.append(.startTimer(.binary, seconds: 120))
                case .completed(let payload):
                    actions.append(contentsOf: finishIncomingMessage(payload))
                    return Data(data[index...])
                case .checksumFailure:
                    actions.append(contentsOf: failSession("binary block checksum failure"))
                    return Data()
                case .protocolError(let reason):
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
            if lowered.contains("unknown client") || lowered.contains("not allowed")
                || lowered.contains("invalid password") || lowered.contains("login failure") {
                return failSession("the CMS refused the connection: \(notice)")
            }
            return []
        }

        switch state {
        case .awaitingBanner:
            return processBannerLine(line)
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
            proposedBatch = []
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
        incomingQueue = []
        for proposal in remoteProposals {
            // Sanity-check sizes; a hostile or corrupt proposal must not
            // make us buffer unbounded data.
            let acceptable = proposal.kind == .encapsulatedMessage
                && proposal.compressedSize >= 6
                && proposal.compressedSize <= 4 * 1024 * 1024
            if acceptable {
                answers.append(.accept)
                incomingQueue.append(proposal)
            } else {
                answers.append(.reject)
            }
        }

        let fsLine = "FS " + answers.map(\.rendered).joined() + "\r"
        var actions: [Action] = [.cancelTimer(.response), sendText(fsLine)]

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

    private func finishIncomingMessage(_ payload: Data) -> [Action] {
        guard !incomingQueue.isEmpty else {
            return failSession("internal: completed a body with an empty incoming queue")
        }
        let proposal = incomingQueue.removeFirst()

        let message: WinlinkB2Message
        do {
            let decompressed = try LZHUF.decodeB2F(payload)
            message = try WinlinkB2Message.parse(decompressed)
        } catch {
            return failSession("failed to decode incoming message \(proposal.mid): \(error)")
        }

        summary.receivedMIDs.append(message.mid)
        var actions: [Action] = [
            .cancelTimer(.binary),
            .messageFullyReceived(message, compressedSize: payload.count),
        ]

        if incomingQueue.isEmpty {
            // Batch drained — remote either proposes again or ends its turn.
            blockParser = nil
            state = .awaitingRemoteProposals
            actions.append(.startTimer(.response, seconds: 120))
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
        case (.awaitingProposalAnswer, .response), (.awaitingRemoteProposals, .response):
            return failSession("timed out waiting for the gateway's response")
        case (.receivingBodies, .binary):
            return failSession("timed out waiting for message data")
        default:
            return []  // stale timer from a state we already left
        }
    }

    private func failSession(_ reason: String) -> [Action] {
        state = .failed
        summary.failureReason = reason
        return [
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

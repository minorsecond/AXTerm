//
//  YAPPSessionTransfer.swift
//  AXTerm
//
//  Runs one YAPP transfer over one connected AX.25 session.
//
//  YAPP's bytes are foreign protocol bytes (spec §16): they go out as plain
//  PID 0xF0 I-frames, never wrapped in AXDP, and the session's delivered
//  stream is claimed for the length of the transfer so neither the terminal
//  nor AXDP reassembly sees them. The claim is dropped when the transfer
//  ends, and the session layer drops it on its own if the link goes first.
//

import Foundation

@MainActor
final class YAPPSessionTransfer: FileTransferProtocolDelegate {
    enum Role: Equatable { case sending, receiving }

    let role: Role
    let peer: AX25Address
    let path: DigiPath
    let radio: RadioID
    let sessionKey: SessionKey
    let yapp = YAPPProtocol()

    /// The BulkTransfer this drives. A receive has none until the header
    /// says what the file is.
    var transferId: UUID?

    private weak var owner: SessionCoordinator?
    private var claim: SessionDeliveryClaim?
    private var pumpTimer: Timer?
    private var finished = false

    init(role: Role, session: AX25Session, owner: SessionCoordinator, responseTimeout: TimeInterval) {
        self.role = role
        self.peer = session.remoteAddress
        self.path = session.path
        self.radio = session.radio
        self.sessionKey = session.key
        self.owner = owner
        yapp.responseTimeout = responseTimeout
        // Each block with its two header bytes and a possible checksum fits
        // one I-frame, for receivers that read one block per packet.
        // The paclen in use when the transfer starts; it may change later in
        // the session, and the block reader copes with blocks split across
        // I-frames anyway.
        yapp.blockSize = max(1, min(256, session.livePaclen - 3))
        yapp.delegate = self
        yapp.readyForData = { [weak self] in self?.linkHasRoom ?? false }
    }

    /// Takes the session's byte stream. Fails when something else already
    /// holds it (a Winlink exchange, say), because two protocols cannot
    /// share one stream.
    func claimSession() -> Bool {
        guard let manager = owner?.sessionManager else { return false }
        claim = manager.claimDelivery(
            for: sessionKey,
            handler: { [weak self] session, data in
                self?.received(data, on: session)
            },
            stateHandler: { [weak self] session, _, newState in
                guard newState == .disconnected || newState == .error else { return }
                self?.linkLost(timedOut: newState == .error, peer: session.remoteAddress.display)
            },
            ackHandler: { [weak self] _, _ in
                self?.yapp.pumpData()
            })
        return claim != nil
    }

    // MARK: Receiving bytes

    private func received(_ data: Data, on session: AX25Session) {
        // A receive still waiting for its header, handed bytes that cannot
        // start a YAPP frame: the sender is not running YAPP any more (its
        // program quit, or a link reset that only it was told about ended its
        // transfer, spec 7.1.1). Answering with CN printed "The other station
        // sent something that is not YAPP" on a terminal that never asked,
        // and the bytes, a chat line or an AXDP offer, were lost (full-stack
        // fuzz seed 3034, StaleYAPPReceiveTests). Stop without a word and
        // pass them on as if this receive had never claimed the session.
        if role == .receiving, transferId == nil, yapp.isAwaitingHeader,
           !YAPPProtocol.canStartFrame(data), !finished {
            TxLog.inbound(.session, "YAPP start not followed by a header; passing the bytes on", [
                "from": peer.display, "size": data.count
            ])
            finished = true
            yapp.abandon()
            end()
            owner?.sessionManager.deliverUnclaimed(data, on: session)
            return
        }
        yapp.handleIncomingData(data)
    }

    // MARK: Driving

    func startSending(fileName: String, data: Data) throws {
        try yapp.startSending(fileName: fileName, fileData: data)
    }

    /// Feeds the packet that started a receive (the SI) to the protocol.
    func receiveOpening(_ data: Data) {
        yapp.handleIncomingData(data)
    }

    func accept() { yapp.acceptTransfer() }

    func decline(reason: String) {
        yapp.rejectTransfer(reason: reason)
        end()
    }

    func pause() { yapp.pause() }
    func resume() { yapp.resume() }

    /// The last block handed to the session is still queued, whole: none of
    /// it numbered or on the air, nothing else queued with it.
    var lastBlockQueuedWhole = false

    func cancel() {
        guard !yapp.state.isTerminal else {
            end()
            return
        }
        // The cancel goes out behind whatever is queued, and on a slow link
        // the other station heard it 38 s late (smoke run 2026-10-03-1,
        // issue 19). A block still queued whole has never been on the air,
        // so it is dropped and the CN is next. Frames already in the window
        // are numbered and must still be delivered.
        stopPumping()
        if lastBlockQueuedWhole {
            owner?.sessionManager.discardQueuedData(for: sessionKey)
            lastBlockQueuedWhole = false
        }
        // Keep the claim until the other side's CA arrives (or the wait for
        // it runs out), so those two bytes are not typed into the terminal.
        yapp.onCancelSettled = { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
        yapp.cancel()
    }

    /// The link went away under the transfer.
    private func linkLost(timedOut: Bool, peer: String) {
        guard !finished else { return }
        finished = true
        stopPumping()
        yapp.abandon()
        claim = nil  // The session layer drops claims on disconnect itself.
        owner?.yappTransfer(self, failedWith: TransferLinkLoss.reason(peer: peer, timedOut: timedOut),
                            canceledByPeer: false)
        owner?.yappTransferEnded(self)
    }

    /// Releases the session and forgets this transfer.
    func end() {
        stopPumping()
        if let claim { owner?.sessionManager.releaseDelivery(claim) }
        claim = nil
        owner?.yappTransferEnded(self)
    }

    // MARK: Link pacing

    /// Room for another block: nothing of ours is still queued behind the
    /// window. The session sends what it queues, so one block waiting there
    /// is enough to keep the channel busy.
    private var linkHasRoom: Bool {
        guard let session = owner?.sessionManager.sessions[sessionKey],
              session.state == .connected else { return false }
        return session.pendingDataQueue.isEmpty
    }

    private func startPumping() {
        guard pumpTimer == nil else { return }
        // Acks also pump (see the claim's ackHandler). The timer covers a
        // window that opens without one reaching us, such as a queue drained
        // by a retransmit.
        pumpTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.yapp.pumpData() }
        }
    }

    private func stopPumping() {
        pumpTimer?.invalidate()
        pumpTimer = nil
    }

    // MARK: FileTransferProtocolDelegate
    //
    // The protocol calls these on the main thread: it is driven from
    // session delivery and main-run-loop timers only.

    nonisolated func transferProtocol(_ transfer: FileTransferProtocol, needsToSend data: Data) {
        MainActor.assumeIsolated {
            owner?.yappTransfer(self, send: data)
        }
    }

    nonisolated func transferProtocol(_ transfer: FileTransferProtocol, didUpdateProgress progress: Double, bytesSent: Int) {
        MainActor.assumeIsolated {
            owner?.yappTransfer(self, progressed: bytesSent)
        }
    }

    nonisolated func transferProtocol(_ transfer: FileTransferProtocol, didComplete successfully: Bool, error: String?) {
        MainActor.assumeIsolated {
            guard !finished else { return }
            finished = true
            stopPumping()
            if successfully {
                if role == .sending { owner?.yappTransferSucceeded(self) }
                end()
            } else {
                let byPeer = (error ?? "").hasPrefix("Canceled by the other station")
                if error != "Canceled" {
                    owner?.yappTransfer(self, failedWith: error ?? "The transfer failed", canceledByPeer: byPeer)
                }
                // A local cancel ends itself after the CA grace period.
                if error != "Canceled" { end() }
            }
        }
    }

    nonisolated func transferProtocol(_ transfer: FileTransferProtocol, didReceiveFile data: Data, metadata: TransferFileMetadata) {
        MainActor.assumeIsolated {
            owner?.yappTransfer(self, received: data, name: metadata.fileName)
        }
    }

    nonisolated func transferProtocol(_ transfer: FileTransferProtocol, requestsConfirmation metadata: TransferFileMetadata) {
        MainActor.assumeIsolated {
            owner?.yappTransfer(self, offers: metadata)
        }
    }

    nonisolated func transferProtocol(_ transfer: FileTransferProtocol, stateChanged newState: TransferProtocolState) {
        MainActor.assumeIsolated {
            if newState == .transferring, role == .sending { startPumping() }
            if newState.isTerminal || newState == .paused { stopPumping() }
            owner?.yappTransfer(self, changedTo: newState)
        }
    }
}

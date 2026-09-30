//
//  SessionCoordinator+FileTransfers.swift
//  AXTerm
//
//  The parts of packet file transfer that sit around the AXDP wire code in
//  SessionCoordinator.swift: pause, resume and cancel; what happens when a
//  session drops or a transfer goes quiet; how offers are judged; YAPP over
//  a connected session; and telling the operator when a transfer ends.
//
//  Living in the coordinator rather than a view is the point. The coordinator
//  exists for the whole life of the app on both platforms, so an offer that
//  arrives while the operator is on the map is judged and prompted for the
//  same way as one that arrives with the terminal on screen.
//

import Foundation

nonisolated extension BulkTransferStatus {
    /// Finished one way or another. Nothing more will happen to it.
    var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .failed: return true
        default: return false
        }
    }
}

extension SessionCoordinator {

    // MARK: - Pause, resume, cancel

    /// Stops sending after the chunk or block already handed to the link.
    /// Only outbound transfers pause: a receiver cannot make the sender stop.
    func pauseTransfer(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }), transfers[index].canPause else { return }
        yappTransfers[id]?.pause()
        transfers[index].status = .paused
    }

    /// Picks a paused transfer up where it stopped.
    ///
    /// Setting the status back is not enough on its own: pausing ended the
    /// chunk loop, so something has to start it again. That is what was
    /// missing when resume left transfers showing "Sending" forever.
    func resumeTransfer(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }),
              transfers[index].status == .paused else { return }
        transfers[index].status = .sending
        if let runner = yappTransfers[id] {
            runner.resume()
            return
        }
        guard let route = transferRoutes[id], let sessionId = transferSessionIds[id] else { return }
        // A chunk timer from before the pause may still be pending, and it
        // carries the loop on by itself now the status is .sending again.
        guard !chunkLoopScheduled.contains(id) else { return }
        sendNextChunk(for: id, to: route.destination, path: route.path, axdpSessionId: sessionId)
    }

    /// Stops a transfer and tells the other station.
    ///
    /// AXDP has no abort message of its own, so cancel sends the NACK a
    /// receiver sends to decline (session ID, message ID 1). An older AXTerm
    /// reads it as "declined" and stops; a newer one reads it as canceled.
    /// YAPP sends CN, its cancel frame.
    func cancelTransfer(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }), transfers[index].canCancel else { return }
        transfersEndedLocally.insert(id)

        if pendingIncomingTransfers.contains(where: { $0.id == id }) {
            declineIncomingTransfer(id)
            return
        }
        if let runner = yappTransfers[id] {
            runner.cancel()
            setStatus(.cancelled, for: id)
            return
        }
        sendAXDPCancel(for: id)
        setStatus(.cancelled, for: id)
    }

    /// The NACK that ends an AXDP transfer at the other end, best effort.
    func sendAXDPCancel(for id: UUID) {
        guard let transfer = transfers.first(where: { $0.id == id }) else { return }
        let nack: (UInt32, AX25Address)?
        switch transfer.direction {
        case .outbound:
            if let sessionId = transferSessionIds[id], let route = transferRoutes[id] {
                nack = (sessionId, route.destination)
            } else {
                nack = nil
            }
        case .inbound:
            if let sessionId = axdpToTransferId.first(where: { $0.value == id })?.key,
               let state = inboundTransferStates[sessionId] {
                nack = (sessionId, CallsignNormalizer.toAddress(state.sourceCallsign))
            } else {
                nack = nil
            }
        }
        guard let (sessionId, peer) = nack else { return }
        let path = sessionManager.connectedSession(withPeer: peer)?.path
            ?? transferRoutes[id]?.path ?? DigiPath()
        let message = AXDP.Message(type: .nack, sessionId: sessionId, messageId: 1)
        _ = sendAXDPPayload(message.encode(), to: peer, path: path, displayInfo: "AXDP NACK (cancel transfer)")
    }

    func setStatus(_ status: BulkTransferStatus, for id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }),
              !transfers[index].status.isTerminal else { return }
        transfers[index].status = status
    }

    /// Fails a transfer with a reason, unless it already ended.
    func failTransfer(_ id: UUID, reason: String) {
        pendingIncomingTransfers.removeAll { $0.id == id }
        setStatus(.failed(reason: reason), for: id)
    }

    // MARK: - Link loss

    /// Fails every transfer riding a session with `peer`, which just closed
    /// or timed out. Transfers sent by UI frames are not tied to a session
    /// and are left to the watchdog.
    func failTransfersOnLinkLoss(peer: AX25Address, timedOut: Bool) {
        let key = peer.display.uppercased()
        let reason = TransferLinkLoss.reason(peer: peer.display, timedOut: timedOut)
        for (id, boundPeer) in sessionBoundTransferPeers where boundPeer == key {
            yappTransfers[id]?.yapp.abandon()
            failTransfer(id, reason: reason)
        }
        for runner in yappAwaitingHeader.values where runner.peer == peer {
            runner.yapp.abandon()
            runner.end()
        }
    }

    // MARK: - Watchdog

    /// Starts the periodic check for transfers nobody is answering. It stops
    /// itself when no transfer is left running.
    func startTransferWatchdogIfNeeded() {
        guard transferWatchdogTask == nil else { return }
        transferWatchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let interval = self?.transferWatchdogInterval ?? 5
                try? await Task.sleep(nanoseconds: UInt64(max(0.01, interval) * 1_000_000_000))
                guard let self else { return }
                if !self.runTransferWatchdog() {
                    self.transferWatchdogTask = nil
                    return
                }
            }
        }
    }

    /// One pass of the watchdog. Returns whether any transfer is still running.
    @discardableResult
    func runTransferWatchdog(now: Date = Date()) -> Bool {
        var running = false
        for transfer in transfers where !transfer.status.isTerminal {
            running = true
            let idle = now.timeIntervalSince(transferLastActivity[transfer.id] ?? now)
            guard let reason = TransferWatchdog.verdict(
                status: transfer.status, direction: transfer.direction,
                idle: idle, peer: transfer.destination, timeouts: transferTimeouts) else { continue }
            TxLog.warning(.session, "Transfer timed out", [
                "file": transfer.fileName,
                "peer": transfer.destination,
                "status": String(describing: transfer.status),
                "idle": Int(idle)
            ])
            // Tell the other side on the way out, in case it is still there
            // and only this direction failed.
            if let runner = yappTransfers[transfer.id] {
                runner.cancel()
            } else {
                sendAXDPCancel(for: transfer.id)
            }
            failTransfer(transfer.id, reason: reason)
        }
        return running
    }

    // MARK: - Watching transfers end

    /// Called for every change to `transfers`. Notes activity for the
    /// watchdog, and catches the moment each transfer ends.
    func transfersDidChange(from old: [BulkTransfer]) {
        let previous = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var anyRunning = false
        let now = Date()
        for transfer in transfers {
            let before = previous[transfer.id]
            if before == nil || before?.status != transfer.status
                || before?.bytesSent != transfer.bytesSent
                || before?.completedChunks != transfer.completedChunks {
                transferLastActivity[transfer.id] = now
            }
            if transfer.status.isTerminal {
                if let before, !before.status.isTerminal { transferEnded(transfer) }
            } else {
                anyRunning = true
            }
        }
        if anyRunning { startTransferWatchdogIfNeeded() }
    }

    /// Tells the operator how a transfer ended (unless they ended it) and
    /// empties the per-transfer maps, so nothing is left to leak or to match
    /// a stray NACK against later.
    private func transferEnded(_ transfer: BulkTransfer) {
        let id = transfer.id
        let endedHere = transfersEndedLocally.remove(id) != nil
        let peer = transfer.destination

        switch transfer.status {
        case .completed:
            if let seconds = transfer.dataPhaseDurationSeconds, seconds >= 1, transfer.transmissionSize > 0 {
                measuredTransferRates[peer.uppercased()] = Double(transfer.transmissionSize) / seconds
            }
            notifyTransfer(.completed(fileName: transfer.fileName, peer: peer, direction: transfer.direction))
        case .failed(let reason):
            if !endedHere { notifyTransfer(.failed(fileName: transfer.fileName, peer: peer, reason: reason)) }
        case .cancelled:
            if !endedHere { notifyTransfer(.canceledByPeer(fileName: transfer.fileName, peer: peer)) }
        default:
            break
        }

        transferFileData.removeValue(forKey: id)
        transferSessionIds.removeValue(forKey: id)
        transferCompressionAlgorithms.removeValue(forKey: id)
        transferRoutes.removeValue(forKey: id)
        sessionBoundTransferPeers.removeValue(forKey: id)
        transferLastActivity.removeValue(forKey: id)
        for (sessionId, transferId) in transfersAwaitingAcceptance where transferId == id {
            transfersAwaitingAcceptance.removeValue(forKey: sessionId)
        }
        for (sessionId, transferId) in axdpToTransferId where transferId == id {
            axdpToTransferId.removeValue(forKey: sessionId)
            inboundTransferStates.removeValue(forKey: sessionId)
        }
        if pendingIncomingTransfers.contains(where: { $0.id == id }) {
            pendingIncomingTransfers.removeAll { $0.id == id }
        }
    }

    func notifyTransfer(_ event: TransferNotificationEvent) {
        packetEngine?.notificationScheduler?.scheduleTransferNotification(event)
    }

    // MARK: - Offers

    /// Judges an offer the moment it arrives: deny list, size cap, allow
    /// list, and only then the operator. Runs here rather than in a view so
    /// the rules hold whatever is on screen, or with no window open at all.
    func applyOfferPolicy(to request: IncomingTransferRequest) {
        let policy = appSettings?.fileTransferOfferPolicy
            ?? TransferOfferPolicy(allowed: [], denied: [], maxBytes: TransferOfferPolicy.defaultMaxBytes)
        switch policy.decide(callsign: request.sourceCallsign, fileSize: request.fileSize) {
        case .accept(let reason):
            TxLog.inbound(.session, "Auto-accepted file transfer", [
                "from": request.sourceCallsign, "file": request.fileName, "size": request.fileSize
            ])
            packetEngine?.appendSystemNotification(
                "Accepted \(request.fileName) from \(request.sourceCallsign): \(reason).")
            acceptIncomingTransfer(request.id)
        case .decline(let reason):
            TxLog.inbound(.session, "Auto-declined file transfer", [
                "from": request.sourceCallsign, "file": request.fileName, "size": request.fileSize,
                "reason": reason
            ])
            packetEngine?.appendSystemNotification(
                "Declined \(request.fileName) from \(request.sourceCallsign): \(reason).")
            declineIncomingTransfer(request.id, reason: reason)
        case .ask:
            notifyTransfer(.offer(from: request.sourceCallsign, fileName: request.fileName,
                                  fileSize: request.fileSize))
        }
    }

    /// Airtime for `bytes` at the rate measured on the last finished transfer
    /// with `peer`, or nil when there has not been one.
    func estimatedAirtime(bytes: Int, peer: String) -> TimeInterval? {
        TransferAirtimeEstimate.seconds(bytes: bytes, bytesPerSecond: measuredTransferRates[peer.uppercased()])
    }

    // MARK: - YAPP: sending

    /// Sends a file by YAPP over the connected session with `destination`.
    func startYAPPTransfer(to destination: String, fileName: String, data: Data, path: DigiPath) -> String? {
        let address = CallsignNormalizer.toAddress(destination)
        guard let session = sessionManager.connectedSession(withPeer: address) else {
            return "Cannot send file: YAPP requires a connected session. Connect to \(destination) first."
        }
        // YAPP takes the session's whole byte stream, which would starve an
        // AXDP transfer already running on it.
        guard activeTransferCount(withPeer: session.remoteAddress) == 0 else {
            return "Cannot send file: a transfer with \(destination) is already running. "
                + "Wait for it to finish first."
        }
        let runner = YAPPSessionTransfer(role: .sending, session: session, owner: self,
                                         responseTimeout: yappResponseTimeout)
        guard runner.claimSession() else {
            return "Cannot send file: the session with \(destination) is busy with another exchange."
        }

        var transfer = BulkTransfer(
            id: UUID(),
            fileName: fileName,
            fileSize: data.count,
            destination: session.remoteAddress.display,
            chunkSize: runner.yapp.blockSize,
            direction: .outbound,
            transferProtocol: .yapp,
            compressionSettings: .disabled)
        transfer.status = .awaitingAcceptance
        runner.transferId = transfer.id
        yappTransfers[transfer.id] = runner
        sessionBoundTransferPeers[transfer.id] = session.remoteAddress.display.uppercased()
        transfers.append(transfer)

        do {
            try runner.startSending(fileName: fileName, data: data)
        } catch {
            runner.end()
            failTransfer(transfer.id, reason: error.localizedDescription)
            return error.localizedDescription
        }
        TxLog.outbound(.session, "Started YAPP send", [
            "file": fileName, "size": data.count, "dest": session.remoteAddress.display
        ])
        return nil
    }

    /// Transfers with `peer` that have not ended, plus a YAPP receive still
    /// waiting for its header.
    func activeTransferCount(withPeer peer: AX25Address) -> Int {
        let running = transfers.filter {
            !$0.status.isTerminal && CallsignNormalizer.addressMatchesDisplay(peer, $0.destination)
        }.count
        let opening = yappAwaitingHeader.values.filter { $0.peer == peer }.count
        return running + opening
    }

    // MARK: - YAPP: receiving

    /// Starts a YAPP receive when a terminal session delivers SI and nothing
    /// else is being transferred with that station. See `YAPPReceiveDetector`.
    func interceptUnclaimedDelivery(session: AX25Session, data: Data) -> Bool {
        // Every terminal packet passes through here; the size check is the
        // cheap one, so it goes first.
        guard data.count == 2, YAPPReceiveDetector.shouldStart(
            packet: data, activeTransfersWithPeer: activeTransferCount(withPeer: session.remoteAddress)) else {
            return false
        }
        let runner = YAPPSessionTransfer(role: .receiving, session: session, owner: self,
                                         responseTimeout: yappResponseTimeout)
        guard runner.claimSession() else { return false }
        yappAwaitingHeader[session.key] = runner
        TxLog.inbound(.session, "YAPP send-init received", ["from": session.remoteAddress.display])
        packetEngine?.appendSystemNotification(
            "\(session.remoteAddress.display) is starting a YAPP file transfer.")
        runner.receiveOpening(data)
        return true
    }

    // MARK: - YAPP: runner callbacks

    func yappTransfer(_ runner: YAPPSessionTransfer, send data: Data) {
        // Never through a session that is not up: sendData on a closed
        // session opens a new link, and a transfer that ended must not
        // reconnect to anybody.
        guard let session = sessionManager.sessions[runner.sessionKey], session.state == .connected else { return }
        let frames = sessionManager.sendData(
            data, to: runner.peer, path: runner.path, radio: runner.radio, pid: 0xF0,
            displayInfo: "YAPP (\(data.count) bytes)")
        for frame in frames { sendFrame(frame) }
    }

    func yappTransfer(_ runner: YAPPSessionTransfer, progressed bytes: Int) {
        guard let id = runner.transferId, let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        var transfer = transfers[index]
        guard !transfer.status.isTerminal else { return }
        if transfer.dataPhaseStartedAt == nil {
            let now = Date()
            transfer.dataPhaseStartedAt = now
            transfer.startedAt = now
        }
        // Blocks count as chunks, so the row's chunk counter moves too.
        let blocks = transfer.chunkSize > 0 ? (bytes + transfer.chunkSize - 1) / transfer.chunkSize : 0
        for block in 0..<blocks where block >= transfer.completedChunks {
            transfer.markChunkCompleted(block)
        }
        transfer.bytesSent = bytes
        transfer.bytesTransmitted = bytes
        if transfer.status == .pending || transfer.status == .awaitingAcceptance {
            transfer.status = .sending
        }
        transfers[index] = transfer
    }

    func yappTransfer(_ runner: YAPPSessionTransfer, changedTo state: TransferProtocolState) {
        guard let id = runner.transferId, let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        let status = transfers[index].status
        guard !status.isTerminal else { return }
        switch state {
        case .transferring where status == .pending || status == .awaitingAcceptance:
            transfers[index].status = .sending
        case .waitingForAck where runner.role == .sending:
            // All blocks sent; waiting for AF and AT.
            transfers[index].dataPhaseCompletedAt = Date()
            transfers[index].status = .awaitingCompletion
        default:
            break
        }
    }

    func yappTransferSucceeded(_ runner: YAPPSessionTransfer) {
        guard let id = runner.transferId, let index = transfers.firstIndex(where: { $0.id == id }),
              !transfers[index].status.isTerminal else { return }
        var transfer = transfers[index]
        transfer.markCompleted()
        transfers[index] = transfer
    }

    func yappTransfer(_ runner: YAPPSessionTransfer, failedWith reason: String, canceledByPeer: Bool) {
        guard let id = runner.transferId else { return }
        pendingIncomingTransfers.removeAll { $0.id == id }
        setStatus(canceledByPeer ? .cancelled : .failed(reason: reason), for: id)
    }

    /// The header arrived: now there is a file to offer the operator.
    func yappTransfer(_ runner: YAPPSessionTransfer, offers metadata: TransferFileMetadata) {
        yappAwaitingHeader.removeValue(forKey: runner.sessionKey)
        let id = UUID()
        runner.transferId = id
        yappTransfers[id] = runner
        let policy = appSettings?.fileTransferOfferPolicy
        if let cap = policy?.maxBytes, cap > 0 { runner.yapp.maxReceiveBytes = cap }

        var transfer = BulkTransfer(
            id: id,
            fileName: metadata.fileName,
            fileSize: metadata.fileSize,
            destination: runner.peer.display,
            chunkSize: 128,
            direction: .inbound,
            transferProtocol: .yapp,
            compressionSettings: .disabled)
        transfer.status = .pending
        sessionBoundTransferPeers[id] = runner.peer.display.uppercased()
        transfers.append(transfer)

        let request = IncomingTransferRequest(
            id: id,
            sourceCallsign: runner.peer.display,
            fileName: metadata.fileName,
            fileSize: metadata.fileSize,
            axdpSessionId: 0,
            transferProtocol: .yapp,
            estimatedAirtimeSeconds: estimatedAirtime(bytes: metadata.fileSize, peer: runner.peer.display))
        pendingIncomingTransfers.append(request)
        applyOfferPolicy(to: request)
    }

    func yappTransfer(_ runner: YAPPSessionTransfer, received data: Data, name: String) {
        guard let id = runner.transferId, let index = transfers.firstIndex(where: { $0.id == id }),
              !transfers[index].status.isTerminal else { return }
        var transfer = transfers[index]
        if let path = saveReceivedFile(fileName: name, data: data) {
            transfer.savedFilePath = path
            transfer.bytesSent = data.count
            transfer.markCompleted()
        } else {
            transfer.status = .failed(reason: "The file arrived but could not be saved in \(ReceivedFileStore.folderName).")
        }
        transfers[index] = transfer
    }

    func yappTransferEnded(_ runner: YAPPSessionTransfer) {
        if let id = runner.transferId, yappTransfers[id] === runner {
            yappTransfers.removeValue(forKey: id)
        }
        if yappAwaitingHeader[runner.sessionKey] === runner {
            yappAwaitingHeader.removeValue(forKey: runner.sessionKey)
        }
    }
}

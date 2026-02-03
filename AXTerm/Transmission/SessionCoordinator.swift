//
//  SessionCoordinator.swift
//  AXTerm
//
//  Coordinates AX.25 session management across the app.
//  Lives at the ContentView level to survive tab switches.
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 7
//

import Foundation
import Combine
import SwiftUI
import CommonCrypto

/// Coordinates session management and file transfers across the app.
/// This class is owned by ContentView and passed down to child views.
@MainActor
final class SessionCoordinator: ObservableObject {
    /// The session manager for connected-mode operations
    let sessionManager = AX25SessionManager()

    /// Bulk transfers in progress
    @Published var transfers: [BulkTransfer] = []

    /// Pending incoming transfers waiting for accept/decline
    @Published var pendingIncomingTransfers: [IncomingTransferRequest] = []

    /// Local callsign (synced from settings)
    @Published var localCallsign: String = "NOCALL" {
        didSet {
            updateSessionManagerCallsign()
        }
    }

    /// Reference to PacketEngine for sending frames
    weak var packetEngine: PacketEngine?

    /// Cancellables for subscriptions
    private var cancellables = Set<AnyCancellable>()

    /// File data cache for active transfers (keyed by transfer ID)
    private var transferFileData: [UUID: Data] = [:]

    /// Session IDs for AXDP transfers (keyed by transfer ID)
    private var transferSessionIds: [UUID: UInt32] = [:]

    /// Inbound transfer states (keyed by AXDP session ID)
    private var inboundTransferStates: [UInt32: InboundTransferState] = [:]

    /// Map from AXDP session ID to BulkTransfer ID for UI updates
    private var axdpToTransferId: [UInt32: UUID] = [:]

    /// Pending capability discovery requests (callsign -> timestamp)
    /// Used to track which stations we've sent PING to but haven't received PONG from
    private var pendingCapabilityDiscovery: [String: Date] = [:]

    /// Timeout for capability discovery (seconds)
    private let capabilityDiscoveryTimeout: TimeInterval = 30.0

    /// Callback for capability discovery events (for debug display)
    var onCapabilityEvent: ((CapabilityDebugEvent) -> Void)?

    /// Transfers awaiting acceptance (AXDP session ID -> transfer ID)
    /// Used to map ACK/NACK responses to the correct transfer
    private var transfersAwaitingAcceptance: [UInt32: UUID] = [:]

    /// Global adaptive settings (for compression, etc.)
    var globalAdaptiveSettings: TxAdaptiveSettings = TxAdaptiveSettings()

    init() {
        setupCallbacks()
    }

    // MARK: - Setup

    private func setupCallbacks() {
        // Wire up response frame sending
        sessionManager.onRetransmitFrame = { [weak self] frame in
            self?.sendFrame(frame)
        }

        // Wire up session state changes for automatic capability discovery
        sessionManager.onSessionStateChanged = { [weak self] session, oldState, newState in
            guard let self = self else { return }

            // Force UI update for any session state change - ensures both stations update
            self.objectWillChange.send()

            // When a session becomes connected AND we are the initiator, send AXDP PING
            // The responder will receive PING and reply with PONG
            if oldState != .connected && newState == .connected {
                if session.isInitiator {
                    self.sendCapabilityPing(to: session)
                    TxLog.debug(.capability, "Session connected (initiator), sending AXDP PING", [
                        "peer": session.remoteAddress.display
                    ])
                } else {
                    TxLog.debug(.capability, "Session connected (responder), waiting for PING from initiator", [
                        "peer": session.remoteAddress.display
                    ])
                }
            }

            // When a session disconnects, invalidate cached capabilities
            // This ensures we re-discover on next connection (station might switch software)
            if oldState == .connected && (newState == .disconnected || newState == .error) {
                self.invalidateCapability(for: session.remoteAddress.display)
            }
        }
    }

    /// Invalidate cached capability for a station
    /// Called when session disconnects to ensure fresh discovery on next connection
    private func invalidateCapability(for callsign: String) {
        let call = callsign.uppercased()

        // Clear from capability store
        packetEngine?.capabilityStore.remove(for: call)

        // Clear pending discovery status
        pendingCapabilityDiscovery.removeValue(forKey: call)

        TxLog.debug(.capability, "Invalidated capability cache", [
            "peer": callsign
        ])
    }

    /// Send an AXDP PING to a connected session to discover capabilities
    private func sendCapabilityPing(to session: AX25Session) {
        let peerCallsign = session.remoteAddress.display.uppercased()

        // Don't send if we already know their capability or discovery is pending
        if hasConfirmedAXDPCapability(for: peerCallsign) {
            TxLog.debug(.capability, "Skipping PING - capability already confirmed", [
                "peer": peerCallsign
            ])
            return
        }

        if isCapabilityDiscoveryPending(for: peerCallsign) {
            TxLog.debug(.capability, "Skipping PING - discovery already pending", [
                "peer": peerCallsign
            ])
            return
        }

        let localCaps = AXDPCapability.defaultLocal()
        let pingMessage = AXDP.Message(
            type: .ping,
            sessionId: UInt32(session.id.hashValue & 0xFFFFFFFF),
            messageId: 1,
            capabilities: localCaps
        )

        // For connected sessions, use I-frames
        let frame = OutboundFrame(
            destination: session.remoteAddress,
            source: sessionManager.localCallsign,
            path: session.path,
            payload: pingMessage.encode(),
            frameType: "i",
            displayInfo: "AXDP PING"
        )

        // Track that we're waiting for a response
        pendingCapabilityDiscovery[peerCallsign] = Date()

        sendFrame(frame)

        TxLog.outbound(.capability, "Sent AXDP PING via session", [
            "dest": session.remoteAddress.display,
            "features": localCaps.features.description
        ])

        // Emit debug event for PING sent
        onCapabilityEvent?(CapabilityDebugEvent(
            type: .pingSent,
            peer: session.remoteAddress.display,
            capabilities: localCaps
        ))
    }

    /// Send an AXDP PONG response to a received PING
    private func sendCapabilityPong(to address: AX25Address, path: DigiPath, sessionId: UInt32, messageId: UInt32) {
        let localCaps = AXDPCapability.defaultLocal()
        let pongMessage = AXDP.Message(
            type: .pong,
            sessionId: sessionId,
            messageId: messageId,
            capabilities: localCaps
        )

        // Respond via UI frame if not in a session, or I-frame if connected
        let session = sessionManager.sessions.values.first { $0.remoteAddress == address && $0.state == .connected }
        let frameType = session != nil ? "i" : "ui"

        let frame = OutboundFrame(
            destination: address,
            source: sessionManager.localCallsign,
            path: path,
            payload: pongMessage.encode(),
            frameType: frameType,
            displayInfo: "AXDP PONG"
        )

        sendFrame(frame)

        TxLog.outbound(.capability, "Sent AXDP PONG", [
            "dest": address.display,
            "features": localCaps.features.description
        ])

        // Emit debug event for PONG sent
        onCapabilityEvent?(CapabilityDebugEvent(
            type: .pongSent,
            peer: address.display,
            capabilities: localCaps
        ))
    }

    private func updateSessionManagerCallsign() {
        let input = localCallsign.isEmpty ? "NOCALL" : localCallsign
        let parts = input.uppercased().split(separator: "-")
        let baseCall = String(parts.first ?? "NOCALL")
        let ssid = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        sessionManager.localCallsign = AX25Address(call: baseCall, ssid: ssid)
    }

    /// Subscribe to incoming packets from PacketEngine
    func subscribeToPackets(from client: PacketEngine) {
        self.packetEngine = client

        client.packetPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] packet in
                self?.handleIncomingPacket(packet)
            }
            .store(in: &cancellables)
    }

    /// Send a frame via PacketEngine
    private func sendFrame(_ frame: OutboundFrame) {
        packetEngine?.send(frame: frame) { result in
            Task { @MainActor in
                switch result {
                case .success:
                    TxLog.outbound(.session, "Frame sent", [
                        "type": frame.frameType,
                        "dest": frame.destination.display
                    ])
                case .failure(let error):
                    TxLog.error(.session, "Frame send failed", error: error)
                }
            }
        }
    }

    // MARK: - Connected Sessions

    /// Returns all sessions that are currently connected
    var connectedSessions: [AX25Session] {
        sessionManager.sessions.values.filter { $0.state == .connected }
    }

    /// Returns callsigns of all connected stations
    var connectedCallsigns: [String] {
        connectedSessions.map { $0.remoteAddress.display }
    }

    // MARK: - Packet Handling

    private func handleIncomingPacket(_ packet: Packet) {
        guard let from = packet.from, let to = packet.to else {
            return
        }

        let decoded = AX25ControlFieldDecoder.decode(control: packet.control, controlByte1: packet.controlByte1)
        let localCall = sessionManager.localCallsign.call.uppercased()
        let toCall = to.call.uppercased()

        // Only process packets addressed to us
        guard toCall == localCall else { return }

        let channel: UInt8 = 0

        switch decoded.frameClass {
        case .U:
            handleUFrame(packet: packet, from: from, to: to, uType: decoded.uType, channel: channel)
        case .I:
            handleIFrame(packet: packet, from: from, ns: decoded.ns ?? 0, nr: decoded.nr ?? 0, pf: (decoded.pf ?? 0) == 1, channel: channel)
        case .S:
            handleSFrame(packet: packet, from: from, sType: decoded.sType, nr: decoded.nr ?? 0, pf: decoded.pf ?? 0, channel: channel)
        case .unknown:
            break
        }
    }

    private func handleUFrame(packet: Packet, from: AX25Address, to: AX25Address, uType: AX25UType?, channel: UInt8) {
        guard let uType = uType else { return }

        let path = DigiPath.from(packet.via.map { $0.display })

        switch uType {
        case .UA:
            sessionManager.handleInboundUA(from: from, path: path, channel: channel)
        case .DM:
            sessionManager.handleInboundDM(from: from, path: path, channel: channel)
        case .DISC:
            if let responseFrame = sessionManager.handleInboundDISC(from: from, path: path, channel: channel) {
                sendFrame(responseFrame)
            }
        case .SABM, .SABME:
            if let uaFrame = sessionManager.handleInboundSABM(
                from: from,
                to: to,
                path: path,
                channel: channel
            ) {
                sendFrame(uaFrame)
            }
        case .UI:
            // UI frames can contain AXDP messages (capability discovery, file transfers)
            handleAXDPMessage(from: from, path: path, payload: packet.info)
        default:
            break
        }
    }

    private func handleIFrame(packet: Packet, from: AX25Address, ns: Int, nr: Int, pf: Bool, channel: UInt8) {
        let path = DigiPath.from(packet.via.map { $0.display })
        if let rrFrame = sessionManager.handleInboundIFrame(
            from: from,
            path: path,
            channel: channel,
            ns: ns,
            nr: nr,
            pf: pf,
            payload: packet.info
        ) {
            sendFrame(rrFrame)
        }

        // Handle all AXDP messages (capabilities, file transfers, etc.)
        handleAXDPMessage(from: from, path: path, payload: packet.info)
    }

    /// Handle all AXDP messages from incoming packets.
    /// Routes to appropriate handlers based on message type.
    private func handleAXDPMessage(from: AX25Address, path: DigiPath, payload: Data) {
        guard AXDP.hasMagic(payload) else { return }
        guard let message = AXDP.Message.decode(from: payload) else { return }

        switch message.type {
        case .ping, .pong:
            handleCapabilityMessage(message, from: from, path: path)

        case .fileMeta:
            handleFileMetaMessage(message, from: from, path: path)

        case .fileChunk:
            handleFileChunkMessage(message, from: from)

        case .ack:
            handleAckMessage(message, from: from)

        case .nack:
            handleNackMessage(message, from: from)

        default:
            TxLog.debug(.axdp, "Unhandled AXDP message type", [
                "type": String(describing: message.type),
                "from": from.display
            ])
        }
    }

    /// Handle PING/PONG capability messages
    /// This method is internal to allow testing
    func handleCapabilityMessage(_ message: AXDP.Message, from: AX25Address, path: DigiPath) {
        guard let caps = message.capabilities else { return }

        let peerCallsign = from.display.uppercased()

        // Store capabilities in the capability store
        packetEngine?.capabilityStore.store(caps, for: from.call, ssid: from.ssid)

        // Clear pending discovery if this was a PONG response
        if message.type == .pong {
            pendingCapabilityDiscovery.removeValue(forKey: peerCallsign)
            TxLog.debug(.capability, "AXDP capability confirmed", [
                "peer": from.display,
                "protoMax": caps.protoMax,
                "features": caps.features.description
            ])

            // Emit debug event for PONG received
            onCapabilityEvent?(CapabilityDebugEvent(
                type: .pongReceived,
                peer: from.display,
                capabilities: caps
            ))
        } else if message.type == .ping {
            TxLog.debug(.capability, "Detected AXDP capabilities via PING", [
                "peer": from.display,
                "protoMax": caps.protoMax,
                "features": caps.features.description
            ])

            // Emit debug event for PING received
            onCapabilityEvent?(CapabilityDebugEvent(
                type: .pingReceived,
                peer: from.display,
                capabilities: caps
            ))
        }

        // If we received a PING, respond with PONG to share our capabilities
        if message.type == .ping {
            sendCapabilityPong(
                to: from,
                path: path,
                sessionId: message.sessionId,
                messageId: message.messageId
            )
        }
    }

    /// Handle incoming FILE_META message - creates pending transfer request
    private func handleFileMetaMessage(_ message: AXDP.Message, from: AX25Address, path: DigiPath) {
        guard let fileMeta = message.fileMeta else {
            TxLog.warning(.axdp, "FILE_META missing metadata", ["from": from.display])
            return
        }

        let axdpSessionId = message.sessionId

        // Check if we already have this transfer
        if inboundTransferStates[axdpSessionId] != nil {
            TxLog.debug(.axdp, "Duplicate FILE_META received", [
                "session": axdpSessionId,
                "file": fileMeta.filename
            ])
            return
        }

        TxLog.inbound(.axdp, "Received FILE_META", [
            "from": from.display,
            "file": fileMeta.filename,
            "size": fileMeta.fileSize,
            "chunks": message.totalChunks,
            "session": axdpSessionId
        ])

        // Create inbound transfer state
        let expectedChunks = Int(message.totalChunks ?? 1)
        let state = InboundTransferState(
            axdpSessionId: axdpSessionId,
            sourceCallsign: from.display,
            fileName: fileMeta.filename,
            fileSize: Int(fileMeta.fileSize),
            expectedChunks: expectedChunks,
            chunkSize: Int(fileMeta.chunkSize),
            sha256: fileMeta.sha256
        )
        inboundTransferStates[axdpSessionId] = state

        // Create BulkTransfer for UI tracking
        let transferId = UUID()
        axdpToTransferId[axdpSessionId] = transferId

        var transfer = BulkTransfer(
            id: transferId,
            fileName: fileMeta.filename,
            fileSize: Int(fileMeta.fileSize),
            destination: from.display,
            chunkSize: Int(fileMeta.chunkSize),
            direction: .inbound
        )
        transfer.status = .pending
        transfer.markStarted()
        transfers.append(transfer)

        // Create pending incoming transfer request for UI accept/decline
        // CRITICAL: Store the actual AXDP session ID so ACK/NACK uses the correct value
        let request = IncomingTransferRequest(
            id: transferId,
            sourceCallsign: from.display,
            fileName: fileMeta.filename,
            fileSize: Int(fileMeta.fileSize),
            axdpSessionId: axdpSessionId
        )
        pendingIncomingTransfers.append(request)

        TxLog.debug(.axdp, "Created incoming transfer request", [
            "id": transferId.uuidString.prefix(8),
            "from": from.display,
            "file": fileMeta.filename,
            "axdpSessionId": axdpSessionId
        ])
    }

    /// Handle incoming FILE_CHUNK message - accumulates data for transfer
    private func handleFileChunkMessage(_ message: AXDP.Message, from: AX25Address) {
        let axdpSessionId = message.sessionId

        guard var state = inboundTransferStates[axdpSessionId] else {
            TxLog.warning(.axdp, "FILE_CHUNK for unknown transfer", [
                "session": axdpSessionId,
                "from": from.display
            ])
            return
        }

        guard let payload = message.payload else {
            TxLog.warning(.axdp, "FILE_CHUNK missing payload", [
                "session": axdpSessionId,
                "chunk": message.chunkIndex ?? 0
            ])
            return
        }

        let chunkIndex = Int(message.chunkIndex ?? 0)

        // Receive the chunk
        state.receiveChunk(index: chunkIndex, data: payload)
        inboundTransferStates[axdpSessionId] = state

        // Update BulkTransfer progress for UI - use explicit reassignment for SwiftUI
        if let transferId = axdpToTransferId[axdpSessionId],
           let transferIndex = transfers.firstIndex(where: { $0.id == transferId }) {
            var transfer = transfers[transferIndex]
            transfer.markChunkCompleted(chunkIndex)

            // If transfer is in pending state, move to receiving
            if transfer.status == .pending {
                transfer.status = .sending  // Use .sending for "receiving" state
            }

            // Force SwiftUI to see the entire array as new on last chunk (fixes diffing issue)
            // This ensures the 109/109 count is visible before completion
            if chunkIndex == state.expectedChunks - 1 {
                var updatedTransfers = transfers
                updatedTransfers[transferIndex] = transfer
                transfers = updatedTransfers
            } else {
                transfers[transferIndex] = transfer
            }

            // Adaptive UI update frequency - more frequent for small transfers, less for large
            // Aim for ~20-30 updates during the transfer for smooth progress
            let updateFrequency = max(1, min(5, state.expectedChunks / 25))
            if chunkIndex % updateFrequency == 0 || chunkIndex == state.expectedChunks - 1 {
                objectWillChange.send()
            }

            TxLog.debug(.axdp, "Received chunk", [
                "session": axdpSessionId,
                "chunk": "\(chunkIndex + 1)/\(state.expectedChunks)",
                "progress": String(format: "%.0f%%", state.progress * 100)
            ])
        }

        // Check if transfer is complete
        if state.isComplete {
            handleTransferComplete(axdpSessionId: axdpSessionId, state: state)
        }
    }

    /// Handle transfer completion - verify hash, save file, and send completion ACK/NACK to sender
    private func handleTransferComplete(axdpSessionId: UInt32, state: InboundTransferState) {
        guard let transferId = axdpToTransferId[axdpSessionId],
              let transferIndex = transfers.firstIndex(where: { $0.id == transferId }) else {
            return
        }

        // Calculate metrics
        let metrics = state.calculateMetrics()

        TxLog.inbound(.axdp, "Transfer complete", [
            "file": state.fileName,
            "size": state.totalBytesReceived,
            "duration": metrics.map { String(format: "%.1fs", $0.durationSeconds) } ?? "unknown",
            "rate": metrics.map { String(format: "%.0f B/s", $0.effectiveBytesPerSecond) } ?? "unknown"
        ])

        // Use explicit copy for SwiftUI update
        var transfer = transfers[transferIndex]

        // Prepare sender address for ACK/NACK
        let sourceParts = state.sourceCallsign.uppercased().split(separator: "-")
        let sourceCall = String(sourceParts.first ?? "")
        let sourceSSID = sourceParts.count > 1 ? Int(sourceParts[1]) ?? 0 : 0
        let sourceAddress = AX25Address(call: sourceCall, ssid: sourceSSID)

        // Find the session for path info
        let session = sessionManager.sessions.values.first { $0.remoteAddress == sourceAddress && $0.state == .connected }
        let path = session?.path ?? DigiPath()

        var transferSuccess = false

        // Reassemble file
        if let fileData = state.reassembleFile() {
            // Verify SHA256 hash
            let computedHash = computeSHA256(fileData)
            if computedHash == state.sha256 {
                TxLog.debug(.axdp, "File hash verified", ["file": state.fileName])

                // Save file to Downloads folder
                if let savedPath = saveReceivedFile(fileName: state.fileName, data: fileData) {
                    // Success - mark as completed and store path
                    transfer.markCompleted()
                    transfer.savedFilePath = savedPath
                    transferSuccess = true

                    TxLog.inbound(.axdp, "File transfer completed and saved", [
                        "file": state.fileName,
                        "path": savedPath,
                        "size": fileData.count
                    ])
                } else {
                    // File save failed
                    transfer.status = .failed(reason: "Failed to save file to Downloads folder")

                    TxLog.error(.axdp, "Transfer completed but file save failed", error: nil, [
                        "file": state.fileName
                    ])
                }
            } else {
                // Hash mismatch - file corrupted during transfer
                TxLog.error(.axdp, "File hash mismatch - file corrupted", error: nil, [
                    "file": state.fileName,
                    "expected": String(state.sha256.hexEncodedString().prefix(16)),
                    "computed": String(computedHash.hexEncodedString().prefix(16))
                ])
                transfer.status = .failed(reason: "Hash verification failed - file corrupted during transfer")
            }
        } else {
            // Failed to reassemble file
            transfer.status = .failed(reason: "Failed to reassemble file from chunks")
        }

        // Send completion ACK or NACK to sender
        if transferSuccess {
            // Send completion ACK to tell sender the transfer is fully complete
            let completionAck = AXDP.Message(
                type: .ack,
                sessionId: axdpSessionId,
                messageId: SessionCoordinator.transferCompleteMessageId
            )

            let ackFrame = OutboundFrame(
                destination: sourceAddress,
                source: sessionManager.localCallsign,
                path: path,
                payload: completionAck.encode(),
                frameType: session != nil ? "i" : "ui",
                displayInfo: "AXDP ACK (transfer complete)"
            )

            sendFrame(ackFrame)

            TxLog.outbound(.axdp, "Sent transfer completion ACK to sender", [
                "dest": state.sourceCallsign,
                "file": state.fileName,
                "axdpSession": axdpSessionId
            ])
        } else {
            // Send completion NACK to tell sender the transfer failed on receiver side
            let completionNack = AXDP.Message(
                type: .nack,
                sessionId: axdpSessionId,
                messageId: SessionCoordinator.transferCompleteMessageId
            )

            let nackFrame = OutboundFrame(
                destination: sourceAddress,
                source: sessionManager.localCallsign,
                path: path,
                payload: completionNack.encode(),
                frameType: session != nil ? "i" : "ui",
                displayInfo: "AXDP NACK (transfer failed)"
            )

            sendFrame(nackFrame)

            TxLog.outbound(.axdp, "Sent transfer completion NACK to sender", [
                "dest": state.sourceCallsign,
                "file": state.fileName,
                "reason": transfer.failureExplanation,
                "axdpSession": axdpSessionId
            ])
        }

        // Force SwiftUI to see the entire array as new (fixes diffing issue)
        var updatedTransfers = transfers
        updatedTransfers[transferIndex] = transfer
        transfers = updatedTransfers

        // Clean up state
        inboundTransferStates.removeValue(forKey: axdpSessionId)
        axdpToTransferId.removeValue(forKey: axdpSessionId)

        // Remove from pending requests
        pendingIncomingTransfers.removeAll { $0.sourceCallsign == state.sourceCallsign && $0.fileName == state.fileName }

        // Force objectWillChange to ensure UI updates - send immediately and again on next run loop
        objectWillChange.send()

        // Double-send on next run loop to ensure SwiftUI catches the state change
        Task { @MainActor in
            self.objectWillChange.send()
        }
    }

    /// Save received file to Downloads folder (or Documents as fallback)
    /// - Returns: The path where the file was saved, or nil if save failed
    private func saveReceivedFile(fileName: String, data: Data) -> String? {
        let fileManager = FileManager.default

        // Try Downloads folder first, then Documents as fallback
        var baseURL: URL?

        // Try Downloads folder
        if let downloadsURL = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            // For sandboxed apps, create an AXTerm subfolder
            let axTermDownloads = downloadsURL.appendingPathComponent("AXTerm Transfers")
            do {
                try fileManager.createDirectory(at: axTermDownloads, withIntermediateDirectories: true)
                baseURL = axTermDownloads
                TxLog.debug(.axdp, "Using Downloads folder", ["path": axTermDownloads.path])
            } catch {
                TxLog.warning(.axdp, "Cannot create Downloads subfolder, trying Documents", ["error": error.localizedDescription])
            }
        }

        // Fall back to Documents folder if Downloads failed
        if baseURL == nil {
            if let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
                let axTermDocs = documentsURL.appendingPathComponent("AXTerm Transfers")
                do {
                    try fileManager.createDirectory(at: axTermDocs, withIntermediateDirectories: true)
                    baseURL = axTermDocs
                    TxLog.debug(.axdp, "Using Documents folder", ["path": axTermDocs.path])
                } catch {
                    TxLog.error(.axdp, "Cannot create Documents subfolder", error: error)
                }
            }
        }

        guard let downloadsURL = baseURL else {
            TxLog.error(.axdp, "Cannot access any writable folder - check sandbox entitlements", error: nil)
            return nil
        }

        var targetURL = downloadsURL.appendingPathComponent(fileName)

        // Handle filename conflicts - append (1), (2), etc.
        var counter = 1
        let baseName = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        while fileManager.fileExists(atPath: targetURL.path) {
            let newName = ext.isEmpty ? "\(baseName) (\(counter))" : "\(baseName) (\(counter)).\(ext)"
            targetURL = downloadsURL.appendingPathComponent(newName)
            counter += 1
        }

        do {
            // Use atomic write for reliability
            try data.write(to: targetURL, options: .atomic)
            TxLog.inbound(.axdp, "File saved successfully", [
                "path": targetURL.path,
                "size": data.count,
                "sizeFormatted": ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
            ])
            return targetURL.path
        } catch {
            TxLog.error(.axdp, "Failed to save file", error: error, [
                "path": targetURL.path,
                "errorCode": (error as NSError).code,
                "errorDomain": (error as NSError).domain
            ])
            return nil
        }
    }

    /// Handle ACK message (transfer accepted, chunk acknowledged, or transfer complete)
    func handleAckMessage(_ message: AXDP.Message, from: AX25Address) {
        TxLog.debug(.axdp, "Received ACK", [
            "from": from.display,
            "session": message.sessionId,
            "messageId": message.messageId
        ])

        let axdpSessionId = message.sessionId

        // Check if this is a transfer completion ACK from receiver
        if message.messageId == SessionCoordinator.transferCompleteMessageId {
            // Find the transfer awaiting completion
            if let transferId = transferSessionIds.first(where: { $0.value == axdpSessionId })?.key,
               let transferIndex = transfers.firstIndex(where: { $0.id == transferId }) {

                // Verify the transfer is in awaitingCompletion state
                guard transfers[transferIndex].status == .awaitingCompletion else {
                    TxLog.warning(.axdp, "Received completion ACK but transfer not awaiting completion", [
                        "transfer": String(transferId.uuidString.prefix(8)),
                        "status": String(describing: transfers[transferIndex].status)
                    ])
                    return
                }

                // Mark transfer as truly completed
                var transfer = transfers[transferIndex]
                transfer.markCompleted()

                // Force SwiftUI to see the entire array as new (fixes diffing issue)
                var updatedTransfers = transfers
                updatedTransfers[transferIndex] = transfer
                transfers = updatedTransfers

                // Clean up resources now that transfer is fully complete
                transferFileData.removeValue(forKey: transferId)
                transferSessionIds.removeValue(forKey: transferId)

                // Force UI update
                objectWillChange.send()
                Task { @MainActor in
                    self.objectWillChange.send()
                }

                TxLog.outbound(.axdp, "Transfer completed - receiver confirmed file saved", [
                    "file": transfer.fileName,
                    "chunks": transfer.totalChunks
                ])
            }
            return
        }

        // Check if this ACK is for a transfer awaiting acceptance
        if let transferId = transfersAwaitingAcceptance[axdpSessionId],
           let transferIndex = transfers.firstIndex(where: { $0.id == transferId }) {
            // Remove from awaiting acceptance
            transfersAwaitingAcceptance.removeValue(forKey: axdpSessionId)

            // Start sending chunks now that transfer is accepted
            transfers[transferIndex].status = .sending

            // Get destination and path from transfer
            let destParts = transfers[transferIndex].destination.uppercased().split(separator: "-")
            let destCall = String(destParts.first ?? "")
            let destSSID = destParts.count > 1 ? Int(destParts[1]) ?? 0 : 0
            let destAddress = AX25Address(call: destCall, ssid: destSSID)

            // Find the session to get the path
            let session = sessionManager.sessions.values.first { $0.remoteAddress == destAddress && $0.state == .connected }
            let path = session?.path ?? DigiPath()

            TxLog.outbound(.axdp, "Transfer accepted, starting chunk transmission", [
                "transfer": String(transferId.uuidString.prefix(8)),
                "dest": destAddress.display
            ])

            // Start sending chunks
            sendNextChunk(for: transferId, to: destAddress, path: path, axdpSessionId: axdpSessionId)
        }
    }

    /// Handle NACK message (transfer declined, error, or transfer failed on receiver)
    func handleNackMessage(_ message: AXDP.Message, from: AX25Address) {
        TxLog.debug(.axdp, "Received NACK", [
            "from": from.display,
            "session": message.sessionId,
            "messageId": message.messageId
        ])

        let axdpSessionId = message.sessionId

        // Check if this is a transfer completion NACK (receiver failed to save file)
        if message.messageId == SessionCoordinator.transferCompleteMessageId {
            if let transferId = transferSessionIds.first(where: { $0.value == axdpSessionId })?.key,
               let transferIndex = transfers.firstIndex(where: { $0.id == transferId }) {

                // Transfer failed on receiver side (hash mismatch, save failed, etc.)
                var transfer = transfers[transferIndex]
                transfer.status = .failed(reason: "Receiver failed to save file - transfer unsuccessful")

                // Force SwiftUI to see the entire array as new (fixes diffing issue)
                var updatedTransfers = transfers
                updatedTransfers[transferIndex] = transfer
                transfers = updatedTransfers

                // Clean up resources
                transferFileData.removeValue(forKey: transferId)
                transferSessionIds.removeValue(forKey: transferId)

                // Force UI update
                objectWillChange.send()
                Task { @MainActor in
                    self.objectWillChange.send()
                }

                TxLog.error(.axdp, "Transfer failed - receiver could not save file", error: nil, [
                    "file": transfer.fileName,
                    "from": from.display
                ])
            }
            return
        }

        // Check if this NACK is for a transfer awaiting acceptance
        if let transferId = transfersAwaitingAcceptance[axdpSessionId],
           let transferIndex = transfers.firstIndex(where: { $0.id == transferId }) {
            // Remove from awaiting acceptance
            transfersAwaitingAcceptance.removeValue(forKey: axdpSessionId)

            // Fail the transfer
            transfers[transferIndex].status = .failed(reason: "Transfer declined by remote station")
            transferFileData.removeValue(forKey: transferId)
            transferSessionIds.removeValue(forKey: transferId)

            TxLog.outbound(.axdp, "Transfer declined by remote", [
                "transfer": String(transferId.uuidString.prefix(8)),
                "from": from.display
            ])
            return
        }

        // Legacy: check by session ID in transferSessionIds (for already-sending transfers)
        if let transferId = transferSessionIds.first(where: { $0.value == message.sessionId })?.key,
           let transferIndex = transfers.firstIndex(where: { $0.id == transferId }) {
            transfers[transferIndex].status = .failed(reason: "Transfer declined by remote")
            transferFileData.removeValue(forKey: transferId)
            transferSessionIds.removeValue(forKey: transferId)
        }
    }

    // MARK: - AXDP Session ID Helpers

    /// Store an AXDP session ID mapping for a transfer
    func storeAXDPSessionId(_ sessionId: UInt32, for transferId: UUID) {
        transferSessionIds[transferId] = sessionId
    }

    /// Get the AXDP session ID for a transfer
    func getAXDPSessionId(for transferId: UUID) -> UInt32? {
        return transferSessionIds[transferId]
    }

    private func handleSFrame(packet: Packet, from: AX25Address, sType: AX25SType?, nr: Int, pf: Int, channel: UInt8) {
        guard let sType = sType else { return }
        let path = DigiPath.from(packet.via.map { $0.display })
        let isPoll = pf == 1

        switch sType {
        case .RR:
            if let responseFrame = sessionManager.handleInboundRR(from: from, path: path, channel: channel, nr: nr, isPoll: isPoll) {
                sendFrame(responseFrame)
            }
        case .REJ:
            let retransmitFrames = sessionManager.handleInboundREJ(from: from, path: path, channel: channel, nr: nr)
            for frame in retransmitFrames {
                sendFrame(frame)
            }
        case .RNR, .SREJ:
            break
        }
    }

    // MARK: - Capability Discovery

    /// Send an AXDP PING to discover a station's capabilities
    /// - Parameters:
    ///   - destination: The callsign to ping
    ///   - path: Optional digipeater path
    func discoverCapabilities(for destination: String, path: DigiPath = DigiPath()) {
        guard !destination.isEmpty else { return }

        // Parse destination callsign
        let parts = destination.uppercased().split(separator: "-")
        let baseCall = String(parts.first ?? "")
        let ssid = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let destAddress = AX25Address(call: baseCall, ssid: ssid)

        // Build AXDP PING message with our capabilities
        let localCaps = AXDPCapability.defaultLocal()
        let pingMessage = AXDP.Message(
            type: .ping,
            sessionId: UInt32.random(in: 0...UInt32.max),
            messageId: 1,
            capabilities: localCaps
        )

        // Create UI frame with AXDP payload
        let frame = OutboundFrame(
            destination: destAddress,
            source: sessionManager.localCallsign,
            path: path,
            payload: pingMessage.encode(),
            frameType: "ui",
            displayInfo: "AXDP PING"
        )

        sendFrame(frame)

        TxLog.outbound(.capability, "Sent AXDP PING", [
            "dest": destination,
            "features": localCaps.features.description
        ])
    }

    // MARK: - Capability Status

    /// Check if a station has confirmed AXDP capability
    func hasConfirmedAXDPCapability(for callsign: String) -> Bool {
        return packetEngine?.capabilityStore.hasCapabilities(for: callsign) ?? false
    }

    /// Check if capability discovery is pending for a station
    func isCapabilityDiscoveryPending(for callsign: String) -> Bool {
        guard let sentAt = pendingCapabilityDiscovery[callsign.uppercased()] else {
            return false
        }
        // Check if still within timeout window
        return Date().timeIntervalSince(sentAt) < capabilityDiscoveryTimeout
    }

    /// Get capability status for display
    enum CapabilityStatus {
        case unknown       // Never checked
        case pending       // PING sent, waiting for PONG
        case confirmed     // PONG received, AXDP supported
        case notSupported  // Timeout expired, no PONG received
    }

    func capabilityStatus(for callsign: String) -> CapabilityStatus {
        let call = callsign.uppercased()

        if hasConfirmedAXDPCapability(for: call) {
            return .confirmed
        }

        if let sentAt = pendingCapabilityDiscovery[call] {
            let elapsed = Date().timeIntervalSince(sentAt)
            if elapsed < capabilityDiscoveryTimeout {
                return .pending
            } else {
                return .notSupported
            }
        }

        return .unknown
    }

    /// Validate that protocol requirements are met for a transfer
    /// - Parameters:
    ///   - destination: Destination callsign
    ///   - protocol: The transfer protocol to use
    /// - Returns: Error message if requirements not met, nil if OK
    private func validateProtocolRequirements(for destination: String, protocol transferProtocol: TransferProtocolType) -> String? {
        let call = destination.uppercased()

        // AXDP requires capability confirmation
        if transferProtocol == .axdp {
            let status = capabilityStatus(for: call)
            switch status {
            case .unknown:
                TxLog.warning(.session, "Cannot transfer: AXDP capability unknown", [
                    "dest": destination,
                    "protocol": transferProtocol.rawValue
                ])
                return "Cannot send file: \(destination) AXDP capability unknown. Connect first to discover capabilities."

            case .pending:
                TxLog.warning(.session, "Cannot transfer: AXDP discovery in progress", [
                    "dest": destination,
                    "protocol": transferProtocol.rawValue
                ])
                return "Cannot send file: Waiting for \(destination) to respond to capability check."

            case .notSupported:
                TxLog.warning(.session, "Cannot transfer: Station does not support AXDP", [
                    "dest": destination,
                    "protocol": transferProtocol.rawValue
                ])
                return "Cannot send file: \(destination) does not support AXDP. Try a legacy protocol (YAPP, 7plus, or Raw)."

            case .confirmed:
                // AXDP confirmed, good to go
                break
            }
        }

        // Legacy protocols require connected mode
        if transferProtocol.requiresConnectedMode {
            let hasConnectedSession = sessionManager.sessions.values.contains {
                $0.remoteAddress.display.uppercased() == call && $0.state == .connected
            }
            guard hasConnectedSession else {
                TxLog.warning(.session, "Cannot transfer: No connected session", [
                    "dest": destination,
                    "protocol": transferProtocol.rawValue
                ])
                return "Cannot send file: \(transferProtocol.displayName) requires a connected session. Connect to \(destination) first."
            }
        }

        return nil  // All requirements met
    }

    /// Get available protocols for a destination based on current state
    func availableProtocols(for destination: String) -> [TransferProtocolType] {
        let call = destination.uppercased()
        let hasAXDP = hasConfirmedAXDPCapability(for: call)
        let isConnected = sessionManager.sessions.values.contains {
            $0.remoteAddress.display.uppercased() == call && $0.state == .connected
        }

        return TransferProtocolRegistry.shared.availableProtocols(
            for: call,
            hasAXDP: hasAXDP,
            isConnected: isConnected
        )
    }

    /// Get recommended protocol for a destination
    func recommendedProtocol(for destination: String) -> TransferProtocolType? {
        let call = destination.uppercased()
        let hasAXDP = hasConfirmedAXDPCapability(for: call)
        let isConnected = sessionManager.sessions.values.contains {
            $0.remoteAddress.display.uppercased() == call && $0.state == .connected
        }

        return TransferProtocolRegistry.shared.recommendedProtocol(
            for: call,
            hasAXDP: hasAXDP,
            isConnected: isConnected
        )
    }

    // MARK: - Transfer Management

    /// Start a file transfer to a connected session
    /// - Parameters:
    ///   - destination: Destination callsign
    ///   - fileURL: URL of file to transfer
    ///   - path: Digipeater path
    ///   - transferProtocol: Protocol to use (default: AXDP)
    ///   - compressionSettings: Compression settings (AXDP only)
    /// - Returns: Error message if transfer cannot start, nil on success
    @discardableResult
    func startTransfer(
        to destination: String,
        fileURL: URL,
        path: DigiPath = DigiPath(),
        transferProtocol: TransferProtocolType = .axdp,
        compressionSettings: TransferCompressionSettings = .useGlobal
    ) -> String? {
        // Validate protocol requirements
        if let error = validateProtocolRequirements(for: destination, protocol: transferProtocol) {
            return error
        }

        guard let fileData = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            TxLog.error(.session, "Failed to read file for transfer", error: nil, [
                "file": fileURL.lastPathComponent
            ])
            return "Failed to read file"
        }

        var transfer = BulkTransfer(
            id: UUID(),
            fileName: fileURL.lastPathComponent,
            fileSize: fileData.count,
            destination: destination,
            direction: .outbound,
            transferProtocol: transferProtocol,
            compressionSettings: compressionSettings
        )

        // Analyze compressibility
        transfer.analyzeCompressibility(fileData)

        // Log compressibility result
        if let analysis = transfer.compressibilityAnalysis {
            TxLog.debug(.session, "File compressibility analyzed", [
                "file": fileURL.lastPathComponent,
                "category": analysis.fileCategory.rawValue,
                "compressible": analysis.isCompressible ? "yes" : "no",
                "reason": analysis.reason
            ])
        }

        // Set status to awaiting acceptance - we'll only send chunks after receiver accepts
        transfer.status = .awaitingAcceptance
        transfer.markStarted()
        transfers.append(transfer)

        // Store file data for chunking
        let transferId = transfer.id
        transferFileData[transferId] = fileData

        // Generate AXDP session ID for this transfer
        let axdpSessionId = UInt32.random(in: 0...UInt32.max)
        transferSessionIds[transferId] = axdpSessionId

        // Track that this transfer is awaiting acceptance
        transfersAwaitingAcceptance[axdpSessionId] = transferId

        // Parse destination address
        let destParts = destination.uppercased().split(separator: "-")
        let destCall = String(destParts.first ?? "")
        let destSSID = destParts.count > 1 ? Int(destParts[1]) ?? 0 : 0
        let destAddress = AX25Address(call: destCall, ssid: destSSID)

        // Compute SHA256 hash
        let fileHash = computeSHA256(fileData)

        // Send FILE_META message first
        let fileMeta = AXDPFileMeta(
            filename: transfer.fileName,
            fileSize: UInt64(transfer.fileSize),
            sha256: fileHash,
            chunkSize: UInt16(transfer.chunkSize)
        )

        let metaMessage = AXDP.Message(
            type: .fileMeta,
            sessionId: axdpSessionId,
            messageId: 0,
            totalChunks: UInt32(transfer.totalChunks),
            fileMeta: fileMeta
        )

        let metaFrame = OutboundFrame(
            destination: destAddress,
            source: sessionManager.localCallsign,
            path: path,
            payload: metaMessage.encode(),
            frameType: "i",
            displayInfo: "AXDP FILE_META: \(transfer.fileName)"
        )

        sendFrame(metaFrame)

        TxLog.outbound(.session, "Sent FILE_META, waiting for acceptance", [
            "file": transfer.fileName,
            "size": transfer.fileSize,
            "chunks": transfer.totalChunks,
            "axdpSession": axdpSessionId
        ])

        // Do NOT send chunks yet - wait for ACK from receiver
        // Chunks will be sent in handleAckMessage when acceptance is received

        return nil  // Success
    }

    /// Sentinel message ID used for transfer completion ACK/NACK
    /// Using 0xFFFFFFFF as it's unlikely to be a legitimate chunk message ID
    static let transferCompleteMessageId: UInt32 = 0xFFFFFFFF

    /// Send the next chunk for a transfer
    private func sendNextChunk(for transferId: UUID, to destination: AX25Address, path: DigiPath, axdpSessionId: UInt32) {
        guard let transferIndex = transfers.firstIndex(where: { $0.id == transferId }) else { return }
        guard transfers[transferIndex].status == .sending else { return }
        guard let fileData = transferFileData[transferId] else { return }
        guard let nextChunk = transfers[transferIndex].nextChunkToSend else {
            // All chunks sent - transition to awaitingCompletion (NOT completed yet!)
            // Sender waits for completion ACK from receiver before marking as completed
            var transfer = transfers[transferIndex]
            transfer.status = .awaitingCompletion

            // Keep the transfer data and session ID - we still need them until completion ACK
            // Don't clean up yet: transferFileData, transferSessionIds

            // Force SwiftUI to see the entire array as new (fixes diffing issue)
            var updatedTransfers = transfers
            updatedTransfers[transferIndex] = transfer
            transfers = updatedTransfers

            // Force objectWillChange to ensure UI updates immediately
            objectWillChange.send()

            // Double-send on next run loop to ensure SwiftUI catches the state change
            Task { @MainActor in
                self.objectWillChange.send()
            }

            TxLog.outbound(.axdp, "All chunks sent, awaiting completion confirmation from receiver", [
                "file": transfer.fileName,
                "chunks": transfer.totalChunks,
                "axdpSession": axdpSessionId
            ])
            return
        }

        // Get chunk data
        guard let chunkData = transfers[transferIndex].chunkData(from: fileData, chunk: nextChunk) else { return }

        // Resolve compression algorithm from transfer settings + global settings
        let compressionAlgo: AXDPCompression.Algorithm = {
            let currentTransfer = transfers[transferIndex]
            // Check per-transfer override first
            if let enabledOverride = currentTransfer.compressionSettings.enabledOverride {
                if !enabledOverride {
                    return .none  // Explicitly disabled for this transfer
                }
                // Enabled override - use algorithm override or global algorithm
                return currentTransfer.compressionSettings.algorithmOverride ?? globalAdaptiveSettings.compressionAlgorithm
            }
            // No override - use global settings
            if globalAdaptiveSettings.compressionEnabled {
                return globalAdaptiveSettings.compressionAlgorithm
            }
            return .none
        }()

        // Build FILE_CHUNK message with compression
        let chunkMessage = AXDP.Message(
            type: .fileChunk,
            sessionId: axdpSessionId,
            messageId: UInt32(nextChunk + 1),  // 1-indexed message IDs
            chunkIndex: UInt32(nextChunk),
            totalChunks: UInt32(transfers[transferIndex].totalChunks),
            payload: chunkData,
            compression: compressionAlgo
        )

        let chunkFrame = OutboundFrame(
            destination: destination,
            source: sessionManager.localCallsign,
            path: path,
            payload: chunkMessage.encode(),
            frameType: "i",
            displayInfo: "AXDP CHUNK \(nextChunk + 1)/\(transfers[transferIndex].totalChunks)"
        )

        sendFrame(chunkFrame)

        // Mark chunk as sent and update progress - use explicit reassignment for SwiftUI
        var transfer = transfers[transferIndex]
        transfer.markChunkSent(nextChunk)
        transfer.markChunkCompleted(nextChunk)
        transfers[transferIndex] = transfer

        // Adaptive UI update frequency - more frequent for small transfers
        let updateFrequency = max(1, min(5, transfer.totalChunks / 25))
        if nextChunk % updateFrequency == 0 || nextChunk == transfer.totalChunks - 1 {
            objectWillChange.send()
        }

        // Schedule next chunk with a small delay to avoid overwhelming the TNC
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms delay between chunks
            sendNextChunk(for: transferId, to: destination, path: path, axdpSessionId: axdpSessionId)
        }
    }

    /// Compute SHA256 hash of data
    private func computeSHA256(_ data: Data) -> Data {
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash)
    }

    func pauseTransfer(_ id: UUID) {
        if let index = transfers.firstIndex(where: { $0.id == id }) {
            transfers[index].status = .paused
        }
    }

    func resumeTransfer(_ id: UUID) {
        if let index = transfers.firstIndex(where: { $0.id == id }) {
            transfers[index].status = .sending
        }
    }

    func cancelTransfer(_ id: UUID) {
        if let index = transfers.firstIndex(where: { $0.id == id }) {
            transfers[index].status = .cancelled
        }
    }

    func clearCompletedTransfers() {
        transfers.removeAll { transfer in
            switch transfer.status {
            case .completed, .cancelled, .failed:
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Incoming Transfer Handling

    func acceptIncomingTransfer(_ id: UUID) {
        if let index = pendingIncomingTransfers.firstIndex(where: { $0.id == id }) {
            let request = pendingIncomingTransfers.remove(at: index)

            // Parse source callsign
            let sourceParts = request.sourceCallsign.uppercased().split(separator: "-")
            let sourceCall = String(sourceParts.first ?? "")
            let sourceSSID = sourceParts.count > 1 ? Int(sourceParts[1]) ?? 0 : 0
            let sourceAddress = AX25Address(call: sourceCall, ssid: sourceSSID)

            // Find the session for this transfer
            let session = sessionManager.sessions.values.first { $0.remoteAddress == sourceAddress && $0.state == .connected }
            let path = session?.path ?? DigiPath()

            // Send AXDP ACK to accept the transfer
            // CRITICAL: Use the exact same AXDP session ID from FILE_META so sender can match it
            let ackMessage = AXDP.Message(
                type: .ack,
                sessionId: request.axdpSessionId,
                messageId: 1
            )

            let ackFrame = OutboundFrame(
                destination: sourceAddress,
                source: sessionManager.localCallsign,
                path: path,
                payload: ackMessage.encode(),
                frameType: session != nil ? "i" : "ui",
                displayInfo: "AXDP ACK (accept transfer)"
            )

            sendFrame(ackFrame)

            TxLog.outbound(.session, "Accepted incoming transfer", [
                "from": request.sourceCallsign,
                "file": request.fileName,
                "size": request.fileSize,
                "axdpSessionId": request.axdpSessionId
            ])

            // Note: The inbound transfer tracking (BulkTransfer) was already created in handleFileMetaMessage
            // No need to create another one here - it would duplicate the entry
        }
    }

    func declineIncomingTransfer(_ id: UUID) {
        if let index = pendingIncomingTransfers.firstIndex(where: { $0.id == id }) {
            let request = pendingIncomingTransfers.remove(at: index)

            // Parse source callsign
            let sourceParts = request.sourceCallsign.uppercased().split(separator: "-")
            let sourceCall = String(sourceParts.first ?? "")
            let sourceSSID = sourceParts.count > 1 ? Int(sourceParts[1]) ?? 0 : 0
            let sourceAddress = AX25Address(call: sourceCall, ssid: sourceSSID)

            // Find the session for this transfer
            let session = sessionManager.sessions.values.first { $0.remoteAddress == sourceAddress && $0.state == .connected }
            let path = session?.path ?? DigiPath()

            // Send AXDP NACK to decline the transfer
            // CRITICAL: Use the exact same AXDP session ID from FILE_META so sender can match it
            let nackMessage = AXDP.Message(
                type: .nack,
                sessionId: request.axdpSessionId,
                messageId: 1
            )

            let nackFrame = OutboundFrame(
                destination: sourceAddress,
                source: sessionManager.localCallsign,
                path: path,
                payload: nackMessage.encode(),
                frameType: session != nil ? "i" : "ui",
                displayInfo: "AXDP NACK (decline transfer)"
            )

            sendFrame(nackFrame)

            // Mark the inbound transfer as failed/declined
            if let transferId = axdpToTransferId[request.axdpSessionId],
               let transferIndex = transfers.firstIndex(where: { $0.id == transferId }) {
                transfers[transferIndex].status = .cancelled
                inboundTransferStates.removeValue(forKey: request.axdpSessionId)
                axdpToTransferId.removeValue(forKey: request.axdpSessionId)
            }

            TxLog.outbound(.session, "Declined incoming transfer", [
                "from": request.sourceCallsign,
                "file": request.fileName,
                "axdpSessionId": request.axdpSessionId
            ])
        }
    }
}

// MARK: - Incoming Transfer Request

/// Represents an incoming file transfer request waiting for user approval
struct IncomingTransferRequest: Identifiable, Equatable {
    let id: UUID
    let sourceCallsign: String
    let fileName: String
    let fileSize: Int
    let receivedAt: Date
    /// The AXDP session ID from the FILE_META message - MUST use this exact value in ACK/NACK responses
    let axdpSessionId: UInt32

    init(
        id: UUID = UUID(),
        sourceCallsign: String,
        fileName: String,
        fileSize: Int,
        axdpSessionId: UInt32
    ) {
        self.id = id
        self.sourceCallsign = sourceCallsign
        self.fileName = fileName
        self.fileSize = fileSize
        self.receivedAt = Date()
        self.axdpSessionId = axdpSessionId
    }
}

// MARK: - Inbound Transfer State

/// State for tracking an inbound file transfer
struct InboundTransferState {
    let axdpSessionId: UInt32
    let sourceCallsign: String
    let fileName: String
    let fileSize: Int
    let expectedChunks: Int
    let chunkSize: Int
    let sha256: Data

    var receivedChunks: Set<Int> = []
    var chunkData: [Int: Data] = [:]
    var totalBytesReceived: Int = 0
    var startTime: Date?
    var endTime: Date?

    var isComplete: Bool {
        receivedChunks.count >= expectedChunks
    }

    var progress: Double {
        guard expectedChunks > 0 else { return 0 }
        return Double(receivedChunks.count) / Double(expectedChunks)
    }

    mutating func receiveChunk(index: Int, data: Data) {
        // Don't count duplicates
        guard !receivedChunks.contains(index) else { return }

        if startTime == nil {
            startTime = Date()
        }

        receivedChunks.insert(index)
        chunkData[index] = data
        totalBytesReceived += data.count

        if isComplete {
            endTime = Date()
        }
    }

    func reassembleFile() -> Data? {
        guard isComplete else { return nil }

        var assembled = Data()
        for i in 0..<expectedChunks {
            guard let chunk = chunkData[i] else { return nil }
            assembled.append(chunk)
        }
        return assembled
    }

    func calculateMetrics() -> TransferMetrics? {
        guard let start = startTime else { return nil }
        let end = endTime ?? Date()
        let duration = end.timeIntervalSince(start)

        return TransferMetrics(
            totalBytes: totalBytesReceived,
            durationSeconds: duration,
            originalSize: nil,
            compressedSize: nil,
            compressionAlgorithm: nil
        )
    }
}

// MARK: - Transfer Metrics

/// Metrics for a completed transfer
struct TransferMetrics {
    let totalBytes: Int
    let durationSeconds: TimeInterval
    let originalSize: Int?
    let compressedSize: Int?
    let compressionAlgorithm: AXDPCompression.Algorithm?

    var effectiveBytesPerSecond: Double {
        guard durationSeconds > 0 else { return 0 }
        return Double(totalBytes) / durationSeconds
    }

    var effectiveBitsPerSecond: Double {
        effectiveBytesPerSecond * 8
    }

    var compressionRatio: Double? {
        guard let original = originalSize, let compressed = compressedSize, original > 0 else {
            return nil
        }
        return Double(compressed) / Double(original)
    }

    var spaceSavedPercent: Double? {
        guard let ratio = compressionRatio else { return nil }
        return (1.0 - ratio) * 100.0
    }
}

// MARK: - Data Extensions

extension Data {
    /// Convert data to hex-encoded string
    func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Capability Debug Events

/// Event type for capability discovery debugging
enum CapabilityDebugEventType: Equatable {
    case pingSent
    case pongReceived
    case pingReceived
    case pongSent
    case timeout
}

/// Debug event for capability discovery (for debug mode display)
struct CapabilityDebugEvent {
    let type: CapabilityDebugEventType
    let peer: String
    let timestamp: Date
    let capabilities: AXDPCapability?

    init(type: CapabilityDebugEventType, peer: String, capabilities: AXDPCapability? = nil) {
        self.type = type
        self.peer = peer
        self.timestamp = Date()
        self.capabilities = capabilities
    }

    /// Human-readable description for debug display
    var description: String {
        switch type {
        case .pingSent:
            return "PING → \(peer)"
        case .pongReceived:
            return "PONG ← \(peer)"
        case .pingReceived:
            return "PING ← \(peer)"
        case .pongSent:
            return "PONG → \(peer)"
        case .timeout:
            return "TIMEOUT: \(peer)"
        }
    }
}

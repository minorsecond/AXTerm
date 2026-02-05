//
//  TerminalView.swift
//  AXTerm
//
//  Main terminal view combining session output, compose, and transfer management.
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 10
//

import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - Observable View Model Wrapper

/// Observable wrapper around TerminalTxViewModel for SwiftUI binding
@MainActor
final class ObservableTerminalTxViewModel: ObservableObject {
    @Published private(set) var viewModel: TerminalTxViewModel

    /// Session manager for connected-mode operations (shared from SessionCoordinator)
    let sessionManager: AX25SessionManager

    /// Human-readable transcript lines for the active connected session.
    /// Built from in-order AX.25 I-frame payloads so that out-of-order or
    /// retransmitted packets don't scramble the on-screen text.
    @Published private(set) var sessionTranscriptLines: [String] = []

    /// Buffer for assembling the current line between CR/LF terminators.
    private var currentLineBuffer = Data()

    /// Current session (if any) for the active destination
    @Published private(set) var currentSession: AX25Session?

    /// When a peer sends peerAxdpEnabled, set this to trigger a toast. View clears after showing.
    @Published var pendingPeerAxdpNotification: String?

    /// When a peer sends peerAxdpDisabled, set this to trigger a toast.
    @Published var pendingPeerAxdpDisabledNotification: String?

    /// Current outbound message progress for sender UI highlighting (pending → sent → acked)
    @Published private(set) var currentOutboundProgress: OutboundMessageProgress?

    /// Cancellables for Combine subscriptions
    private var cancellables = Set<AnyCancellable>()

    /// Callback for sending response frames (RR, REJ, etc.)
    var onSendResponseFrame: ((OutboundFrame) -> Void)?

    /// Callback when plain-text (non-AXDP) data is received from connected session.
    /// Used to add to console when sender uses plain text instead of AXDP.
    var onPlainTextChatReceived: ((AX25Address, String) -> Void)?

    /// Tracks peers that are currently mid-AXDP reassembly.
    /// When data with AXDP magic is received, the peer is added here.
    /// When AXDP message extraction completes via appendAXDPChatToTranscript, the peer is removed.
    /// When non-AXDP data arrives from a peer in this set, the flag is cleared (they switched to plain text).
    /// This prevents subsequent AXDP fragments (which lack magic) from being displayed as raw text.
    private var peersInAXDPReassembly: Set<String> = []
    
    #if DEBUG
    /// Test helper: Check if a peer is currently marked as in AXDP reassembly.
    /// Only available in DEBUG builds for testing purposes.
    func isPeerInAXDPReassembly(_ peerKey: String) -> Bool {
        return peersInAXDPReassembly.contains(peerKey)
    }
    
    /// Test helper: Set the current session for testing purposes.
    /// Only available in DEBUG builds.
    func setCurrentSession(_ session: AX25Session?) {
        currentSession = session
    }
    #endif

    init(sourceCall: String = "", sessionManager: AX25SessionManager? = nil) {
        var vm = TerminalTxViewModel()
        vm.sourceCall = sourceCall
        self.viewModel = vm

        // Use shared session manager if provided, otherwise create one
        self.sessionManager = sessionManager ?? AX25SessionManager()

        // Set up session manager callbacks - parse callsign-SSID format
        let (baseCall, ssid) = CallsignNormalizer.parse(sourceCall.isEmpty ? "NOCALL" : sourceCall)
        self.sessionManager.localCallsign = AX25Address(call: baseCall.isEmpty ? "NOCALL" : baseCall, ssid: ssid)
        print("[ObservableTerminalTxViewModel.init] Set localCallsign: call='\(baseCall)', ssid=\(ssid)")

        // Chain session state callback - preserve any existing callback (e.g., from SessionCoordinator)
        let previousStateCallback = self.sessionManager.onSessionStateChanged
        self.sessionManager.onSessionStateChanged = { [weak self] session, oldState, newState in
            // Call previous callback first (important for AXDP capability discovery)
            previousStateCallback?(session, oldState, newState)

            // Then handle our own state updates
            Task { @MainActor in
                // When a session connects, refresh currentSession to pick up responder sessions
                // This handles the case where Station B receives an inbound SABM
                // but currentSession is nil because we didn't initiate the connection
                if newState == .connected {
                    self?.updateCurrentSession()
                }
                
                // When a session disconnects, clear the AXDP reassembly flag for that peer.
                // This prevents stale flags from suppressing future plain-text data.
                if newState == .disconnected {
                    let peerKey = session.remoteAddress.display.uppercased()
                    self?.peersInAXDPReassembly.remove(peerKey)
                }
                
                self?.objectWillChange.send()
            }
        }

        self.sessionManager.onDataReceived = { [weak self] session, data in
            guard let self = self else { return }
            // Handle received data from connected session. The AX.25 state machine
            // only delivers in-order, de-duplicated payloads here, so we can safely
            // build a linear text transcript for the UI.
            TxLog.inbound(.session, "Data received from session", [
                "peer": session.remoteAddress.display,
                "size": data.count
            ])
            self.appendToSessionTranscript(from: session, data: data)
        }

        // Chain onOutboundAckReceived for sender progress highlighting
        let previousAckCallback = self.sessionManager.onOutboundAckReceived
        self.sessionManager.onOutboundAckReceived = { [weak self] session, va in
            previousAckCallback?(session, va)
            Task { @MainActor in
                self?.updateOutboundBytesAcked(session: session, va: va)
            }
        }
    }

    /// Start tracking an outbound message for progressive highlighting
    /// - Parameters:
    ///   - text: The message text being sent
    ///   - totalBytes: Total bytes in the message
    ///   - destination: Remote callsign
    ///   - hasAcks: True for connected-mode (AXDP), false for datagram
    ///   - startingVs: The V(S) sequence number when transmission starts (for modulo-8 ack tracking)
    ///   - paclen: Packet length for fragmentation
    func startOutboundProgress(text: String, totalBytes: Int, destination: String, hasAcks: Bool, startingVs: Int, paclen: Int) {
        let chunks = (totalBytes + paclen - 1) / paclen
        currentOutboundProgress = OutboundMessageProgress(
            id: UUID(),
            text: text,
            totalBytes: totalBytes,
            bytesSent: 0,
            bytesAcked: 0,
            destination: destination,
            timestamp: Date(),
            hasAcks: hasAcks,
            startingVs: startingVs,
            totalChunks: chunks,
            paclen: paclen,
            lastKnownVa: startingVs,  // Initially, no frames are acked, so va == startingVs
            chunksAcked: 0
        )
        objectWillChange.send()
    }

    /// Update bytes-sent count when a chunk is transmitted
    func updateOutboundBytesSent(additionalBytes: Int) {
        guard var prog = currentOutboundProgress else { return }
        prog.bytesSent = min(prog.bytesSent + additionalBytes, prog.totalBytes)
        currentOutboundProgress = prog
        if prog.isComplete {
            clearOutboundProgressAfterDelay()
        }
        objectWillChange.send()
    }

    /// Update bytes-acked from RR (va = N(R) sequence number, uses modulo-8)
    /// Correctly handles sequence number wraparound for messages spanning >7 frames.
    func updateOutboundBytesAcked(session: AX25Session, va: Int) {
        guard var prog = currentOutboundProgress, prog.hasAcks,
              session.remoteAddress.display.uppercased() == prog.destination.uppercased()
        else { return }
        
        // Calculate delta using modulo-8 arithmetic
        // va is the N(R) from RR, meaning all frames with N(S) < N(R) are acknowledged
        let modulus = 8
        let delta = (va - prog.lastKnownVa + modulus) % modulus
        
        // Only update if there's forward progress (delta > 0 and we haven't acked everything yet)
        if delta > 0 && prog.chunksAcked < prog.totalChunks {
            prog.lastKnownVa = va
            prog.chunksAcked = min(prog.chunksAcked + delta, prog.totalChunks)
            
            // Calculate bytesAcked from chunksAcked
            var bytes: Int = 0
            for i in 0..<prog.chunksAcked {
                if i < prog.totalChunks - 1 {
                    bytes += prog.paclen
                } else {
                    // Last chunk may be smaller
                    bytes += prog.totalBytes - (prog.totalChunks - 1) * prog.paclen
                }
            }
            prog.bytesAcked = min(bytes, prog.totalBytes)
            currentOutboundProgress = prog
            
            if prog.isComplete {
                clearOutboundProgressAfterDelay()
            }
            objectWillChange.send()
        }
    }

    /// Clear progress after a short delay when complete (so user sees final state)
    private func clearOutboundProgressAfterDelay() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)  // 1.5s
            if currentOutboundProgress?.isComplete == true {
                currentOutboundProgress = nil
                objectWillChange.send()
            }
        }
    }

    /// Clear progress immediately (e.g. user sends another message)
    func clearOutboundProgress() {
        currentOutboundProgress = nil
        objectWillChange.send()
    }

    /// Append decoded AXDP chat text to the session transcript.
    /// Called when AXDP chat is received regardless of local AXDP badge state.
    func appendAXDPChatToTranscript(from: AX25Address, text: String) {
        guard let session = sessionManager.connectedSession(withPeer: from) else {
            TxLog.debug(.axdp, "AXDP chat: no connected session for peer", [
                "from": from.display,
                "textLen": text.count
            ])
            return
        }
        // Clear the AXDP reassembly flag for this peer—reassembly is complete.
        // This must happen BEFORE appendToSessionTranscript so the text isn't suppressed.
        let peerKey = from.display.uppercased()
        peersInAXDPReassembly.remove(peerKey)
        
        // Append with newline so appendToSessionTranscript flushes the line
        let data = Data((text.trimmingCharacters(in: .whitespacesAndNewlines) + "\r\n").utf8)
        appendToSessionTranscript(from: session, data: data)
    }

    /// Subscribe to incoming packets from PacketEngine
    func subscribeToPackets(from client: PacketEngine) {
        client.packetPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] packet in
                self?.handleIncomingPacket(packet)
            }
            .store(in: &cancellables)
    }

    /// Process an incoming packet and route it to the session manager if relevant
    private func handleIncomingPacket(_ packet: Packet) {
        // Only process packets addressed to us
        guard let from = packet.from, let to = packet.to else {
            return
        }

        // Debug: show all packets and check if they're addressed to us
        let decoded = AX25ControlFieldDecoder.decode(control: packet.control, controlByte1: packet.controlByte1)
        let localCall = sessionManager.localCallsign.call.uppercased()
        let toCall = to.call.uppercased()

        // Log if it's a U-frame (which includes SABM)
        if decoded.frameClass == .U {
            print("[TerminalView.handleIncomingPacket] U-frame: from=\(from.display), to.call='\(toCall)' ssid=\(to.ssid), localCallsign.call='\(localCall)' ssid=\(sessionManager.localCallsign.ssid), uType=\(decoded.uType?.rawValue ?? "nil")")
        }

        guard toCall == localCall else {
            if decoded.frameClass == .U && (decoded.uType == .SABM || decoded.uType == .SABME) {
                print("[TerminalView.handleIncomingPacket] SABM filtered: to.call='\(toCall)' (len=\(toCall.count)) != localCallsign.call='\(localCall)' (len=\(localCall.count))")
            }
            return
        }

        print("[TerminalView.handleIncomingPacket] Packet addressed to us: from=\(from.display), frameClass=\(decoded.frameClass.rawValue), uType=\(decoded.uType?.rawValue ?? "nil")")

        // Use channel 0 for default KISS port
        let channel: UInt8 = 0

        switch decoded.frameClass {
        case .U:
            handleUFrame(packet: packet, from: from, uType: decoded.uType, channel: channel)
        case .I:
            handleIFrame(packet: packet, from: from, ns: decoded.ns ?? 0, nr: decoded.nr ?? 0, pf: (decoded.pf ?? 0) == 1, channel: channel)
        case .S:
            handleSFrame(packet: packet, from: from, sType: decoded.sType, nr: decoded.nr ?? 0, pf: decoded.pf ?? 0, channel: channel)
        case .unknown:
            break
        }
    }

    private func handleUFrame(packet: Packet, from: AX25Address, uType: AX25UType?, channel: UInt8) {
        guard let uType = uType else { return }

        // Get the digipeater path from the packet
        let path = DigiPath.from(packet.via.map { $0.display })

        switch uType {
        case .UA:
            sessionManager.handleInboundUA(from: from, path: path, channel: channel)
            updateCurrentSession()
        case .DM:
            sessionManager.handleInboundDM(from: from, path: path, channel: channel)
            updateCurrentSession()
        case .DISC:
            if let responseFrame = sessionManager.handleInboundDISC(from: from, path: path, channel: channel) {
                sendResponseFrame(responseFrame)
            }
            updateCurrentSession()
        case .SABM, .SABME:
            // Respond with UA to accept the incoming connection
            print("[TerminalView] Received SABM from \(from.display), calling handleInboundSABM")
            if let uaFrame = sessionManager.handleInboundSABM(
                from: from,
                to: sessionManager.localCallsign,
                path: path,
                channel: channel
            ) {
                print("[TerminalView] Got UA frame back, calling sendResponseFrame")
                sendResponseFrame(uaFrame)
            } else {
                print("[TerminalView] WARNING: handleInboundSABM returned nil!")
            }
            updateCurrentSession()
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
            // Send the RR/REJ acknowledgement frame
            sendResponseFrame(rrFrame)
        }
    }

    /// Send a response frame (RR, REJ, etc.) via the callback
    private func sendResponseFrame(_ frame: OutboundFrame) {
        print("[TerminalView.sendResponseFrame] Sending frame type=\(frame.frameType) to \(frame.destination.display)")
        if onSendResponseFrame != nil {
            print("[TerminalView.sendResponseFrame] Callback is set, calling it")
            onSendResponseFrame?(frame)
        } else {
            print("[TerminalView.sendResponseFrame] WARNING: onSendResponseFrame callback is nil!")
        }
    }

    private func handleSFrame(packet: Packet, from: AX25Address, sType: AX25SType?, nr: Int, pf: Int, channel: UInt8) {
        guard let sType = sType else { return }
        let path = DigiPath.from(packet.via.map { $0.display })
        let isPoll = pf == 1

        switch sType {
        case .RR:
            // Handle RR - if it's a poll (P=1), we need to respond
            if let responseFrame = sessionManager.handleInboundRR(from: from, path: path, channel: channel, nr: nr, isPoll: isPoll) {
                sendResponseFrame(responseFrame)
            }
        case .REJ:
            // REJ returns frames that need to be retransmitted
            let retransmitFrames = sessionManager.handleInboundREJ(from: from, path: path, channel: channel, nr: nr)
            for frame in retransmitFrames {
                sendResponseFrame(frame)
            }
        case .RNR:
            // RNR handling could be added to session manager
            break
        case .SREJ:
            break
        }
    }

    // MARK: - Compose Bindings

    var composeText: Binding<String> {
        Binding(
            get: { self.viewModel.composeText },
            set: { self.viewModel.composeText = $0 }
        )
    }

    var destinationCall: Binding<String> {
        Binding(
            get: { self.viewModel.destinationCall },
            set: {
                self.viewModel.destinationCall = $0
                // Update current session when destination changes
                self.updateCurrentSession()
            }
        )
    }

    var digiPath: Binding<String> {
        Binding(
            get: { self.viewModel.digiPath },
            set: {
                self.viewModel.digiPath = $0
                // Update current session when path changes
                self.updateCurrentSession()
            }
        )
    }

    var connectionMode: Binding<TxConnectionMode> {
        Binding(
            get: { self.viewModel.connectionMode },
            set: { self.viewModel.connectionMode = $0 }
        )
    }

    var useAXDP: Binding<Bool> {
        Binding(
            get: { self.viewModel.useAXDP },
            set: { self.viewModel.useAXDP = $0 }
        )
    }

    func setUseAXDP(_ value: Bool) {
        viewModel.useAXDP = value
    }

    // MARK: - Read-only Properties

    var sourceCall: String {
        viewModel.sourceCall
    }

    var canSend: Bool {
        viewModel.canSend
    }

    var characterCount: Int {
        viewModel.characterCount
    }

    var queueEntries: [TxQueueEntry] {
        viewModel.queueEntries
    }

    var queueDepth: Int {
        viewModel.queueEntries.filter { entry in
            switch entry.state.status {
            case .queued, .sending, .awaitingAck:
                return true
            default:
                return false
            }
        }.count
    }

    /// Current session state for display
    var sessionState: AX25SessionState? {
        currentSession?.state
    }

    /// Append payload bytes from an AX.25 I-frame into the human-readable
    /// session transcript, respecting CR/LF line boundaries and keeping
    /// messages grouped in arrival order.
    private func appendToSessionTranscript(from session: AX25Session, data: Data) {
        let peerKey = session.remoteAddress.display.uppercased()
        
        // Suppress raw AXDP envelope bytes—AXDP chat is delivered via appendAXDPChatToTranscript.
        // When we see AXDP magic, mark this peer as mid-reassembly.
        if AXDP.hasMagic(data) {
            peersInAXDPReassembly.insert(peerKey)
            return
        }
        
        // If this peer was mid-AXDP-reassembly but sent non-AXDP data:
        // - They switched from AXDP to plain text (e.g., fallback or different message type)
        // - Clear the reassembly flag so plain text is delivered
        // - This handles the case where AXDP reassembly completes via timeout or user switches to plain text
        //
        // BUG FIX: Previously, if a peer ever sent AXDP data, they would remain in peersInAXDPReassembly
        // and ALL subsequent non-AXDP data would be suppressed. This was incorrect.
        // The flag should only suppress data that is a continuation of an AXDP message (no magic),
        // not data from a peer who has switched to plain text entirely.
        //
        // Heuristic: If the data doesn't start with magic AND the peer was in reassembly,
        // this could be either: (1) an AXDP fragment continuation, or (2) plain text.
        // Since AXDP fragments are delivered by the reassembly process (via SessionCoordinator),
        // any data reaching appendToSessionTranscript that isn't AXDP is plain text.
        // Clear the flag and deliver it.
        if peersInAXDPReassembly.contains(peerKey) {
            // Peer was in reassembly but this data isn't AXDP (no magic)
            // This means they've switched to plain text - clear the flag and deliver
            peersInAXDPReassembly.remove(peerKey)
            // Fall through to deliver the plain text data
        }

        // Auto-select the session when data arrives:
        // - If no currentSession is set, use the incoming session
        // - If currentSession is set but to a different session, check if the incoming
        //   session is connected and auto-switch to it (this handles the responder case
        //   where data arrives before updateCurrentSession() has run)
        // - Only ignore data if the incoming session is NOT connected (shouldn't happen)
        if currentSession == nil {
            // No session selected yet, use this one
            currentSession = session
            TxLog.debug(.session, "Auto-selected session on first data", [
                "peer": session.remoteAddress.display,
                "sessionId": session.id.uuidString
            ])
        } else if currentSession?.id != session.id {
            // Different session - if it's connected, switch to it
            if session.state == .connected {
                TxLog.debug(.session, "Auto-switching to connected session with incoming data", [
                    "oldPeer": currentSession?.remoteAddress.display ?? "nil",
                    "newPeer": session.remoteAddress.display,
                    "sessionId": session.id.uuidString
                ])
                currentSession = session
            } else {
                // Incoming data from a non-connected session, ignore (shouldn't happen normally)
                TxLog.debug(.session, "Ignoring data from non-connected session", [
                    "peer": session.remoteAddress.display,
                    "state": String(describing: session.state)
                ])
                return
            }
        }

        for byte in data {
            if byte == 0x0D || byte == 0x0A {
                // End-of-line: flush current buffer if it has any content.
                if !currentLineBuffer.isEmpty {
                    let line = String(data: currentLineBuffer, encoding: .utf8) ??
                               String(data: currentLineBuffer, encoding: .ascii) ??
                               currentLineBuffer.map { String(format: "%02X", $0) }.joined()
                    sessionTranscriptLines.append(line)
                    // Plain-text chat must go to console (sessionTranscriptLines is legacy).
                    TxLog.debug(.session, "Delivering plain text line to console", [
                        "peer": session.remoteAddress.display,
                        "lineLength": line.count,
                        "preview": String(line.prefix(50))
                    ])
                    onPlainTextChatReceived?(session.remoteAddress, line)
                    // Keep transcript bounded for performance.
                    if sessionTranscriptLines.count > 1000 {
                        sessionTranscriptLines.removeFirst(sessionTranscriptLines.count - 1000)
                    }
                    currentLineBuffer.removeAll(keepingCapacity: true)
                }
            } else {
                currentLineBuffer.append(byte)
            }
        }
    }

    // MARK: - Actions

    func updateSourceCall(_ call: String) {
        viewModel.sourceCall = call
        let (baseCall, ssid) = CallsignNormalizer.parse(call.isEmpty ? "NOCALL" : call)
        sessionManager.localCallsign = AX25Address(call: baseCall.isEmpty ? "NOCALL" : baseCall, ssid: ssid)
        print("[updateSourceCall] Set localCallsign: call='\(baseCall)', ssid=\(ssid)")
    }

    func enqueueCurrentMessage() {
        viewModel.enqueueCurrentMessage()
    }

    func clearCompose() {
        viewModel.composeText = ""
    }

    func cancelFrame(_ frameId: UUID) {
        viewModel.cancelFrame(frameId)
    }

    func clearCompleted() {
        viewModel.clearCompleted()
    }

    func updateFrameStatus(_ frameId: UUID, status: TxFrameStatus) {
        viewModel.updateFrameState(frameId: frameId, status: status)
    }

    // MARK: - Session Management

    /// Public method to refresh the current session
    /// Called when session state changes (especially for responder sessions)
    func refreshCurrentSession() {
        updateCurrentSession()
    }

    /// Connect to the current destination (for connected mode)
    func connect() -> OutboundFrame? {
        guard !viewModel.destinationCall.isEmpty else { return nil }

        let dest = parseCallsign(viewModel.destinationCall)
        let path = parsePath(viewModel.digiPath)

        currentSession = sessionManager.session(for: dest, path: path)
        return sessionManager.connect(to: dest, path: path)
    }

    /// Disconnect from the current session
    func disconnect() -> OutboundFrame? {
        guard let session = currentSession else { return nil }
        return sessionManager.disconnect(session: session)
    }

    /// Send data through connected session
    /// Returns frames to send (may include SABM if not connected)
    func sendConnected(payload: Data, displayInfo: String?) -> [OutboundFrame] {
        guard !viewModel.destinationCall.isEmpty else { return [] }

        let dest = parseCallsign(viewModel.destinationCall)
        let path = parsePath(viewModel.digiPath)

        return sessionManager.sendData(
            payload,
            to: dest,
            path: path,
            displayInfo: displayInfo
        )
    }
    
    /// Get session info (vs, paclen) for the current destination.
    /// Used to properly initialize outbound progress tracking with modulo-8 ack handling.
    func sessionInfo(for destination: String) -> (vs: Int, paclen: Int)? {
        guard !destination.isEmpty else { return nil }
        let dest = parseCallsign(destination)
        let path = parsePath(viewModel.digiPath)
        
        // Check for existing connected session first
        if let session = sessionManager.connectedSession(withPeer: dest) {
            return (vs: session.vs, paclen: session.stateMachine.config.paclen)
        }
        
        // Check for any existing session (even if not yet connected)
        if let session = sessionManager.existingSession(for: dest, path: path) {
            return (vs: session.vs, paclen: session.stateMachine.config.paclen)
        }
        
        // No session yet - return default config values
        // The session will be created when sendConnected is called
        return (vs: 0, paclen: AX25Constants.defaultPacketLength)
    }

    /// Update the current session based on destination/path
    /// Also handles responder sessions where we might not have set a destination
    private func updateCurrentSession() {
        // If we have a destination specified, look for that specific session
        if !viewModel.destinationCall.isEmpty {
            let dest = parseCallsign(viewModel.destinationCall)
            let path = parsePath(viewModel.digiPath)

            if let session = sessionManager.existingSession(for: dest, path: path) {
                currentSession = session
                return
            }

            // Also check if there's a connected session with this peer (for responder case)
            if let session = sessionManager.connectedSession(withPeer: dest) {
                currentSession = session
                return
            }
        }

        // If no destination set or not found, check for any connected session
        // This handles the responder case where Station B receives an inbound connection
        // but hasn't typed the destination callsign yet
        if let session = sessionManager.anyConnectedSession() {
            currentSession = session
            // Auto-populate the destination field with the connected peer's callsign
            // so the user can see who they're connected to
            if viewModel.destinationCall.isEmpty {
                viewModel.destinationCall = session.remoteAddress.display
            }
            return
        }

        currentSession = nil
    }

    // MARK: - Parsing Helpers

    private func parseCallsign(_ input: String) -> AX25Address {
        return CallsignNormalizer.toAddress(input)
    }

    private func parsePath(_ input: String) -> DigiPath {
        guard !input.isEmpty else { return DigiPath() }

        let calls = input
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return DigiPath.from(calls)
    }
}

// MARK: - Terminal Tab Enum

enum TerminalTab: String, CaseIterable {
    case session = "Session"
    case transfers = "Transfers"
}

// MARK: - Terminal View

/// Main terminal view with session output and transmission controls
struct TerminalView: View {
    @ObservedObject var client: PacketEngine
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var sessionCoordinator: SessionCoordinator
    @StateObject private var txViewModel: ObservableTerminalTxViewModel

    @State private var selectedTab: TerminalTab = .session
    @State private var showingTransferSheet = false
    @State private var selectedFileURL: URL?

    // Transfer error alert
    @State private var transferError: String?
    @State private var showingTransferError = false

    // Incoming transfer sheet - using item binding for .sheet(item:)
    @State private var currentIncomingRequest: IncomingTransferRequest?

    // Session notification toast
    @State private var sessionNotification: SessionNotification?
    @State private var notificationTask: Task<Void, Never>?
    @State private var showConnectionBanner = false
    @State private var connectionBannerTask: Task<Void, Never>?

    init(client: PacketEngine, settings: AppSettingsStore, sessionCoordinator: SessionCoordinator) {
        self.client = client
        _settings = ObservedObject(wrappedValue: settings)
        _sessionCoordinator = ObservedObject(wrappedValue: sessionCoordinator)
        _txViewModel = StateObject(wrappedValue: ObservableTerminalTxViewModel(
            sourceCall: settings.myCallsign,
            sessionManager: sessionCoordinator.sessionManager
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker
            Picker("", selection: $selectedTab) {
                ForEach(TerminalTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 8)

            // Adaptive transmission status (updates when coordinator learns)
            if sessionCoordinator.adaptiveTransmissionEnabled {
                HStack(spacing: 8) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.caption2)
                        .foregroundStyle(.green)
                    Text("Adaptive")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("On")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.green)
                    Text("K:\(sessionCoordinator.globalAdaptiveSettings.windowSize.effectiveValue)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("P:\(sessionCoordinator.globalAdaptiveSettings.paclen.effectiveValue)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Adaptive Off")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }

            Divider()
                .padding(.top, 8)

            // Content based on tab
            switch selectedTab {
            case .session:
                sessionView
            case .transfers:
                transfersView
            }
        }
        .onChange(of: settings.myCallsign) { _, newValue in
            txViewModel.updateSourceCall(newValue)
        }
        .onChange(of: client.status) { oldValue, newValue in
            if shouldShowConnectionBanner(oldValue: oldValue, newValue: newValue) {
                showConnectionBannerTemporarily()
            }
        }
        .onAppear {
            if !showConnectionBanner {
                if TestModeConfiguration.shared.isTestMode {
                    showConnectionBannerTemporarily()
                } else if client.status == .connected {
                    showConnectionBannerTemporarily()
                }
            }
        }
        .sheet(isPresented: $showingTransferSheet) {
            SendFileSheet(
                isPresented: $showingTransferSheet,
                selectedFileURL: selectedFileURL,
                connectedSessions: sessionCoordinator.connectedSessions,
                onSend: { destination, path, transferProtocol, compressionSettings in
                    startTransfer(destination: destination, path: path, transferProtocol: transferProtocol, compressionSettings: compressionSettings)
                },
                checkCapability: { callsign in
                    sessionCoordinator.capabilityStatus(for: callsign)
                },
                availableProtocols: { callsign in
                    sessionCoordinator.availableProtocols(for: callsign)
                }
            )
        }
        .alert("Transfer Error", isPresented: $showingTransferError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(transferError ?? "Unknown error")
        }
        .sheet(item: $currentIncomingRequest) { request in
            // Using .sheet(item:) guarantees request is non-nil when this closure executes
            IncomingTransferSheet(
                isPresented: Binding(
                    get: { currentIncomingRequest != nil },
                    set: { if !$0 { currentIncomingRequest = nil } }
                ),
                request: request,
                onAccept: {
                    sessionCoordinator.acceptIncomingTransfer(request.id)
                    currentIncomingRequest = nil
                },
                onDecline: {
                    sessionCoordinator.declineIncomingTransfer(request.id)
                    currentIncomingRequest = nil
                },
                onAlwaysAccept: {
                    settings.allowCallsignForFileTransfer(request.sourceCallsign)
                    sessionCoordinator.acceptIncomingTransfer(request.id)
                    currentIncomingRequest = nil
                },
                onAlwaysDeny: {
                    settings.denyCallsignForFileTransfer(request.sourceCallsign)
                    sessionCoordinator.declineIncomingTransfer(request.id)
                    currentIncomingRequest = nil
                }
            )
        }
        .onChange(of: sessionCoordinator.pendingIncomingTransfers) { _, newRequests in
            handlePendingIncomingTransfers(newRequests)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleFileDrop(providers)
        }
        .onAppear {
            // Wire sender progress: I-frames transmitted (incl. from drain) update bytesSent
            client.onUserFrameTransmitted = { [weak txViewModel] bytes in
                txViewModel?.updateOutboundBytesSent(additionalBytes: bytes)
            }

            // Wire AXDP chat received to terminal transcript (regardless of AXDP badge state).
            // appendAXDPChatToTranscript handles adding to console via appendToSessionTranscript
            // → onPlainTextChatReceived → appendSessionChatLine. Do NOT call appendSessionChatLine
            // here directly or the message will appear twice.
            sessionCoordinator.onAXDPChatReceived = { [weak txViewModel] from, text in
                txViewModel?.appendAXDPChatToTranscript(from: from, text: text)
            }

            // Wire plain-text chat (non-AXDP) to console when sender uses plain text.
            txViewModel.onPlainTextChatReceived = { [weak client] from, text in
                client?.appendSessionChatLine(from: from.display, text: text)
            }

            sessionCoordinator.onPeerAxdpEnabled = { [weak txViewModel] from in
                Task { @MainActor in
                    txViewModel?.pendingPeerAxdpNotification = from.display
                }
            }
            sessionCoordinator.onPeerAxdpDisabled = { [weak txViewModel] from in
                Task { @MainActor in
                    txViewModel?.pendingPeerAxdpDisabledNotification = from.display
                }
            }

            // Wire up response frame sending (for RR, REJ, etc.)
            txViewModel.onSendResponseFrame = { [weak client] frame in
                print("[TerminalView.onAppear] onSendResponseFrame callback invoked for \(frame.destination.display)")
                client?.send(frame: frame) { result in
                    Task { @MainActor in
                        switch result {
                        case .success:
                            print("[TerminalView] Response frame sent successfully")
                            TxLog.outbound(.ax25, "Response frame sent", [
                                "type": frame.frameType,
                                "dest": frame.destination.display
                            ])
                        case .failure(let error):
                            print("[TerminalView] Response frame send FAILED: \(error)")
                            TxLog.error(.ax25, "Response frame send failed", error: error)
                        }
                    }
                }
            }

            // Wire up session state change notifications for this view's toast display
            let previousCallback = txViewModel.sessionManager.onSessionStateChanged
            txViewModel.sessionManager.onSessionStateChanged = { [weak txViewModel] session, oldState, newState in
                // Call any previous callback first
                previousCallback?(session, oldState, newState)

                Task { @MainActor in
                    // CRITICAL: When a session connects (especially responder sessions),
                    // we need to update currentSession so the UI reflects the connected state.
                    // This handles the case where Station B receives an inbound connection
                    // but hasn't set a destination yet - the session exists but currentSession is nil.
                    if newState == .connected {
                        txViewModel?.refreshCurrentSession()
                    }

                    txViewModel?.objectWillChange.send()

                    // Show notification for significant state changes
                    if oldState != newState {
                        let notification: SessionNotification?

                        switch newState {
                        case .connected:
                            notification = SessionNotification(
                                type: .connected,
                                peer: session.remoteAddress.display,
                                message: "Session established"
                            )
                        case .disconnected where oldState == .connected || oldState == .disconnecting:
                            notification = SessionNotification(
                                type: .disconnected,
                                peer: session.remoteAddress.display,
                                message: "Session ended"
                            )
                        case .error:
                            notification = SessionNotification(
                                type: .error,
                                peer: session.remoteAddress.display,
                                message: "Session error"
                            )
                        default:
                            notification = nil
                        }

                        if let notification = notification {
                            showSessionNotification(notification)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Session Notifications

    private func showSessionNotification(_ notification: SessionNotification) {
        // Cancel any existing notification task
        notificationTask?.cancel()

        // Show the notification
        withAnimation(.easeOut(duration: 0.2)) {
            sessionNotification = notification
        }

        // Auto-dismiss after 4 seconds
        notificationTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled {
                withAnimation(.easeIn(duration: 0.2)) {
                    sessionNotification = nil
                }
            }
        }
    }

    private func dismissSessionNotification() {
        notificationTask?.cancel()
        withAnimation(.easeIn(duration: 0.2)) {
            sessionNotification = nil
        }
    }

    /// Notify all connected peers with confirmed AXDP capability that we enabled AXDP.
    /// Called when user enables via the toggle or via the toast's Enable button.
    private func sendPeerAxdpEnabledToConnectedSessions() {
        for session in sessionCoordinator.connectedSessions {
            if sessionCoordinator.hasConfirmedAXDPCapability(for: session.remoteAddress.display) {
                sessionCoordinator.sendPeerAxdpEnabled(to: session.remoteAddress, path: session.path)
            }
        }
    }


    /// Binding for AXDP toggle that also sends peerAxdpEnabled/Disabled to peers when toggled.
    /// Sends to ALL connected sessions with confirmed capability.
    private var useAXDPBinding: Binding<Bool> {
        Binding(
            get: { txViewModel.viewModel.useAXDP },
            set: { newValue in
                let wasOn = txViewModel.viewModel.useAXDP
                txViewModel.setUseAXDP(newValue)
                if newValue, !wasOn {
                    sendPeerAxdpEnabledToConnectedSessions()
                } else if !newValue, wasOn {
                    for session in sessionCoordinator.connectedSessions {
                        if sessionCoordinator.hasConfirmedAXDPCapability(for: session.remoteAddress.display) {
                            sessionCoordinator.sendPeerAxdpDisabled(to: session.remoteAddress, path: session.path)
                        }
                    }
                }
            }
        )
    }

    private func shouldShowConnectionBanner(oldValue: ConnectionStatus, newValue: ConnectionStatus) -> Bool {
        guard oldValue != newValue else { return false }
        switch newValue {
        case .connected, .disconnected, .failed:
            return true
        case .connecting:
            return false
        }
    }

    private func showConnectionBannerTemporarily() {
        connectionBannerTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) {
            showConnectionBanner = true
        }
        connectionBannerTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled {
                withAnimation(.easeIn(duration: 0.2)) {
                    showConnectionBanner = false
                }
            }
        }
    }

    // MARK: - Session View

    @ViewBuilder
    private var sessionView: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                if TestModeConfiguration.shared.isTestMode {
                    Text(connectionMessage)
                        .font(.caption)
                        .opacity(0.01)
                        .accessibilityIdentifier("connectionStatus")
                        .accessibilityLabel(connectionMessage)
                        .accessibilityHidden(false)
                        .frame(width: 1, height: 1)
                }

                // Connection status banner
                if showConnectionBanner {
                    connectionBanner
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                // Session output (reuse console view for now, filtered by session)
                sessionOutputView

                // Outbound progress (sender: pending → sent → acked highlighting)
                if let progress = txViewModel.currentOutboundProgress {
                    OutboundProgressView(progress: progress, sourceCall: txViewModel.viewModel.sourceCall)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .opacity
                        ))
                }

                // TX Queue (collapsible)
                if !txViewModel.queueEntries.isEmpty {
                    TxQueueView(
                        entries: txViewModel.queueEntries,
                    onCancel: { frameId in
                        txViewModel.cancelFrame(frameId)
                    },
                    onClearCompleted: {
                        txViewModel.clearCompleted()
                    }
                )
            }

            // Compose area
            TerminalComposeView(
                destinationCall: txViewModel.destinationCall,
                digiPath: txViewModel.digiPath,
                composeText: txViewModel.composeText,
                connectionMode: txViewModel.connectionMode,
                useAXDP: useAXDPBinding,
                sourceCall: txViewModel.sourceCall,
                canSend: txViewModel.canSend,
                characterCount: txViewModel.characterCount,
                queueDepth: txViewModel.queueDepth,
                isConnected: client.status == .connected,
                sessionState: txViewModel.sessionState,
                destinationCapability: client.capabilityStore.capabilities(for: txViewModel.viewModel.destinationCall),
                capabilityStatus: sessionCoordinator.capabilityStatus(for: txViewModel.viewModel.destinationCall),
                onSend: {
                    sendCurrentMessage()
                },
                onClear: {
                    txViewModel.clearCompose()
                },
                onConnect: {
                    connectToDestination()
                },
                onDisconnect: {
                    disconnectFromDestination()
                }
            )
            }

            // Session notification toast overlay
            if let notification = sessionNotification {
                SessionNotificationToast(
                    notification: notification,
                    onDismiss: dismissSessionNotification,
                    primaryActionLabel: notification.supportsPrimaryAction ? notification.defaultPrimaryActionLabel : nil,
                    onPrimaryAction: (notification.type == .peerAxdpEnabled) ? {
                        txViewModel.setUseAXDP(true)
                        sendPeerAxdpEnabledToConnectedSessions()
                        dismissSessionNotification()
                    } : nil
                )
                .padding(.horizontal, 20)
                .padding(.top, 60)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onReceive(txViewModel.$pendingPeerAxdpNotification.compactMap { $0 }.removeDuplicates()) { peer in
            txViewModel.pendingPeerAxdpNotification = nil
            let alreadyUsing = txViewModel.viewModel.useAXDP
            showSessionNotification(SessionNotification(
                type: alreadyUsing ? .peerAxdpEnabledAlreadyUsing : .peerAxdpEnabled,
                peer: peer,
                message: alreadyUsing
                    ? "has enabled AXDP – you're both using it"
                    : "has enabled AXDP – turn it on for enhanced features?"
            ))
        }
        .onReceive(txViewModel.$pendingPeerAxdpDisabledNotification.compactMap { $0 }.removeDuplicates()) { peer in
            showSessionNotification(SessionNotification(
                type: .peerAxdpDisabled,
                peer: peer,
                message: "has disabled AXDP"
            ))
            txViewModel.pendingPeerAxdpDisabledNotification = nil
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: sessionNotification)
    }

    @ViewBuilder
    private var connectionBanner: some View {
        HStack {
            Image(systemName: connectionIcon)
                .foregroundStyle(connectionColor)

            Text(connectionMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("connectionStatus")

            Spacer()

            if client.status == .disconnected || client.status == .failed {
                Button("Connect") {
                    client.connect(host: settings.host, port: settings.portValue)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(connectionColor.opacity(0.1))
    }

    private var connectionIcon: String {
        switch client.status {
        case .connected: return "checkmark.circle.fill"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .disconnected: return "circle"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var connectionColor: Color {
        switch client.status {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .secondary
        case .failed: return .red
        }
    }

    private var connectionMessage: String {
        switch client.status {
        case .connected: return "Connected"
        case .connecting: return "Connecting..."
        case .disconnected: return "Not connected. Connect to send messages."
        case .failed: return "Connection failed."
        }
    }

    @ViewBuilder
    private var sessionOutputView: some View {
        // Restore original ConsoleView-based UI so we keep timestamps,
        // message-type pills, colors, etc. Improvements to grouping are
        // handled at the data level rather than replacing this view.
        ConsoleView(
            lines: client.consoleLines,
            showDaySeparators: settings.showConsoleDaySeparators,
            clearedAt: $settings.terminalClearedAt
        )
        .overlay(alignment: .center) {
            if filteredConsoleLines.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)

                    Text("No messages yet")
                        .foregroundStyle(.secondary)

                    if settings.terminalClearedAt != nil {
                        Text("Session cleared")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("Connect to a TNC to start receiving packets")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    /// Console lines filtered by clear timestamp (for empty state check)
    private var filteredConsoleLines: [ConsoleLine] {
        guard let cutoff = settings.terminalClearedAt else {
            return client.consoleLines
        }
        return client.consoleLines.filter { $0.timestamp > cutoff }
    }

    // MARK: - Transmission

    /// Send the current composed message
    private func sendCurrentMessage() {
        let connectionMode = txViewModel.viewModel.connectionMode

        switch connectionMode {
        case .datagram:
            sendDatagramMessage()

        case .connected:
            sendConnectedMessage()
        }
    }

    /// Send message as UI datagram (no connection required)
    private func sendDatagramMessage() {
        // Add to queue (for UI display)
        txViewModel.enqueueCurrentMessage()

        // Get the last queued entry and actually send it
        guard let entry = txViewModel.queueEntries.last else { return }

        // Start outbound progress (datagram has no ACKs; fire-and-forget)
        // For datagrams, vs/paclen don't matter since we don't track acks
        let text = entry.frame.displayInfo ?? String(data: entry.frame.payload, encoding: .utf8) ?? ""
        txViewModel.startOutboundProgress(
            text: text,
            totalBytes: entry.frame.payload.count,
            destination: txViewModel.viewModel.destinationCall.isEmpty ? "BROADCAST" : txViewModel.viewModel.destinationCall,
            hasAcks: false,
            startingVs: 0,
            paclen: AX25Constants.defaultPacketLength
        )

        // Send via PacketEngine (bytesSent for I-frame via onUserFrameTransmitted; UI frames use payload)
        client.send(frame: entry.frame) { [weak txViewModel] result in
            Task { @MainActor in
                switch result {
                case .success:
                    txViewModel?.updateFrameStatus(entry.frame.id, status: .sent)
                    // For UI frames (datagram), update progress when sent
                    if entry.frame.frameType.lowercased() == "ui" {
                        txViewModel?.updateOutboundBytesSent(additionalBytes: entry.frame.payload.count)
                    }
                case .failure:
                    txViewModel?.updateFrameStatus(entry.frame.id, status: .failed)
                }
            }
        }
    }

    /// Send message via connected session (I-frames)
    private func sendConnectedMessage() {
        // Build payload
        let text = txViewModel.viewModel.composeText
        let useAXDP = txViewModel.viewModel.useAXDP
        
        // If AXDP is requested, verify capability is confirmed
        if useAXDP {
            let capabilityStatus = sessionCoordinator.capabilityStatus(for: txViewModel.viewModel.destinationCall)
            if capabilityStatus != .confirmed {
                TxLog.warning(.axdp, "Cannot send AXDP message - capability not confirmed", [
                    "destination": txViewModel.viewModel.destinationCall,
                    "status": String(describing: capabilityStatus)
                ])
                // Fall back to plain text
                var data = Data(text.utf8)
                data.append(0x0D)  // CR
                let fallbackSessionInfo = txViewModel.sessionInfo(for: txViewModel.viewModel.destinationCall)
                txViewModel.startOutboundProgress(
                    text: text,
                    totalBytes: data.count,
                    destination: txViewModel.viewModel.destinationCall,
                    hasAcks: true,
                    startingVs: fallbackSessionInfo?.vs ?? 0,
                    paclen: fallbackSessionInfo?.paclen ?? AX25Constants.defaultPacketLength
                )
                let frames = txViewModel.sendConnected(
                    payload: data,
                    displayInfo: text
                )
                for frame in frames {
                    client.send(frame: frame) { result in
                        Task { @MainActor in
                            switch result {
                            case .success:
                                TxLog.outbound(.ax25, "Frame sent (fallback to plain text)", [
                                    "type": frame.frameType,
                                    "dest": frame.destination.display
                                ])
                            case .failure(let error):
                                TxLog.error(.ax25, "Frame send failed", error: error)
                            }
                        }
                    }
                }
                if !frames.isEmpty {
                    txViewModel.clearCompose()
                }
                return
            }
        }

        let payload: Data
        if useAXDP {
            let message = AXDP.Message(
                type: .chat,
                sessionId: 0,
                messageId: UInt32.random(in: 1...UInt32.max),
                payload: Data(text.utf8)
            )
            payload = message.encode()
        } else {
            // Standard plain-text: append CR for BBS/node compatibility
            // BBSes expect commands to end with carriage return (0x0D)
            var data = Data(text.utf8)
            data.append(0x0D)  // CR
            payload = data
        }

        // Start outbound progress for sender highlighting (AXDP/connected has ACKs)
        // Get session info for proper modulo-8 ack tracking
        let sessionInfo = txViewModel.sessionInfo(for: txViewModel.viewModel.destinationCall)
        txViewModel.startOutboundProgress(
            text: text,
            totalBytes: payload.count,
            destination: txViewModel.viewModel.destinationCall,
            hasAcks: true,
            startingVs: sessionInfo?.vs ?? 0,
            paclen: sessionInfo?.paclen ?? AX25Constants.defaultPacketLength
        )

        // Get frames from session manager (may include SABM if not connected)
        let frames = txViewModel.sendConnected(
            payload: payload,
            displayInfo: text
        )

        // Send all frames (bytesSent updated via client.onUserFrameTransmitted)
        for frame in frames {
            client.send(frame: frame) { result in
                Task { @MainActor in
                    switch result {
                    case .success:
                        TxLog.outbound(.ax25, "Frame sent", [
                            "type": frame.frameType,
                            "dest": frame.destination.display
                        ])
                    case .failure(let error):
                        TxLog.error(.ax25, "Frame send failed", error: error)
                    }
                }
            }
        }

        // Clear compose text if we sent something
        if !frames.isEmpty {
            txViewModel.clearCompose()
        }
    }

    /// Establish connection to current destination
    private func connectToDestination() {
        guard let frame = txViewModel.connect() else { return }

        // Send SABM
        client.send(frame: frame) { result in
            Task { @MainActor in
                switch result {
                case .success:
                    TxLog.outbound(.session, "SABM sent", [
                        "dest": frame.destination.display
                    ])
                case .failure(let error):
                    TxLog.error(.session, "SABM send failed", error: error)
                }
            }
        }
    }

    /// Disconnect from current session
    private func disconnectFromDestination() {
        guard let frame = txViewModel.disconnect() else { return }

        // Send DISC
        client.send(frame: frame) { result in
            Task { @MainActor in
                switch result {
                case .success:
                    TxLog.outbound(.session, "DISC sent", [
                        "dest": frame.destination.display
                    ])
                case .failure(let error):
                    TxLog.error(.session, "DISC send failed", error: error)
                }
            }
        }
    }

    // MARK: - Transfers View

    @ViewBuilder
    private var transfersView: some View {
        BulkTransferListView(
            transfers: sessionCoordinator.transfers,
            pendingIncomingTransfers: currentIncomingRequest == nil ? sessionCoordinator.pendingIncomingTransfers : [],
            suppressIncomingRequests: true,
            onPause: { id in
                sessionCoordinator.pauseTransfer(id)
            },
            onResume: { id in
                sessionCoordinator.resumeTransfer(id)
            },
            onCancel: { id in
                sessionCoordinator.cancelTransfer(id)
            },
            onClearCompleted: {
                sessionCoordinator.clearCompletedTransfers()
            },
            onAddFile: {
                selectFileForTransfer()
            },
            onAcceptIncoming: { id in
                sessionCoordinator.acceptIncomingTransfer(id)
            },
            onDeclineIncoming: { id in
                sessionCoordinator.declineIncomingTransfer(id)
            }
        )
    }

    // MARK: - Transfer Management

    /// Handle pending incoming transfer requests with auto-accept/deny logic
    private func handlePendingIncomingTransfers(_ newRequests: [IncomingTransferRequest]) {
        // Auto-show modal for first pending request if not already showing
        guard currentIncomingRequest == nil, let first = newRequests.first else { return }

        // Check if auto-accept or auto-deny is enabled for this callsign
        if settings.isCallsignAllowedForFileTransfer(first.sourceCallsign) {
            // Auto-accept - log so user knows what happened
            TxLog.inbound(.session, "Auto-accepted file transfer (callsign in allow list)", [
                "from": first.sourceCallsign,
                "file": first.fileName,
                "size": first.fileSize
            ])
            sessionCoordinator.acceptIncomingTransfer(first.id)
        } else if settings.isCallsignDeniedForFileTransfer(first.sourceCallsign) {
            // Auto-deny - log so user knows what happened
            TxLog.inbound(.session, "Auto-declined file transfer (callsign in deny list)", [
                "from": first.sourceCallsign,
                "file": first.fileName,
                "size": first.fileSize
            ])
            sessionCoordinator.declineIncomingTransfer(first.id)
        } else {
            // Show modal for user decision - setting the item shows the sheet
            currentIncomingRequest = first
        }
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url = url else { return }
            Task { @MainActor in
                selectedFileURL = url
                showingTransferSheet = true
            }
        }

        return true
    }

    private func selectFileForTransfer() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        if panel.runModal() == .OK, let url = panel.url {
            selectedFileURL = url
            showingTransferSheet = true
        }
    }

    private func startTransfer(destination: String, path: String, transferProtocol: TransferProtocolType = .axdp, compressionSettings: TransferCompressionSettings = .useGlobal) {
        guard let url = selectedFileURL else { return }
        let digiPath = path.isEmpty ? DigiPath() : DigiPath.from(path.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) })

        if let error = sessionCoordinator.startTransfer(to: destination, fileURL: url, path: digiPath, transferProtocol: transferProtocol, compressionSettings: compressionSettings) {
            transferError = error
            showingTransferError = true
        }
        selectedFileURL = nil
    }
}

// MARK: - Preview

#Preview("Terminal View") {
    let settings = AppSettingsStore()
    let coordinator = SessionCoordinator()
    return TerminalView(
        client: PacketEngine(settings: settings),
        settings: settings,
        sessionCoordinator: coordinator
    )
    .frame(width: 800, height: 600)
}

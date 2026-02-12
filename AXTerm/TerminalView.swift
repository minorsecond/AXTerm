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

typealias TerminalLine = ConsoleLine

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

    /// Per-peer buffer for assembling the current line between CR/LF terminators.
    /// Each peer has its own buffer to prevent data from one peer contaminating another.
    /// Key is the peer's callsign (uppercased).
    private var currentLineBuffers: [String: Data] = [:]

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

    // MARK: - Filtering Pipeline
    
    /// Full in-memory buffer of console lines
    @Published private(set) var allLines: [TerminalLine] = []
    
    /// Performance window (last N lines)
    @Published private(set) var visibleLines: [TerminalLine] = []
    
    /// Final filtered lines for the UI
    @Published private(set) var filteredLines: [TerminalLine] = []
    
    /// Debounced search query
    @Published private(set) var debouncedQuery: String = ""
    
    /// Shared settings for type filtering (ID, BCN, etc)
    private let settings: AppSettingsStore
    
    /// Max lines for the performance window
    private let maxVisibleLines = 1000

    /// Session notification toast
    @Published var sessionNotification: SessionNotification?
    private var notificationTask: Task<Void, Never>?

    /// Callback for sending response frames (RR, REJ, etc.)

    /// Callback for sending response frames (RR, REJ, etc.)
    var onSendResponseFrame: ((OutboundFrame) -> Void)?

    /// Callback when plain-text (non-AXDP) data is received from connected session.
    /// Used to add to console when sender uses plain text instead of AXDP.
    var onPlainTextChatReceived: ((AX25Address, String, [String]) -> Void)?

    /// Tracks peers that are currently mid-AXDP reassembly.
    /// When data with AXDP magic is received, the peer is added here.
    /// When AXDP message extraction completes via appendAXDPChatToTranscript, the peer is removed.
    /// When non-AXDP data arrives from a peer in this set, the flag is cleared (they switched to plain text).
    /// This prevents subsequent AXDP fragments (which lack magic) from being displayed as raw text.
    private var peersInAXDPReassembly: Set<String> = []
    
    /// Clear the AXDP reassembly flag for a peer when reassembly completes.
    /// Called by SessionCoordinator via onAXDPReassemblyComplete callback.
    /// This allows subsequent plain text from this peer to be delivered to the console.
    func clearAXDPReassemblyFlag(for address: AX25Address) {
        let peerKey = address.display.uppercased()
        if peersInAXDPReassembly.contains(peerKey) {
            peersInAXDPReassembly.remove(peerKey)
            TxLog.debug(.axdp, "Cleared AXDP reassembly flag on completion", [
                "peer": peerKey
            ])
        }
    }

    /// Clear AXDP/plain-text per-peer state (reassembly flag + line buffer).
    /// Used when toggling AXDP or when a peer disables AXDP mid-session.
    func resetAxdpState(for address: AX25Address, reason: String) {
        let peerKey = address.display.uppercased()
        let hadFlag = peersInAXDPReassembly.contains(peerKey)
        peersInAXDPReassembly.remove(peerKey)
        let hadBuffer = currentLineBuffers.removeValue(forKey: peerKey) != nil
        TxLog.debug(.axdp, "Reset AXDP/plain-text state", [
            "peer": peerKey,
            "reason": reason,
            "hadFlag": hadFlag,
            "hadBuffer": hadBuffer
        ])
    }

    /// Clear AXDP/plain-text per-peer state for all known sessions.
    func resetAxdpStateForAllPeers(reason: String) {
        let peers = sessionManager.sessions.values.map { $0.remoteAddress }
        var resetCount = 0
        for peer in peers {
            resetAxdpState(for: peer, reason: reason)
            resetCount += 1
        }
        TxLog.debug(.axdp, "Reset AXDP/plain-text state for all peers", [
            "count": resetCount,
            "reason": reason
        ])
    }
    
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

    /// Flag to ensure callbacks are only set up once per instance.
    /// This prevents the @StateObject gotcha where init() is called multiple times
    /// but only the first instance is kept - subsequent instances would overwrite
    /// callbacks with weak refs to deallocated objects.
    private var callbacksConfigured = false
    
    init(client: PacketEngine, settings: AppSettingsStore, sourceCall: String, sessionManager: AX25SessionManager) {
        var vm = TerminalTxViewModel()
        vm.sourceCall = sourceCall
        self.viewModel = vm
        self.settings = settings
        self.sessionManager = sessionManager

        // Set up local callsign
        let (baseCall, ssid) = CallsignNormalizer.parse(sourceCall.isEmpty ? "NOCALL" : sourceCall)
        self.sessionManager.localCallsign = AX25Address(call: baseCall.isEmpty ? "NOCALL" : baseCall, ssid: ssid)
        
        print("[ObservableTerminalTxViewModel.init] Set localCallsign: call='\(baseCall)', ssid=\(ssid)")
        
        setupSearchDebounce()
        setupConsoleSubscription(client: client)
    }

    private func createSessionNotification(for session: AX25Session, oldState: AX25SessionState, newState: AX25SessionState) -> SessionNotification? {
        switch newState {
        case .connected:
            return SessionNotification(
                type: .connected,
                peer: session.remoteAddress.display,
                message: "Session established"
            )
        case .disconnected where oldState == .connected || oldState == .disconnecting:
            return SessionNotification(
                type: .disconnected,
                peer: session.remoteAddress.display,
                message: "Session ended"
            )
        case .error:
            return SessionNotification(
                type: .error,
                peer: session.remoteAddress.display,
                message: "Session error"
            )
        default:
            return nil
        }
    }

    func showSessionNotification(_ notification: SessionNotification) {
        notificationTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) {
            sessionNotification = notification
        }
        notificationTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled {
                withAnimation(.easeIn(duration: 0.2)) {
                    sessionNotification = nil
                }
            }
        }
    }

    func dismissSessionNotification() {
        notificationTask?.cancel()
        withAnimation(.easeIn(duration: 0.2)) {
            sessionNotification = nil
        }
    }
    
    /// Set up session manager callbacks. Must be called from a stable location
    /// (e.g., TerminalView.onAppear) to ensure callbacks point to the actual
    /// @StateObject instance, not a discarded temporary instance.
    ///
    /// This method is idempotent - calling it multiple times is safe.
    func setupSessionCallbacks() {
        // Only configure once per instance
        guard !callbacksConfigured else {
            print("[ObservableTerminalTxViewModel] Callbacks already configured, skipping")
            return
        }
        callbacksConfigured = true
        print("[ObservableTerminalTxViewModel] Setting up session callbacks")

        // Chain session state callback - preserve any existing callback (e.g., from SessionCoordinator)
        let previousStateCallback = self.sessionManager.onSessionStateChanged
        self.sessionManager.onSessionStateChanged = { [weak self] session, oldState, newState in
            // Call previous callback first (important for AXDP capability discovery)
            previousStateCallback?(session, oldState, newState)

            // Then handle our own state updates
            Task { @MainActor in
                // When a session connects, refresh currentSession to pick up responder sessions
                if newState == .connected {
                    self?.updateCurrentSession()
                }
                
                // When a session disconnects, clear per-peer state
                if newState == .disconnected {
                    let peerKey = session.remoteAddress.display.uppercased()
                    self?.peersInAXDPReassembly.remove(peerKey)
                    self?.currentLineBuffers.removeValue(forKey: peerKey)
                }
                
                // Show notification for significant state changes
                if oldState != newState {
                    if let notification = self?.createSessionNotification(for: session, oldState: oldState, newState: newState) {
                        self?.showSessionNotification(notification)
                    }
                }
                
                self?.objectWillChange.send()
            }
        }

        self.sessionManager.onDataReceived = { [weak self] session, data in
            guard let self = self else {
                // This should NEVER happen now that callbacks are set up correctly
                print("[ObservableTerminalTxViewModel] ERROR: onDataReceived called but self is nil!")
                TxLog.error(.session, "onDataReceived: self is nil - data lost!", error: nil, [
                    "peer": session.remoteAddress.display,
                    "size": data.count
                ])
                return
            }
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

    // MARK: - Filtering Logic

    private func setupSearchDebounce() {
        $debouncedQuery
            .dropFirst()
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyFiltering()
            }
            .store(in: &cancellables)
    }

    private func setupConsoleSubscription(client: PacketEngine) {
        client.$consoleLines
            .receive(on: DispatchQueue.main)
            .sink { [weak self] lines in
                guard let self = self else { return }
                self.allLines = lines
                self.applyFiltering()
            }
            .store(in: &cancellables)
    }

    /// Update the current search query (to be called when the shared search model changes)
    func updateSearchQuery(_ query: String) {
        if debouncedQuery != query {
            debouncedQuery = query
            // applyFiltering will be called by the debounce sink
        }
    }

    /// Primary filtering pipeline implementation
    func applyFiltering() {
        // 1. apply performance window (visibleLines)
        let totalCount = allLines.count
        visibleLines = Array(allLines.suffix(maxVisibleLines))
        
        // 2. apply global view filters and search query
        var result = visibleLines
        
        // Filter by clear timestamp
        if let cutoff = settings.terminalClearedAt {
            result = result.filter { $0.timestamp > cutoff }
        }
        
        // HIG: Terminal filters in-memory output (case-insensitive substring match on rendered text)
        if !debouncedQuery.isEmpty {
            let searchLower = debouncedQuery.lowercased()
            result = result.filter { line in
                line.text.lowercased().contains(searchLower) ||
                line.from?.lowercased().contains(searchLower) == true ||
                line.to?.lowercased().contains(searchLower) == true
            }
        }
        
        filteredLines = result
        
        #if DEBUG
        print("[TerminalSearch] query=\"\(debouncedQuery)\" all=\(totalCount) visible=\(visibleLines.count) filtered=\(filteredLines.count)")
        #endif
        
        // Ensure UI updates reliably
        objectWillChange.send()
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
    ///
    /// CRITICAL: This method must NOT clear peersInAXDPReassembly!
    /// Here's why: In AX25SessionManager.handleAction, when an I-frame delivers data:
    ///   1. onDataDeliveredForReassembly is called → SessionCoordinator processes
    ///   2. If AXDP reassembly completes, this method is called
    ///   3. THEN onDataReceived is called for the SAME I-frame's raw bytes
    ///
    /// If we clear the flag here, step 3 will see the flag cleared and let raw bytes
    /// leak into the plain text buffer, causing contamination like "ullamcorper.test 2 long".
    ///
    /// Instead, we:
    /// - Clear the plain text buffer (any leaked raw bytes are discarded)
    /// - Deliver the decoded AXDP text directly (bypassing appendToSessionTranscript)
    /// - Leave the flag set so step 3's raw bytes are suppressed
    /// - The async onAXDPReassemblyComplete callback clears the flag after all returns
    func appendAXDPChatToTranscript(from: AX25Address, text: String) {
        guard let session = sessionManager.connectedSession(withPeer: from) else {
            TxLog.debug(.axdp, "AXDP chat: no connected session for peer", [
                "from": from.display,
                "textLen": text.count
            ])
            return
        }
        
        let peerKey = from.display.uppercased()
        
        // Clear any partial data in the plain text buffer for this peer.
        // This prevents any raw AXDP bytes that may have leaked through from
        // contaminating the decoded message or subsequent plain text.
        currentLineBuffers.removeValue(forKey: peerKey)
        
        // DO NOT clear peersInAXDPReassembly here!
        // The flag must remain set until onAXDPReassemblyComplete's async callback runs.
        // This ensures raw bytes from the last I-frame (delivered via onDataReceived
        // AFTER this method returns) are properly suppressed.
        
        // Deliver the decoded AXDP text directly to the console.
        // We can't use appendToSessionTranscript because the peersInAXDPReassembly flag
        // is still set and would incorrectly suppress this decoded text.
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedText.isEmpty {
            sessionTranscriptLines.append(trimmedText)
            TxLog.debug(.axdp, "Delivering AXDP chat to console", [
                "peer": peerKey,
                "length": trimmedText.count,
                "preview": String(trimmedText.prefix(50))
            ])
            onPlainTextChatReceived?(session.remoteAddress, trimmedText, session.lastReceivedVia)
            
            // Keep transcript bounded for performance
            if sessionTranscriptLines.count > 1000 {
                sessionTranscriptLines.removeFirst(sessionTranscriptLines.count - 1000)
            }
        }
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
        let localAddress = sessionManager.localCallsign

        // Log if it's a U-frame (which includes SABM)
        if decoded.frameClass == .U {
            print("[TerminalView.handleIncomingPacket] U-frame: from=\(from.display), to=\(to.display) local=\(localAddress.display) uType=\(decoded.uType?.rawValue ?? "nil")")
        }

        guard CallsignNormalizer.addressesMatch(to, localAddress) else {
            if decoded.frameClass == .U && (decoded.uType == .SABM || decoded.uType == .SABME) {
                print("[TerminalView.handleIncomingPacket] SABM filtered: to=\(to.display) local=\(localAddress.display)")
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
        let bufferLen = currentLineBuffers[peerKey]?.count ?? 0
        let lineBreaks = data.reduce(0) { count, byte in
            count + ((byte == 0x0D || byte == 0x0A) ? 1 : 0)
        }
        TxLog.debug(.session, "appendToSessionTranscript chunk", [
            "peer": peerKey,
            "size": data.count,
            "hasMagic": AXDP.hasMagic(data),
            "bufferLen": bufferLen,
            "lineBreaks": lineBreaks
        ])
        
        // Suppress raw AXDP envelope bytes—AXDP chat is delivered via appendAXDPChatToTranscript.
        // When we see AXDP magic, mark this peer as mid-reassembly.
        if AXDP.hasMagic(data) {
            peersInAXDPReassembly.insert(peerKey)
            TxLog.debug(.axdp, "AXDP magic detected in I-frame payload (suppress raw)", [
                "peer": peerKey,
                "size": data.count,
                "prefixHex": data.prefix(8).map { String(format: "%02X", $0) }.joined()
            ])
            return
        }
        
        // If peer is mid-AXDP-reassembly, suppress ALL non-magic data.
        // AXDP continuation fragments don't have the magic header - only the first chunk does.
        // The raw bytes will be reconstructed by SessionCoordinator and delivered via
        // appendAXDPChatToTranscript when the complete AXDP message is extracted.
        //
        // The flag is cleared when:
        // 1. SessionCoordinator signals AXDP reassembly completed (via onAXDPReassemblyComplete)
        // 2. Session disconnects (via onSessionStateChanged)
        //
        // This means if a peer switches from AXDP to plain text mid-session without completing
        // the AXDP message, their plain text may be suppressed. This is acceptable because:
        // - AXDP reassembly has timeouts that will eventually clear stale buffers
        // - The flag is cleared on disconnect
        // - Mixed AXDP/plain text mid-message is an edge case
        if peersInAXDPReassembly.contains(peerKey) {
            // Suppress AXDP continuation fragment - SessionCoordinator handles reassembly
            TxLog.debug(.axdp, "Suppressing AXDP continuation fragment", [
                "peer": peerKey,
                "size": data.count,
                "prefixHex": data.prefix(8).map { String(format: "%02X", $0) }.joined(),
                "useAXDP": viewModel.useAXDP
            ])
            return
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

        // Get or create the per-peer buffer
        var peerBuffer = currentLineBuffers[peerKey] ?? Data()
        
        for byte in data {
            if byte == 0x0D || byte == 0x0A {
                // End-of-line: flush current buffer if it has any content.
                if !peerBuffer.isEmpty {
                    let line = String(data: peerBuffer, encoding: .utf8) ??
                               String(data: peerBuffer, encoding: .ascii) ??
                               peerBuffer.map { String(format: "%02X", $0) }.joined()
                    sessionTranscriptLines.append(line)
                    // Plain-text chat must go to console (sessionTranscriptLines is legacy).
                    TxLog.debug(.session, "Delivering plain text line to console", [
                        "peer": session.remoteAddress.display,
                        "lineLength": line.count,
                        "preview": String(line.prefix(50)),
                        "bufferLenBeforeFlush": bufferLen
                    ])
                    onPlainTextChatReceived?(session.remoteAddress, line, session.lastReceivedVia)
                    // Keep transcript bounded for performance.
                    if sessionTranscriptLines.count > 1000 {
                        sessionTranscriptLines.removeFirst(sessionTranscriptLines.count - 1000)
                    }
                    peerBuffer.removeAll(keepingCapacity: true)
                }
            } else {
                peerBuffer.append(byte)
            }
        }
        
        // Store the updated buffer back
        currentLineBuffers[peerKey] = peerBuffer
    }
    
    /// Clear the plain text line buffer for a peer (called when session disconnects)
    func clearPlainTextBuffer(for address: AX25Address) {
        let peerKey = address.display.uppercased()
        currentLineBuffers.removeValue(forKey: peerKey)
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

    /// Force disconnect immediately (no DISC/UA)
    func forceDisconnect() {
        guard let session = currentSession else { return }
        sessionManager.forceDisconnect(session: session)
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

private struct TerminalAutoPathCandidate: Identifiable, Hashable {
    let pathInput: String
    let pathDisplay: String
    let quality: Int
    let freshnessPercent: Int
    let hops: Int
    let sourceLabel: String

    var id: String {
        "\(pathInput)|\(quality)|\(sourceLabel)"
    }
}

private struct SessionRecord: Identifiable, Hashable {
    let id: String
    let destination: String
    let mode: ConnectBarMode
    let via: [String]
    var statusText: String

    var label: String {
        destination  // Removed "• \(statusText)" - state now only in header
    }
}

// MARK: - Terminal View

/// Main terminal view with session output and transmission controls
struct TerminalView: View {
    @ObservedObject var client: PacketEngine
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var sessionCoordinator: SessionCoordinator
    @ObservedObject var connectCoordinator: ConnectCoordinator
    @StateObject private var txViewModel: ObservableTerminalTxViewModel
    @StateObject private var connectBarViewModel: ConnectBarViewModel
    @ObservedObject var searchModel: AppToolbarSearchModel

    @State private var selectedTab: TerminalTab = .session
    @State private var showingTransferSheet = false
    @State private var selectedFileURL: URL?

    // Transfer error alert
    @State private var transferError: String?
    @State private var showingTransferError = false

    // Incoming transfer sheet - using item binding for .sheet(item:)
    @State private var currentIncomingRequest: IncomingTransferRequest?

    @State private var showConnectionBanner = false
    @State private var connectionBannerTask: Task<Void, Never>?
    
    @State private var lastAutoFilledPath: String = ""
    @State private var lastObservedDestination: String = ""
    @State private var sessionRecords: [SessionRecord] = []
    @State private var activeSessionRecordID: String?
    @State private var autoAttemptTask: Task<Void, Never>?
    @State private var pendingRoutingReconnect = false

    init(
        client: PacketEngine,
        settings: AppSettingsStore,
        sessionCoordinator: SessionCoordinator,
        connectCoordinator: ConnectCoordinator,
        searchModel: AppToolbarSearchModel
    ) {
        self.client = client
        _settings = ObservedObject(wrappedValue: settings)
        _sessionCoordinator = ObservedObject(wrappedValue: sessionCoordinator)
        _connectCoordinator = ObservedObject(wrappedValue: connectCoordinator)
        self.searchModel = searchModel
        
        _txViewModel = StateObject(wrappedValue: ObservableTerminalTxViewModel(
            client: client,
            settings: settings,
            sourceCall: settings.myCallsign,
            sessionManager: sessionCoordinator.sessionManager
        ))
        _connectBarViewModel = StateObject(wrappedValue: ConnectBarViewModel())
    }

    var body: some View {
        mainLayout
            .onChange(of: searchModel.query) { _, newValue in
                txViewModel.updateSearchQuery(newValue)
            }
            .onAppear {
                txViewModel.updateSearchQuery(searchModel.query)
                lastObservedDestination = txViewModel.viewModel.destinationCall
                connectBarViewModel.toCall = txViewModel.viewModel.destinationCall
                connectBarViewModel.viaDigipeaters = txViewModel.viewModel.digiPath
                    .split(separator: ",")
                    .map { CallsignValidator.normalize(String($0)) }
                    .filter { !$0.isEmpty }
                refreshConnectBarData()
                connectBarViewModel.applyContext(connectCoordinator.activeContext)
                syncAdaptiveSelection()
                if txViewModel.viewModel.connectionMode == .datagram {
                    connectBarViewModel.enterBroadcastComposer()
                } else {
                    connectBarViewModel.enterConnectDraftMode()
                }
            }
            .onReceive(client.$stations) { _ in
                refreshConnectBarData()
            }
            .onReceive(client.$packets) { _ in
                refreshConnectBarData()
            }
            .onReceive(connectCoordinator.$pendingRequest.compactMap { $0 }) { request in
                // Defer request handling one run-loop turn to avoid publishing model
                // updates while SwiftUI is still in the current view update pass.
                DispatchQueue.main.async {
                    handleConnectRequest(request)
                }
            }
            .onChange(of: connectCoordinator.activeContext) { _, context in
                connectBarViewModel.applyContext(context)
                syncAdaptiveSelection()
            }
            .onChange(of: txViewModel.viewModel.connectionMode) { _, newMode in
                switch newMode {
                case .datagram:
                    connectBarViewModel.enterBroadcastComposer()
                case .connected:
                    connectBarViewModel.enterConnectDraftMode()
                }
                syncAdaptiveSelection()
            }
            .onChange(of: connectBarViewModel.mode) { _, _ in syncAdaptiveSelection() }
            .onChange(of: connectBarViewModel.toCall) { _, _ in syncAdaptiveSelection() }
            .onChange(of: connectBarViewModel.viaDigipeaters) { _, _ in syncAdaptiveSelection() }
            .onChange(of: sessionCoordinator.adaptiveTransmissionEnabled) { _, _ in syncAdaptiveSelection() }
            .onChange(of: txViewModel.sessionState) { _, newState in
                switch newState {
                case .connecting:
                    connectBarViewModel.markConnecting()
                    updateActiveSessionRecordState("Connecting")
                case .connected:
                    connectBarViewModel.markConnected(
                        sourceCall: txViewModel.viewModel.sourceCall,
                        destination: txViewModel.viewModel.destinationCall,
                        via: connectBarViewModel.viaDigipeaters,
                        transportMode: connectBarViewModel.mode,
                        forcedNextHop: connectBarViewModel.nextHopSelection == ConnectBarViewModel.autoNextHopID
                            ? nil
                            : connectBarViewModel.nextHopSelection
                    )
                    updateActiveSessionRecordState("Connected")
                case .disconnecting:
                    connectBarViewModel.markDisconnecting()
                    updateActiveSessionRecordState("Disconnecting")
                case .disconnected:
                    connectBarViewModel.markDisconnected()
                    updateActiveSessionRecordState("Disconnected")
                    if pendingRoutingReconnect {
                        pendingRoutingReconnect = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            connectWithActiveIntent(sourceContext: connectCoordinator.activeContext)
                        }
                    }
                case .error:
                    connectBarViewModel.markFailed(reason: .unknown, detail: "Session state entered error")
                    updateActiveSessionRecordState("Failed")
                case .none:
                    break
                }
                syncAdaptiveSelection()
            }
            .onChange(of: txViewModel.viewModel.destinationCall) { _, newValue in
                applyAutoPathSuggestionIfNeeded(previousDestination: lastObservedDestination, newDestination: newValue)
                lastObservedDestination = newValue
            }
            .onChange(of: connectBarViewModel.toCall) { _, _ in
                syncLegacyFieldsFromConnectBar()
            }
            .onChange(of: connectBarViewModel.viaDigipeaters) { _, _ in
                syncLegacyFieldsFromConnectBar()
            }
            .onChange(of: txViewModel.viewModel.digiPath) { _, newValue in
                if newValue != lastAutoFilledPath {
                    lastAutoFilledPath = ""
                }
            }
            .onDisappear {
                stopAutoConnectAttempts()
            }
            .modifier(TerminalViewModifiers(
                searchModel: searchModel,
                showingTransferSheet: $showingTransferSheet,
                showingTransferError: $showingTransferError,
                currentIncomingRequest: $currentIncomingRequest,
                selectedFileURL: selectedFileURL,
                transferError: transferError,
                client: client,
                settings: settings,
                sessionCoordinator: sessionCoordinator,
                txViewModel: txViewModel,
                shouldShowConnectionBanner: shouldShowConnectionBanner,
                showConnectionBannerTemporarily: showConnectionBannerTemporarily,
                handlePendingIncomingTransfers: handlePendingIncomingTransfers,
                handleFileDrop: handleFileDrop,
                startTransfer: startTransfer,
                wireCallbacks: wireCallbacks
            ))
    }

    private var mainLayout: some View {
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
    }

    private func wireCallbacks() {
        // CRITICAL: Set up session callbacks FIRST, before any data can arrive.
        // This must be done in onAppear (not in ObservableTerminalTxViewModel.init)
        // to avoid the @StateObject gotcha where init() is called multiple times
        // but only the first instance is kept. See setupSessionCallbacks() for details.
        txViewModel.setupSessionCallbacks()
        
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
        txViewModel.onPlainTextChatReceived = { [weak client] from, text, via in
            if let client = client {
                TxLog.debug(.session, "onPlainTextChatReceived callback executing", [
                    "from": from.display,
                    "textLength": text.count,
                    "preview": String(text.prefix(50)),
                    "via": via.joined(separator: ",")
                ])
                client.appendSessionChatLine(from: from.display, text: text, via: via)
            } else {
                TxLog.error(.session, "onPlainTextChatReceived: client is nil!", ["from": from.display])
            }
        }

        sessionCoordinator.onPeerAxdpEnabled = { [weak txViewModel] from in
            Task { @MainActor in
                txViewModel?.pendingPeerAxdpNotification = from.display
            }
        }
        sessionCoordinator.onPeerAxdpDisabled = { [weak txViewModel] from in
            Task { @MainActor in
                txViewModel?.pendingPeerAxdpDisabledNotification = from.display
                txViewModel?.resetAxdpState(for: from, reason: "peerAxdpDisabled")
                sessionCoordinator.clearAllReassemblyBuffers(for: from)
            }
        }
        
        // Clear AXDP reassembly flag when a complete message is extracted.
        // This allows subsequent plain text from this peer to be delivered.
        sessionCoordinator.onAXDPReassemblyComplete = { [weak txViewModel] from in
            Task { @MainActor in
                txViewModel?.clearAXDPReassemblyFlag(for: from)
            }
        }

        // Wire up response frame sending (for RR, REJ, etc.)
        txViewModel.onSendResponseFrame = { [weak client] frame in
            client?.send(frame: frame) { result in
                Task { @MainActor in
                    switch result {
                    case .success:
                        TxLog.outbound(.ax25, "Response frame sent", [
                            "type": frame.frameType,
                            "dest": frame.destination.display
                        ])
                    case .failure(let error):
                        TxLog.error(.ax25, "Response frame send failed", error: error)
                    }
                }
            }
        }

        // onSessionStateChanged is now handled inside txViewModel.setupSessionCallbacks()
    }

    private var autoPathSuggestions: [TerminalAutoPathCandidate] {
        buildAutoPathCandidates(for: txViewModel.viewModel.destinationCall)
    }

    private func refreshConnectBarData() {
        let neighbors = client.netRomIntegration?.currentNeighbors(forMode: .hybrid) ?? []
        let routes = client.netRomIntegration?.currentRoutes(forMode: .hybrid) ?? []
        connectBarViewModel.updateRuntimeData(
            stations: client.stations,
            neighbors: neighbors,
            routes: routes,
            packets: client.packets,
            favorites: settings.watchCallsigns
        )
    }

    private func handleConnectRequest(_ request: ConnectRequest) {
        txViewModel.connectionMode.wrappedValue = .connected
        if request.intent.sourceContext == .stations {
            let normalized = CallsignValidator.normalize(request.intent.to)
            let hasRoute = client.netRomIntegration?.bestRouteTo(normalized) != nil
            let selection = SidebarStationSelection(
                callsign: normalized,
                context: .stations,
                lastUsedMode: request.mode,
                hasNetRomRoute: hasRoute
            )
            connectBarViewModel.applySidebarSelection(
                selection,
                action: request.executeImmediately ? .connect : .prefill
            )
        } else {
            if case let .netrom(nextHopOverride) = request.intent.kind {
                connectBarViewModel.applyNetRomPrefill(
                    destination: request.intent.to,
                    routeHint: request.intent.routeHint,
                    suggestedPreview: request.intent.suggestedRoutePreview,
                    nextHopOverride: nextHopOverride?.stringValue
                )
            } else {
                connectBarViewModel.setMode(request.mode, for: request.intent.sourceContext)
                connectBarViewModel.toCall = request.intent.to
                if case let .ax25ViaDigis(digis) = request.intent.kind {
                    connectBarViewModel.viaDigipeaters = digis.map(\.stringValue)
                } else {
                    connectBarViewModel.viaDigipeaters = []
                }
                connectBarViewModel.nextHopSelection = ConnectBarViewModel.autoNextHopID
                connectBarViewModel.validate()
            }
            connectBarViewModel.applyInlineNote(request.intent.note)
        }

        syncLegacyFieldsFromConnectBar()
        syncAdaptiveSelection()

        if request.executeImmediately {
            connectWithActiveIntent(sourceContext: request.intent.sourceContext)
        }

        connectCoordinator.consumeRequest(id: request.id)
    }

    private func syncLegacyFieldsFromConnectBar() {
        txViewModel.destinationCall.wrappedValue = connectBarViewModel.toCall
        if connectBarViewModel.mode == .ax25ViaDigi {
            txViewModel.digiPath.wrappedValue = connectBarViewModel.viaDigipeaters.joined(separator: ",")
        } else {
            txViewModel.digiPath.wrappedValue = ""
        }
    }

    private func syncAdaptiveSelection() {
        guard sessionCoordinator.adaptiveTransmissionEnabled,
              txViewModel.viewModel.connectionMode == .connected,
              let state = txViewModel.sessionState,
              state == .connecting || state == .connected || state == .disconnecting else {
            sessionCoordinator.selectAdaptiveSession(destination: nil, path: nil)
            return
        }

        let destination = CallsignValidator.normalize(connectBarViewModel.toCall)
        guard !destination.isEmpty else {
            sessionCoordinator.selectAdaptiveSession(destination: nil, path: nil)
            return
        }
        let path: String
        if let sessionPath = txViewModel.currentSession?.path.display, !sessionPath.isEmpty {
            path = sessionPath
        } else if connectBarViewModel.mode == .ax25ViaDigi {
            path = connectBarViewModel.viaDigipeaters.joined(separator: ",")
        } else {
            path = ""
        }
        sessionCoordinator.selectAdaptiveSession(destination: destination, path: path)
    }

    private func applyAutoPathSuggestionIfNeeded(previousDestination: String, newDestination: String) {
        let previous = CallsignValidator.normalize(previousDestination)
        let next = CallsignValidator.normalize(newDestination)
        guard previous != next else { return }

        let existingPath = txViewModel.viewModel.digiPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let canAutoFill = existingPath.isEmpty || existingPath == lastAutoFilledPath
        guard canAutoFill else { return }

        if let best = buildAutoPathCandidates(for: newDestination).first {
            let sanitized = sanitizedPathInput(best.pathInput)
            lastAutoFilledPath = sanitized
            txViewModel.digiPath.wrappedValue = sanitized
            if sanitized != best.pathInput {
                connectBarViewModel.applyInlineNote("Removed duplicate digis from path.")
            }
        } else {
            lastAutoFilledPath = ""
            txViewModel.digiPath.wrappedValue = ""
        }
    }

    private func applyAutoPath(_ pathInput: String) {
        let sanitized = sanitizedPathInput(pathInput)
        lastAutoFilledPath = sanitized
        txViewModel.digiPath.wrappedValue = sanitized
        if sanitized != pathInput {
            connectBarViewModel.applyInlineNote("Removed duplicate digis from path.")
        }
    }

    private func sanitizedPathInput(_ raw: String) -> String {
        let parsed = DigipeaterListParser.parse(raw)
        let deduped = DigipeaterListParser.dedupedPreservingOrder(parsed)
        return deduped.joined(separator: ",")
    }

    private func buildAutoPathCandidates(for destination: String) -> [TerminalAutoPathCandidate] {
        guard let integration = client.netRomIntegration else { return [] }
        let normalizedDestination = CallsignValidator.normalize(destination)
        guard !normalizedDestination.isEmpty else { return [] }

        let now = Date()
        let mode = integration.currentMode
        let routeCandidates = integration.currentRoutes(forMode: mode)
            .filter { CallsignValidator.normalize($0.destination) == normalizedDestination }

        var byPathInput: [String: TerminalAutoPathCandidate] = [:]

        for route in routeCandidates {
            let connectNodes = Array(route.path.dropLast())
            let pathInput = connectNodes.joined(separator: ",")
            let hops = connectNodes.count
            let freshness = route.freshness(now: now, ttl: FreshnessCalculator.defaultTTL)
            let candidate = TerminalAutoPathCandidate(
                pathInput: pathInput,
                pathDisplay: pathInput.isEmpty ? "Direct" : connectNodes.joined(separator: " → "),
                quality: route.quality,
                freshnessPercent: Int(round(freshness * 100.0)),
                hops: hops,
                sourceLabel: route.sourceType.capitalized
            )

            if let existing = byPathInput[pathInput] {
                if candidate.quality > existing.quality ||
                    (candidate.quality == existing.quality && candidate.freshnessPercent > existing.freshnessPercent) {
                    byPathInput[pathInput] = candidate
                }
            } else {
                byPathInput[pathInput] = candidate
            }
        }

        let directNeighbor = integration.currentNeighbors(forMode: mode)
            .contains { CallsignValidator.normalize($0.call) == normalizedDestination }
        if directNeighbor && byPathInput[""] == nil {
            byPathInput[""] = TerminalAutoPathCandidate(
                pathInput: "",
                pathDisplay: "Direct",
                quality: 255,
                freshnessPercent: 100,
                hops: 0,
                sourceLabel: "Direct"
            )
        }

        return byPathInput.values.sorted {
            if $0.quality != $1.quality { return $0.quality > $1.quality }
            if $0.freshnessPercent != $1.freshnessPercent { return $0.freshnessPercent > $1.freshnessPercent }
            if $0.hops != $1.hops { return $0.hops < $1.hops }
            return $0.pathInput < $1.pathInput
        }
    }

    private func dismissSessionNotification() {
        txViewModel.dismissSessionNotification()
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
                TxLog.debug(.axdp, "AXDP toggle changed", [
                    "wasOn": wasOn,
                    "isOn": newValue
                ])
                if newValue, !wasOn {
                    sendPeerAxdpEnabledToConnectedSessions()
                } else if !newValue, wasOn {
                    // Clearing state avoids stale AXDP reassembly flags suppressing plain text after toggles.
                    txViewModel.resetAxdpStateForAllPeers(reason: "localAxdpDisabled")
                    for session in sessionCoordinator.connectedSessions {
                        sessionCoordinator.clearAllReassemblyBuffers(for: session.remoteAddress)
                    }
                    for session in sessionCoordinator.connectedSessions {
                        if sessionCoordinator.hasConfirmedAXDPCapability(for: session.remoteAddress.display) {
                            sessionCoordinator.sendPeerAxdpDisabled(to: session.remoteAddress, path: session.path)
                        }
                    }
                }
            }
        )
    }

    /// Determines if connection status change warrants showing a banner.
    /// HIG: Success toasts should only appear for rare, user-initiated events.
    /// TNC connection is expected on app launch, so we don't celebrate it.
    /// We only show banners for unexpected disconnects or failures.
    private func shouldShowConnectionBanner(oldValue: ConnectionStatus, newValue: ConnectionStatus) -> Bool {
        guard oldValue != newValue else { return false }
        switch newValue {
        case .connected:
            // TNC connected successfully - NO banner (expected success)
            return false
        case .disconnected:
            // Unexpected disconnect - show banner
            return oldValue == .connected
        case .failed:
            // Connection failed - show banner
            return true
        case .connecting:
            return false
        }
    }

    // MARK: - View Components
    
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
                }

                // Session output (reuse console view for now, filtered by session)
                if !sessionRecords.isEmpty {
                    sessionSelectorView
                }

                // Session status pill (shown during active session lifecycle)
                if txViewModel.viewModel.connectionMode == .connected {
                    ConnectionStatusStripView(
                        session: txViewModel.currentSession,
                        sessionState: txViewModel.sessionState,
                        destinationCall: connectBarViewModel.toCall,
                        viaDigipeaters: connectBarViewModel.viaDigipeaters,
                        connectionMode: connectBarViewModel.mode,
                        isTNCConnected: client.status == .connected
                    )
                }

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
                connectBarViewModel: connectBarViewModel,
                connectContext: connectCoordinator.activeContext,
                autoPathSuggestions: autoPathSuggestions.map { suggestion in
                    AutoPathSuggestionItem(
                        id: suggestion.id,
                        pathInput: suggestion.pathInput,
                        pathDisplay: suggestion.pathDisplay,
                        quality: suggestion.quality,
                        freshnessPercent: suggestion.freshnessPercent,
                        hops: suggestion.hops,
                        sourceLabel: suggestion.sourceLabel
                    )
                },
                onApplyAutoPath: { pathInput in
                    applyAutoPath(pathInput)
                },
                onSend: {
                    sendCurrentMessage()
                },
                onClear: {
                    txViewModel.clearCompose()
                },
                onConnect: {
                    connectToDestination()
                },
                onConnectBarConnect: {
                    connectWithActiveIntent(sourceContext: connectCoordinator.activeContext)
                },
                onAutoConnect: {
                    startAutoConnectAttempts(sourceContext: connectCoordinator.activeContext)
                },
                onStopAutoConnect: {
                    stopAutoConnectAttempts()
                },
                onDisconnect: {
                    disconnectFromDestination()
                },
                onForceDisconnect: {
                    forceDisconnectFromDestination()
                },
                onReconnectWithNewRouting: {
                    pendingRoutingReconnect = true
                    disconnectFromDestination()
                }
            )
            }

            // Session notification toast overlay
            if let notification = txViewModel.sessionNotification {
                SessionNotificationToast(
                    notification: notification,
                    onDismiss: { txViewModel.dismissSessionNotification() },
                    primaryActionLabel: notification.supportsPrimaryAction ? notification.defaultPrimaryActionLabel : nil,
                    onPrimaryAction: (notification.type == .peerAxdpEnabled) ? {
                        txViewModel.setUseAXDP(true)
                        sendPeerAxdpEnabledToConnectedSessions()
                        txViewModel.dismissSessionNotification()
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
            txViewModel.showSessionNotification(SessionNotification(
                type: alreadyUsing ? .peerAxdpEnabledAlreadyUsing : .peerAxdpEnabled,
                peer: peer,
                message: alreadyUsing
                    ? "has enabled AXDP – you're both using it"
                    : "has enabled AXDP – turn it on for enhanced features?"
            ))
        }
        .onReceive(txViewModel.$pendingPeerAxdpDisabledNotification.compactMap { $0 }.removeDuplicates()) { peer in
            txViewModel.showSessionNotification(SessionNotification(
                type: .peerAxdpDisabled,
                peer: peer,
                message: "has disabled AXDP"
            ))
            txViewModel.pendingPeerAxdpDisabledNotification = nil
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: txViewModel.sessionNotification)
    }

    private var sessionSelectorView: some View {
        HStack(spacing: 8) {
            Label("Sessions", systemImage: "rectangle.stack")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Sessions", selection: $activeSessionRecordID) {
                ForEach(sessionRecords) { record in
                    Text(record.label).tag(Optional(record.id))
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 360, alignment: .leading)
            .onChange(of: activeSessionRecordID) { _, newValue in
                guard let newValue else { return }
                focusSessionRecord(id: newValue)
            }

            Spacer()

            Button("Clear Closed") {
                sessionRecords.removeAll { $0.statusText == "Disconnected" || $0.statusText == "Failed" }
                if let activeID = activeSessionRecordID,
                   !sessionRecords.contains(where: { $0.id == activeID }) {
                    activeSessionRecordID = sessionRecords.first?.id
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .disabled(sessionRecords.allSatisfy { $0.statusText != "Disconnected" && $0.statusText != "Failed" })
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
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
        let lines = displayedSessionLines
        ZStack {
            ConsoleView(
                lines: lines,
                showDaySeparators: settings.showConsoleDaySeparators,
                clearedAt: $settings.terminalClearedAt
            )
            .opacity(lines.isEmpty ? 0 : 1)
            
            if lines.isEmpty {
                emptyStateView
            }
        }
    }

    private var displayedSessionLines: [TerminalLine] {
        guard let activeSessionRecordID,
              let record = sessionRecords.first(where: { $0.id == activeSessionRecordID }) else {
            return txViewModel.filteredLines
        }
        let peer = CallsignValidator.normalize(record.destination)
        guard !peer.isEmpty else { return txViewModel.filteredLines }
        return txViewModel.filteredLines.filter { line in
            let from = CallsignValidator.normalize(line.from ?? "")
            let to = CallsignValidator.normalize(line.to ?? "")
            if from == peer || to == peer {
                return true
            }
            return line.text.uppercased().contains(peer)
        }
    }

    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: txViewModel.allLines.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            
            VStack(spacing: 8) {
                if txViewModel.allLines.isEmpty {
                    Text("No messages yet")
                        .font(.headline)
                    Text("Monitoring network traffic and active sessions.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No Results")
                        .font(.headline)
                    Text("No messages matching \"\(searchModel.query)\"")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    Button("Clear Search") {
                        searchModel.clear()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background.opacity(0.8))
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
            TxLog.debug(.axdp, "AXDP send decision", [
                "destination": txViewModel.viewModel.destinationCall,
                "useAXDP": useAXDP,
                "capabilityStatus": String(describing: capabilityStatus)
            ])
            if capabilityStatus != .confirmed {
                TxLog.warning(.axdp, "Cannot send AXDP message - capability not confirmed", [
                    "destination": txViewModel.viewModel.destinationCall,
                    "status": String(describing: capabilityStatus)
                ])
                // Fall back to plain text
                var data = Data(text.utf8)
                data.append(0x0D)  // CR
                TxLog.debug(.axdp, "AXDP fallback to plain text", [
                    "destination": txViewModel.viewModel.destinationCall,
                    "payloadLen": data.count,
                    "hasMagic": AXDP.hasMagic(data)
                ])
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
            TxLog.debug(.axdp, "AXDP payload encoded for connected send", [
                "destination": txViewModel.viewModel.destinationCall,
                "messageId": message.messageId,
                "payloadLen": payload.count,
                "hasMagic": AXDP.hasMagic(payload)
            ])
        } else {
            // Standard plain-text: append CR for BBS/node compatibility
            // BBSes expect commands to end with carriage return (0x0D)
            var data = Data(text.utf8)
            data.append(0x0D)  // CR
            payload = data
            TxLog.debug(.session, "Plain-text payload encoded for connected send", [
                "destination": txViewModel.viewModel.destinationCall,
                "payloadLen": payload.count
            ])
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
        connectWithActiveIntent(sourceContext: connectCoordinator.activeContext)
    }

    private func startAutoConnectAttempts(sourceContext: ConnectSourceContext) {
        stopAutoConnectAttempts()
        syncLegacyFieldsFromConnectBar()

        let destination = CallsignValidator.normalize(connectBarViewModel.toCall)
        guard !destination.isEmpty else {
            connectBarViewModel.markFailed(reason: .invalidDraft, detail: "Destination callsign is required")
            return
        }

        let plan = ConnectAttemptPlanner.plan(mode: connectBarViewModel.mode, suggestions: connectBarViewModel.connectSuggestions)
        if connectBarViewModel.mode == .ax25ViaDigi && plan.steps.isEmpty {
            connectBarViewModel.markFailed(reason: .noRoute, detail: "No suggested digi paths available.")
            return
        }

        connectCoordinator.navigateToTerminal?()
        connectBarViewModel.beginAutoAttempting()

        autoAttemptTask = Task { @MainActor in
            let runner = ConnectAttemptRunner(maxAttempts: 3, backoffSeconds: 8)
            let result = await runner.run(
                plan: plan,
                onStatus: { attemptIndex, totalAttempts, step in
                    connectBarViewModel.updateAutoAttemptStatus(
                        autoAttemptStatusText(
                            step: step,
                            attemptIndex: attemptIndex,
                            totalAttempts: totalAttempts
                        )
                    )
                },
                execute: { step, _, _ in
                    await executeAutoAttemptStep(
                        step,
                        destination: destination,
                        sourceContext: sourceContext
                    )
                }
            )

            handleAutoAttemptRunnerResult(result)
            autoAttemptTask = nil
        }
    }

    private func stopAutoConnectAttempts() {
        let wasRunning = autoAttemptTask != nil || connectBarViewModel.isAutoAttemptInProgress
        autoAttemptTask?.cancel()
        autoAttemptTask = nil
        connectBarViewModel.endAutoAttempting()
        if wasRunning {
            txViewModel.forceDisconnect()
            connectBarViewModel.markDisconnected()
            updateActiveSessionRecordState("Disconnected")
        }
    }

    private func autoAttemptStatusText(step: ConnectAttemptStep, attemptIndex: Int, totalAttempts: Int) -> String {
        switch step {
        case .ax25ViaDigis(let digis):
            if digis.isEmpty {
                return "Trying \(attemptIndex)/\(totalAttempts): direct"
            }
            return "Trying \(attemptIndex)/\(totalAttempts): via \(formatViaPath(digis))"
        case .netrom(let nextHopOverride):
            if let nextHopOverride, !nextHopOverride.isEmpty {
                return "Trying \(attemptIndex)/\(totalAttempts): next hop \(nextHopOverride)"
            }
            return "Trying \(attemptIndex)/\(totalAttempts): next hop Auto"
        }
    }

    private func formatViaPath(_ digis: [String]) -> String {
        switch digis.count {
        case 0:
            return "Direct"
        case 1:
            return digis[0]
        case 2:
            return "\(digis[0]) → \(digis[1])"
        default:
            return "\(digis[0]) → \(digis[1]) → …"
        }
    }

    private func handleAutoAttemptRunnerResult(_ result: ConnectAttemptRunnerResult) {
        switch result.outcome {
        case .success:
            connectBarViewModel.endAutoAttempting()
        case .failed:
            connectBarViewModel.endAutoAttempting()
            if case .failed = connectBarViewModel.barState {
                return
            }
            connectBarViewModel.markFailed(reason: .timeout, detail: "Auto connect attempts exhausted.")
        case .cancelled:
            connectBarViewModel.endAutoAttempting()
            updateActiveSessionRecordState("Cancelled")
        case .unavailable(let message):
            connectBarViewModel.endAutoAttempting()
            connectBarViewModel.markFailed(reason: .unknown, detail: message)
            updateActiveSessionRecordState("Failed")
        case .noPlan:
            connectBarViewModel.endAutoAttempting()
        }
    }

    private func executeAutoAttemptStep(
        _ step: ConnectAttemptStep,
        destination: String,
        sourceContext: ConnectSourceContext
    ) async -> ConnectAttemptStepResult {
        if Task.isCancelled {
            return .cancelled
        }

        switch step {
        case .ax25ViaDigis(let digis):
            connectBarViewModel.setMode(.ax25ViaDigi, for: sourceContext)
            connectBarViewModel.applySuggestedTo(destination)
            connectBarViewModel.applyPathPreset(digis)
            syncLegacyFieldsFromConnectBar()
            let intent = connectBarViewModel.buildIntent(sourceContext: sourceContext)
            guard intent.validationErrors.isEmpty else {
                connectBarViewModel.recordAttempt(intent: intent, result: .failed)
                connectBarViewModel.markFailed(reason: .invalidDraft, detail: intent.validationErrors.joined(separator: "; "))
                updateActiveSessionRecordState("Failed")
                return .failed
            }
            return await executeAX25AutoAttempt(intent: intent, digis: digis)

        case .netrom(let nextHopOverride):
            connectBarViewModel.setMode(.netrom, for: sourceContext)
            connectBarViewModel.applySuggestedTo(destination)
            connectBarViewModel.nextHopSelection = nextHopOverride ?? ConnectBarViewModel.autoNextHopID
            connectBarViewModel.validate()
            syncLegacyFieldsFromConnectBar()
            let intent = connectBarViewModel.buildIntent(sourceContext: sourceContext)
            guard intent.validationErrors.isEmpty else {
                connectBarViewModel.recordAttempt(intent: intent, result: .failed)
                connectBarViewModel.markFailed(reason: .invalidDraft, detail: intent.validationErrors.joined(separator: "; "))
                updateActiveSessionRecordState("Failed")
                return .failed
            }
            return executeNETROMAutoAttempt(intent: intent, override: nextHopOverride)
        }
    }

    private func executeAX25AutoAttempt(intent: ConnectIntent, digis: [String]) async -> ConnectAttemptStepResult {
        upsertSessionRecord(intent: intent, statusText: "Connecting")
        connectBarViewModel.markConnecting()

        guard let frame = txViewModel.connect() else {
            connectBarViewModel.recordAttempt(intent: intent, result: .failed)
            connectBarViewModel.markFailed(reason: .unknown, detail: "Unable to build SABM frame")
            updateActiveSessionRecordState("Failed")
            return .failed
        }

        let sendResult = await sendFrameAsync(frame)
        switch sendResult {
        case .failure(let error):
            TxLog.error(.session, "SABM send failed", error: error)
            connectBarViewModel.recordAttempt(intent: intent, result: .failed)
            connectBarViewModel.markFailed(reason: .connectRejected, detail: error.localizedDescription)
            updateActiveSessionRecordState("Failed")
            return .failed
        case .success:
            TxLog.outbound(.session, "SABM sent (auto attempt)", [
                "dest": frame.destination.display,
                "via": digis.joined(separator: ",")
            ])
        }

        let waitResult = await waitForAX25ConnectOutcome(destination: intent.normalizedTo, digis: digis, timeoutSeconds: 12)
        switch waitResult {
        case .success:
            connectBarViewModel.recordAttempt(intent: intent, result: .success)
            updateActiveSessionRecordState("Connected")
            return .success
        case .cancelled:
            disconnectSession(destination: intent.normalizedTo, digis: digis)
            return .cancelled
        case .failed(let detail):
            connectBarViewModel.recordAttempt(intent: intent, result: .failed)
            connectBarViewModel.markFailed(reason: .connectRejected, detail: detail)
            updateActiveSessionRecordState("Failed")
            disconnectSession(destination: intent.normalizedTo, digis: digis)
            return .failed
        case .timeout:
            connectBarViewModel.recordAttempt(intent: intent, result: .failed)
            connectBarViewModel.markFailed(reason: .timeout, detail: "Connection timed out.")
            updateActiveSessionRecordState("Failed")
            disconnectSession(destination: intent.normalizedTo, digis: digis)
            return .timeout
        }
    }

    private func executeNETROMAutoAttempt(intent: ConnectIntent, override: String?) -> ConnectAttemptStepResult {
        let message = "NET/ROM transport unavailable"
        upsertSessionRecord(intent: intent, statusText: "Connecting")
        connectBarViewModel.markConnecting()
        connectBarViewModel.recordAttempt(intent: intent, result: .failed)
        connectBarViewModel.markFailed(reason: .unknown, detail: message)
        updateActiveSessionRecordState("Failed")
        client.appendSystemNotification(
            "NET/ROM connect requested to \(intent.normalizedTo) (next hop: \(override ?? "Auto")). \(message)."
        )
        return .unavailable(message: message)
    }

    private enum AX25AutoWaitResult {
        case success
        case failed(detail: String)
        case timeout
        case cancelled
    }

    private func waitForAX25ConnectOutcome(
        destination: String,
        digis: [String],
        timeoutSeconds: TimeInterval
    ) async -> AX25AutoWaitResult {
        let destinationAddress = CallsignNormalizer.toAddress(destination)
        let path = DigiPath.from(digis)
        let start = Date()
        let deadline = start.addingTimeInterval(timeoutSeconds)

        while Date() < deadline {
            if Task.isCancelled {
                return .cancelled
            }

            if let session = txViewModel.sessionManager.existingSession(for: destinationAddress, path: path)
                ?? txViewModel.sessionManager.connectedSession(withPeer: destinationAddress) {
                switch session.state {
                case .connected:
                    return .success
                case .error:
                    return .failed(detail: "Session entered error state.")
                case .disconnected where Date().timeIntervalSince(start) > 2:
                    return .failed(detail: "Peer disconnected before session establishment.")
                case .disconnecting:
                    return .failed(detail: "Session disconnected during connect attempt.")
                case .connecting, .disconnected:
                    break
                }
            }

            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return .cancelled
            }
        }
        return .timeout
    }

    private func disconnectSession(destination: String, digis: [String]) {
        let address = CallsignNormalizer.toAddress(destination)
        let path = DigiPath.from(digis)
        if let session = txViewModel.sessionManager.existingSession(for: address, path: path)
            ?? txViewModel.sessionManager.connectedSession(withPeer: address) {
            txViewModel.sessionManager.forceDisconnect(session: session)
        }
    }

    private func sendFrameAsync(_ frame: OutboundFrame) async -> Result<Void, Error> {
        await withCheckedContinuation { continuation in
            client.send(frame: frame) { result in
                switch result {
                case .success:
                    continuation.resume(returning: .success(()))
                case .failure(let error):
                    continuation.resume(returning: .failure(error))
                }
            }
        }
    }

    private func connectWithActiveIntent(sourceContext: ConnectSourceContext) {
        stopAutoConnectAttempts()
        syncLegacyFieldsFromConnectBar()
        let intent = connectBarViewModel.buildIntent(sourceContext: sourceContext)
        guard intent.validationErrors.isEmpty else {
            connectBarViewModel.markFailed(reason: .invalidDraft, detail: intent.validationErrors.joined(separator: "; "))
            updateActiveSessionRecordState("Failed")
            return
        }

        upsertSessionRecord(intent: intent, statusText: "Connecting")
        connectBarViewModel.markConnecting()

        switch intent.kind {
        case .ax25Direct:
            connectAX25AndRecord(intent: intent)
        case .ax25ViaDigis:
            connectAX25AndRecord(intent: intent)
        case let .netrom(nextHopOverride):
            connectNETROM(intent: intent, override: nextHopOverride)
        }
    }

    private func connectAX25AndRecord(intent: ConnectIntent) {
        guard let frame = txViewModel.connect() else {
            connectBarViewModel.markFailed(reason: .unknown, detail: "Unable to build SABM frame")
            updateActiveSessionRecordState("Failed")
            return
        }
        client.send(frame: frame) { result in
            Task { @MainActor in
                switch result {
                case .success:
                    TxLog.outbound(.session, "SABM sent", [
                        "dest": frame.destination.display
                    ])
                    connectBarViewModel.recordAttempt(intent: intent, result: .success)
                    updateActiveSessionRecordState("Connecting")
                case .failure(let error):
                    TxLog.error(.session, "SABM send failed", error: error)
                    connectBarViewModel.recordAttempt(intent: intent, result: .failed)
                    connectBarViewModel.markFailed(reason: .connectRejected, detail: error.localizedDescription)
                    updateActiveSessionRecordState("Failed")
                }
            }
        }
    }

    private func connectNETROM(intent: ConnectIntent, override: CallsignSSID?) {
        let forced = override?.stringValue ?? "Auto"
        let message = "NET/ROM transport unavailable"
        connectBarViewModel.recordAttempt(intent: intent, result: .failed)
        connectBarViewModel.markFailed(
            reason: .unknown,
            detail: message
        )
        updateActiveSessionRecordState("Failed")
        client.appendSystemNotification(
            "NET/ROM connect requested to \(intent.normalizedTo) (next hop: \(forced)). \(message)."
        )
    }

    /// Disconnect from current session
    private func disconnectFromDestination() {
        guard let frame = txViewModel.disconnect() else {
            connectBarViewModel.markFailed(reason: .unknown, detail: "Unable to build DISC frame")
            updateActiveSessionRecordState("Failed")
            return
        }
        connectBarViewModel.markDisconnecting()
        updateActiveSessionRecordState("Disconnecting")

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
                    connectBarViewModel.markFailed(reason: .unknown, detail: error.localizedDescription)
                    updateActiveSessionRecordState("Failed")
                }
            }
        }
    }

    /// Force disconnect immediately without DISC/UA exchange
    private func forceDisconnectFromDestination() {
        txViewModel.forceDisconnect()
        connectBarViewModel.markDisconnected()
        updateActiveSessionRecordState("Disconnected")
    }

    private func sessionKey(for intent: ConnectIntent) -> String {
        switch intent.kind {
        case .ax25Direct:
            return "ax25|\(intent.normalizedTo)"
        case let .ax25ViaDigis(digis):
            let via = digis.map(\.stringValue).joined(separator: ",")
            return "ax25digi|\(intent.normalizedTo)|\(via)"
        case let .netrom(nextHop):
            return "netrom|\(intent.normalizedTo)|\(nextHop?.stringValue ?? "auto")"
        }
    }

    private func upsertSessionRecord(intent: ConnectIntent, statusText: String) {
        let key = sessionKey(for: intent)
        let mode: ConnectBarMode
        let via: [String]
        switch intent.kind {
        case .ax25Direct:
            mode = .ax25
            via = []
        case let .ax25ViaDigis(digis):
            mode = .ax25ViaDigi
            via = digis.map(\.stringValue)
        case .netrom:
            mode = .netrom
            via = []
        }

        if let idx = sessionRecords.firstIndex(where: { $0.id == key }) {
            sessionRecords[idx].statusText = statusText
        } else {
            sessionRecords.insert(
                SessionRecord(
                    id: key,
                    destination: intent.normalizedTo,
                    mode: mode,
                    via: via,
                    statusText: statusText
                ),
                at: 0
            )
            sessionRecords = Array(sessionRecords.prefix(20))
        }
        activeSessionRecordID = key
    }

    private func updateActiveSessionRecordState(_ state: String) {
        guard let activeSessionRecordID,
              let idx = sessionRecords.firstIndex(where: { $0.id == activeSessionRecordID }) else { return }
        sessionRecords[idx].statusText = state
    }

    private func focusSessionRecord(id: String) {
        guard let record = sessionRecords.first(where: { $0.id == id }) else { return }
        connectBarViewModel.setMode(record.mode, for: connectCoordinator.activeContext)
        connectBarViewModel.applySuggestedTo(record.destination)
        connectBarViewModel.viaDigipeaters = record.via
        syncLegacyFieldsFromConnectBar()
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

// MARK: - View Modifiers

struct TerminalViewModifiers: ViewModifier {
    @ObservedObject var searchModel: AppToolbarSearchModel
    @Binding var showingTransferSheet: Bool
    @Binding var showingTransferError: Bool
    @Binding var currentIncomingRequest: IncomingTransferRequest?
    
    let selectedFileURL: URL?
    let transferError: String?
    
    let client: PacketEngine
    let settings: AppSettingsStore
    let sessionCoordinator: SessionCoordinator
    let txViewModel: ObservableTerminalTxViewModel
    
    let shouldShowConnectionBanner: (ConnectionStatus, ConnectionStatus) -> Bool
    let showConnectionBannerTemporarily: () -> Void
    let handlePendingIncomingTransfers: ([IncomingTransferRequest]) -> Void
    let handleFileDrop: ([NSItemProvider]) -> Bool
    let startTransfer: (String, String, TransferProtocolType, TransferCompressionSettings) -> Void
    let wireCallbacks: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: settings.myCallsign) { _, newValue in
                txViewModel.updateSourceCall(newValue)
            }
            .onChange(of: client.status) { oldValue, newValue in
                // HIG: Only show banners for unexpected events (failures, disconnects).
                // Don't celebrate expected success (TNC connection on app launch).
                if shouldShowConnectionBanner(oldValue, newValue) {
                    showConnectionBannerTemporarily()
                }
            }
            .sheet(isPresented: $showingTransferSheet) {
                SendFileSheet(
                    isPresented: $showingTransferSheet,
                    selectedFileURL: selectedFileURL,
                    connectedSessions: sessionCoordinator.connectedSessions,
                    onSend: { destination, path, transferProtocol, compressionSettings in
                        startTransfer(destination, path, transferProtocol, compressionSettings)
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
                wireCallbacks()
            }
    }
}


// MARK: - Preview

#Preview("Terminal View") {
    let settings = AppSettingsStore()
    let coordinator = SessionCoordinator()
    let connectCoordinator = ConnectCoordinator()
    let searchModel = AppToolbarSearchModel()
    TerminalView(
        client: PacketEngine(settings: settings),
        settings: settings,
        sessionCoordinator: coordinator,
        connectCoordinator: connectCoordinator,
        searchModel: searchModel
    )
    .frame(width: 800, height: 600)
}

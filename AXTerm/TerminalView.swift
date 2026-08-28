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

nonisolated enum TerminalSessionLineFilter {
    static func apply(_ lines: [TerminalLine], peer: String?) -> [TerminalLine] {
        guard let peer, !peer.isEmpty else { return lines }
        let normalizedPeer = CallsignValidator.normalize(peer)
        guard !normalizedPeer.isEmpty else { return lines }

        return lines.filter { line in
            let from = CallsignValidator.normalize(line.from ?? "")
            let to = CallsignValidator.normalize(line.to ?? "")
            if from == normalizedPeer || to == normalizedPeer {
                return true
            }
            return line.text.uppercased().contains(normalizedPeer)
        }
    }
}

nonisolated enum TerminalSessionDisplayScope {
    static func selectedPeer(
        connectionMode: TxConnectionMode,
        sessionState: AX25SessionState?,
        activeSessionRecordID: String?,
        destinationByRecordID: [String: String],
        connectedPeers: Set<String>
    ) -> String? {
        // Only filter in connected mode
        guard connectionMode == .connected else {
            return nil
        }
        
        // If a specific session is selected, use it for filtering even if disconnected,
        // so the user can review the session's history.
        guard let activeSessionRecordID,
              let destination = destinationByRecordID[activeSessionRecordID] else {
            return nil
        }

        let normalizedDestination = CallsignValidator.normalize(destination)
        guard !normalizedDestination.isEmpty else {
            return nil
        }

        return destination
    }
}

// MARK: - NET/ROM Relay

/// Phase of a NET/ROM connect-through relay handshake.
fileprivate enum NetRomRelayPhase {
    /// L2 connected to the link target, waiting for a node banner.
    ///
    /// `nextHop` is the **L2 peer** and never changes for the life of the
    /// relay — every frame, including the far node's banner, arrives from
    /// it. `remaining` is the chain of further node prompts still to
    /// drive before commanding the destination; empty means the node
    /// talking now is the one to ask.
    case awaitingBanner(destination: String, nextHop: String, remaining: [String])
    /// A C command was sent, waiting for the node's answer.
    case awaitingConnected(destination: String, nextHop: String, remaining: [String])
    /// Relay established — transparent I/O to final destination.
    case established(destination: String, nextHop: String)
}

/// When a change in session state means a live NET/ROM relay is gone.
nonisolated enum NetRomRelayLifecycle {
    /// Whether a `.disconnected` session state ends an armed relay.
    ///
    /// The distinction is level versus transition. `.disconnected` is both "the
    /// link went away" and "this session has not connected yet" — a session is
    /// created in that state and stays there until its SABM goes out, which XID
    /// negotiation can stretch to eight seconds. Only a transition *from* a
    /// state the link actually reached says the link is gone.
    static func abandonsRelay(onDisconnectFrom oldState: AX25SessionState?) -> Bool {
        guard let oldState else { return false }
        return oldState != .disconnected
    }

    /// What to call the far end on screen, given what the operator typed.
    ///
    /// The mirror of `wireDestination`, and deliberately not its equal. The
    /// wire redirect arms on *any* live relay phase, because a frame sent
    /// during the handshake would open a second link. The display waits for the
    /// circuit to actually be up: naming the destination while the node has yet
    /// to answer would announce a connection that has not happened, which is
    /// the same overclaim as calling an established circuit by its next hop,
    /// only pointing the other way.
    static func displayedDestination(typed: String, establishedDestination: String?) -> String {
        guard let destination = establishedDestination, !destination.isEmpty else { return typed }
        return destination
    }

    /// Where session bytes must actually be addressed.
    ///
    /// Through an established circuit the destination the operator typed and
    /// the peer that carries the frames come apart: they are talking to
    /// KB5YZB-1, but every frame rides the L2 link to DRLNOD, which forwards.
    /// The digipeater path goes with the typed destination and is dropped with
    /// it — the node is reached directly, and the circuit beyond it is the
    /// node's business, not ours.
    static func wireDestination(
        typed: (call: String, path: String),
        establishedNextHop: String?
    ) -> (call: String, path: String) {
        guard let nextHop = establishedNextHop, !nextHop.isEmpty else { return typed }
        return (nextHop, "")
    }

    /// What the relay stall watchdog should do after a grace period.
    enum StallCheck: Equatable {
        /// The chain delivered something — this hop earned a fresh budget.
        case chainAdvanced
        /// Nothing was delivered, but I-frames from the peer kept arriving:
        /// REJ recovery is filling a gap and the missing frame may be next.
        /// Flushing now destroys data the peer is in the middle of resending.
        case peerStillTransmitting
        /// Genuine silence — nudge or give up.
        case stalled
    }

    /// Distinguishes REJ recovery from real silence before the watchdog acts.
    ///
    /// Field capture 2026-08-28: the ASHCHT chain reached COSCO, DRLNOD's
    /// frames 4 and 5 swapped on air, and while go-back-N recovery was
    /// visibly running (frame 5 retransmitted twice) the watchdog counted
    /// 20 s of no *delivered* text as silence and flushed the gap — 240 ms
    /// before the retransmission of frame 4, which carried the "Connected
    /// to COSCO" confirmation. The connection had succeeded on air and was
    /// torn down here as unknowable.
    ///
    /// The deferral is budgeted: a peer that keeps transmitting without
    /// ever filling the gap (resending the wrong frame forever) must not
    /// hold the relay open past `deferralBudget`. The 2026-08-27 deadlock
    /// that motivated the flush — a peer that answers polls but never
    /// resends — produces no I-frames at all and still stalls on schedule.
    static func stallVerdict(
        tickMoved: Bool,
        inboundIFramesMoved: Bool,
        deferralSpent: TimeInterval,
        deferralBudget: TimeInterval
    ) -> StallCheck {
        if tickMoved { return .chainAdvanced }
        if inboundIFramesMoved && deferralSpent < deferralBudget { return .peerStillTransmitting }
        return .stalled
    }
}

/// Matches plain-text success/failure responses from BBS/NET/ROM nodes during relay handshake.
///
/// There is no standard for these strings — each node family answers a connect
/// request in its own words, and the only way to know them is to have been
/// answered. BPQ/LinBPQ, the most common node software on the air, says
/// **`###LINK MADE`**, which matches nothing that reads like "connected"
/// (captured against DRLNOD/KE0NCQ, 2026-08-26; its absence left every circuit
/// stuck one step from done — the far end's BBS banner arrived and the relay
/// still believed it was waiting).
nonisolated struct NetRomRelayResponseParser {
    static let successPatterns = [
        "connected to", "*** connected", "linked to", "link established",
        "link made"    // BPQ / LinBPQ: "###LINK MADE"
    ]
    // Deliberately not a bare "connected": "disconnected" contains it, and
    // reading a teardown notice as a successful connect is worse than missing
    // a node whose wording we have not met yet.
    static let failurePatterns = [
        "no route", "not found", "invalid command", "busy", "*** busy",
        "rejected", "failure",
        "downlink denied",  // BPQ, when the node will not connect outward
        "no connection"
    ]

    static func isSuccess(_ text: String) -> Bool {
        let lower = text.lowercased()
        return successPatterns.contains { lower.contains($0) }
    }

    static func isFailure(_ text: String) -> Bool {
        let lower = text.lowercased()
        return failurePatterns.contains { lower.contains($0) }
    }

    static func failureDetail(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

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

    // MARK: - NET/ROM Relay State

    /// Current phase of a NET/ROM connect-through handshake (nil when no relay active).
    /// fileprivate so TerminalView (same file) can both read and write the phase.
    @Published fileprivate var netRomRelayPhase: NetRomRelayPhase? {
        didSet {
            // Any phase change is forward motion, including arming. Doing
            // it here rather than at each of the dozen assignment sites is
            // the difference between a watchdog that is correct and one
            // that is correct until someone adds a thirteenth.
            relayProgressTick &+= 1
            switch netRomRelayPhase {
            case let .awaitingBanner(_, nextHop, _):
                // Mid-chain hops overwrite this immediately afterwards
                // with the node that actually just came on the link; at
                // arm time the L2 peer is the one expected to greet.
                relayWaitingOn = nextHop.uppercased()
            case .awaitingConnected:
                break
            case .established:
                relayWaitingOn = nil
                relayWitness.stopWatching()
            case nil:
                relayWaitingOn = nil
                relayWitness.stopWatching()
                relayPlannedChain = []
            }
        }
    }

    /// Reads a hop's outcome off the air when the node's own word for it is
    /// lost. Rebuilt at each ask so it always carries this station's current
    /// identity — the operator can change callsign mid-session.
    private var relayWitness = RelayLegWitness(localCallsign: "NOCALL", answers: [])

    /// Whether this handshake has permanently discarded received bytes.
    ///
    /// A flushed receive gap is not a normal timeout: the node said something
    /// and we destroyed it to get at what came after (`skipReceiveGapForHandshake`).
    /// Whatever verdict it carried is unrecoverable, so failing the attempt on
    /// silence afterwards is failing on evidence we threw away ourselves. The
    /// connect path reads this to retry the chain from a clean link rather
    /// than report a circuit that was never actually refused.
    @Published fileprivate private(set) var relayLostFrames = false

    /// Each attempt answers for its own losses. Without this a gap flushed on
    /// the first run would license a retry after the second, and so on.
    fileprivate func clearRelayFrameLoss() { relayLostFrames = false }

    /// Bumped every time the relay handshake actually moves — a banner
    /// read, a hop made, a C command sent.
    ///
    /// The stall watchdog was armed once, when L2 to the link target came
    /// up, and its twenty seconds then had to cover the *whole* chain. On
    /// 2026-08-27 that fired at 14:24:32 on a relay that had greeted at
    /// 14:24:12, made its first hop at 14:24:17 and been asked for COSCO at
    /// 14:24:22 — nine seconds of honest waiting, reported to the operator
    /// as "DRLNOD has said nothing since the link came up" and answered
    /// with a stray CR into a node that was mid-connect. Progress has to
    /// reset the clock, or a chain is judged by a budget written for one
    /// hop.
    @Published fileprivate private(set) var relayProgressTick = 0

    /// The node whose answer the relay is actually waiting on right now.
    ///
    /// Distinct from `netRomRelayNextHop`, which is the L2 peer and never
    /// changes: after the first hop is made every byte still arrives from
    /// DRLNOD, but the station being waited on is KB5YZB-7. Anything that
    /// tells the operator who has gone quiet must name the latter.
    @Published fileprivate private(set) var relayWaitingOn: String?

    /// Record that the relay moved forward, and who is now expected to speak.
    fileprivate func noteRelayProgress(waitingOn: String?) {
        relayProgressTick &+= 1
        relayWaitingOn = waitingOn?.uppercased()
    }

    /// The full chain the relay set out to walk, link target first.
    ///
    /// The phase's `remaining` list shrinks as hops are made, so by itself
    /// it cannot say which nodes are already behind us. This is the fixed
    /// frame the status strip lays the relay's position over. Set when the
    /// relay arms, cleared with the phase.
    @Published fileprivate private(set) var relayPlannedChain: [String] = []

    fileprivate func armRelayChain(_ chain: [String]) {
        relayPlannedChain = chain.map { $0.uppercased() }
    }

    /// Where the relay currently stands, hop by hop, for the status strip.
    fileprivate var relayProgressHops: [NetRomRelayProgress.Hop] {
        guard let phase = netRomRelayPhase else { return [] }
        switch phase {
        case let .awaitingBanner(destination, nextHop, remaining):
            return NetRomRelayProgress.hops(
                chain: relayPlannedChain.isEmpty ? [nextHop.uppercased()] : relayPlannedChain,
                destination: destination.uppercased(),
                remainingCount: remaining.count,
                askInFlight: false, established: false)
        case let .awaitingConnected(destination, nextHop, remaining):
            return NetRomRelayProgress.hops(
                chain: relayPlannedChain.isEmpty ? [nextHop.uppercased()] : relayPlannedChain,
                destination: destination.uppercased(),
                remainingCount: remaining.count,
                askInFlight: true, established: false)
        case let .established(destination, nextHop):
            return NetRomRelayProgress.hops(
                chain: relayPlannedChain.isEmpty ? [nextHop.uppercased()] : relayPlannedChain,
                destination: destination.uppercased(),
                remainingCount: 0,
                askInFlight: false, established: true)
        }
    }

    /// Called when relay handshake succeeds (destination, nextHop).
    var onNetRomRelayEstablished: ((String, String) -> Void)?

    /// Called when relay handshake fails (error detail).
    var onNetRomRelayFailed: ((String) -> Void)?

    /// Progress notes for the operator's transcript.
    ///
    /// The relay's own state was previously visible only in `TxLog`, which
    /// lands in a debug console the operator is not reading. That left the
    /// terminal showing frames with no way to tell a circuit from a direct
    /// link — the same screenshot could mean four different things.
    var onRelayNotice: ((String) -> Void)?

    /// Who the operator is actually conversing with on this session.
    ///
    /// The inverse of `wireDestination`. Frames on a NET/ROM circuit genuinely
    /// come from the next hop — that is honest at layer 2 — but their *content*
    /// is the far end talking, and labelling KB5YZB-7's BBS banner "DRLNOD"
    /// tells the operator something that isn't so. Once the circuit is up, BPQ
    /// forwards transparently, so everything on that link belongs to the far
    /// end until the circuit ends.
    fileprivate func conversationPeer(for session: AX25Session) -> AX25Address {
        guard case let .established(destination, nextHop) = netRomRelayPhase,
              session.remoteAddress.display.uppercased() == nextHop.uppercased()
        else { return session.remoteAddress }
        return parseCallsign(destination)
    }

    /// The peer that actually carries this session's bytes, and the path to it.
    ///
    /// Normally this is just the destination the operator typed. Through an
    /// established NET/ROM circuit the two come apart: the operator is talking
    /// to KB5YZB-1, but every frame rides the L2 link to DRLNOD, which forwards
    /// it. `destinationCall` names who they are talking to — correct for the UI,
    /// and wrong for the wire. Addressing frames to the destination opens a
    /// second, unrelated link to it (2026-08-26: the circuit came up through
    /// DRLNOD, and the first thing typed went out as a fresh SABM to KB5YZB-1).
    fileprivate var wireDestination: (call: String, path: String) {
        // Any live relay phase, not only `.established`. Field capture
        // 2026-08-26 17:53: the circuit was armed and waiting on DRLNOD's
        // banner when the operator typed, and because the redirect was gated on
        // `.established` the text opened a fresh direct link to KB5YZB-7 —
        // exactly the second link this whole mechanism exists to prevent. While
        // a relay is in flight, nothing may address the destination directly.
        return NetRomRelayLifecycle.wireDestination(
            typed: (viewModel.destinationCall, viewModel.digiPath),
            establishedNextHop: netRomRelayNextHop)
    }

    /// The next hop of a relay in any live phase, or nil when none is running.
    fileprivate var netRomRelayNextHop: String? {
        switch netRomRelayPhase {
        case let .awaitingBanner(_, nextHop, _),
             let .awaitingConnected(_, nextHop, _):
            return nextHop
        case let .established(_, nextHop):
            return nextHop
        case nil:
            return nil
        }
    }

    /// The two ends of an established relay, for anything that names the far
    /// end to the operator.
    ///
    /// Bringing a NET/ROM circuit up rewrites the connect bar to the next hop,
    /// because that is where the L2 link genuinely goes. Nothing rewrites it
    /// back, so every readout fed from the connect bar keeps saying DRLNOD long
    /// after the conversation moved to KB5YZB-7 (2026-08-27, reported as
    /// "it says I'm connected to drlnode... the endpoint right now is
    /// kb5yzb-7"). The wire fields stay as they are — they are still right
    /// about the wire — and the displays ask here instead.
    fileprivate var relayConversation: (destination: String, nextHop: String)? {
        guard case let .established(destination, nextHop) = netRomRelayPhase else { return nil }
        return (destination, nextHop)
    }

    /// The far end of a relay still being set up, or nil when none is.
    ///
    /// Separate from `relayConversation`, which is deliberately established-only
    /// so nothing claims a live circuit early. This one is for saying what is
    /// being *attempted*, which is a different and honest thing to show.
    fileprivate var relayHandshakeDestination: String? {
        switch netRomRelayPhase {
        case let .awaitingBanner(destination, _, _),
             let .awaitingConnected(destination, _, _):
            return destination
        case .established, nil:
            return nil
        }
    }

    /// Whether a relay is running but has not yet carried anything.
    ///
    /// Typed text must wait here. Sending it to the next hop would issue it as
    /// a *node command* to DRLNOD rather than to KB5YZB-7, and sending it to
    /// the destination opens the second link. Neither is what the operator
    /// meant, so nothing goes out until the circuit is up.
    fileprivate var relayIsHandshaking: Bool {
        switch netRomRelayPhase {
        case .awaitingBanner, .awaitingConnected: return true
        case .established, nil: return false
        }
    }

    /// I-frames the link peer has sent this session, deliverable or not.
    /// The relay watchdog samples it to tell REJ recovery from real silence.
    fileprivate var relayInboundIFrameCount: Int {
        currentSession?.stateMachine.inboundIFrameCount ?? 0
    }

    /// Called to send data frames produced by sessionManager.sendData (e.g. relay C command).
    var onSendFrames: (([OutboundFrame]) -> Void)?

    // MARK: - Manual Relay Detection

    /// Tracks user-initiated NET/ROM relay commands and responses.
    fileprivate var manualRelayDetector = ManualRelayDetector()

    /// Published destination of the currently active manual relay, or nil when no relay is established.
    @Published private(set) var manualRelayDestination: String?

    /// Clear manual relay state (call on L2 session disconnect).
    fileprivate func clearManualRelay() {
        manualRelayDetector.clear()
        manualRelayDestination = nil
    }

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
                
                // When a session disconnects, flush any remaining buffered text then clear per-peer state
                if newState == .disconnected {
                    let peerKey = session.remoteAddress.display.uppercased()
                    self?.peersInAXDPReassembly.remove(peerKey)
                    // Flush partial line buffer before clearing — don't silently discard
                    // text that hasn't reached a CR/LF yet (e.g. BPQ node data split across frames)
                    if let remainingData = self?.currentLineBuffers[peerKey], !remainingData.isEmpty {
                        let line = String(data: remainingData, encoding: .utf8) ??
                                   String(data: remainingData, encoding: .ascii) ??
                                   remainingData.map { String(format: "%02X", $0) }.joined()
                        TxLog.debug(.session, "Flushing partial line buffer on disconnect", [
                            "peer": peerKey,
                            "lineLength": line.count,
                            "preview": String(line.prefix(50))
                        ])
                        self?.onPlainTextChatReceived?(self?.conversationPeer(for: session) ?? session.remoteAddress, line, session.lastReceivedVia)
                    }
                    self?.currentLineBuffers.removeValue(forKey: peerKey)

                    // Clear any in-progress send indicator for this peer.
                    // If the session drops while an I-frame is in-flight (DM received, T1
                    // exhausted, etc.) the ACK that would normally advance bytesAcked and
                    // trigger clearOutboundProgressAfterDelay() never arrives, leaving the
                    // "Sending…" badge stuck indefinitely.
                    if self?.currentOutboundProgress?.destination.uppercased() == peerKey {
                        self?.clearOutboundProgress()
                    }
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
                DispatchQueue.main.async {
                    self?.applyFiltering()
                }
            }
            .store(in: &cancellables)
    }

    private func setupConsoleSubscription(client: PacketEngine) {
        // Throttle to at most 1 UI update per 80 ms (~12 fps for the terminal scroll).
        // Without this, every incoming packet fires objectWillChange → full TerminalView
        // body re-evaluation → 20-30 renders/second under active monitoring, which
        // saturates the main thread and delays the sidebar checkmark by ~1 s.
        client.$consoleLines
            .receive(on: DispatchQueue.main)
            .throttle(for: .milliseconds(80), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] lines in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    self.allLines = lines
                    self.applyFiltering()
                }
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
            // Acks come from whoever carries the frames — the next hop through a
            // relay, the destination otherwise. See `OutboundMessageProgress.ackPeer`.
            ackPeer: wireDestination.call.isEmpty ? destination : wireDestination.call,
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

    /// Record a heard digipeat echo of one of our outbound I-frames.
    /// Advances the delivery indicator to "relayed" (never to "delivered" —
    /// digipeating is fire-and-forget; only the peer's ack proves receipt).
    func recordOutboundRelay(destination: String, digis: [String]) {
        guard var prog = currentOutboundProgress,
              // Our outbound frames are addressed to whoever carries them, so a
              // digipeat echo names the ack peer, not the final destination.
              destination.uppercased() == prog.ackPeer.uppercased(),
              !(prog.hasAcks && prog.isComplete),
              digis.contains(where: { !prog.relayedDigis.contains($0) })
        else { return }
        prog.recordRelay(digis: digis, at: Date())
        currentOutboundProgress = prog
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
              session.remoteAddress.display.uppercased() == prog.ackPeer.uppercased()
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
            onPlainTextChatReceived?(conversationPeer(for: session), trimmedText, session.lastReceivedVia)
            
            // Keep transcript bounded for performance
            if sessionTranscriptLines.count > 1000 {
                sessionTranscriptLines.removeFirst(sessionTranscriptLines.count - 1000)
            }
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

        // NET/ROM relay phase: intercept handshake data from next-hop node.
        // Side effects (send C command, update phase, fire callbacks) happen here;
        // the data still falls through so the user sees all node text in the transcript.
        if let phase = netRomRelayPhase {
            switch phase {
            case let .awaitingBanner(destination, nextHop, remaining) where peerKey == nextHop.uppercased():
                // A node greeted us. Ask it for the next thing in the
                // chain — another node when the route needs one, else the
                // destination itself.
                let ask = remaining.first ?? destination
                let speaker = (remaining.isEmpty ? nextHop : nextHop).uppercased()
                netRomRelayPhase = .awaitingConnected(
                    destination: destination, nextHop: nextHop, remaining: remaining)
                // The chain moved: this node greeted and has now been asked
                // for the next thing. Its answer gets its own budget.
                noteRelayProgress(waitingOn: speaker)
                onRelayNotice?("\(speaker) answered — asking it to connect to \(ask.uppercased()). "
                               + "Anything below is a node talking, not \(destination.uppercased()).")
                sendRelayConnectCommand(destination: ask)
                TxLog.outbound(.session, "Node-prompt relay: banner received, C command sent", [
                    "destination": destination, "asked": ask, "nextHop": nextHop,
                    "remaining": remaining.joined(separator: ",")
                ])

            case let .awaitingConnected(destination, nextHop, remaining) where peerKey == nextHop.uppercased():
                // Check node response for success/failure patterns
                let text = String(data: data, encoding: .utf8) ?? ""
                if NetRomRelayResponseParser.isSuccess(text) {
                    advanceRelayPastHop(destination: destination, nextHop: nextHop,
                                        remaining: remaining, evidence: "node said so")
                } else if NetRomRelayResponseParser.isFailure(text) {
                    failRelay(detail: NetRomRelayResponseParser.failureDetail(text),
                              destination: destination, nextHop: nextHop,
                              evidence: String(text.prefix(80)))
                }
                // Fall through — node response text is shown in the transcript either way

            default:
                break
            }
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
                    onPlainTextChatReceived?(conversationPeer(for: session), line, session.lastReceivedVia)
                    // Manual relay detection: inspect each received line for ###LINK MADE/FAILED / ENTER COMMAND
                    let prevRelayState = manualRelayDetector.state
                    manualRelayDetector.processIncoming(line)
                    manualRelayDestination = manualRelayDetector.activeRelayDestination
                    if manualRelayDetector.state != prevRelayState {
                        TxLog.debug(.session, "Manual relay state transition (incoming)", [
                            "from": "\(prevRelayState)",
                            "to": "\(manualRelayDetector.state)",
                            "trigger": String(line.prefix(80))
                        ])
                    }
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

    /// Send a `C DESTINATION\r` command through the current AX.25 session to relay to a node.
    /// Does what an operator does when a node's greeting arrives mangled.
    ///
    /// Two different stalls, in the order they can be fixed. If frames are
    /// stranded behind a lost one, nothing new can be delivered either — a CR
    /// would just add another frame to the same queue — so the gap is cleared
    /// first and the buffered greeting comes through, which is all the
    /// handshake was waiting for. Only if nothing is stranded is the node
    /// actually silent, and then a bare CR is the standard prod: every node
    /// re-prints its prompt for one.
    ///
    /// - Returns: what was tried, for the operator's benefit.
    fileprivate enum RelayNudge { case clearedGap, prompted, nothingToTry }

    @discardableResult
    fileprivate func nudgeStalledRelay() -> RelayNudge {
        guard let session = currentSession else { return .nothingToTry }

        let (frames, flushed) = sessionManager.flushReceiveGapForHandshake(for: session)
        if flushed {
            relayLostFrames = true
            onSendFrames?(frames)
            TxLog.outbound(.session, "Node-prompt relay: cleared a receive gap to read the banner", [
                "nextHop": session.remoteAddress.display
            ])
            return .clearedGap
        }

        let cr = Data("\r".utf8)
        let prompt = sessionManager.sendData(cr, to: session.remoteAddress,
                                             path: session.path,
                                             channel: session.channel, pid: 0xF0)
        onSendFrames?(prompt)
        TxLog.outbound(.session, "Node-prompt relay: prompted a silent node with CR", [
            "nextHop": session.remoteAddress.display, "frames": prompt.count
        ])
        return .prompted
    }

    /// One hop of the chain is up: either the relay is done or the next node
    /// is now on the far end and will greet in its own time.
    ///
    /// Shared because there are two ways to learn this and they must produce
    /// the same state. The node's own announcement is the usual one; a UA
    /// seen on the node's outward link is the one that still works when the
    /// announcement is lost (`RelayLegWitness`).
    fileprivate func advanceRelayPastHop(
        destination: String, nextHop: String, remaining: [String], evidence: String
    ) {
        relayWitness.stopWatching()
        guard let reached = remaining.first else {
            netRomRelayPhase = .established(destination: destination, nextHop: nextHop)
            onNetRomRelayEstablished?(destination, nextHop)
            TxLog.inbound(.session, "Node-prompt relay established", [
                "destination": destination, "nextHop": nextHop, "evidence": evidence
            ])
            return
        }
        let rest = Array(remaining.dropFirst())
        netRomRelayPhase = .awaitingBanner(
            destination: destination, nextHop: nextHop, remaining: rest)
        // A hop was made. From here the station expected to speak is the one
        // that just came on the link, not the L2 peer its bytes travel through.
        noteRelayProgress(waitingOn: reached)
        onRelayNotice?("\(reached.uppercased()) is on the link. "
                       + "Waiting for its prompt before going further.")
        TxLog.inbound(.session, "Node-prompt relay hop made", [
            "destination": destination, "reached": reached,
            "remaining": rest.joined(separator: ","), "evidence": evidence
        ])
    }

    fileprivate func failRelay(
        detail: String, destination: String, nextHop: String, evidence: String
    ) {
        relayWitness.stopWatching()
        netRomRelayPhase = nil
        onNetRomRelayFailed?(detail)
        TxLog.inbound(.session, "Node-prompt relay handshake failed", [
            "destination": destination, "nextHop": nextHop, "response": evidence
        ])
    }

    /// A U-frame between two stations this one is not party to.
    ///
    /// Handed to the witness, which cares about exactly one conversation: the
    /// node's outward connect for the hop we just asked for, dialled under our
    /// own callsign with an SSID the node chose.
    fileprivate func noteForeignUFrame(from: String, to: String, uType: AX25UType?) {
        guard case let .awaitingConnected(destination, nextHop, remaining) = netRomRelayPhase,
              let verdict = relayWitness.observe(from: from, to: to, uType: uType)
        else { return }
        switch verdict {
        case let .made(hop):
            // Said out loud because it contradicts what the operator can see:
            // the node has not announced anything, and the transcript will
            // look stalled right up until this line.
            onRelayNotice?("\(hop) answered \(nextHop.uppercased())'s call with UA — "
                           + "the hop is up. Read off the air, not from \(nextHop.uppercased()).")
            advanceRelayPastHop(destination: destination, nextHop: nextHop,
                                remaining: remaining, evidence: "UA on \(nextHop)'s outward link")
        case let .refused(hop):
            failRelay(detail: "\(hop) answered with DM — it is not accepting connections.",
                      destination: destination, nextHop: nextHop,
                      evidence: "DM on \(nextHop)'s outward link")
        }
    }

    private func sendRelayConnectCommand(destination: String) {
        guard let session = currentSession else {
            TxLog.error(.session, "Node-prompt relay: no current session to send C command through", ["destination": destination])
            return
        }
        // Armed here rather than at the phase change: this is the moment the
        // node is asked, and the SABM it sends on our behalf follows within
        // seconds. Arming earlier would watch a hop nobody has requested.
        relayWitness = RelayLegWitness(
            localCallsign: sessionManager.localCallsign.display,
            answers: sessionManager.answeredAddresses.map(\.display))
        relayWitness.expect(destination)

        let command = Data("C \(destination)\r".utf8)
        let frames = sessionManager.sendData(command, to: session.remoteAddress, path: session.path, channel: session.channel, pid: 0xF0)
        onSendFrames?(frames)
        TxLog.outbound(.session, "Node-prompt relay connect command queued", [
            "destination": destination,
            "nextHop": session.remoteAddress.display,
            "frames": frames.count
        ])
    }

    // MARK: - Actions

    func updateSourceCall(_ call: String) {
        viewModel.sourceCall = call
        let (baseCall, ssid) = CallsignNormalizer.parse(call.isEmpty ? "NOCALL" : call)
        let newAddress = AX25Address(call: baseCall.isEmpty ? "NOCALL" : baseCall, ssid: ssid)

        // Purge stale sessions if callsign actually changed
        if sessionManager.localCallsign != newAddress {
            sessionManager.purgeSessionsForCallsignChange()
        }

        sessionManager.localCallsign = newAddress
        print("[updateSourceCall] Set localCallsign: call='\(baseCall)', ssid=\(ssid)")

        // Clear currentSession if it has a stale localAddress
        if let session = currentSession, session.localAddress != newAddress {
            currentSession = nil
        }
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

        // Manual relay detection: watch for the user typing "C <callsign>" commands.
        if let text = displayInfo {
            let prevRelayState = manualRelayDetector.state
            manualRelayDetector.processOutgoing(text)
            manualRelayDestination = manualRelayDetector.activeRelayDestination
            if manualRelayDetector.state != prevRelayState {
                TxLog.debug(.session, "Manual relay state transition (outgoing)", [
                    "from": "\(prevRelayState)",
                    "to": "\(manualRelayDetector.state)",
                    "trigger": String(text.prefix(80))
                ])
            }
        }

        // Through a relay this is the next hop, not the destination — see
        // `wireDestination`.
        let wire = wireDestination
        let dest = parseCallsign(wire.call)
        let path = parsePath(wire.path)

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
        // If we have a destination specified, look for that specific session.
        // Through a relay that is the next-hop link, not the destination — the
        // circuit lives on the link to the node (see `wireDestination`), and so
        // do its state, its timers, and what Disconnect has to tear down.
        let wire = wireDestination
        if !wire.call.isEmpty {
            let dest = parseCallsign(wire.call)
            let path = parsePath(wire.path)

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
            // Auto-populate from the session so the operator can see who they
            // are connected to — the path as well as the callsign. Restoring
            // the peer alone would redraw a session through DRLNOD as direct,
            // and the next thing typed would go out the wrong way.
            if viewModel.destinationCall.isEmpty {
                viewModel.destinationCall = session.remoteAddress.display
                viewModel.digiPath = session.path.display
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
    var relayDestination: String?

    var label: String {
        if let relay = relayDestination {
            return "\(destination) → \(relay)"
        }
        return destination
    }
}

// MARK: - Terminal View

/// Main terminal view with session output and transmission controls
struct TerminalView: View {
    /// Tapping a callsign in the console asks who it is; long-pressing opens
    /// the menu of things to do with it. Supplied by the shell, because who
    /// presents a profile is the shell's business, not the terminal's.
    var onIdentity: ((String) -> Void)?
    var onIdentityMenu: ((String) -> Void)?
    @ObservedObject var client: PacketEngine
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var sessionCoordinator: SessionCoordinator
    /// Text received from a connected station, with that station's callsign.
    ///
    /// One hook rather than several: node aliases and white pages facts are
    /// both read out of the same bytes, and the owner of both lives above this
    /// view. Nil on platforms with no mailbox UI.
    let onSessionText: ((String, String) -> Void)?
    @ObservedObject var connectCoordinator: ConnectCoordinator
    /// What nodes say they can reach, as a second source of connect routes.
    ///
    /// Without it the connect bar knows only the ten destinations this station
    /// has measured a route to, so typing a name the operator just read on the
    /// Nodes page answered "No known route" — the app holding the answer in
    /// one screen and refusing it in another.
    @ObservedObject var nodeAliases: NodeAliasStore
    /// Capability verdicts for the strategy ladder — read for planning,
    /// never observed: a verdict changing mid-plan is next plan's business.
    let nodeCapabilities: NodeCapabilityStore?
    @StateObject private var txViewModel: ObservableTerminalTxViewModel
    @StateObject private var connectBarViewModel: ConnectBarViewModel
    @ObservedObject var searchModel: AppToolbarSearchModel
    /// Optional app-wide position source for "insert my position".
    var locationService: StationLocationService?

    @State private var selectedTab: TerminalTab = .session
    @State private var showingTransferSheet = false
    @State private var selectedFileURL: URL?
    /// Drives the iOS file importer; unused on macOS, which runs a panel.
    @State private var isPickingTransfer = false

    // Transfer error alert
    @State private var transferError: String?
    @State private var showingTransferError = false

    // Incoming transfer sheet - using item binding for .sheet(item:)
    @State private var currentIncomingRequest: IncomingTransferRequest?

    @State private var lastAutoFilledPath: String = ""
    @State private var lastObservedDestination: String = ""
    @State private var cachedAutoPathSuggestions: [TerminalAutoPathCandidate] = []
    @State private var sessionRecords: [SessionRecord] = []
    @State private var activeSessionRecordID: String?
    @State private var autoAttemptTask: Task<Void, Never>?
    @State private var pendingRoutingReconnect = false
    @State private var connectBarRefreshWorkItem: DispatchWorkItem?

    init(
        client: PacketEngine,
        settings: AppSettingsStore,
        sessionCoordinator: SessionCoordinator,
        connectCoordinator: ConnectCoordinator,
        nodeAliases: NodeAliasStore,
        nodeCapabilities: NodeCapabilityStore? = nil,
        onSessionText: ((String, String) -> Void)? = nil,
        searchModel: AppToolbarSearchModel,
        locationService: StationLocationService? = nil,
        onIdentity: ((String) -> Void)? = nil,
        onIdentityMenu: ((String) -> Void)? = nil
    ) {
        self.onIdentity = onIdentity
        self.onIdentityMenu = onIdentityMenu
        self.client = client
        _settings = ObservedObject(wrappedValue: settings)
        _sessionCoordinator = ObservedObject(wrappedValue: sessionCoordinator)
        _connectCoordinator = ObservedObject(wrappedValue: connectCoordinator)
        _nodeAliases = ObservedObject(wrappedValue: nodeAliases)
        self.nodeCapabilities = nodeCapabilities
        self.onSessionText = onSessionText
        self.searchModel = searchModel
        self.locationService = locationService

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
                // Leaving Terminal destroys this view, and with it the view
                // model holding `currentSession` — while the session itself
                // carries on in the session manager. Coming back with no
                // re-adoption showed "Not connected" over a live link that was
                // still exchanging I-frames. Sessions outlive the UI
                // (CLAUDE.md §5), so the view has to ask rather than assume.
                txViewModel.refreshCurrentSession()

                txViewModel.updateSearchQuery(searchModel.query)
                lastObservedDestination = txViewModel.viewModel.destinationCall
                cachedAutoPathSuggestions = buildAutoPathCandidates(for: txViewModel.viewModel.destinationCall)
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
                scheduleConnectBarRefresh()
            }
            .onReceive(client.$packets) { _ in
                scheduleConnectBarRefresh()
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
            .onChange(of: sessionCoordinator.netRomDriver.circuits) { _, _ in
                syncCircuitSessionRecords()
            }
            .onChange(of: txViewModel.sessionState) { oldState, newState in
                switch newState {
                case .connecting:
                    connectBarViewModel.markConnecting()
                    updateActiveSessionRecordState("Connecting")
                case .connected:
                    // When a NET/ROM relay is in progress, L2 to the next-hop just became
                    // connected. Do not call markConnected yet — the relay handshake will
                    // call onNetRomRelayEstablished (→ markConnected) once the node confirms.
                    if txViewModel.relayIsHandshaking {
                        // Say which of the two connections just happened. Both
                        // are "connected" and only one is what was asked for,
                        // and the node's own text arrives next — without a line
                        // marking the stage it reads as the destination
                        // answering (reported 2026-08-27).
                        if let hop = txViewModel.netRomRelayNextHop,
                           let destination = txViewModel.relayHandshakeDestination {
                            client.appendSystemNotification(
                                "Link to \(hop.uppercased()) is up. Waiting for its prompt "
                                + "before asking it to connect to \(destination.uppercased()) "
                                + "— not connected to \(destination.uppercased()) yet.")
                        }
                        // The link to the node is up; its banner is what starts
                        // the handshake. DRLNOD accepted the connect at 17:52:41
                        // on 2026-08-26 and then said nothing for three minutes,
                        // and the relay waited the whole time in silence.
                        startRelayBannerWatchdog()
                        break
                    }
                    guard txViewModel.netRomRelayPhase == nil else { break }
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
                    // Abandon a relay only when a link that existed went away.
                    //
                    // `.disconnected` is also the state a brand-new session sits
                    // in between being created and its SABM going out, and XID
                    // negotiation makes that window seconds long (8 s against
                    // DRLNOD on 2026-08-26, which answers XID with DM). Clearing
                    // on the level rather than the transition disarmed every
                    // NET/ROM connect the moment its own session appeared: the
                    // link to the next hop came up with nothing left to answer
                    // the node's banner, and the operator was parked at
                    // "ENTER COMMAND:" with a session labelled for a station it
                    // had never asked for.
                    if NetRomRelayLifecycle.abandonsRelay(onDisconnectFrom: oldState) {
                        txViewModel.netRomRelayPhase = nil
                        txViewModel.clearManualRelay()
                    }
                    connectBarViewModel.markDisconnected()
                    updateActiveSessionRecordState("Disconnected")
                    if sessionCoordinator.connectedSessions.isEmpty {
                        activeSessionRecordID = nil
                    }
                    if pendingRoutingReconnect {
                        pendingRoutingReconnect = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            connectWithActiveIntent(sourceContext: connectCoordinator.activeContext)
                        }
                    }
                case .error:
                    // If a relay was active, abandon it on error
                    txViewModel.netRomRelayPhase = nil
                    txViewModel.clearManualRelay()
                    connectBarViewModel.markFailed(reason: .unknown, detail: "Session state entered error")
                    updateActiveSessionRecordState("Failed")
                    if sessionCoordinator.connectedSessions.isEmpty {
                        activeSessionRecordID = nil
                    }
                case .none:
                    break
                }
                syncAdaptiveSelection()
            }
            .onChange(of: txViewModel.viewModel.destinationCall) { _, newValue in
                applyAutoPathSuggestionIfNeeded(previousDestination: lastObservedDestination, newDestination: newValue)
                lastObservedDestination = newValue
                cachedAutoPathSuggestions = buildAutoPathCandidates(for: newValue)
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
            .onChange(of: txViewModel.manualRelayDestination) { _, newDest in
                updateActiveSessionRelayDestination(newDest)
            }
            .onDisappear {
                stopAutoConnectAttempts()
            }
            #if os(iOS)
            .fileImporter(isPresented: $isPickingTransfer,
                          allowedContentTypes: [.item],
                          allowsMultipleSelection: false,
                          onCompletion: acceptPickedTransfer)
            #endif
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
        let observe = onSessionText
        txViewModel.onPlainTextChatReceived = { [weak client] from, text, via in
            // A BBS session the operator opened themselves. Reading structure
            // out of what already arrived costs nobody anything; asking the
            // far end for it would spend their channel on our convenience.
            observe?(text, from.display.uppercased())
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

        // A digipeater repeating one of our own I-frames is evidence the frame
        // cleared that hop. It advances the delivery indicator to "relayed" —
        // never to "delivered": digipeating is fire-and-forget, and only the
        // peer's ack proves receipt.
        //
        // Detected in SessionCoordinator because that is where inbound frames
        // are seen. It used to live in this view model's own packet handler,
        // which was superseded in February; nothing has set `relayedDigis`
        // since, so OutboundProgressView's "Relayed by …" branch could not
        // render.
        sessionCoordinator.onForeignUFrame = { [weak txViewModel] from, to, uType in
            txViewModel?.noteForeignUFrame(from: from, to: to, uType: uType)
        }

        sessionCoordinator.onOutboundRelayHeard = { [weak txViewModel] destination, digis in
            txViewModel?.recordOutboundRelay(destination: destination, digis: digis)
        }

        // NET/ROM relay: send data frames produced by sessionManager.sendData (e.g. C command)
        txViewModel.onSendFrames = { [weak client] frames in
            for frame in frames {
                client?.send(frame: frame) { result in
                    Task { @MainActor in
                        if case .failure(let error) = result {
                            TxLog.error(.session, "Node-prompt relay frame send failed", error: error, [
                                "type": frame.frameType,
                                "dest": frame.destination.display
                            ])
                        }
                    }
                }
            }
        }

        // NET/ROM relay: update connect bar when relay is established or fails.
        txViewModel.onNetRomRelayEstablished = { [weak connectBarViewModel, weak txViewModel, weak client] destination, nextHop in
            client?.appendSystemNotification(
                "NET/ROM circuit to \(destination.uppercased()) established via \(nextHop.uppercased()).")
            connectBarViewModel?.markConnected(
                sourceCall: txViewModel?.viewModel.sourceCall,
                destination: destination,
                via: [],
                transportMode: .netrom,
                forcedNextHop: nextHop
            )
        }
        txViewModel.onRelayNotice = { [weak client] note in
            client?.appendSystemNotification(note)
        }
        txViewModel.onNetRomRelayFailed = { [weak connectBarViewModel, weak client] detail in
            client?.appendSystemNotification("NET/ROM circuit refused: \(detail)")
            connectBarViewModel?.markFailed(reason: .connectRejected, detail: detail)
        }

        // onSessionStateChanged is now handled inside txViewModel.setupSessionCallbacks()
    }

    private var autoPathSuggestions: [TerminalAutoPathCandidate] { cachedAutoPathSuggestions }

    private func refreshConnectBarData() {
        let neighbors = client.netRomIntegration?.currentNeighbors(forMode: .hybrid) ?? []
        let routes = client.netRomIntegration?.currentRoutes(forMode: .hybrid) ?? []
        connectBarViewModel.updateRuntimeData(
            stations: client.stations,
            neighbors: neighbors,
            routes: routes,
            packets: client.packets,
            favorites: settings.watchCallsigns,
            directoryRoutes: nodeAliases.directory.connectRoutes()
        )
    }

    // Debounced entry point for packet/station stream handlers.
    // rebuildObservedPaths iterates every packet — running it on every arrival
    // (potentially 10+ times/second) stalls the main thread and delays rendering.
    private func scheduleConnectBarRefresh() {
        connectBarRefreshWorkItem?.cancel()
        let item = DispatchWorkItem { refreshConnectBarData() }
        connectBarRefreshWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private func handleConnectRequest(_ request: ConnectRequest) {
        txViewModel.connectionMode.wrappedValue = .connected
        if request.intent.sourceContext == .stations {
            let normalized = CallsignValidator.normalize(request.intent.to)
            let hasRoute = client.netRomIntegration?.bestRouteTo(normalized) != nil
            var requestVias: [String] = []
            if case let .ax25ViaDigis(digis) = request.intent.kind {
                requestVias = digis.map(\.stringValue)
            }
            let selection = SidebarStationSelection(
                callsign: normalized,
                context: .stations,
                lastUsedMode: request.mode,
                hasNetRomRoute: hasRoute,
                viaDigipeaters: requestVias
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

    // MARK: - View Components

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
                        sessionState: displayedSessionState,
                        destinationCall: displayedDestination,
                        viaDigipeaters: displayedVia,
                        connectionMode: displayedConnectionMode,
                        isTNCConnected: client.status == .connected,
                        relayHops: txViewModel.relayProgressHops
                    )
                }

                // Station filter indicator — shown whenever a sidebar station is selected.
                // Makes the active filter visible so the user knows why output is narrowed.
                if let stationFilter = client.selectedStationCall {
                    HStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal.decrease.circle.fill")
                            .foregroundStyle(.blue)
                            .font(.subheadline)
                        Text("Filtered: \(stationFilter)")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        Spacer()
                        Button(action: {
                            client.selectedStationCall = nil
                        }) {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .font(.subheadline)
                        .foregroundStyle(.blue)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.blue.opacity(0.08))
                    .transition(.move(edge: .top).combined(with: .opacity))
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
                relayDestination: txViewModel.relayConversation?.destination,
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
                },
                onInsertPosition: locationService.map { service in
                    {
                        Task { @MainActor in
                            guard let location = await service.currentLocation() else { return }
                            let stamp = StationLocationFormat.stamp(location)
                            let text = txViewModel.composeText.wrappedValue
                            txViewModel.composeText.wrappedValue = text.isEmpty ? stamp : text + " " + stamp
                        }
                    }
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
                Text("All Traffic").tag(Optional<String>.none)
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
                    activeSessionRecordID = nil
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .disabled(sessionRecords.allSatisfy { $0.statusText != "Disconnected" && $0.statusText != "Failed" })
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(platform: .platformCardBackground).opacity(0.5))
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
                clearedAt: $settings.terminalClearedAt,
                localCallsign: settings.myCallsign,
                onIdentity: onIdentity,
                onIdentityMenu: onIdentityMenu
            )
            .opacity(lines.isEmpty ? 0 : 1)
            
            if lines.isEmpty {
                emptyStateView
            }
        }
    }

    private var displayedSessionLines: [TerminalLine] {
        // Sidebar station filter overrides session-peer filter — clicking any station in the
        // sidebar shows all console traffic involving that station, matching the Packets view.
        if let stationCall = client.selectedStationCall, !stationCall.isEmpty {
            let normalized = CallsignValidator.normalize(stationCall)
            return txViewModel.filteredLines.filter { line in
                CallsignValidator.normalize(line.from ?? "") == normalized ||
                CallsignValidator.normalize(line.to ?? "") == normalized ||
                line.via.contains { CallsignValidator.normalize($0) == normalized }
            }
        }

        let destinationByRecordID = Dictionary(uniqueKeysWithValues: sessionRecords.map { ($0.id, $0.destination) })
        let connectedPeers = Set(
            sessionCoordinator.connectedSessions
                .map { CallsignValidator.normalize($0.remoteAddress.display) }
                .filter { !$0.isEmpty }
        )
        let selectedPeer = TerminalSessionDisplayScope.selectedPeer(
            connectionMode: txViewModel.viewModel.connectionMode,
            sessionState: txViewModel.sessionState,
            activeSessionRecordID: activeSessionRecordID,
            destinationByRecordID: destinationByRecordID,
            connectedPeers: connectedPeers
        )
        return TerminalSessionLineFilter.apply(txViewModel.filteredLines, peer: selectedPeer)
    }

    @ViewBuilder
    private var emptyStateView: some View {
        let stationFilter = client.selectedStationCall
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
                } else if let call = stationFilter {
                    Text("No traffic for \(call)")
                        .font(.headline)
                    Text("No messages heard involving this station.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Show All") {
                        client.selectedStationCall = nil
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 8)
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
    /// Put the composed line on a NET/ROM circuit.
    ///
    /// The bytes we transmit are a datagram inside an I-frame addressed
    /// to the *neighbor*, so nothing legible would ever appear in the
    /// transcript on its own — the echo below is what makes the
    /// conversation readable, the same role the raw console plays for
    /// AX.25 text.
    private func sendOnCircuit(_ circuitID: NetRomCircuitID) {
        let text = txViewModel.viewModel.composeText
        guard !text.isEmpty else { return }
        var payload = Data(text.utf8)
        payload.append(0x0D)  // CR, as node command lines expect
        sessionCoordinator.netRomDriver.send(payload, on: circuitID)
        client.appendSessionChatLine(from: settings.myCallsign, text: text)
        txViewModel.clearCompose()
    }

    /// Mirror live circuits into the session picker so a circuit is
    /// selectable, filterable, and typeable like any other session
    /// (CLAUDE.md §5 lists NET/ROM circuits as a session type).
    private func syncCircuitSessionRecords() {
        let circuits = sessionCoordinator.netRomDriver.circuits
        for circuit in circuits {
            let key = NetRomCircuitSession.recordID(for: circuit.id)
            let status = NetRomCircuitSession.statusText(for: circuit.state)
            if let idx = sessionRecords.firstIndex(where: { $0.id == key }) {
                sessionRecords[idx].statusText = status
            } else {
                let hop = circuit.neighbor.display == circuit.destination.display
                    ? [] : [circuit.neighbor.display]
                sessionRecords.insert(
                    SessionRecord(
                        id: key,
                        // The name the operator used, with the callsign
                        // actually on the air.
                        destination: circuit.displayName,
                        mode: .netrom,
                        via: hop,
                        statusText: status,
                        relayDestination: nil
                    ),
                    at: 0
                )
                sessionRecords = Array(sessionRecords.prefix(20))
                // Selecting it is the point: the operator asked for this
                // circuit, so typing should reach it without a second step.
                activeSessionRecordID = key
            }
        }
        // A circuit that closed leaves its record behind, marked, the way
        // a dropped AX.25 session does — the transcript above it is still
        // worth reading.
        let live = Set(circuits.map { NetRomCircuitSession.recordID(for: $0.id) })
        for idx in sessionRecords.indices
        where NetRomCircuitSession.isCircuitRecord(sessionRecords[idx].id)
            && !live.contains(sessionRecords[idx].id)
            && sessionRecords[idx].statusText != "Disconnected" {
            sessionRecords[idx].statusText = "Disconnected"
        }
    }

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
        // A native NET/ROM circuit is its own session with its own
        // transport; the AX.25 path below cannot carry it.
        switch NetRomCircuitSession.sendTarget(
            activeRecordID: activeSessionRecordID,
            circuits: sessionCoordinator.netRomDriver.circuits
        ) {
        case .circuit(let circuitID):
            sendOnCircuit(circuitID)
            return
        case .circuitNotReady(let reason):
            client.appendSystemNotification(reason)
            return
        case .ax25:
            break
        }

        // A circuit still being set up carries nothing yet. Holding the text in
        // the composer is the honest answer: the operator's words are meant for
        // the far end, and until the node says the link is made there is nowhere
        // to put them that means that.
        if txViewModel.relayIsHandshaking {
            let hop = (txViewModel.netRomRelayNextHop ?? "the node").uppercased()
            client.appendSystemNotification(
                "Not sent — still waiting for \(hop) to make the circuit. "
                + "Your message is still in the box.")
            return
        }

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

    /// The Auto button: the operator names a station, the app plans every
    /// way it knows to get there — direct, digi path, native circuit,
    /// node-prompt relay — ranked by evidence, tried in order, each attempt
    /// explained in the transcript. Forced modes and the plain Connect
    /// button are untouched; this is the cross-family path.
    private func startAutoConnectAttempts(sourceContext: ConnectSourceContext) {
        stopAutoConnectAttempts()
        syncLegacyFieldsFromConnectBar()

        let destination = CallsignValidator.normalize(connectBarViewModel.toCall)
        guard !destination.isEmpty else {
            connectBarViewModel.markFailed(reason: .invalidDraft, detail: "Destination callsign is required")
            return
        }

        let ladder = ConnectStrategyPlanner.plan(evidence: buildStrategyEvidence(destination: destination))

        guard !ladder.isEmpty else {
            // Silence would read as a hang; the skip reasons are the answer.
            for skip in ladder.skipped {
                client.appendSystemNotification("Can't try \(skip.familyLabel): \(skip.reason).")
            }
            connectBarViewModel.markFailed(
                reason: .noRoute,
                detail: "No evidence of any way to reach \(destination).")
            return
        }

        connectCoordinator.navigateToTerminal?()
        connectBarViewModel.beginAutoAttempting()

        client.appendSystemNotification(
            "Auto-routing to \(destination) — \(ladder.steps.count) "
            + "way\(ladder.steps.count == 1 ? "" : "s") known, best evidence first.")
        for skip in ladder.skipped {
            client.appendSystemNotification("Skipping \(skip.familyLabel): \(skip.reason).")
        }

        autoAttemptTask = Task { @MainActor in
            let runner = ConnectStrategyRunner()
            let outcome = await runner.run(
                ladder: ladder,
                onExplain: { rung, total, step in
                    connectBarViewModel.updateAutoAttemptStatus(
                        "Trying \(rung)/\(total): \(step.kind.familyLabel)")
                    client.appendSystemNotification("Trying \(rung)/\(total): \(step.reason)")
                },
                execute: { step in
                    await executeStrategyStep(step, destination: destination, sourceContext: sourceContext)
                }
            )
            handleStrategyLadderOutcome(outcome, destination: destination, rungCount: ladder.steps.count)
            autoAttemptTask = nil
        }
    }

    /// The snapshot the pure planner reads — assembled here because this is
    /// where all the stores live.
    private func buildStrategyEvidence(destination: String) -> ConnectStrategyEvidence {
        var evidence = ConnectStrategyEvidence(destination: destination, now: Date())

        if let station = client.stations.first(where: {
            CallsignValidator.normalize($0.call) == destination
        }), let lastHeard = station.lastHeard {
            evidence.direct = .init(lastHeard: lastHeard, heardVia: station.lastVia)
        }

        evidence.digiPaths = connectBarViewModel.digiPathEvidence(for: destination)
        evidence.candidateRoutes = client.netRomIntegration?.candidateRoutes(to: destination) ?? []

        if let capabilities = nodeCapabilities {
            for route in evidence.candidateRoutes {
                let anchor = route.origin.uppercased()
                if let verdict = capabilities.canRouteNetRom(anchor) {
                    evidence.capabilityByAnchor[anchor] = verdict
                }
            }
        }

        evidence.tellers = nodeAliases.directory.tellerClaims(for: destination).map {
            .init(teller: $0.teller, claimedAt: $0.claimedAt)
        }
        evidence.nativeCircuitCoolingDown = !sessionCoordinator.shouldTryNativeNetRom(to: destination)
        evidence.advertiseSelfEnabled = sessionCoordinator.netRomDriver.advertisesItself
        return evidence
    }

    private func executeStrategyStep(
        _ step: ConnectStrategyStep,
        destination: String,
        sourceContext: ConnectSourceContext
    ) async -> ConnectAttemptStepResult {
        if Task.isCancelled { return .cancelled }

        switch step.kind {
        case .directL2:
            return await executeAutoAttemptStep(
                .ax25ViaDigis(digis: []),
                destination: destination,
                sourceContext: sourceContext,
                timeoutSeconds: step.budget)

        case .ax25ViaDigis(let digis):
            return await executeAutoAttemptStep(
                .ax25ViaDigis(digis: digis),
                destination: destination,
                sourceContext: sourceContext,
                timeoutSeconds: step.budget)

        case .netromCircuit(let override):
            connectBarViewModel.setMode(.netrom, for: sourceContext)
            connectBarViewModel.applySuggestedTo(destination)
            connectBarViewModel.nextHopSelection = override ?? ConnectBarViewModel.autoNextHopID
            connectBarViewModel.validate()
            syncLegacyFieldsFromConnectBar()
            let intent = connectBarViewModel.buildIntent(sourceContext: sourceContext)
            guard intent.validationErrors.isEmpty else { return .failed }
            // Straight to the circuit — never through executeNETROMAutoAttempt,
            // whose hardcoded fallback would run a relay the planner may have
            // ranked elsewhere (or skipped).
            return await attemptNativeNetRomCircuit(intent: intent, announceFallback: false) ?? .failed

        case .nodePromptRelay(let teller):
            connectBarViewModel.setMode(.netrom, for: sourceContext)
            connectBarViewModel.applySuggestedTo(destination)
            connectBarViewModel.validate()
            syncLegacyFieldsFromConnectBar()
            let intent = connectBarViewModel.buildIntent(sourceContext: sourceContext)
            return await runNodePromptRelayWithRetry(intent: intent, override: teller)
        }
    }

    private func handleStrategyLadderOutcome(
        _ outcome: ConnectStrategyRunner.Outcome,
        destination: String,
        rungCount: Int
    ) {
        switch outcome {
        case .connected:
            connectBarViewModel.endAutoAttempting()
        case .refused(let detail):
            connectBarViewModel.endAutoAttempting()
            connectBarViewModel.markFailed(reason: .connectRejected, detail: detail)
            updateActiveSessionRecordState("Failed")
            client.appendSystemNotification(
                "\(destination) answered and declined (\(detail)) — stopping rather than knocking on other doors.")
        case .exhausted:
            connectBarViewModel.endAutoAttempting()
            if case .failed = connectBarViewModel.barState {} else {
                connectBarViewModel.markFailed(
                    reason: .timeout,
                    detail: "Tried every way this station knows (\(rungCount)) — none got through.")
            }
        case .cancelled:
            connectBarViewModel.endAutoAttempting()
            updateActiveSessionRecordState("Cancelled")
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

    // MARK: - Displayed Identity

    /// What the header and the composer should call the far end.
    ///
    /// Not the same question as where frames go. Bringing up a relay points the
    /// connect bar at the next hop and leaves it there, so anything that reads
    /// the connect bar for a name shows the node instead of the station the
    /// operator is actually talking to.
    private var displayedDestination: String {
        if let handshaking = txViewModel.relayHandshakeDestination { return handshaking }
        return NetRomRelayLifecycle.displayedDestination(
            typed: connectBarViewModel.toCall,
            establishedDestination: txViewModel.relayConversation?.destination)
    }

    /// The link state to show, which is not the same as the L2 link's state.
    ///
    /// The wire to the next hop is genuinely `.connected` the moment its UA
    /// lands, but the operator asked for AGCHAT and AGCHAT is not connected
    /// until the node says so. Reporting the L2 state put a green dot and
    /// "KB5YZB-7" on screen while the thing that was asked for had not
    /// happened — reported 2026-08-27 as "it looks like I am just connected to
    /// kb5yzb".
    private var displayedSessionState: AX25SessionState? {
        txViewModel.relayIsHandshaking ? .connecting : txViewModel.sessionState
    }

    /// The relay's next hop reads as a via — which is what it is, one node
    /// forwarding for another, even though AX.25 never saw a digipeater field.
    private var displayedVia: [String] {
        if let relay = txViewModel.relayConversation { return [relay.nextHop] }
        if txViewModel.relayIsHandshaking, let hop = txViewModel.netRomRelayNextHop {
            return [hop]
        }
        return connectBarViewModel.viaDigipeaters
    }

    /// A live circuit is NET/ROM however the L2 link beneath it was dialled.
    private var displayedConnectionMode: ConnectBarMode {
        if txViewModel.relayConversation != nil || txViewModel.relayIsHandshaking {
            return .netrom
        }
        return connectBarViewModel.mode
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

    private func executeAutoAttemptStep(
        _ step: ConnectAttemptStep,
        destination: String,
        sourceContext: ConnectSourceContext,
        timeoutSeconds: TimeInterval = 45
    ) async -> ConnectAttemptStepResult {
        if Task.isCancelled {
            return .cancelled
        }

        switch step {
        case .ax25ViaDigis(let digis):
            connectBarViewModel.setMode(digis.isEmpty ? .ax25 : .ax25ViaDigi, for: sourceContext)
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
            return await executeAX25AutoAttempt(intent: intent, digis: digis, timeoutSeconds: timeoutSeconds)

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
            return await executeNETROMAutoAttempt(intent: intent, override: nextHopOverride)
        }
    }

    private func executeAX25AutoAttempt(
        intent: ConnectIntent,
        digis: [String],
        timeoutSeconds: TimeInterval = 45
    ) async -> ConnectAttemptStepResult {
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

        let waitResult = await waitForAX25ConnectOutcome(destination: intent.normalizedTo, digis: digis, timeoutSeconds: timeoutSeconds)
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
        case .refused(let detail):
            connectBarViewModel.recordAttempt(intent: intent, result: .failed)
            connectBarViewModel.markFailed(reason: .connectRejected, detail: detail)
            updateActiveSessionRecordState("Refused")
            // Nothing to tear down: the DM already ended the session on
            // both sides.
            return .refused(detail: detail)
        case .timeout:
            connectBarViewModel.recordAttempt(intent: intent, result: .failed)
            connectBarViewModel.markFailed(reason: .timeout, detail: "Connection timed out.")
            updateActiveSessionRecordState("Failed")
            disconnectSession(destination: intent.normalizedTo, digis: digis)
            return .timeout
        }
    }

    /// How long a native circuit gets to answer before we fall back.
    ///
    /// Deliberately far short of the transport's own patience (T1 = 120 s,
    /// N2 = 3, so a NET/ROM connect takes six minutes to fail on its own).
    /// A CONACK that has not arrived in half a minute is not coming from a
    /// node that speaks L4 at all, and the operator is better served by the
    /// prompt relay than by watching a timer.
    private static let nativeCircuitGrace: TimeInterval = 30

    /// Try a real NET/ROM circuit — L3/L4 datagrams in PID-0xCF I-frames,
    /// with the network doing the routing.
    ///
    /// This is what "NET/ROM" is supposed to mean, and what was missing:
    /// the transport has been complete and tested for a while but reachable
    /// only from the Routes page, so every connect from the connect bar fell
    /// through to driving node command prompts instead. That method works,
    /// but it is not NET/ROM — it types `C DRLNOD`, `C KB5YZB-7`, `C COSCO`
    /// at three command interpreters in turn, which is why the field capture
    /// of 2026-08-27 shows node menus scrolling past on the way to COSCO and
    /// every frame carrying PID 0xF0.
    ///
    /// - Returns: the attempt's result, or nil meaning "fall back to the
    ///   command-prompt relay" — no route known, or no answer in time.
    /// - Parameter announceFallback: whether a nil return should tell the
    ///   operator the prompt relay is coming next. True for the legacy
    ///   native-then-relay path; false when the strategy ladder calls this
    ///   as one rung, because what runs next is the planner's decision.
    private func attemptNativeNetRomCircuit(
        intent: ConnectIntent,
        announceFallback: Bool = true
    ) async -> ConnectAttemptStepResult? {
        let driver = sessionCoordinator.netRomDriver
        let target = CallsignNormalizer.toAddress(intent.normalizedTo)

        // A destination that has already proved it cannot carry a circuit
        // is not worth another grace period this hour.
        guard sessionCoordinator.shouldTryNativeNetRom(to: intent.normalizedTo) else {
            TxLog.debug(.session, "Skipping native NET/ROM — it did not work here recently", [
                "destination": intent.normalizedTo
            ])
            return nil
        }

        // Which peers we already held links to. Sampled *before* the
        // attempt, because opening a circuit sends its CONREQ synchronously
        // and brings the neighbor link up on the way — ask afterwards and
        // every link looks pre-existing. Only a link this attempt opened may
        // be torn down on the way out; one that was already carrying traffic
        // is not ours to drop.
        let linksBefore = Set(
            txViewModel.sessionManager.sessions.values
                .filter { $0.state == .connected || $0.state == .connecting }
                .map { $0.remoteAddress.display.uppercased() }
        )

        // The address the L3 header will carry. The operator names a node
        // by alias ("COSCO"); NET/ROM addresses by callsign (KE0GB-7), and
        // the circuit list is keyed by the latter.
        let resolved = driver.resolveDestination(intent.normalizedTo).address

        switch driver.autoConnect(to: target) {
        case .success:
            break
        case .failure(let reason):
            // Not a failure of the connect — a failure to find a native
            // route, which the prompt relay may still manage because it
            // can ask a node to do the routing on our behalf.
            TxLog.debug(.session, "Native NET/ROM unavailable, falling back to prompt relay", [
                "destination": intent.normalizedTo, "reason": reason.operatorText
            ])
            if announceFallback {
                client.appendSystemNotification(
                    reason.operatorText
                    + " Asking a node to connect on our behalf instead — its menus will "
                    + "appear below, because that method talks to node command prompts.")
            } else {
                client.appendSystemNotification(reason.operatorText)
            }
            return nil
        }

        connectBarViewModel.markConnecting()
        updateActiveSessionRecordState("NET/ROM circuit…")

        switch await waitForCircuitOutcome(to: resolved, timeoutSeconds: Self.nativeCircuitGrace) {
        case .success:
            let neighbor = driver.circuits.first {
                CallsignNormalizer.addressesMatch($0.destination, resolved)
                    && $0.state == .connected
            }?.neighbor.display
            connectBarViewModel.setMode(.netrom, for: intent.sourceContext)
            connectBarViewModel.markConnected(
                sourceCall: txViewModel.viewModel.sourceCall,
                destination: intent.normalizedTo,
                via: [],
                transportMode: .netrom,
                forcedNextHop: neighbor
            )
            connectBarViewModel.recordAttempt(intent: intent, result: .success)
            updateActiveSessionRecordState("Connected")
            sessionCoordinator.noteNativeNetRomSucceeded(to: intent.normalizedTo)
            return .success

        case .cancelled:
            // Not evidence about the network — the operator stopped it.
            abandonCircuits(to: resolved)
            return .cancelled

        case .refused(let detail):
            // The transport worked end to end — the station answered and
            // said no. Deliberately NOT the negative cache: that cache
            // means "native didn't work here", and it just did.
            abandonCircuits(to: resolved)
            connectBarViewModel.recordAttempt(intent: intent, result: .failed)
            connectBarViewModel.markFailed(reason: .connectRejected, detail: detail)
            updateActiveSessionRecordState("Refused")
            return .refused(detail: detail)

        case .failed(let detail), .timeout(let detail):
            // Abandon whatever is still in flight before trying anything
            // else. Left alone a connecting circuit keeps retransmitting
            // CONREQ for six more minutes (T1 120 s, N2 3), keying the
            // transmitter underneath the relay we are about to run.
            let neighbor = driver.circuits.first {
                CallsignNormalizer.addressesMatch($0.destination, resolved)
                    && $0.state != .disconnected
            }?.neighbor
            abandonCircuits(to: resolved)
            // And drop the L2 link the attempt opened, if it opened one and
            // nothing else is using it. The relay that runs next asks a node
            // for its prompt, and a node greets on *connect* — inheriting a
            // link this attempt established means BPQ is already past its
            // greeting and the relay waits for a banner that will never
            // come. The same inherited-session trap as a failed relay
            // leaving its link up (2026-08-27).
            if let neighbor,
               !linksBefore.contains(neighbor.display.uppercased()),
               !driver.circuits.contains(where: {
                   $0.state != .disconnected
                       && CallsignNormalizer.addressesMatch($0.neighbor, neighbor)
               }) {
                disconnectSession(destination: neighbor.display, digis: [])
            }
            sessionCoordinator.noteNativeNetRomFailed(to: intent.normalizedTo)
            TxLog.debug(.session, "Native NET/ROM circuit did not come up", [
                "destination": intent.normalizedTo, "detail": detail
            ])
            // Name the most likely cause when it applies. A circuit's
            // acknowledgement has to be *routed home*, and no node routes
            // to a station it has never heard advertise itself — so with
            // advertising off the reply has nowhere to go, however well the
            // outbound half worked. That is a setting, not a fault, and the
            // operator can only act on it if someone says so.
            let advice = driver.advertisesItself ? ""
                : " No node advertises a route back to this station, so a reply may "
                    + "have nowhere to go — turn on \"Announce this station to the "
                    + "network\" in Transmission settings if you want circuits to "
                    + "work here."
            let fallbackText = announceFallback
                ? " Asking a node to connect on our behalf instead — its menus will appear below."
                : ""
            client.appendSystemNotification(
                "\(intent.normalizedTo.uppercased()) did not answer as a NET/ROM node "
                + "(\(detail))." + advice + fallbackText)
            return nil
        }
    }

    /// Close every live circuit to a destination.
    ///
    /// Plural because auto-try may have more than one in flight — it opens
    /// a fresh circuit per hop, and the one whose ID `autoConnect` returned
    /// is only the first of them.
    private func abandonCircuits(to destination: AX25Address) {
        let driver = sessionCoordinator.netRomDriver
        for circuit in driver.circuits where
            CallsignNormalizer.addressesMatch(circuit.destination, destination)
            && circuit.state != .disconnected {
            driver.disconnect(circuit.id)
        }
    }

    /// Outcome of waiting on a native circuit. `timeout` carries a detail
    /// too so the fallback notice can say what actually happened.
    private enum CircuitWaitResult {
        case success
        case failed(String)
        /// The far station answered the CONREQ with a choke — an answer,
        /// not a path failure, so the strategy ladder stops here.
        case refused(String)
        case timeout(String)
        case cancelled
    }

    /// Poll until a circuit to `destination` connects, the attempt runs
    /// out of routes, or the grace expires.
    ///
    /// Watches the **destination**, not one circuit ID, because auto-try
    /// opens a fresh circuit per hop: watching the ID returned by
    /// `autoConnect` would see hop one close, call the whole thing failed,
    /// and abandon a campaign that was walking to hop two exactly as
    /// designed. A campaign that is genuinely spent leaves no live circuit
    /// behind, which is the condition below.
    private func waitForCircuitOutcome(
        to destination: AX25Address,
        timeoutSeconds: TimeInterval
    ) async -> CircuitWaitResult {
        let start = Date()
        let deadline = start.addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if Task.isCancelled { return .cancelled }
            let driver = sessionCoordinator.netRomDriver
            let live = driver.circuits.filter {
                CallsignNormalizer.addressesMatch($0.destination, destination)
                    && $0.state != .disconnected
            }
            if live.contains(where: { $0.state == .connected }) { return .success }
            if live.isEmpty {
                // A campaign that ended in a refusal is the station
                // answering no — surfaced as its own outcome so the
                // strategy ladder stops instead of knocking on the next
                // door. Everything else the driver's own operator note
                // has already explained — out of routes, link down.
                if let postMortem = driver.lastCampaignPostMortem,
                   postMortem.wasRefused,
                   postMortem.endedAt >= start,
                   CallsignNormalizer.addressesMatch(postMortem.destination, destination) {
                    return .refused(postMortem.detail)
                }
                return .failed("no route carried the circuit")
            }
            do { try await Task.sleep(nanoseconds: 250_000_000) }
            catch { return .cancelled }
        }
        return .timeout("no answer in \(Int(timeoutSeconds))s")
    }

    private func executeNETROMAutoAttempt(intent: ConnectIntent, override: String?) async -> ConnectAttemptStepResult {
        // Real NET/ROM first. Only when the network cannot carry a circuit
        // do we fall back to driving node command prompts.
        if let native = await attemptNativeNetRomCircuit(intent: intent) { return native }
        return await runNodePromptRelayWithRetry(intent: intent, override: override)
    }

    /// The prompt relay with its one justified retry — shared by the legacy
    /// native-then-relay path and the strategy ladder's relay rung.
    private func runNodePromptRelayWithRetry(intent: ConnectIntent, override: String?) async -> ConnectAttemptStepResult {
        let first = await runNodePromptRelay(intent: intent, override: override)

        // One retry, and only for the one failure that is not a failure: a
        // handshake that stalled after we destroyed part of it ourselves.
        //
        // 2026-08-27, DRLNOD → KB5YZB-7 → COSCO. The frame carrying the last
        // hop's verdict was lost, REJ went unanswered, the gap was flushed,
        // and the attempt was reported as "the circuit was not made" — while
        // the banner of a third node, which could only have come from COSCO,
        // was already on screen. Nothing was wrong with the route; a hundred
        // and twenty-eight bytes were wrong with the channel. The link is torn
        // down by then, which is what makes a retry worth anything: a node
        // greets on a fresh connect, so the second run gets the whole
        // handshake again rather than inheriting a node with nothing left to
        // say.
        guard case .failed = first, txViewModel.relayLostFrames else { return first }
        client.appendSystemNotification(
            "Part of the node's answer was lost on air and it did not resend, so "
            + "there is no way to tell whether that hop was made. Starting over on a "
            + "fresh link rather than calling it a failure.")
        return await runNodePromptRelay(intent: intent, override: override)
    }

    /// One run of the node-prompt chain: plan it, reach the first node, drive
    /// its prompts. Separate from the caller so it can be run twice.
    private func runNodePromptRelay(
        intent: ConnectIntent, override: String?
    ) async -> ConnectAttemptStepResult {
        txViewModel.clearRelayFrameLoss()

        guard let nextHop = override ?? intent.routeHint?.nextHop, !nextHop.isEmpty else {
            let message = "No NET/ROM route to \(intent.normalizedTo)"
            upsertSessionRecord(intent: intent, statusText: "Failed")
            connectBarViewModel.markConnecting()
            connectBarViewModel.recordAttempt(intent: intent, result: .failed)
            connectBarViewModel.markFailed(reason: .noRoute, detail: message)
            updateActiveSessionRecordState("Failed")
            client.appendSystemNotification(message)
            return .unavailable(message: message)
        }

        // The station that lists the destination may not be one this
        // station can reach directly. The route table knows who reaches
        // it; chain through them rather than dialling a node that never
        // answers (field capture 2026-08-27: KB5YZB-7 direct came up and
        // stayed silent three times, while DRLNOD → KB5YZB-7 → COSCO
        // worked by hand).
        let plan = NetRomRelayPlan.plan(
            destination: intent.normalizedTo,
            teller: nextHop,
            routeLookup: { [weak client] station in
                if let origin = client?.netRomIntegration?.bestRouteTo(station)?.origin {
                    return origin
                }
                // bestRouteTo filters by TTL — right for routing, wrong for
                // chain planning: the harvested COSCO route scraped this
                // morning is "expired" by evening, and the walk found
                // nothing behind the alias (field capture 2026-08-28,
                // second run). The alias directory still remembers who
                // *listed* the station, and a remembered signpost beats
                // dialling a name we cannot hear — the relay proves every
                // hop live anyway.
                return nodeAliases.directory.tellerClaims(for: station).first?.teller
            },
            aliasResolve: { nodeAliases.directory.callsign(for: $0) }
        )
        let linkTarget = plan.linkTarget

        TxLog.outbound(.session, "Node-prompt relay auto-attempt", [
            "destination": intent.normalizedTo,
            "linkTarget": linkTarget,
            "chain": plan.chain.joined(separator: "→")
        ])
        client.appendSystemNotification(plan.operatorSummary)

        // Set relay phase so data interception is ready the moment UA arrives and data flows
        txViewModel.armRelayChain(plan.chain)
        txViewModel.netRomRelayPhase = .awaitingBanner(
            destination: intent.normalizedTo,
            nextHop: linkTarget,
            remaining: plan.intermediateHops)

        // Reaching the node is its own problem, and this station may already
        // know the answer. `digis: []` below used to dial every next hop
        // direct, ignoring a measured route — KB5YZB-7 is in the route table
        // *via DRLNOD*, and the direct path to it runs at 18% loss, which is
        // what kept eating the node's greeting (2026-08-27).
        let hopPath = bestPathToRelayNode(linkTarget)
        connectBarViewModel.setMode(hopPath.isEmpty ? .ax25 : .ax25ViaDigi,
                                    for: intent.sourceContext)
        connectBarViewModel.applySuggestedTo(linkTarget)
        if !hopPath.isEmpty {
            connectBarViewModel.viaDigipeaters = hopPath
            client.appendSystemNotification(
                "Reaching \(linkTarget.uppercased()) via \(hopPath.joined(separator: " → ")) "
                + "— that is how this station last heard it.")
        }
        syncLegacyFieldsFromConnectBar()
        let nodeIntent = connectBarViewModel.buildIntent(sourceContext: intent.sourceContext)
        guard nodeIntent.validationErrors.isEmpty else {
            txViewModel.netRomRelayPhase = nil
            connectBarViewModel.recordAttempt(intent: intent, result: .failed)
            connectBarViewModel.markFailed(reason: .invalidDraft, detail: nodeIntent.validationErrors.joined(separator: "; "))
            return .failed
        }

        // Establish the L2 connection to the next-hop node
        let l2Result = await executeAX25AutoAttempt(intent: nodeIntent, digis: hopPath)
        guard case .success = l2Result else {
            txViewModel.netRomRelayPhase = nil
            return l2Result
        }

        updateActiveSessionRecordState("Relay handshake…")

        // Wait for relay handshake: banner → C command → node "Connected" response
        let relayResult = await waitForNetRomRelayOutcome(timeoutSeconds: 45)
        switch relayResult {
        case .success:
            connectBarViewModel.recordAttempt(intent: intent, result: .success)
            updateActiveSessionRecordState("Connected")
            return .success
        case .failed(let detail):
            connectBarViewModel.recordAttempt(intent: intent, result: .failed)
            connectBarViewModel.markFailed(reason: .connectRejected, detail: detail)
            updateActiveSessionRecordState("Failed")
            return .failed
        case .refused(let detail):
            // The relay-phase wait never produces this today; kept for
            // exhaustiveness so a future refusal signal flows through.
            connectBarViewModel.recordAttempt(intent: intent, result: .failed)
            connectBarViewModel.markFailed(reason: .connectRejected, detail: detail)
            updateActiveSessionRecordState("Refused")
            return .refused(detail: detail)
        case .timeout:
            txViewModel.netRomRelayPhase = nil
            connectBarViewModel.recordAttempt(intent: intent, result: .failed)
            connectBarViewModel.markFailed(reason: .timeout, detail: "Relay handshake timed out.")
            updateActiveSessionRecordState("Failed")
            return .timeout
        case .cancelled:
            txViewModel.netRomRelayPhase = nil
            return .cancelled
        }
    }

    /// How this station last actually reached the node it is about to dial.
    ///
    /// The relay's first leg is an ordinary AX.25 connect and deserves the same
    /// evidence any other connect gets. Empty means direct, which is both the
    /// common case and the right fallback: a path nothing has observed is a
    /// worse bet than the one the operator's own receiver has been hearing.
    private func bestPathToRelayNode(_ nextHop: String) -> [String] {
        let key = CallsignValidator.normalize(nextHop)
        guard let station = client.stations.first(
            where: { CallsignValidator.normalize($0.call) == key })
        else { return [] }
        return ConnectCoordinator.returnPath(heardVia: station.lastVia)
    }

    private enum AX25AutoWaitResult {
        case success
        case failed(detail: String)
        /// The peer answered the SABM with DM — an answer, not a path
        /// failure, so the strategy ladder stops instead of falling through.
        case refused(detail: String)
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
                if session.peerRefusedConnect {
                    return .refused(detail: "\(destination) answered the connect request with DM (refused).")
                }
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

    /// Poll txViewModel.netRomRelayPhase until the relay is established or fails.
    /// Returns .success when .established, .failed when phase goes nil (failure detected),
    /// .timeout when deadline is reached, or .cancelled if the Task is cancelled.
    private func waitForNetRomRelayOutcome(timeoutSeconds: TimeInterval) async -> AX25AutoWaitResult {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if Task.isCancelled { return .cancelled }
            switch txViewModel.netRomRelayPhase {
            case .established:
                return .success
            case .none:
                return .failed(detail: "Relay handshake failed.")
            default:
                break
            }
            do { try await Task.sleep(nanoseconds: 250_000_000) }
            catch { return .cancelled }
        }
        return .timeout
    }

    private func disconnectSession(destination: String, digis: [String]) {
        let address = CallsignNormalizer.toAddress(destination)
        let path = DigiPath.from(digis)
        guard let session = txViewModel.sessionManager.existingSession(for: address, path: path)
            ?? txViewModel.sessionManager.connectedSession(withPeer: address) else { return }

        // Dropping the link "so the next attempt starts clean" is only true
        // if the peer hears about it. Torn down silently, BPQ keeps the
        // session and treats the next SABM as a reset of it — already past
        // its greeting, so the banner the relay waits on never comes (field
        // capture 2026-08-28: KB5YZB-7 RR-polled a half-open session before
        // our SABM, then never greeted). See `LinkTeardownPolicy`.
        switch LinkTeardownPolicy.action(for: session.state) {
        case .sendDISC:
            if let disc = txViewModel.sessionManager.disconnect(session: session) {
                client.send(frame: disc) { result in
                    if case .failure(let error) = result {
                        TxLog.warning(.session, "DISC send failed on link teardown", [
                            "peer": address.display,
                            "error": error.localizedDescription
                        ])
                    }
                }
            } else {
                // The state moved under us between the policy check and the
                // disconnect call. Don't leave the session dangling.
                txViewModel.sessionManager.forceDisconnect(session: session)
            }
        case .dropLocally:
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

        // Every connect starts from a clean relay state. A relay armed by an
        // earlier attempt that died before its link ever reached `.connecting`
        // is not cleared by the session-state transition, and would otherwise
        // fire its `C <dest>` at the next node the operator dialled by hand.
        txViewModel.netRomRelayPhase = nil

        // Say out loud which route this connect took. Without it a NET/ROM
        // circuit and a direct link are indistinguishable in the transcript
        // until you read frame addresses, and the operator cannot tell whether
        // the app did what they asked.
        switch intent.kind {
        case .ax25Direct:
            client.appendSystemNotification("Connecting to \(intent.normalizedTo) — direct.")
            connectAX25AndRecord(intent: intent)
        case .ax25ViaDigis:
            let digis = connectBarViewModel.viaDigipeaters.joined(separator: ", ")
            client.appendSystemNotification("Connecting to \(intent.normalizedTo) — digipeating via \(digis).")
            connectAX25AndRecord(intent: intent)
        case let .netrom(nextHopOverride):
            // Deliberately no "NET/ROM circuit through X" line here any
            // more. Which of the two methods is about to be used is not
            // known yet, and announcing the one we did not use is how the
            // transcript came to claim NET/ROM over a chain of node
            // command prompts. Each path below says what it actually did.
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

    /// How long a next hop may hold the link without speaking.
    ///
    /// A node greets on connect; that greeting is what the handshake waits for.
    /// Forty-five seconds is several times the slowest banner observed (11 s
    /// through DRLNOD) and still far short of the operator giving up on their
    /// own.
    /// How long a node gets to greet us before we assume something was lost.
    ///
    /// Shorter than the old single 45 s wait because it is no longer the whole
    /// budget — it is the point at which we try what an operator would, and
    /// there is a second wait after that.
    private static let relayBannerGrace: TimeInterval = 20
    /// And how long the nudge gets to work before we give up.
    private static let relayNudgeGrace: TimeInterval = 25
    /// Extra patience while the peer's I-frames keep arriving undelivered —
    /// REJ recovery in flight. Bounded so a peer resending the wrong frame
    /// forever cannot hold the relay open. See `NetRomRelayLifecycle.stallVerdict`.
    private static let relayRecoveryDeferralBudget: TimeInterval = 60

    /// Gives up on a node that took the link and then went quiet.
    ///
    /// The budget is **per hop**, not per relay: each wait below restarts
    /// whenever `relayProgressTick` moves, so a chain that is walking
    /// normally is never interrupted. Only a hop that genuinely stops
    /// speaking for its whole grace period is nudged, and only one that
    /// stays silent through the nudge is abandoned.
    private func startRelayBannerWatchdog() {
        let armed = txViewModel.netRomRelayNextHop
        Task { @MainActor in
            /// Waits `grace`, restarting the clock on every relay
            /// advance. Returns false when the relay ended or moved to a
            /// different link — nothing left for this watchdog to judge.
            @MainActor func waitForStall(_ grace: TimeInterval) async -> Bool {
                var tick = txViewModel.relayProgressTick
                var inboundIFrames = txViewModel.relayInboundIFrameCount
                var deferralSpent: TimeInterval = 0
                while true {
                    try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
                    guard txViewModel.relayIsHandshaking,
                          txViewModel.netRomRelayNextHop == armed else { return false }
                    let verdict = NetRomRelayLifecycle.stallVerdict(
                        tickMoved: txViewModel.relayProgressTick != tick,
                        inboundIFramesMoved: txViewModel.relayInboundIFrameCount != inboundIFrames,
                        deferralSpent: deferralSpent,
                        deferralBudget: Self.relayRecoveryDeferralBudget)
                    switch verdict {
                    case .chainAdvanced:
                        tick = txViewModel.relayProgressTick
                        inboundIFrames = txViewModel.relayInboundIFrameCount
                        deferralSpent = 0
                        continue  // the chain moved; this hop gets its own budget
                    case .peerStillTransmitting:
                        // Undelivered I-frames are still arriving — the peer is
                        // retransmitting into a gap. Give recovery room, on a
                        // budget, before treating the hop as silent.
                        inboundIFrames = txViewModel.relayInboundIFrameCount
                        deferralSpent += grace
                        continue
                    case .stalled:
                        return true
                    }
                }
            }

            guard let linkPeer = armed?.uppercased() else { return }
            guard await waitForStall(Self.relayBannerGrace) else { return }
            // Name the station that actually went quiet. After a hop is
            // made every byte still arrives from the L2 peer, so naming
            // that peer sends the operator to look at the wrong node.
            let silent = txViewModel.relayWaitingOn ?? linkPeer

            // Try what a human would before declaring failure.
            switch txViewModel.nudgeStalledRelay() {
            case .clearedGap:
                client.appendSystemNotification(
                    "\(silent)'s greeting was incomplete — a frame was lost on air and it "
                    + "did not resend. Reading the rest and carrying on.")
            case .prompted:
                client.appendSystemNotification(
                    "\(silent) has said nothing for \(Int(Self.relayBannerGrace)) seconds. "
                    + "Sending a carriage return to ask it for its prompt.")
            case .nothingToTry:
                break
            }

            guard await waitForStall(Self.relayNudgeGrace) else { return }
            let hop = txViewModel.relayWaitingOn ?? linkPeer
            txViewModel.netRomRelayPhase = nil
            // Silence and a sequence gap look the same from here and are not
            // the same problem. On 2026-08-27 KB5YZB-7's banner arrived as
            // N(S)=1 with N(S)=0 lost on air; we asked for the missing frame
            // with REJ and it never came, so the prompt was sitting in the
            // receive buffer undelivered. Reporting that as "never sent its
            // prompt" sent the operator looking at the wrong station.
            // Tear the link down rather than leaving it up "helpfully".
            //
            // A node greets on *connect*. Leaving a half-made link open means
            // the next attempt's SABM resets an existing session rather than
            // opening a new one (§4.3.3.1), and BPQ's command handler is
            // already past the greeting — so it answers polls, acknowledges
            // input, and never says anything again. Field capture 2026-08-27:
            // the 09:27 failure left the link up, and the 10:03 retry inherited
            // a session where KB5YZB-7 had nothing left to say. The advice to
            // "try again" was causing the next failure.
            // Two different stories end up here, and only one of them is the
            // node's fault. If part of its answer was destroyed to clear a
            // receive gap, "it did not answer" is this station describing its
            // own data loss as somebody else's silence.
            client.appendSystemNotification(
                txViewModel.relayLostFrames
                ? "\(hop)'s answer was cut short — a frame was lost on air and it did "
                  + "not resend, so whether that hop was made is unknowable from here. "
                  + "Dropping the link to \(linkPeer) to start over on a clean one."
                : "\(hop) did not answer with a node prompt, even after being asked, so "
                  + "the circuit was not made. Dropping the link to \(linkPeer) so the next "
                  + "attempt starts clean — a node only greets on a fresh connect.")
            // The link to tear down is always the L2 peer. `hop` may be a
            // node further along the chain, which we hold no session to —
            // disconnecting *that* name is a no-op that leaves the real
            // link up, which is the exact state this branch exists to avoid.
            disconnectSession(destination: linkPeer, digis: [])
            connectBarViewModel.markFailed(
                reason: .connectRejected,
                detail: "\(hop) did not answer with a node prompt")
            updateActiveSessionRecordState("Failed")
        }
    }

    /// Connect in NET/ROM mode: a real circuit if the network can carry
    /// one, otherwise a node's command prompt driven on our behalf.
    ///
    /// Same order as the auto path, for the same reason — the two are the
    /// operator's one button and two buttons for the same intent, and it
    /// would be strange for them to use different transports.
    private func connectNETROM(intent: ConnectIntent, override: CallsignSSID?) {
        Task { @MainActor in
            if await attemptNativeNetRomCircuit(intent: intent) != nil { return }
            connectNETROMViaNodePrompts(intent: intent, override: override)
        }
    }

    /// The fallback: open an AX.25 link to a node and type `C <somewhere>`
    /// at its command interpreter, once per hop. Not NET/ROM, whatever the
    /// mode is called — the node's menus are on the operator's screen
    /// because the operator is, unavoidably, sitting in its shell.
    private func connectNETROMViaNodePrompts(intent: ConnectIntent, override: CallsignSSID?) {
        guard let nextHop = override?.stringValue ?? intent.routeHint?.nextHop, !nextHop.isEmpty else {
            connectBarViewModel.recordAttempt(intent: intent, result: .failed)
            connectBarViewModel.markFailed(
                reason: .noRoute,
                detail: "No NET/ROM route to \(intent.normalizedTo). Try NET/ROM Auto or select a next hop."
            )
            updateActiveSessionRecordState("Failed")
            return
        }

        let plan = NetRomRelayPlan.plan(
            destination: intent.normalizedTo,
            teller: nextHop,
            routeLookup: { [weak client] station in
                if let origin = client?.netRomIntegration?.bestRouteTo(station)?.origin {
                    return origin
                }
                // bestRouteTo filters by TTL — right for routing, wrong for
                // chain planning: the harvested COSCO route scraped this
                // morning is "expired" by evening, and the walk found
                // nothing behind the alias (field capture 2026-08-28,
                // second run). The alias directory still remembers who
                // *listed* the station, and a remembered signpost beats
                // dialling a name we cannot hear — the relay proves every
                // hop live anyway.
                return nodeAliases.directory.tellerClaims(for: station).first?.teller
            },
            aliasResolve: { nodeAliases.directory.callsign(for: $0) }
        )
        client.appendSystemNotification(plan.operatorSummary)

        // Set relay phase BEFORE sending SABM so data interception is active when UA arrives
        txViewModel.armRelayChain(plan.chain)
        txViewModel.netRomRelayPhase = .awaitingBanner(
            destination: intent.normalizedTo,
            nextHop: plan.linkTarget,
            remaining: plan.intermediateHops)

        // Redirect connect bar to the link target for the L2 connect
        connectBarViewModel.setMode(.ax25, for: intent.sourceContext)
        connectBarViewModel.applySuggestedTo(plan.linkTarget)
        syncLegacyFieldsFromConnectBar()

        guard let frame = txViewModel.connect() else {
            txViewModel.netRomRelayPhase = nil
            connectBarViewModel.recordAttempt(intent: intent, result: .failed)
            connectBarViewModel.markFailed(reason: .unknown, detail: "Unable to build SABM to \(nextHop)")
            updateActiveSessionRecordState("Failed")
            return
        }

        connectBarViewModel.markConnecting()
        updateActiveSessionRecordState("Connecting via \(nextHop)")

        client.send(frame: frame) { result in
            Task { @MainActor in
                if case .failure(let error) = result {
                    self.txViewModel.netRomRelayPhase = nil
                    self.connectBarViewModel.recordAttempt(intent: intent, result: .failed)
                    self.connectBarViewModel.markFailed(reason: .connectRejected, detail: error.localizedDescription)
                    self.updateActiveSessionRecordState("Failed")
                } else {
                    // Not necessarily a SABM, and never to `nextHop`:
                    // `txViewModel.connect()` opens the link to the plan's
                    // *link target*, and against an unknown peer that
                    // starts with XID. The old wording claimed both — the
                    // 2026-08-27 capture logged "SABM sent … nextHop=
                    // KB5YZB-7" for an XID addressed to DRLNOD.
                    TxLog.outbound(.session, "Node-prompt relay link opening", [
                        "destination": intent.normalizedTo,
                        "linkTarget": plan.linkTarget,
                        "chain": plan.chain.joined(separator: "\u{2192}")
                    ])
                }
            }
        }
    }

    /// Disconnect from current session
    private func disconnectFromDestination() {
        // Closing a circuit is a DISCREQ on the circuit, not a DISC on
        // the neighbor link — that link may be carrying other circuits.
        if let activeSessionRecordID,
           let summary = NetRomCircuitSession.circuit(
                forRecordID: activeSessionRecordID,
                among: sessionCoordinator.netRomDriver.circuits) {
            sessionCoordinator.netRomDriver.disconnect(summary.id)
            updateActiveSessionRecordState("Disconnecting…")
            return
        }

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
                    statusText: statusText,
                    relayDestination: nil
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

    private func updateActiveSessionRelayDestination(_ destination: String?) {
        guard let activeSessionRecordID,
              let idx = sessionRecords.firstIndex(where: { $0.id == activeSessionRecordID }) else { return }
        sessionRecords[idx].relayDestination = destination
    }

    private func focusSessionRecord(id: String) {
        // A circuit record is not a connect-bar draft: repointing the bar
        // at its destination would make Connect start a *relay* to the
        // same station, which is a different mechanism entirely.
        guard !NetRomCircuitSession.isCircuitRecord(id) else { return }
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

    /// Picks a file to send over the air.
    ///
    /// macOS runs its own panel modally, which is the platform convention and
    /// keeps this a plain function call. iOS has no modal panel, so the flag
    /// drives a `fileImporter` on the view instead — see `isPickingTransfer`.
    private func selectFileForTransfer() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        if panel.runModal() == .OK, let url = panel.url {
            selectedFileURL = url
            showingTransferSheet = true
        }
        #else
        isPickingTransfer = true
        #endif
    }

    /// Accepts the file the operator chose on a platform with no modal panel.
    ///
    /// The security scope has to be *held*, not released here: the transfer
    /// reads the file later, on its own schedule. Releasing on return would
    /// leave the transfer reading a URL it no longer has permission to open,
    /// which fails partway through a send rather than before one.
    private func acceptPickedTransfer(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        _ = url.startAccessingSecurityScopedResource()
        selectedFileURL = url
        showingTransferSheet = true
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
    
    let handlePendingIncomingTransfers: ([IncomingTransferRequest]) -> Void
    let handleFileDrop: ([NSItemProvider]) -> Bool
    let startTransfer: (String, String, TransferProtocolType, TransferCompressionSettings) -> Void
    let wireCallbacks: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: settings.myCallsign) { _, newValue in
                txViewModel.updateSourceCall(newValue)
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
        nodeAliases: NodeAliasStore(),
        searchModel: searchModel
    )
    .frame(width: 800, height: 600)
}

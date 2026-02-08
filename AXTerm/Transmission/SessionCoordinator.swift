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

// MARK: - Per-route adaptive cache

/// Key for per-route adaptive cache (destination + path so direct vs via digi are separate).
struct RouteAdaptiveKey: Hashable, Sendable {
    let destination: String
    let pathSignature: String
}

/// Normalizes destination so "PEER" and "PEER-0" match (SSID 0 display form).
private func canonicalDestination(_ destination: String) -> String {
    let u = destination.uppercased().trimmingCharacters(in: .whitespaces)
    if u.hasSuffix("-0") { return String(u.dropLast(2)) }
    return u
}

/// Cached learned params for one route with TTL for invalidation.
struct CachedAdaptiveEntry: Sendable {
    var settings: TxAdaptiveSettings
    var lastUpdated: Date
}

/// Coordinates session management and file transfers across the app.
/// This class is owned by ContentView and passed down to child views.
@MainActor
final class SessionCoordinator: ObservableObject {
    /// Shared instance for settings integration (single coordinator for app lifecycle).
    /// This is assigned in `init` for the main `ContentView`-owned coordinator.
    static weak var shared: SessionCoordinator?
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
    /// Dedicated subscription for packet processing — kept separate from `cancellables`
    /// so that repeated calls to `subscribeToPackets` replace (not accumulate) subscriptions.
    private var packetSubscription: AnyCancellable?

    /// File data cache for active transfers (keyed by transfer ID)
    private var transferFileData: [UUID: Data] = [:]

    /// Session IDs for AXDP transfers (keyed by transfer ID)
    private var transferSessionIds: [UUID: UInt32] = [:]

    /// Inbound transfer states (keyed by AXDP session ID)
    private var inboundTransferStates: [UInt32: InboundTransferState] = [:]

    /// Map from AXDP session ID to BulkTransfer ID for UI updates
    private var axdpToTransferId: [UInt32: UUID] = [:]

    /// Track compression algorithm used for each transfer (for FILE_META and metrics)
    private var transferCompressionAlgorithms: [UUID: AXDPCompression.Algorithm] = [:]

    /// Pending capability discovery requests (callsign -> timestamp)
    /// Used to track which stations we've sent PING to but haven't received PONG from
    private var pendingCapabilityDiscovery: [String: Date] = [:]

    /// Timeout for capability discovery (seconds)
    private let capabilityDiscoveryTimeout: TimeInterval = 900.0
    /// Cache for peers that did not respond to AXDP discovery
    private var axdpNotSupported: [String: Date] = [:]
    
    /// Set of peers implicitly confirmed as AXDP-capable because we received an AXDP message from them.
    /// This supplements the capability store - if a peer sends us ANY AXDP message, they obviously support AXDP.
    private var implicitlyConfirmedAXDP: Set<String> = []

    /// Plain ASCII text probe for safe AXDP capability discovery, sent as a UI frame.
    /// UI frames are connectionless and not fed into the connected-mode application layer,
    /// so legacy BBS/nodes never see this text — no "Invalid command" and no transcript noise.
    /// AXTerm peers detect the probe in their UI frame handler and respond with AXDP PONG.
    static let axdpTextProbe = "AXDP?\r"

    /// Peers where a text-safe AXDP probe is pending (waiting for first inbound I-frame or fallback timer).
    private var pendingTextProbe: Set<String> = []

    /// Peers where we sent a text probe and received their PONG, but haven't yet sent
    /// our own PING with capabilities.  After receiving PONG we send a binary PING (UI frame)
    /// so the peer also learns our capabilities (bidirectional exchange).
    private var awaitingCapabilityExchange: Set<String> = []

    /// Set of (from, messageId, sessionId) for displayed chat messages; prevents duplicates from retransmissions
    private var displayedChatMessageIds: Set<String> = []
    /// How long to remember "not supported" before allowing auto-discovery again
    private let axdpNotSupportedTTL: TimeInterval = 86400.0

    /// Callback for capability discovery events (for debug display)
    var onCapabilityEvent: ((CapabilityDebugEvent) -> Void)?

    /// Callback when AXDP chat message is received. Parameters: (from address, decoded text).
    /// Used to deliver chat to the terminal transcript regardless of AXDP badge state.
    var onAXDPChatReceived: ((AX25Address, String) -> Void)?

    /// Callback when AXDP reassembly completes (a full message was extracted). Parameter: peer address.
    /// Used to clear the peersInAXDPReassembly flag in TerminalView so subsequent plain text
    /// messages from this peer will be delivered to the console.
    var onAXDPReassemblyComplete: ((AX25Address) -> Void)?

    /// Callback when peer sends peerAxdpEnabled (they turned on AXDP). Parameter: peer address.
    /// Used to show a toast prompting the local user to enable AXDP.
    var onPeerAxdpEnabled: ((AX25Address) -> Void)?

    /// Callback when peer sends peerAxdpDisabled (they turned off AXDP). Parameter: peer address.
    var onPeerAxdpDisabled: ((AX25Address) -> Void)?

    /// Transfers awaiting acceptance (AXDP session ID -> transfer ID)
    /// Used to map ACK/NACK responses to the correct transfer
    private var transfersAwaitingAcceptance: [UInt32: UUID] = [:]

    #if DEBUG
    /// Test-only switch: when true, completion NACK + SACK handling will
    /// skip selective retransmit logic and only log + return.
    /// This allows unit tests to validate state transitions without
    /// exercising the full retransmit/PacketEngine pipeline, which can be
    /// fragile in the ephemeral test environment.
    static var disableCompletionNackSackRetransmitForTests: Bool = false
    #endif

    /// Task that periodically sends completion-request (ACK 0xFFFFFFFE) for transfers awaiting completion.
    /// Receiver responds with completion ACK or NACK with SACK bitmap; sender then selectively retransmits only missing chunks.
    private var awaitingCompletionRequestTask: Task<Void, Never>?

    /// Global adaptive settings (for compression, etc.)
    var globalAdaptiveSettings: TxAdaptiveSettings = TxAdaptiveSettings()

    /// When true, learn from session and network and use learned params; when false, use fixed defaults.
    @Published var adaptiveTransmissionEnabled: Bool = true

    /// Destinations that should use default config (no learned params). "Reset for this station" adds here.
    @Published var useDefaultConfigForDestinations: Set<String> = []

    /// Per-route learned adaptive params so multiple connections (e.g. same peer direct vs via digi) don't overwrite each other.
    /// Key: (destination, pathSignature); value: learned settings + last update time for TTL invalidation.
    var adaptiveCache: [RouteAdaptiveKey: CachedAdaptiveEntry] = [:]

    /// TTL for per-route cache: after this many seconds without a sample for that route, we fall back to global.
    private static let adaptiveCacheTTLSeconds: TimeInterval = 30 * 60  // 30 minutes

    /// Reassembly buffer for fragmented AXDP messages over connected-mode I-frames.
    /// Key: "callsign-path"; value: accumulated bytes.
    private var inboundReassemblyBuffer: [String: Data] = [:]
    
    #if DEBUG
    /// Test-only accessor for reassembly buffer state (for integration tests)
    var testReassemblyBufferState: [String: Int] {
        inboundReassemblyBuffer.mapValues { $0.count }
    }
    
    /// Test-only callback for monitoring reassembly events
    var onReassemblyEvent: ((String, Int, Bool) -> Void)?  // key, bufferSize, extracted
    #endif

    init() {
        SessionCoordinator.shared = self
        setupCallbacks()
    }

    /// Sync AX.25 session config from global adaptive settings so both messaging and file transfer use the same window size, RTO bounds, and retries.
    /// Call after setting globalAdaptiveSettings (e.g. on launch or when user changes TX adaptive settings).
    func syncSessionManagerConfigFromAdaptive() {
        guard adaptiveTransmissionEnabled else {
            sessionManager.defaultConfig = AX25SessionConfig()
            TxLog.adaptiveConfigSynced(window: 4, paclen: 128, rtoMin: 1, rtoMax: 30, maxRetries: 10, initialRto: 4.0)
            return
        }
        let a = globalAdaptiveSettings
        sessionManager.defaultConfig = AX25SessionConfig(
            windowSize: a.windowSize.effectiveValue,
            paclen: a.paclen.effectiveValue,
            maxReceiveBufferSize: nil,
            maxRetries: a.maxRetries.effectiveValue,
            extended: false,
            rtoMin: a.rtoMin.effectiveValue,
            rtoMax: a.rtoMax.effectiveValue,
            initialRto: max(a.rtoMin.effectiveValue, min(a.rtoMax.effectiveValue, 4.0))
        )
        TxLog.adaptiveConfigSynced(
            window: a.windowSize.effectiveValue,
            paclen: a.paclen.effectiveValue,
            rtoMin: a.rtoMin.effectiveValue,
            rtoMax: a.rtoMax.effectiveValue,
            maxRetries: a.maxRetries.effectiveValue,
            initialRto: max(a.rtoMin.effectiveValue, min(a.rtoMax.effectiveValue, 4.0))
        )
    }

    /// Apply a link quality sample to adaptive settings (per-route when session, global when network).
    /// Session samples update the per-route cache so multiple connections (e.g. same peer direct vs via digi) don't overwrite each other.
    func applyLinkQualitySample(lossRate: Double, etx: Double, srtt: Double?, source: String = "session", routeKey: RouteAdaptiveKey? = nil) {
        guard adaptiveTransmissionEnabled else {
            TxLog.adaptiveSampleIgnored(reason: "adaptive disabled", lossRate: lossRate, etx: etx)
            return
        }
        
        var changes: [String] = []
        let reason: String
        
        if let key = routeKey {
            // Normalize destination for consistent cache lookups (PEER-0 and PEER map to same key)
            let normalizedKey = RouteAdaptiveKey(destination: canonicalDestination(key.destination), pathSignature: key.pathSignature)
            
            // Per-route adaptation
            var adaptive = adaptiveCache[normalizedKey]?.settings ?? globalAdaptiveSettings
            // Inherit global defaults if fresh, then adapt
            if adaptiveCache[normalizedKey] == nil {
                adaptive = globalAdaptiveSettings
            }
            
            changes = adaptive.updateFromLinkQuality(lossRate: lossRate, etx: etx, srtt: srtt)
            reason = adaptive.windowSize.adaptiveReason ?? adaptive.paclen.adaptiveReason ?? "route update"
            
            // Update cache
            adaptiveCache[normalizedKey] = CachedAdaptiveEntry(settings: adaptive, lastUpdated: Date())
            
            TxLog.adaptiveLearning(
                source: source,
                lossRate: lossRate,
                etx: etx,
                srtt: srtt,
                rto: adaptive.currentRto,
                window: adaptive.windowSize.effectiveValue,
                paclen: adaptive.paclen.effectiveValue,
                maxRetries: adaptive.maxRetries.effectiveValue,
                reason: reason + " [route \(normalizedKey.destination) \(normalizedKey.pathSignature.isEmpty ? "direct" : normalizedKey.pathSignature)]"
            )
            
            if !changes.isEmpty {
                 let msg = "[ADAPTIVE] \(normalizedKey.destination): \(changes.joined(separator: ", ")) | \(reason)"
                 packetEngine?.addSystemLine(msg, category: .system)
            }
            
        } else {
            // Global adaptation
            changes = globalAdaptiveSettings.updateFromLinkQuality(lossRate: lossRate, etx: etx, srtt: srtt)
            let a = globalAdaptiveSettings
            reason = a.windowSize.adaptiveReason ?? a.paclen.adaptiveReason ?? "updated"
            
            TxLog.adaptiveLearning(
                source: source,
                lossRate: lossRate,
                etx: etx,
                srtt: srtt,
                rto: a.currentRto,
                window: a.windowSize.effectiveValue,
                paclen: a.paclen.effectiveValue,
                maxRetries: a.maxRetries.effectiveValue,
                reason: reason
            )
            syncSessionManagerConfigFromAdaptive()
            
            if !changes.isEmpty {
                 let msg = "[ADAPTIVE] Global: \(changes.joined(separator: ", ")) | \(reason)"
                 packetEngine?.addSystemLine(msg, category: .system)
            }
        }
        objectWillChange.send()
    }

    /// True if cached entry is older than TTL (route-level cache invalidation).
    private func isAdaptiveCacheEntryExpired(_ entry: CachedAdaptiveEntry) -> Bool {
        Date().timeIntervalSince(entry.lastUpdated) > Self.adaptiveCacheTTLSeconds
    }

    /// Build session config from adaptive settings (shared by per-route and merged paths).
    private func configFromAdaptive(_ a: TxAdaptiveSettings) -> AX25SessionConfig {
        AX25SessionConfig(
            windowSize: a.windowSize.effectiveValue,
            paclen: a.paclen.effectiveValue,
            maxReceiveBufferSize: nil,
            maxRetries: a.maxRetries.effectiveValue,
            extended: false,
            rtoMin: a.rtoMin.effectiveValue,
            rtoMax: a.rtoMax.effectiveValue,
            initialRto: max(a.rtoMin.effectiveValue, min(a.rtoMax.effectiveValue, 4.0))
        )
    }

    /// Number of active sessions (any state) to the given destination. Used to stabilize config when multiple connections exist.
    private func activeSessionCount(forDestination destination: String) -> Int {
        let canon = canonicalDestination(destination)
        return sessionManager.sessions.values.filter { canonicalDestination($0.remoteAddress.display) == canon }.count
    }

    /// Conservative merge of configs for a destination: min window, max RTO, max retries. Used when 2+ sessions exist to same peer so we don't flip parameters between connections or corrupt transmissions.
    private func mergedConfigForDestination(_ destination: String) -> AX25SessionConfig {
        var configs: [AX25SessionConfig] = [configFromAdaptive(globalAdaptiveSettings)]
        let canon = canonicalDestination(destination)
        for (key, entry) in adaptiveCache where key.destination == canon && !isAdaptiveCacheEntryExpired(entry) {
            configs.append(configFromAdaptive(entry.settings))
        }
        guard let first = configs.first else { return AX25SessionConfig() }
        let windowSize = configs.map(\.windowSize).min() ?? first.windowSize
        let paclen = configs.map(\.paclen).min() ?? first.paclen
        let rtoMin = configs.compactMap(\.rtoMin).max() ?? first.rtoMin ?? 1.0
        let rtoMax = configs.compactMap(\.rtoMax).max() ?? first.rtoMax ?? 30.0
        let maxRetries = configs.map(\.maxRetries).max() ?? first.maxRetries
        return AX25SessionConfig(
            windowSize: windowSize,
            paclen: paclen,
            maxReceiveBufferSize: nil,
            maxRetries: maxRetries,
            extended: false,
            rtoMin: rtoMin,
            rtoMax: rtoMax,
            initialRto: max(rtoMin, min(rtoMax, 4.0))
        )
    }

    /// Remove expired entries from per-route cache (call periodically or when looking up).
    private func pruneExpiredAdaptiveCache() {
        let now = Date()
        adaptiveCache = adaptiveCache.filter { _, entry in
            now.timeIntervalSince(entry.lastUpdated) <= Self.adaptiveCacheTTLSeconds
        }
    }

    /// Clear all learned adaptive settings, per-route cache, and per-station overrides; reset to defaults.
    func clearAllLearned() {
        globalAdaptiveSettings = TxAdaptiveSettings()
        useDefaultConfigForDestinations.removeAll()
        adaptiveCache.removeAll()
        syncSessionManagerConfigFromAdaptive()
        TxLog.adaptiveCleared(reason: "clear all – reset to defaults (routes + global)")
        objectWillChange.send()
    }

    /// Use default config for this station (reset learned params for this callsign only).
    func resetStationToDefault(callsign: String) {
        let normalized = canonicalDestination(callsign)
        guard !normalized.isEmpty else { return }
        useDefaultConfigForDestinations.insert(normalized)
        TxLog.adaptiveStationReset(callsign: normalized)
        objectWillChange.send()
    }

    /// Use global adaptive config for this station again (undo per-station reset).
    func useGlobalAdaptiveForStation(callsign: String) {
        let normalized = canonicalDestination(callsign)
        useDefaultConfigForDestinations.remove(normalized)
        objectWillChange.send()
    }

    /// Explicit deinit to ensure any background tasks are cancelled cleanly.
    /// Marked nonisolated to avoid actor deallocation bookkeeping that has
    /// been triggering a Swift concurrency runtime bug in unit tests.
    nonisolated deinit {
        awaitingCompletionRequestTask?.cancel()
    }

    // MARK: - Debug Logging (AXDP)

    private func debugAXDP(_ message: String, _ fields: [String: Any] = [:]) {
        #if DEBUG
        if fields.isEmpty {
            print("[AXDP TRACE][Session] \(message)")
        } else {
            let details = fields
                .map { "\($0.key)=\($0.value)" }
                .sorted()
                .joined(separator: " ")
            print("[AXDP TRACE][Session] \(message) | \(details)")
        }
        #endif
    }

    // MARK: - Setup

    private func setupCallbacks() {
        // Wire up frame sending for drain queue and immediate sends
        sessionManager.onSendFrame = { [weak self] frame in
            self?.sendFrame(frame)
        }

        // Wire up AXDP reassembly - must use in-order delivered data only.
        // Out-of-window or buffered frames are discarded/buffered by AX.25; appending them
        // would corrupt reassembly (chunks arrive out of order over KISS relay).
        sessionManager.onDataDeliveredForReassembly = { [weak self] session, data in
            print("[DEBUG:DELIVERY] Data delivered for reassembly | from=\(session.remoteAddress.display) size=\(data.count) hex=\(data.prefix(16).map { String(format: "%02X", $0) }.joined())")
            self?.appendToReassemblyAndExtract(from: session.remoteAddress, path: session.path, data: data)

            // Send our text probe (UI frame) after receiving first inbound I-frame (if pending).
            // Note: inbound text probes arrive via UI frames, not I-frames, so detection
            // is handled in handleUFrame's .UI case instead of here.
            self?.sendTextProbeIfNeeded(for: session)
        }

        sessionManager.onLinkQualitySample = { [weak self] session, lossRate, etx, srtt in
            let routeKey = RouteAdaptiveKey(
                destination: session.remoteAddress.display.uppercased(),
                pathSignature: session.path.display
            )
            self?.applyLinkQualitySample(lossRate: lossRate, etx: etx, srtt: srtt, source: "session", routeKey: routeKey)
        }

        sessionManager.getConfigForDestination = { [weak self] destination, pathSignature in
            guard let self = self else { return AX25SessionConfig() }
            if !self.adaptiveTransmissionEnabled { return AX25SessionConfig() }
            if self.useDefaultConfigForDestinations.contains(where: { canonicalDestination($0) == canonicalDestination(destination) }) { return AX25SessionConfig() }
            // When multiple connections exist to the same destination, use a conservative merged config so we don't flip parameters between connections or change settings mid-transmission.
            if self.activeSessionCount(forDestination: destination) >= 1 {
                return self.mergedConfigForDestination(destination)
            }
            let key = RouteAdaptiveKey(destination: canonicalDestination(destination), pathSignature: pathSignature)
            if let cached = self.adaptiveCache[key], !self.isAdaptiveCacheEntryExpired(cached) {
                return self.configFromAdaptive(cached.settings)
            }
            return self.configFromAdaptive(self.globalAdaptiveSettings)
        }

        // Wire up session state changes for capability discovery
        sessionManager.onSessionStateChanged = { [weak self] session, oldState, newState in
            guard let self = self else { return }

            // Force UI update for any session state change - ensures both stations update
            self.objectWillChange.send()

            if oldState != .connected && newState == .connected {
                let axdpEnabled = self.globalAdaptiveSettings.axdpExtensionsEnabled
                let autoNegotiate = self.globalAdaptiveSettings.autoNegotiateCapabilities
                let isInitiator = session.isInitiator
                let peer = session.remoteAddress.display.uppercased()

                if isInitiator && axdpEnabled && autoNegotiate {
                    if self.isAXDPNotSupported(for: peer) {
                        // Known non-AXDP peer — skip entirely
                        self.debugAXDP("Session connected, skipping probe (peer marked not-supported)", [
                            "peer": session.remoteAddress.display
                        ])
                    } else {
                        // Schedule text-safe probe after first inbound I-frame (or 3s fallback).
                        // Text probes are plain ASCII — harmless to legacy nodes (treated as unknown command).
                        // Note: invalidateCapability clears confirmed state on disconnect, so peers
                        // are always re-probed on reconnect. This is intentional — the peer may have
                        // changed software between sessions.
                        self.pendingTextProbe.insert(peer)
                        self.scheduleTextProbeFallback(for: session)
                        self.debugAXDP("Session connected, scheduling text probe", [
                            "peer": session.remoteAddress.display
                        ])
                        TxLog.debug(.capability, "Session connected (initiator), will send text probe", [
                            "peer": session.remoteAddress.display
                        ])
                    }
                } else {
                    self.debugAXDP("Session connected, no probe (responder or AXDP disabled)", [
                        "peer": session.remoteAddress.display,
                        "isInitiator": isInitiator,
                        "axdpEnabled": axdpEnabled
                    ])
                }
            }

            // When a session disconnects, invalidate cached capabilities and clear reassembly buffer.
            // This ensures we re-discover on next connection (station might switch software)
            // and prevents stale partial AXDP messages from corrupting future communications.
            if (oldState == .connected || oldState == .disconnecting) && (newState == .disconnected || newState == .error) {
                self.invalidateCapability(for: session.remoteAddress.display)
                
                // Clear reassembly buffer for this peer to prevent stale data corruption.
                // This is critical for multi-fragment AXDP messages - if partial data remains
                // and the peer reconnects, the old fragments could corrupt the new message.
                self.clearAllReassemblyBuffers(for: session.remoteAddress)
            }
        }
    }

    /// Invalidate cached capability for a station
    /// Called when session disconnects to ensure fresh discovery on next connection
    private func invalidateCapability(for callsign: String) {
        let call = callsign.uppercased()

        // Clear from capability store
        packetEngine?.capabilityStore.remove(for: call)

        // Clear implicit confirmation and stale "not supported" state so
        // reconnects always perform fresh capability discovery.
        implicitlyConfirmedAXDP.remove(call)
        clearAXDPNotSupported(for: call)

        // Clear pending discovery status
        pendingCapabilityDiscovery.removeValue(forKey: call)

        // Cancel any pending text probe or pending capability exchange
        pendingTextProbe.remove(call)
        awaitingCapabilityExchange.remove(call)

        TxLog.debug(.capability, "Invalidated capability cache", [
            "peer": callsign
        ])
    }

    /// Send an AXDP PING to a connected session to discover capabilities
    func sendCapabilityPing(to session: AX25Session) {
        let peerCallsign = session.remoteAddress.display.uppercased()

        if isAXDPNotSupported(for: peerCallsign) {
            TxLog.debug(.capability, "Skipping PING - peer previously marked not supported", [
                "peer": peerCallsign
            ])
            return
        }

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

        // Track that we're waiting for a response
        pendingCapabilityDiscovery[peerCallsign] = Date()
        scheduleCapabilityTimeout(for: peerCallsign)

        // For connected sessions, route through session manager (I-frames)
        _ = sendAXDPPayload(
            pingMessage.encode(),
            to: session.remoteAddress,
            path: session.path,
            displayInfo: "AXDP PING"
        )

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

    // MARK: - Text-Safe AXDP Capability Probe

    /// Send the text-safe AXDP probe if this peer has one pending.
    /// Called when we receive the first inbound I-frame, indicating the peer's
    /// application layer has initialized.
    private func sendTextProbeIfNeeded(for session: AX25Session) {
        let peer = session.remoteAddress.display.uppercased()
        guard pendingTextProbe.remove(peer) != nil else { return }
        sendTextProbe(to: session)
    }

    /// Send the plain-text `AXDP?\r` probe as a **UI frame** (connectionless).
    /// UI frames are not fed into the connected-mode application layer, so legacy
    /// BBS/nodes never see the probe text — no "Invalid command" response, no
    /// transcript noise.  AXTerm peers detect the probe in their UI frame handler
    /// and respond with an AXDP PONG (also via UI frame).
    private func sendTextProbe(to session: AX25Session) {
        let peerCallsign = session.remoteAddress.display.uppercased()

        if isAXDPNotSupported(for: peerCallsign) { return }
        if hasConfirmedAXDPCapability(for: peerCallsign) { return }
        if isCapabilityDiscoveryPending(for: peerCallsign) { return }

        guard let probeData = Self.axdpTextProbe.data(using: .ascii) else { return }

        // Track that we're waiting for a response, and that we still need to send
        // our own capabilities after receiving theirs (bidirectional exchange).
        pendingCapabilityDiscovery[peerCallsign] = Date()
        awaitingCapabilityExchange.insert(peerCallsign)
        scheduleCapabilityTimeout(for: peerCallsign)

        // Send as UI frame — outside the connected-mode data flow
        let frame = OutboundFrame(
            destination: session.remoteAddress,
            source: sessionManager.localCallsign,
            path: session.path,
            payload: probeData,
            frameType: "ui",
            pid: 0xF0,
            displayInfo: "AXDP probe"
        )
        sendFrame(frame)

        debugAXDP("Sent text probe (UI frame)", ["peer": session.remoteAddress.display])
        TxLog.outbound(.capability, "Sent AXDP text probe via UI frame", [
            "dest": session.remoteAddress.display
        ])

        onCapabilityEvent?(CapabilityDebugEvent(
            type: .pingSent,
            peer: session.remoteAddress.display,
            capabilities: nil
        ))
    }

    /// Send a binary AXDP PING (with our capabilities) via UI frame.
    /// Used to complete the bidirectional exchange after receiving a PONG in response
    /// to our text probe.  The peer already proved AXDP support so binary is safe.
    private func sendCapabilityPingViaUI(to address: AX25Address, path: DigiPath) {
        let localCaps = AXDPCapability.defaultLocal()
        let pingMessage = AXDP.Message(
            type: .ping,
            sessionId: 0,
            messageId: 2,  // Distinct from probe's messageId
            capabilities: localCaps
        )
        let frame = OutboundFrame(
            destination: address,
            source: sessionManager.localCallsign,
            path: path,
            payload: pingMessage.encode(),
            frameType: "ui",
            displayInfo: "AXDP PING"
        )
        sendFrame(frame)

        debugAXDP("Sent capability PING via UI frame (bidirectional exchange)", ["peer": address.display])
        TxLog.outbound(.capability, "Sent AXDP PING via UI frame", [
            "dest": address.display,
            "features": localCaps.features.description
        ])

        onCapabilityEvent?(CapabilityDebugEvent(
            type: .pingSent,
            peer: address.display,
            capabilities: localCaps
        ))
    }

    /// Detect inbound `AXDP?\r` text probe from a peer (received via UI frame) and
    /// respond with AXDP PONG (also via UI frame).  The peer sent us a text probe,
    /// which proves they understand AXDP — so responding with binary PONG is safe.
    /// Internal access for testability.
    func handleInboundTextProbe(from: AX25Address, path: DigiPath, payload: Data) {
        guard globalAdaptiveSettings.axdpExtensionsEnabled else { return }
        guard let text = String(data: payload, encoding: .ascii) else { return }
        guard text.hasPrefix("AXDP?") else { return }

        let peerCallsign = from.display.uppercased()
        debugAXDP("Received text probe from peer (UI frame)", ["peer": peerCallsign])
        TxLog.debug(.capability, "Received AXDP text probe via UI frame, responding with PONG", [
            "peer": peerCallsign
        ])

        // Mark peer as AXDP-capable (they sent a probe, so they understand AXDP)
        markImplicitlyConfirmedAXDP(for: peerCallsign)

        // Respond with binary AXDP PONG via UI frame (stays out of connected-mode data flow)
        let localCaps = AXDPCapability.defaultLocal()
        let pongMessage = AXDP.Message(
            type: .pong,
            sessionId: 0,
            messageId: 1,
            capabilities: localCaps
        )
        let pongFrame = OutboundFrame(
            destination: from,
            source: sessionManager.localCallsign,
            path: path,
            payload: pongMessage.encode(),
            frameType: "ui",
            displayInfo: "AXDP PONG"
        )
        sendFrame(pongFrame)

        TxLog.outbound(.capability, "Sent AXDP PONG via UI frame", [
            "dest": from.display,
            "features": localCaps.features.description
        ])

        onCapabilityEvent?(CapabilityDebugEvent(
            type: .pongSent,
            peer: from.display,
            capabilities: localCaps
        ))
    }

    /// Fallback timer: send text probe after 3 seconds even without inbound data.
    /// Handles AXTerm-to-AXTerm connections where neither side sends a welcome banner.
    /// Text probe is safe for legacy nodes (treated as unknown command).
    private func scheduleTextProbeFallback(for session: AX25Session) {
        let peer = session.remoteAddress.display.uppercased()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard self.pendingTextProbe.remove(peer) != nil else { return }
            guard session.state == .connected else { return }
            self.debugAXDP("Text probe fallback timer fired", [
                "peer": session.remoteAddress.display
            ])
            self.sendTextProbe(to: session)
        }
    }

    /// Trigger AXDP capability discovery for all currently connected sessions
    /// where we are the initiator. This is used when auto-negotiation is turned
    /// on while a session is already connected.
    func triggerCapabilityDiscoveryForConnectedInitiators() {
        triggerCapabilityDiscovery(initiatorOnly: true)
    }
    
    /// Trigger capability discovery for ALL connected sessions (both initiator and responder).
    /// This is the preferred method when the user manually enables AXDP, since they may be
    /// the responder in the session and still need capability confirmation.
    func triggerCapabilityDiscoveryForAllConnected() {
        triggerCapabilityDiscovery(initiatorOnly: false)
    }
    
    /// Internal implementation of capability discovery triggering.
    /// - Parameter initiatorOnly: If true, only send PING for sessions where we initiated.
    ///   If false, send PING for ALL connected sessions.
    private func triggerCapabilityDiscovery(initiatorOnly: Bool) {
        debugAXDP("triggerCapabilityDiscovery called", [
            "initiatorOnly": initiatorOnly,
            "axdpEnabled": globalAdaptiveSettings.axdpExtensionsEnabled,
            "autoNegotiate": globalAdaptiveSettings.autoNegotiateCapabilities,
            "connectedCount": connectedSessions.count
        ])
        
        guard globalAdaptiveSettings.axdpExtensionsEnabled,
              globalAdaptiveSettings.autoNegotiateCapabilities else {
            debugAXDP("triggerCapabilityDiscovery: guards failed", [
                "axdpEnabled": globalAdaptiveSettings.axdpExtensionsEnabled,
                "autoNegotiate": globalAdaptiveSettings.autoNegotiateCapabilities
            ])
            return
        }

        let targetSessions: [AX25Session]
        if initiatorOnly {
            targetSessions = connectedSessions.filter { $0.isInitiator }
        } else {
            targetSessions = connectedSessions
        }
        
        debugAXDP("triggerCapabilityDiscovery: found target sessions", [
            "initiatorOnly": initiatorOnly,
            "totalConnected": connectedSessions.count,
            "targetCount": targetSessions.count,
            "sessions": targetSessions.map { ["peer": $0.remoteAddress.display, "isInitiator": $0.isInitiator] }
        ])

        for session in targetSessions {
            debugAXDP("triggerCapabilityDiscovery: sending PING", [
                "peer": session.remoteAddress.display,
                "sessionId": session.id.uuidString,
                "isInitiator": session.isInitiator
            ])
            // sendCapabilityPing() is internally idempotent with respect to
            // pending/confirmed/not-supported state.
            sendCapabilityPing(to: session)
        }
    }

    /// Send an AXDP PONG response to a received PING, always via UI frame.
    /// Keeps all capability negotiation out of the connected-mode I-frame stream.
    private func sendCapabilityPong(to address: AX25Address, path: DigiPath, sessionId: UInt32, messageId: UInt32) {
        let localCaps = AXDPCapability.defaultLocal()
        let pongMessage = AXDP.Message(
            type: .pong,
            sessionId: sessionId,
            messageId: messageId,
            capabilities: localCaps
        )

        // Always respond via UI frame — capability exchange stays outside connected-mode data flow
        let frame = OutboundFrame(
            destination: address,
            source: sessionManager.localCallsign,
            path: path,
            payload: pongMessage.encode(),
            frameType: "ui",
            displayInfo: "AXDP PONG"
        )
        sendFrame(frame)

        TxLog.outbound(.capability, "Sent AXDP PONG via UI frame", [
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

    /// Send peerAxdpEnabled notification to a peer when the local user enables the AXDP toggle.
    /// Only call when peer has confirmed AXDP capability and a session is connected.
    func sendPeerAxdpEnabled(to address: AX25Address, path: DigiPath) {
        let sessionId = UInt32(arc4random() & 0x7FFFFFFF)
        let messageId = UInt32(arc4random() & 0x7FFFFFFF)
        let msg = AXDP.Message(
            type: .peerAxdpEnabled,
            sessionId: sessionId,
            messageId: messageId
        )
        _ = sendAXDPPayload(msg.encode(), to: address, path: path, displayInfo: "AXDP peer enabled")
        TxLog.debug(.axdp, "Sent peerAxdpEnabled notification", ["dest": address.display])
    }

    /// Send peerAxdpDisabled notification when the local user disables the AXDP toggle.
    func sendPeerAxdpDisabled(to address: AX25Address, path: DigiPath) {
        let sessionId = UInt32(arc4random() & 0x7FFFFFFF)
        let messageId = UInt32(arc4random() & 0x7FFFFFFF)
        let msg = AXDP.Message(
            type: .peerAxdpDisabled,
            sessionId: sessionId,
            messageId: messageId
        )
        _ = sendAXDPPayload(msg.encode(), to: address, path: path, displayInfo: "AXDP peer disabled")
        TxLog.debug(.axdp, "Sent peerAxdpDisabled notification", ["dest": address.display])
    }

    private func updateSessionManagerCallsign() {
        let input = localCallsign.isEmpty ? "NOCALL" : localCallsign
        let parts = input.uppercased().split(separator: "-")
        let baseCall = String(parts.first ?? "NOCALL")
        let ssid = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        sessionManager.localCallsign = AX25Address(call: baseCall, ssid: ssid)
    }

    /// Subscribe to incoming packets from PacketEngine.
    /// Safe to call multiple times — replaces any existing subscription.
    func subscribeToPackets(from client: PacketEngine) {
        self.packetEngine = client
        // Note: onDataDeliveredForReassembly is wired up in setupCallbacks() already

        // Cancel previous subscription to prevent duplicate packet processing.
        // ContentView.init() can be called multiple times by SwiftUI, each time
        // calling subscribeToPackets on the same shared coordinator instance.
        packetSubscription?.cancel()
        packetSubscription = client.packetPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] packet in
                self?.handleIncomingPacket(packet)
            }
    }

    /// Send a frame via PacketEngine
    private func sendFrame(_ frame: OutboundFrame) {
        // Guard: don't send if packetEngine is not set (e.g., in tests)
        guard let packetEngine = packetEngine else {
            TxLog.debug(.session, "Skipping sendFrame - packetEngine not set", [
                "destination": frame.destination.display
            ])
            return
        }
        packetEngine.send(frame: frame) { result in
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
        // Only process packets addressed to us (call + SSID)
        guard CallsignNormalizer.addressesMatch(to, sessionManager.localCallsign) else { return }

        // Ignore packets from ourselves (TNC echo) - match both call AND SSID
        // This allows same-base-callsign but different-SSID traffic (e.g., K0EPI-1 talking to K0EPI-7)
        guard from.call.uppercased() != sessionManager.localCallsign.call || from.ssid != sessionManager.localCallsign.ssid else {
            TxLog.debug(.session, "Ignoring echoed frame from local callsign", [
                "from": from.display,
                "to": to.display,
                "localCallsign": sessionManager.localCallsign.display
            ])
            return
        }

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
            if let response = sessionManager.handleInboundDISC(from: from, path: path, channel: channel) {
                sendFrame(response)
            }
        case .SABM, .SABME:
            if let response = sessionManager.handleInboundSABM(
                from: from,
                to: to,
                path: path,
                channel: channel
            ) {
                sendFrame(response)
            }
        case .UI:
            // Check for text-safe AXDP probe ("AXDP?\r") before binary AXDP check.
            // Text probes don't have AXDP magic, so handleAXDPMessage would skip them.
            handleInboundTextProbe(from: from, path: path, payload: packet.info)
            // UI frames can also contain binary AXDP messages (capability discovery, file transfers)
            handleAXDPMessage(from: from, path: path, payload: packet.info)
        default:
            break
        }
    }

    private func handleIFrame(packet: Packet, from: AX25Address, ns: Int, nr: Int, pf: Bool, channel: UInt8) {
        let path = DigiPath.from(packet.via.map { $0.display })
        if let response = sessionManager.handleInboundIFrame(
            from: from,
            path: path,
            channel: channel,
            ns: ns,
            nr: nr,
            pf: pf,
            payload: packet.info
        ) {
            sendFrame(response)
        }
        // AXDP in I-frames is processed only via reassembly (onDataDeliveredForReassembly -> appendToReassemblyAndExtract).
        // Do not call handleAXDPMessage here: the same payload is delivered to reassembly and would cause duplicate
        // handling (e.g. ping/pong delivered twice).
    }

    /// Append delivered (in-order) data to reassembly buffer and extract complete AXDP messages.
    /// Non-AXDP data (plain text I-frames) is not buffered to prevent polluting AXDP reassembly.
    private func appendToReassemblyAndExtract(from: AX25Address, path: DigiPath, data: Data) {
        let key = reassemblyKey(from: from, path: path)
        var buf = inboundReassemblyBuffer[key] ?? Data()
        let beforeLen = buf.count
        let dataPrefixHex = data.prefix(8).map { String(format: "%02X", $0) }.joined()
        let dataPrefixAscii = asciiPreview(data, maxLen: 16)
        
        // Handle non-AXDP data properly to prevent buffer pollution:
        // 1. If buffer is empty and data doesn't start with magic → non-AXDP data, skip
        // 2. If buffer has garbage (no magic at start) → clear it before processing
        // 3. If buffer starts with magic → valid AXDP reassembly in progress
        
        if buf.isEmpty {
            // Empty buffer: only start buffering if data is AXDP (starts with magic)
            if !AXDP.hasMagic(data) {
                print("[DEBUG:REASSEMBLY] skip non-AXDP | from=\(from.display) size=\(data.count) prefix=\(data.prefix(4).map { String(format: "%02X", $0) }.joined()) ascii=\(dataPrefixAscii)")
                TxLog.debug(.axdp, "Skipping non-AXDP data (no magic header)", [
                    "from": from.display,
                    "size": data.count,
                    "prefixHex": dataPrefixHex,
                    "prefixAscii": dataPrefixAscii
                ])
                return  // Don't buffer non-AXDP data
            }
        } else if !AXDP.hasMagic(buf) {
            // Buffer has garbage that doesn't start with magic.
            // Attempt a resync if magic appears later (e.g., previous decode left extra bytes).
            if let magicOffset = magicOffset(in: buf), magicOffset > 0 {
                print("[DEBUG:REASSEMBLY] resync to magic | from=\(from.display) offset=\(magicOffset) bufLen=\(buf.count)")
                TxLog.debug(.axdp, "Resyncing reassembly buffer to magic header", [
                    "from": from.display,
                    "offset": magicOffset,
                    "bufLen": buf.count
                ])
                buf = buf.subdata(in: magicOffset..<buf.count)
            } else {
                print("[DEBUG:REASSEMBLY] clear garbage | from=\(from.display) garbageLen=\(buf.count)")
                TxLog.debug(.axdp, "Clearing garbage from reassembly buffer", [
                    "from": from.display,
                    "garbageLen": buf.count
                ])
                buf = Data()  // Clear the garbage

                // Now check if new data is AXDP
                if !AXDP.hasMagic(data) {
                    print("[DEBUG:REASSEMBLY] skip non-AXDP after clear | from=\(from.display) size=\(data.count) ascii=\(dataPrefixAscii)")
                    inboundReassemblyBuffer.removeValue(forKey: key)
                    return  // Don't buffer non-AXDP data
                }
            }
        }
        
        // At this point, either:
        // - Buffer was empty and data starts with magic (new AXDP message)
        // - Buffer starts with magic (continuation of AXDP message)
        // - Buffer was garbage and cleared, data starts with magic (new AXDP message)
        
        buf.append(data)
        inboundReassemblyBuffer[key] = buf

        print("[DEBUG:REASSEMBLY] append | from=\(from.display) chunkLen=\(data.count) before=\(beforeLen) after=\(buf.count)")
        TxLog.debug(.axdp, "Reassembly append chunk", [
            "from": from.display,
            "key": key,
            "chunkLen": data.count,
            "before": beforeLen,
            "after": buf.count
        ])
        #if DEBUG
        onReassemblyEvent?(key, buf.count, false)  // appended chunk
        #endif

        while let (message, consumed) = extractOneAXDPMessage(from: buf), consumed > 0, consumed <= buf.count {
            print("[DEBUG:REASSEMBLY] extracted complete | from=\(from.display) type=\(message.type) consumed=\(consumed) payloadLen=\(message.payload?.count ?? 0)")
            TxLog.debug(.axdp, "Reassembly extracted complete message", [
                "from": from.display,
                "type": String(describing: message.type),
                "consumed": consumed,
                "payloadLen": message.payload?.count ?? 0
            ])
            buf.removeFirst(consumed)
            #if DEBUG
            onReassemblyEvent?(key, buf.count, true)  // extracted message
            #endif
            // Notify that AXDP reassembly completed for this peer.
            // This allows TerminalView to clear the peersInAXDPReassembly flag,
            // so subsequent plain text from this peer will be delivered.
            onAXDPReassemblyComplete?(from)
            handleAXDPMessageDecoded(from: from, path: path, message: message)
        }
        if buf.count > 0 {
            let canExtract = extractOneAXDPMessage(from: buf) != nil
            if !canExtract {
                let magicOffset = magicOffset(in: buf) ?? -1
                print("[DEBUG:REASSEMBLY] incomplete | from=\(from.display) bufLen=\(buf.count) hasMagic=\(AXDP.hasMagic(buf)) magicOffset=\(magicOffset)")
                TxLog.debug(.axdp, "Reassembly incomplete", [
                    "from": from.display,
                    "bufLen": buf.count,
                    "hasMagic": AXDP.hasMagic(buf),
                    "magicOffset": magicOffset
                ])
            }
        }
        if buf.count > 65_536 {
            print("[DEBUG:REASSEMBLY] overflow discard | from=\(from.display) bufLen=\(buf.count)")
            inboundReassemblyBuffer.removeValue(forKey: key)
        } else if buf.isEmpty {
            inboundReassemblyBuffer.removeValue(forKey: key)
        } else {
            inboundReassemblyBuffer[key] = buf
        }
    }

    private func reassemblyKey(from: AX25Address, path: DigiPath) -> String {
        "\(from.display)-\(path.display)"
    }
    
    /// Clear the reassembly buffer for a specific peer/path.
    /// Called when a session disconnects to prevent stale buffer data from corrupting future messages.
    /// This is critical for multi-fragment AXDP messages - if partial data remains in the buffer
    /// and the peer reconnects, the old fragments could corrupt the new message.
    private func clearReassemblyBuffer(for peer: AX25Address, path: DigiPath = DigiPath()) {
        let key = reassemblyKey(from: peer, path: path)
        if let removed = inboundReassemblyBuffer.removeValue(forKey: key) {
            TxLog.debug(.axdp, "Cleared reassembly buffer on disconnect", [
                "peer": peer.display,
                "bufferSize": removed.count
            ])
            print("[DEBUG:REASSEMBLY] cleared on disconnect | peer=\(peer.display) size=\(removed.count)")
        }
    }
    
    /// Clear all reassembly buffers associated with a peer (any path).
    /// This is a more aggressive clear that handles cases where the path might differ.
    func clearAllReassemblyBuffers(for peer: AX25Address) {
        let peerPrefix = "\(peer.display)-"
        let keysToRemove = inboundReassemblyBuffer.keys.filter { $0.hasPrefix(peerPrefix) }
        for key in keysToRemove {
            if let removed = inboundReassemblyBuffer.removeValue(forKey: key) {
                TxLog.debug(.axdp, "Cleared reassembly buffer (all paths)", [
                    "key": key,
                    "bufferSize": removed.count
                ])
                print("[DEBUG:REASSEMBLY] cleared all paths | key=\(key) size=\(removed.count)")
            }
        }
    }

    /// Extract one complete AXDP message from buffer. Returns (message, consumedBytes) or nil if incomplete.
    /// When decode succeeds, only the bytes actually consumed by the decoded message are returned.
    private func extractOneAXDPMessage(from buffer: Data) -> (AXDP.Message, Int)? {
        guard AXDP.hasMagic(buffer) else {
            print("[DEBUG:REASSEMBLY:EXTRACT] nil | bufLen=\(buffer.count) reason=noMagic")
            return nil
        }
        guard let (message, consumedBytes) = AXDP.Message.decode(from: buffer) else {
            print("[DEBUG:REASSEMBLY:EXTRACT] nil | bufLen=\(buffer.count) reason=decodeFailed")
            return nil
        }
        print("[DEBUG:REASSEMBLY:EXTRACT] ok | bufLen=\(buffer.count) consumed=\(consumedBytes) type=\(message.type) payloadLen=\(message.payload?.count ?? 0)")
        return (message, consumedBytes)
    }

    private func magicOffset(in data: Data) -> Int? {
        guard !data.isEmpty else { return nil }
        guard let range = data.range(of: AXDP.magic) else { return nil }
        return data.distance(from: data.startIndex, to: range.lowerBound)
    }

    private func asciiPreview(_ data: Data, maxLen: Int) -> String {
        let prefix = data.prefix(maxLen)
        var out = ""
        out.reserveCapacity(prefix.count)
        for byte in prefix {
            if byte >= 0x20 && byte <= 0x7E {
                out.append(Character(UnicodeScalar(UInt32(byte))!))
            } else {
                out.append(".")
            }
        }
        return out
    }

    #if DEBUG
    /// Test-only: force a reassembly buffer for a peer/path.
    func testInjectReassemblyBuffer(for peer: AX25Address, path: DigiPath = DigiPath(), data: Data) {
        let key = reassemblyKey(from: peer, path: path)
        inboundReassemblyBuffer[key] = data
    }
    #endif

    /// Handle a fully decoded AXDP message (used after reassembly or single-frame).
    private func handleAXDPMessageDecoded(from: AX25Address, path: DigiPath, message: AXDP.Message) {
        debugAXDP("RX", [
            "type": String(describing: message.type),
            "from": from.display,
            "path": path.display,
            "sessionId": message.sessionId,
            "messageId": message.messageId,
            "len": message.payload?.count ?? 0
        ])
        
        // Any successfully decoded AXDP message proves the sender supports AXDP
        markImplicitlyConfirmedAXDP(for: from.display)

        switch message.type {
        case .ping, .pong:
            handleCapabilityMessage(message, from: from, path: path)

        case .fileMeta:
            handleFileMetaMessage(message, from: from, path: path)

        case .fileChunk:
            handleFileChunkMessage(message, from: from)

        case .ack:
            handleAckMessage(message, from: from, path: path)

        case .nack:
            handleNackMessage(message, from: from, path: path)

        case .chat:
            handleChatMessage(message, from: from)

        case .peerAxdpEnabled:
            handlePeerAxdpEnabled(from: from)

        case .peerAxdpDisabled:
            handlePeerAxdpDisabled(from: from)

        @unknown default:
            TxLog.debug(.axdp, "Unhandled AXDP message type", [
                "type": String(describing: message.type),
                "from": from.display
            ])
        }
    }

    /// Handle all AXDP messages from incoming packets (UI frames or single I-frame).
    /// Routes to appropriate handlers based on message type.
    private func handleAXDPMessage(from: AX25Address, path: DigiPath, payload: Data) {
        guard AXDP.hasMagic(payload) else { return }
        guard let (message, _) = AXDP.Message.decode(from: payload) else { return }
        handleAXDPMessageDecoded(from: from, path: path, message: message)
    }

    /// Handle peerAxdpEnabled: peer turned on their AXDP toggle; notify UI to show toast.
    private func handlePeerAxdpEnabled(from: AX25Address) {
        TxLog.debug(.axdp, "Peer enabled AXDP", ["from": from.display])
        onPeerAxdpEnabled?(from)
    }

    /// Handle peerAxdpDisabled: peer turned off their AXDP toggle; notify UI.
    private func handlePeerAxdpDisabled(from: AX25Address) {
        TxLog.debug(.axdp, "Peer disabled AXDP", ["from": from.display])
        onPeerAxdpDisabled?(from)
    }

    /// Handle AXDP chat message: decode payload and deliver to terminal transcript.
    /// Per spec: receivers MUST display AXDP chat regardless of local AXDP badge state.
    private func handleChatMessage(_ message: AXDP.Message, from: AX25Address) {
        guard let payload = message.payload, !payload.isEmpty else { return }
        guard let text = String(data: payload, encoding: .utf8), !text.isEmpty else { return }
        let dedupeKey = "\(from.display)-\(message.messageId)-\(message.sessionId)"
        guard !displayedChatMessageIds.contains(dedupeKey) else {
            TxLog.debug(.axdp, "Skipping duplicate chat message", ["from": from.display, "messageId": message.messageId])
            return
        }
        displayedChatMessageIds.insert(dedupeKey)
        if displayedChatMessageIds.count > 2000 { displayedChatMessageIds.removeAll() }
        onAXDPChatReceived?(from, text)
    }

    /// Handle PING/PONG capability messages
    /// This method is internal to allow testing
    func handleCapabilityMessage(_ message: AXDP.Message, from: AX25Address, path: DigiPath) {
        guard let caps = message.capabilities else { return }

        let peerCallsign = from.display.uppercased()
        clearAXDPNotSupported(for: peerCallsign)

        // Receiving a valid PING/PONG proves the peer supports AXDP
        markImplicitlyConfirmedAXDP(for: peerCallsign)

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

            // Bidirectional exchange: if this PONG was in response to our text probe,
            // the peer now has our PONG but not our capabilities.  Send our PING
            // (with capability TLVs) via UI frame so the peer learns our features too.
            if awaitingCapabilityExchange.remove(peerCallsign) != nil {
                sendCapabilityPingViaUI(to: from, path: path)
            }
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

    // MARK: - AXDP Send Helper

    /// Send AXDP payload via connected session if available, otherwise as UI.
    /// Returns true if frames were actually sent, false if window was full or packetEngine not set.
    private func sendAXDPPayload(_ payload: Data, to destination: AX25Address, path: DigiPath, displayInfo: String?) -> Bool {
        // Guard: don't send if packetEngine is not set (e.g., in tests)
        // CRITICAL: This prevents any frame creation or memory allocation when packetEngine is nil
        guard packetEngine != nil else {
            TxLog.debug(.axdp, "Skipping sendAXDPPayload - packetEngine not set", [
                "destination": destination.display,
                "payloadSize": payload.count
            ])
            return false
        }
        
        // Check for connected session first (more efficient path)
        if sessionManager.connectedSession(withPeer: destination) != nil {
            let frames = sessionManager.sendData(
                payload,
                to: destination,
                path: path,
                pid: 0xF0,
                displayInfo: displayInfo
            )
            // If window is full, sendData returns empty array - don't send anything
            guard !frames.isEmpty else {
                TxLog.debug(.axdp, "Window full, cannot send AXDP payload", [
                    "destination": destination.display,
                    "payloadSize": payload.count
                ])
                return false
            }
            for frame in frames {
                sendFrame(frame)
            }
            return true
        }

        let frame = OutboundFrame(
            destination: destination,
            source: sessionManager.localCallsign,
            path: path,
            payload: payload,
            frameType: "ui",
            displayInfo: displayInfo
        )
        sendFrame(frame)
        return true
    }

    // MARK: - AXDP Not Supported Cache

    private func isAXDPNotSupported(for callsign: String) -> Bool {
        guard let markedAt = axdpNotSupported[callsign.uppercased()] else { return false }
        if Date().timeIntervalSince(markedAt) > axdpNotSupportedTTL {
            axdpNotSupported.removeValue(forKey: callsign.uppercased())
            return false
        }
        return true
    }

    private func markAXDPNotSupported(for callsign: String) {
        axdpNotSupported[callsign.uppercased()] = Date()
        TxLog.debug(.capability, "Marked AXDP not supported", ["peer": callsign])
    }

    private func clearAXDPNotSupported(for callsign: String) {
        axdpNotSupported.removeValue(forKey: callsign.uppercased())
    }

    private func scheduleCapabilityTimeout(for callsign: String) {
        let call = callsign.uppercased()
        Task { @MainActor in
            let nanos = UInt64(capabilityDiscoveryTimeout * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard let sentAt = pendingCapabilityDiscovery[call] else { return }
            if Date().timeIntervalSince(sentAt) >= capabilityDiscoveryTimeout {
                pendingCapabilityDiscovery.removeValue(forKey: call)
                markAXDPNotSupported(for: call)
            }
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

        // Check if whole-file compression was used
        let compressionAlgorithm = message.compression

        TxLog.inbound(.axdp, "Received FILE_META", [
            "from": from.display,
            "file": fileMeta.filename,
            "size": fileMeta.fileSize,
            "chunks": message.totalChunks ?? 0,
            "session": axdpSessionId,
            "compression": compressionAlgorithm == .none ? "none" : compressionAlgorithm.displayName
        ])

        // Create inbound transfer state with compression info
        let expectedChunks = Int(message.totalChunks ?? 1)
        let state = InboundTransferState(
            axdpSessionId: axdpSessionId,
            sourceCallsign: from.display,
            fileName: fileMeta.filename,
            fileSize: Int(fileMeta.fileSize),
            expectedChunks: expectedChunks,
            chunkSize: Int(fileMeta.chunkSize),
            sha256: fileMeta.sha256,
            compressionAlgorithm: compressionAlgorithm  // Store for decompression after reassembly
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
        // For inbound transfers with compression, set transmission size based on expected chunks
        // This is the compressed data size we'll actually receive
        let estimatedTransmissionSize = expectedChunks * Int(fileMeta.chunkSize)
        transfer.setTransmissionSize(estimatedTransmissionSize)

        // Store compression metrics if compression was used
        if compressionAlgorithm != .none {
            transfer.setCompressionMetrics(
                algorithm: compressionAlgorithm,
                originalSize: Int(fileMeta.fileSize),
                compressedSize: estimatedTransmissionSize
            )
        }

        transfer.status = .pending
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

        // Per-chunk CRC32 verification (spec 6.x.4): reject corrupt chunks so they stay in "missing" set for NACK
        if let expectedCRC = message.payloadCRC32 {
            let computedCRC = AXDP.crc32(payload)
            guard computedCRC == expectedCRC else {
                TxLog.warning(.axdp, "FILE_CHUNK payload CRC mismatch, requesting retransmit", [
                    "session": axdpSessionId,
                    "chunk": chunkIndex,
                    "expectedCRC": String(format: "%08X", expectedCRC),
                    "computedCRC": String(format: "%08X", computedCRC)
                ])
                return  // Do not count as received; sender will retransmit on NACK
            }
        }

        // Receive the chunk
        state.receiveChunk(index: chunkIndex, data: payload)
        inboundTransferStates[axdpSessionId] = state

        // CRITICAL: Check completion BEFORE UI updates to ensure we detect it even if
        // the transfer lookup fails or the transfer is in an unexpected state.
        // The completion ACK must be sent as soon as all chunks are received.
        let isNowComplete = state.isComplete

        // Update BulkTransfer progress for UI - use explicit reassignment for SwiftUI
        if let transferId = axdpToTransferId[axdpSessionId],
           let transferIndex = transfers.firstIndex(where: { $0.id == transferId }) {
            var transfer = transfers[transferIndex]

            // Guard against processing chunks for already-completed/failed transfers
            // BUT: if this is the completion chunk, we still need to send the ACK
            // even if the transfer was already marked complete (race condition)
            switch transfer.status {
            case .completed, .failed, .cancelled:
                TxLog.debug(.axdp, "Ignoring chunk for terminated transfer", [
                    "session": axdpSessionId,
                    "chunk": chunkIndex,
                    "status": String(describing: transfer.status)
                ])
                // Still check completion - might be a late chunk that completes the transfer
                if isNowComplete {
                    handleTransferComplete(axdpSessionId: axdpSessionId, state: state)
                }
                return
            default:
                break
            }

            transfer.markChunkCompleted(chunkIndex)

            // Track actual bytes received for accurate progress and throughput
            // Use state's totalBytesReceived for precise tracking
            transfer.bytesSent = state.totalBytesReceived
            transfer.bytesTransmitted = state.totalBytesReceived

            // If transfer is in pending state, move to receiving AND reset timing
            // This ensures throughput calculation starts when data actually arrives,
            // not when FILE_META was received (which could be much earlier if user took time to accept)
            if transfer.status == .pending {
                transfer.status = .sending  // Use .sending for "receiving" state
            }

            if transfer.dataPhaseStartedAt == nil, let start = state.startTime {
                transfer.dataPhaseStartedAt = start
                transfer.startedAt = start
            }

            if isNowComplete, transfer.dataPhaseCompletedAt == nil {
                transfer.dataPhaseCompletedAt = state.endTime ?? Date()
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
                "progress": String(format: "%.0f%%", state.progress * 100),
                "receivedCount": state.receivedChunks.count,
                "expectedChunks": state.expectedChunks,
                "isComplete": isNowComplete
            ])
        } else {
            // Transfer ID not found - log warning but still check completion
            TxLog.warning(.axdp, "Received chunk but transfer ID not found", [
                "session": axdpSessionId,
                "chunk": chunkIndex
            ])
        }

        // Check if transfer is complete - MUST happen even if transfer lookup failed
        // The completion ACK is critical for the sender to know the transfer succeeded
        // Re-read state from dictionary to ensure we have the latest version (defense against race conditions)
        if let latestState = inboundTransferStates[axdpSessionId], latestState.isComplete {
            TxLog.debug(.axdp, "Transfer completion detected, calling handleTransferComplete", [
                "session": axdpSessionId,
                "receivedChunks": latestState.receivedChunks.count,
                "expectedChunks": latestState.expectedChunks,
                "file": latestState.fileName
            ])
            handleTransferComplete(axdpSessionId: axdpSessionId, state: latestState)
        } else if isNowComplete {
            // Fallback: use local state if dictionary lookup fails (shouldn't happen, but be defensive)
            TxLog.warning(.axdp, "Completion detected but state not in dictionary, using local state", [
                "session": axdpSessionId
            ])
            handleTransferComplete(axdpSessionId: axdpSessionId, state: state)
        }
    }

    /// Handle transfer completion - verify hash, save file, and send completion ACK/NACK to sender
    private func handleTransferComplete(axdpSessionId: UInt32, state: InboundTransferState) {
        guard let transferId = axdpToTransferId[axdpSessionId],
              let transferIndex = transfers.firstIndex(where: { $0.id == transferId }) else {
            return
        }

        // CRITICAL: Guard against duplicate completion - prevent processing if already completed or failed
        // This can happen if multiple chunks arrive rapidly and trigger completion checks
        switch transfers[transferIndex].status {
        case .completed, .failed, .cancelled:
            TxLog.debug(.axdp, "Ignoring duplicate/late transfer completion", [
                "session": axdpSessionId,
                "file": state.fileName,
                "currentStatus": String(describing: transfers[transferIndex].status)
            ])
            return
        default:
            break
        }

        // Calculate metrics
        let metrics = state.calculateMetrics()
        let processingStart = Date()
        var decompressedSize: Int?

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

        // Reassemble and decompress file (if compression was used)
        if let fileData = state.reassembleAndDecompressFile() {
            decompressedSize = fileData.count
            // Update compression metrics for UI display
            if state.compressionAlgorithm != .none {
                transfer.setCompressionMetrics(
                    algorithm: state.compressionAlgorithm,
                    originalSize: fileData.count,
                    compressedSize: state.totalBytesReceived
                )
            }

            // Verify SHA256 hash of DECOMPRESSED data
            let computedHash = computeSHA256(fileData)
            if computedHash == state.sha256 {
                TxLog.debug(.axdp, "File hash verified", [
                    "file": state.fileName,
                    "compression": state.compressionAlgorithm == .none ? "none" : state.compressionAlgorithm.displayName
                ])

                // Save file to Downloads folder
                if let savedPath = saveReceivedFile(fileName: state.fileName, data: fileData) {
                    // Success - mark as completed and store path
                    transfer.markCompleted()
                    transfer.savedFilePath = savedPath
                    transferSuccess = true

                    var logData: [String: Any] = [
                        "file": state.fileName,
                        "path": savedPath,
                        "size": fileData.count
                    ]
                    if state.compressionAlgorithm != .none {
                        logData["compression"] = state.compressionAlgorithm.displayName
                        logData["compressedSize"] = state.totalBytesReceived
                    }
                    TxLog.inbound(.axdp, "File transfer completed and saved", logData)
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
                    "computed": String(computedHash.hexEncodedString().prefix(16)),
                    "compression": state.compressionAlgorithm == .none ? "none" : state.compressionAlgorithm.displayName
                ])
                transfer.status = .failed(reason: "Hash verification failed - file corrupted during transfer")
            }
        } else {
            // Failed to reassemble/decompress file
            let reason = state.compressionAlgorithm != .none
                ? "Failed to decompress file (algorithm: \(state.compressionAlgorithm.displayName))"
                : "Failed to reassemble file from chunks"
            transfer.status = .failed(reason: reason)
        }

        let processingEnd = Date()

        // Send completion ACK or NACK to sender
        if transferSuccess {
            // Send completion ACK to tell sender the transfer is fully complete
            let dataDurationMs: UInt32
            if let start = state.startTime {
                let end = state.endTime ?? processingStart
                let duration = max(0, end.timeIntervalSince(start))
                dataDurationMs = UInt32(duration * 1000.0)
            } else {
                dataDurationMs = 0
            }

            let processingDurationMs = UInt32(max(0, processingEnd.timeIntervalSince(processingStart)) * 1000.0)
            let metricsExtension = AXDP.AXDPTransferMetrics(
                dataDurationMs: dataDurationMs,
                processingDurationMs: processingDurationMs,
                bytesReceived: UInt32(state.totalBytesReceived),
                decompressedBytes: decompressedSize.map { UInt32($0) }
            )

            let completionAck = AXDP.Message(
                type: .ack,
                sessionId: axdpSessionId,
                messageId: SessionCoordinator.transferCompleteMessageId,
                transferMetrics: globalAdaptiveSettings.axdpExtensionsEnabled ? metricsExtension : nil
            )

            _ = sendAXDPPayload(
                completionAck.encode(),
                to: sourceAddress,
                path: path,
                displayInfo: "AXDP ACK (transfer complete)"
            )

            TxLog.outbound(.axdp, "Sent transfer completion ACK to sender", [
                "dest": state.sourceCallsign,
                "file": state.fileName,
                "axdpSession": axdpSessionId,
                "dataDurationMs": dataDurationMs,
                "processingDurationMs": processingDurationMs
            ])
        } else {
            // Send completion NACK to tell sender the transfer failed on receiver side
            let completionNack = AXDP.Message(
                type: .nack,
                sessionId: axdpSessionId,
                messageId: SessionCoordinator.transferCompleteMessageId
            )

            _ = sendAXDPPayload(
                completionNack.encode(),
                to: sourceAddress,
                path: path,
                displayInfo: "AXDP NACK (transfer failed)"
            )

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
        let safeFileName = sanitizedReceivedFileName(fileName)

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

        var targetURL = downloadsURL.appendingPathComponent(safeFileName)

        // Handle filename conflicts - append (1), (2), etc.
        var counter = 1
        let baseName = (safeFileName as NSString).deletingPathExtension
        let ext = (safeFileName as NSString).pathExtension
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

    /// Sanitize untrusted remote file metadata into a safe local basename.
    /// This prevents path traversal when appending to our writable transfer folder.
    private func sanitizedReceivedFileName(_ fileName: String) -> String {
        let normalizedSeparators = fileName.replacingOccurrences(of: "\\", with: "/")
        let candidate = (normalizedSeparators as NSString).lastPathComponent
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty || trimmed == "." || trimmed == ".." {
            return "received-file"
        }

        return trimmed
    }

    /// Handle ACK message (transfer accepted, chunk acknowledged, completion request, or transfer complete)
    func handleAckMessage(_ message: AXDP.Message, from: AX25Address, path: DigiPath = DigiPath()) {
        TxLog.debug(.axdp, "Received ACK", [
            "from": from.display,
            "session": message.sessionId,
            "messageId": message.messageId
        ])

        let axdpSessionId = message.sessionId

        // Receiver: completion request from sender ("do you have all chunks?")
        if message.messageId == SessionCoordinator.completionRequestMessageId,
           let state = inboundTransferStates[axdpSessionId] {
            if state.isComplete {
                TxLog.debug(.axdp, "Completion request: transfer complete, sending completion ACK", [
                    "session": axdpSessionId,
                    "file": state.fileName
                ])
                handleTransferComplete(axdpSessionId: axdpSessionId, state: state)
            } else {
                // Send NACK with SACK bitmap (what we have) so sender can selectively retransmit missing chunks
                var sack = AXDPSACKBitmap(baseChunk: 0, windowSize: state.expectedChunks)
                for chunk in state.receivedChunks {
                    sack.markReceived(chunk: UInt32(chunk))
                }
                let nackMessage = AXDP.Message(
                    type: .nack,
                    sessionId: axdpSessionId,
                    messageId: SessionCoordinator.transferCompleteMessageId,
                    sackBitmap: sack.encode()
                )
                _ = sendAXDPPayload(
                    nackMessage.encode(),
                    to: from,
                    path: path,
                    displayInfo: "AXDP NACK (missing chunks)"
                )
                TxLog.outbound(.axdp, "Sent NACK with SACK bitmap (missing chunks)", [
                    "dest": from.display,
                    "session": axdpSessionId,
                    "receivedCount": state.receivedChunks.count,
                    "expectedChunks": state.expectedChunks,
                    "file": state.fileName
                ])
            }
            return
        }

        // Check if this is a transfer completion ACK from receiver
        if message.messageId == SessionCoordinator.transferCompleteMessageId {
            // Find the transfer awaiting completion
            if let transferId = transferSessionIds.first(where: { $0.value == axdpSessionId })?.key,
               let transferIndex = transfers.firstIndex(where: { $0.id == transferId }) {

                // Log if the transfer was not already in awaitingCompletion (race/mismatch),
                // but still honor the ACK as authoritative.
                if transfers[transferIndex].status != .awaitingCompletion {
                    TxLog.warning(.axdp, "Completion ACK received while transfer not in awaitingCompletion state", [
                        "transfer": String(transferId.uuidString.prefix(8)),
                        "status": String(describing: transfers[transferIndex].status)
                    ])
                }

                // Mark transfer as truly completed
                var transfer = transfers[transferIndex]
                transfer.markCompleted()
                if let metrics = message.transferMetrics {
                    transfer.remoteTransferMetrics = metrics
                }

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

    /// Handle NACK message (transfer declined, missing chunks, or transfer failed on receiver)
    func handleNackMessage(_ message: AXDP.Message, from: AX25Address, path: DigiPath = DigiPath()) {
        TxLog.debug(.axdp, "Received NACK", [
            "from": from.display,
            "session": message.sessionId,
            "messageId": message.messageId,
            "hasSackBitmap": message.sackBitmap != nil
        ])

        let axdpSessionId = message.sessionId

        // Completion NACK with SACK bitmap = receiver reports missing/corrupt chunks.
        // Behavior:
        //  - NEVER mark the transfer as failed here
        //  - Attempt selective retransmit of missing chunks when we have file data
        //  - Always return early to prevent falling through to failure-handling code below.
        if message.messageId == SessionCoordinator.transferCompleteMessageId, message.sackBitmap != nil {
            #if DEBUG
            if SessionCoordinator.disableCompletionNackSackRetransmitForTests {
                TxLog.debug(.axdp, "Completion NACK with SACK bitmap (retransmit disabled for tests)", [
                    "session": axdpSessionId
                ])
                // Always return early - completion NACK with SACK never marks transfer as failed
                return
            }
            #endif

            // Attempt selective retransmit only when we can safely do so.
            if let transferId = transferSessionIds.first(where: { $0.value == axdpSessionId })?.key,
               let fileData = transferFileData[transferId],
               let sackData = message.sackBitmap,
               let transferIndex = transfers.firstIndex(where: { $0.id == transferId }),
               transfers[transferIndex].status == .awaitingCompletion {

                let transfer = transfers[transferIndex]
                let actualTotalChunks = (fileData.count + transfer.chunkSize - 1) / transfer.chunkSize

                if let sack = AXDPSACKBitmap.decode(from: sackData, baseChunk: 0, windowSize: actualTotalChunks) {
                    let missing = sack.missingChunks(upTo: UInt32(actualTotalChunks - 1))

                    if !missing.isEmpty {
                        let destParts = transfer.destination.uppercased().split(separator: "-")
                        let destCall = String(destParts.first ?? "")
                        let destSSID = destParts.count > 1 ? Int(destParts[1]) ?? 0 : 0
                        let destAddress = AX25Address(call: destCall, ssid: destSSID)

                        for chunkIndex in missing.map({ Int($0) }) {
                            guard let chunkData = transfer.chunkData(from: fileData, chunk: chunkIndex) else { continue }
                            let chunkMessage = AXDP.Message(
                                type: .fileChunk,
                                sessionId: axdpSessionId,
                                messageId: UInt32(chunkIndex + 1),
                                chunkIndex: UInt32(chunkIndex),
                                totalChunks: UInt32(actualTotalChunks),
                                payload: chunkData,
                                payloadCRC32: AXDP.crc32(chunkData),
                                compression: .none
                            )
                            // This internally guards on packetEngine being set.
                            _ = sendAXDPPayload(
                                chunkMessage.encode(),
                                to: destAddress,
                                path: path,
                                displayInfo: "AXDP CHUNK \(chunkIndex + 1)/\(actualTotalChunks) (retransmit)"
                            )
                        }

                        TxLog.outbound(.axdp, "Selective retransmit for missing/corrupt chunks", [
                            "file": transfer.fileName,
                            "session": axdpSessionId,
                            "missingCount": missing.count,
                            "chunks": missing.map { Int($0) }.sorted()
                        ])
                    }
                } else {
                    TxLog.warning(.axdp, "NACK SACK bitmap decode failed", ["session": axdpSessionId])
                }
            } else {
                // Completion NACK with SACK but no matching transfer/file data - log and return.
                // This can happen if the transfer was already completed/cancelled or session ID is unknown.
                TxLog.debug(.axdp, "Completion NACK with SACK bitmap but no matching transfer/file data", [
                    "session": axdpSessionId
                ])
            }

            // Always return early - completion NACK with SACK never marks transfer as failed.
            return
        }

        // Check if this is a transfer completion NACK (receiver failed to save file - no SACK bitmap)
        if message.messageId == SessionCoordinator.transferCompleteMessageId, message.sackBitmap == nil {
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
        // Never treat completion NACK (messageId == transferCompleteMessageId) as generic "declined"
        if message.messageId != SessionCoordinator.transferCompleteMessageId,
           let transferId = transferSessionIds.first(where: { $0.value == message.sessionId })?.key,
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
            if let response = sessionManager.handleInboundRR(from: from, path: path, channel: channel, nr: nr, isPoll: isPoll) {
                sendFrame(response)
            }
        case .REJ:
            let retransmits = sessionManager.handleInboundREJ(from: from, path: path, channel: channel, nr: nr)
            for frame in retransmits {
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

        // Manual discovery overrides "not supported" cache
        clearAXDPNotSupported(for: destAddress.display)

        // Build AXDP PING message with our capabilities
        let localCaps = AXDPCapability.defaultLocal()
        let pingMessage = AXDP.Message(
            type: .ping,
            sessionId: UInt32.random(in: 0...UInt32.max),
            messageId: 1,
            capabilities: localCaps
        )

        // Track that we're waiting for a response
        pendingCapabilityDiscovery[destAddress.display.uppercased()] = Date()
        scheduleCapabilityTimeout(for: destAddress.display)

        // Manual discovery: prefer connected session, but do not force connection
        _ = sendAXDPPayload(
            pingMessage.encode(),
            to: destAddress,
            path: path,
            displayInfo: "AXDP PING"
        )

        TxLog.outbound(.capability, "Sent AXDP PING", [
            "dest": destination,
            "features": localCaps.features.description
        ])
    }

    // MARK: - Capability Status

    /// Check if a station has confirmed AXDP capability
    /// Returns true if:
    /// 1. The capability store has confirmed capabilities (via PING/PONG exchange), OR
    /// 2. The peer has been implicitly confirmed by sending us any AXDP message
    func hasConfirmedAXDPCapability(for callsign: String) -> Bool {
        let call = callsign.uppercased()
        // Check capability store first (from explicit PING/PONG)
        if packetEngine?.capabilityStore.hasCapabilities(for: callsign) == true {
            return true
        }
        // Check implicit confirmation (received any AXDP message from peer)
        return implicitlyConfirmedAXDP.contains(call)
    }
    
    /// Mark a peer as implicitly AXDP-capable because we received an AXDP message from them.
    /// This is called whenever we successfully parse any AXDP message from a peer.
    func markImplicitlyConfirmedAXDP(for callsign: String) {
        let call = callsign.uppercased()
        if !implicitlyConfirmedAXDP.contains(call) {
            implicitlyConfirmedAXDP.insert(call)
            clearAXDPNotSupported(for: call)
            TxLog.debug(.capability, "Implicitly confirmed AXDP capability", [
                "peer": callsign,
                "reason": "Received AXDP message from peer"
            ])
        }
    }
    
    #if DEBUG
    /// Test helper to check implicit confirmation status
    func isImplicitlyConfirmedAXDP(for callsign: String) -> Bool {
        return implicitlyConfirmedAXDP.contains(callsign.uppercased())
    }
    
    /// Test helper to clear all implicit confirmations
    func clearAllImplicitConfirmations() {
        implicitlyConfirmedAXDP.removeAll()
    }

    /// Test helper to run incoming filename sanitization logic.
    func sanitizeIncomingFileNameForTests(_ fileName: String) -> String {
        sanitizedReceivedFileName(fileName)
    }
    
    /// Test helper to simulate receiving an AXDP message (goes through full routing logic).
    /// This is the correct way to test AXDP message handling as it triggers implicit capability confirmation.
    func testHandleAXDPMessage(_ message: AXDP.Message, from: AX25Address, path: DigiPath = DigiPath()) {
        handleAXDPMessageDecoded(from: from, path: path, message: message)
    }
    #endif

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

        if isAXDPNotSupported(for: call) {
            return .notSupported
        }

        if hasConfirmedAXDPCapability(for: call) {
            return .confirmed
        }

        if let sentAt = pendingCapabilityDiscovery[call] {
            let elapsed = Date().timeIntervalSince(sentAt)
            if elapsed < capabilityDiscoveryTimeout {
                return .pending
            } else {
                pendingCapabilityDiscovery.removeValue(forKey: call)
                markAXDPNotSupported(for: call)
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
                return "Cannot send file: \(destination) does not support AXDP. Try a legacy protocol (YAPP)."

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

    // MARK: - Whole-File Compression

    /// Apply whole-file compression before chunking.
    /// This is much more effective than per-chunk compression because larger data compresses better.
    /// - Parameters:
    ///   - originalData: The original uncompressed file data
    ///   - transfer: The transfer to update with compression metrics (inout)
    ///   - compressionSettings: Per-transfer compression settings
    /// - Returns: Tuple of (data to send, compression algorithm used)
    private func applyWholeFileCompression(
        originalData: Data,
        transfer: inout BulkTransfer,
        compressionSettings: TransferCompressionSettings
    ) -> (Data, AXDPCompression.Algorithm) {

        // Determine if compression should be attempted
        let shouldCompress: Bool
        let algorithmToUse: AXDPCompression.Algorithm

        // Check per-transfer override first
        if let enabledOverride = compressionSettings.enabledOverride {
            shouldCompress = enabledOverride
            algorithmToUse = compressionSettings.algorithmOverride ?? globalAdaptiveSettings.compressionAlgorithm
        } else {
            // Use global settings
            shouldCompress = globalAdaptiveSettings.compressionEnabled
            algorithmToUse = globalAdaptiveSettings.compressionAlgorithm
        }

        // Skip compression if disabled or algorithm is none
        guard shouldCompress && algorithmToUse != .none else {
            TxLog.debug(.compression, "Compression disabled", [
                "file": transfer.fileName,
                "size": originalData.count
            ])
            transfer.setCompressionMetrics(algorithm: nil, originalSize: originalData.count, compressedSize: originalData.count)
            return (originalData, .none)
        }

        // Check compressibility analysis - skip if file is already compressed
        if let analysis = transfer.compressibilityAnalysis, !analysis.isCompressible {
            TxLog.debug(.compression, "Skipping compression (not compressible)", [
                "file": transfer.fileName,
                "reason": analysis.reason,
                "category": analysis.fileCategory.rawValue
            ])
            transfer.setCompressionMetrics(algorithm: nil, originalSize: originalData.count, compressedSize: originalData.count)
            return (originalData, .none)
        }

        // Attempt whole-file compression
        TxLog.debug(.compression, "Compressing whole file", [
            "file": transfer.fileName,
            "algorithm": String(describing: algorithmToUse),
            "originalSize": originalData.count
        ])

        guard let compressedData = AXDPCompression.compress(originalData, algorithm: algorithmToUse) else {
            // Compression didn't help (returned nil means no benefit)
            TxLog.debug(.compression, "Whole-file compression skipped (no benefit)", [
                "file": transfer.fileName,
                "algorithm": String(describing: algorithmToUse),
                "size": originalData.count
            ])
            transfer.setCompressionMetrics(algorithm: algorithmToUse, originalSize: originalData.count, compressedSize: originalData.count)
            return (originalData, .none)
        }

        // Compression was beneficial
        let savingsPercent = Double(originalData.count - compressedData.count) / Double(originalData.count) * 100
        TxLog.outbound(.compression, "Whole-file compression successful", [
            "file": transfer.fileName,
            "algorithm": String(describing: algorithmToUse),
            "original": originalData.count,
            "compressed": compressedData.count,
            "savings": String(format: "%.1f%%", savingsPercent)
        ])

        transfer.setCompressionMetrics(
            algorithm: algorithmToUse,
            originalSize: originalData.count,
            compressedSize: compressedData.count
        )

        return (compressedData, algorithmToUse)
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

        guard let originalFileData = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            TxLog.error(.session, "Failed to read file for transfer", error: nil, [
                "file": fileURL.lastPathComponent
            ])
            return "Failed to read file"
        }

        var transfer = BulkTransfer(
            id: UUID(),
            fileName: fileURL.lastPathComponent,
            fileSize: originalFileData.count,
            destination: destination,
            direction: .outbound,
            transferProtocol: transferProtocol,
            compressionSettings: compressionSettings
        )

        // Analyze compressibility
        transfer.analyzeCompressibility(originalFileData)

        // Log compressibility result
        if let analysis = transfer.compressibilityAnalysis {
            TxLog.debug(.session, "File compressibility analyzed", [
                "file": fileURL.lastPathComponent,
                "category": analysis.fileCategory.rawValue,
                "compressible": analysis.isCompressible ? "yes" : "no",
                "reason": analysis.reason
            ])
        }

        // WHOLE-FILE COMPRESSION: Compress the entire file before chunking
        // This is much more effective than per-chunk compression because:
        // 1. Larger data compresses better (more context for compression dictionaries)
        // 2. Small chunks (128 bytes) often expand when compressed
        let (dataToSend, compressionAlgorithmUsed) = applyWholeFileCompression(
            originalData: originalFileData,
            transfer: &transfer,
            compressionSettings: compressionSettings
        )

        // Update transmission size to reflect actual data being sent (compressed or original)
        // This ensures progress tracking is accurate for compressed transfers
        transfer.setTransmissionSize(dataToSend.count)

        // Set status to awaiting acceptance - we'll only send chunks after receiver accepts
        transfer.status = .awaitingAcceptance
        transfers.append(transfer)

        // Store the (possibly compressed) data for chunking
        let transferId = transfer.id
        transferFileData[transferId] = dataToSend

        // Store compression algorithm used for this transfer (needed for FILE_META)
        transferCompressionAlgorithms[transferId] = compressionAlgorithmUsed

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

        // Compute SHA256 hash of ORIGINAL data (receiver will decompress and verify)
        let fileHash = computeSHA256(originalFileData)

        // Calculate total chunks based on the data we'll actually send (compressed or original)
        let actualDataSize = dataToSend.count
        let actualTotalChunks = (actualDataSize + transfer.chunkSize - 1) / transfer.chunkSize

        // Send FILE_META message first
        // FILE_META contains ORIGINAL file size (for receiver's progress display and decompression)
        let fileMeta = AXDPFileMeta(
            filename: transfer.fileName,
            fileSize: UInt64(originalFileData.count),  // Original size - receiver needs this for decompression
            sha256: fileHash,
            chunkSize: UInt16(transfer.chunkSize)
        )

        // Build FILE_META message, include compression algorithm if used
        let metaMessage = AXDP.Message(
            type: .fileMeta,
            sessionId: axdpSessionId,
            messageId: 0,
            totalChunks: UInt32(actualTotalChunks),  // Chunks of (possibly compressed) data
            compression: compressionAlgorithmUsed,  // Tell receiver which algorithm to use for decompression
            fileMeta: fileMeta
        )

        _ = sendAXDPPayload(
            metaMessage.encode(),
            to: destAddress,
            path: path,
            displayInfo: "AXDP FILE_META: \(transfer.fileName)" + (compressionAlgorithmUsed != .none ? " (\(compressionAlgorithmUsed.displayName))" : "")
        )

        // Log with compression details
        var logData: [String: Any] = [
            "file": transfer.fileName,
            "originalSize": originalFileData.count,
            "chunks": actualTotalChunks,
            "axdpSession": axdpSessionId
        ]
        if compressionAlgorithmUsed != .none {
            logData["compression"] = compressionAlgorithmUsed.displayName
            logData["compressedSize"] = actualDataSize
            logData["savings"] = String(format: "%.1f%%", transfer.compressionMetrics?.savingsPercent ?? 0)
        }
        TxLog.outbound(.session, "Sent FILE_META, waiting for acceptance", logData)

        // Do NOT send chunks yet - wait for ACK from receiver
        // Chunks will be sent in handleAckMessage when acceptance is received

        return nil  // Success
    }

    /// Sentinel message ID used for transfer completion ACK/NACK
    /// Using 0xFFFFFFFF as it's unlikely to be a legitimate chunk message ID
    static let transferCompleteMessageId: UInt32 = 0xFFFFFFFF

    /// Message ID for completion request: sender asks receiver "do you have all chunks?"
    /// Receiver responds with completion ACK (all good) or NACK with SACK bitmap (missing/corrupt chunks)
    static let completionRequestMessageId: UInt32 = 0xFFFFFFFE

    /// Interval between completion-request sends while awaiting completion (seconds)
    private static let completionRequestIntervalSeconds: UInt64 = 2

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
            startAwaitingCompletionRequestTaskIfNeeded()
            return
        }

        // Get chunk data from the (possibly pre-compressed) file data
        guard let chunkData = transfers[transferIndex].chunkData(from: fileData, chunk: nextChunk) else { return }

        // Calculate actual total chunks based on stored data size (may differ from transfer.totalChunks
        // if the transfer was created with original size but we're sending compressed data)
        let actualTotalChunks = (fileData.count + transfers[transferIndex].chunkSize - 1) / transfers[transferIndex].chunkSize

        // IMPORTANT: Do NOT apply per-chunk compression here.
        // If compression is enabled, the ENTIRE file was already compressed in startTransfer().
        // Sending chunks with compression: .none because:
        // 1. Data is already compressed at file level (much more effective)
        // 2. Small chunks don't compress well and often expand
        // 3. FILE_META already told receiver which algorithm to use for whole-file decompression
        // Per-chunk CRC32 (PayloadCRC32) per spec 6.x.4: receiver can verify and request retransmit on corruption
        let chunkMessage = AXDP.Message(
            type: .fileChunk,
            sessionId: axdpSessionId,
            messageId: UInt32(nextChunk + 1),  // 1-indexed message IDs
            chunkIndex: UInt32(nextChunk),
            totalChunks: UInt32(actualTotalChunks),
            payload: chunkData,
            payloadCRC32: AXDP.crc32(chunkData),
            compression: .none  // No per-chunk compression - file is pre-compressed
        )

        let chunkPayload = chunkMessage.encode()

        // Start data-phase timing on first chunk sent
        if transfers[transferIndex].dataPhaseStartedAt == nil {
            let now = Date()
            transfers[transferIndex].dataPhaseStartedAt = now
            transfers[transferIndex].startedAt = now
        }

        let frameSent = sendAXDPPayload(
            chunkPayload,
            to: destination,
            path: path,
            displayInfo: "AXDP CHUNK \(nextChunk + 1)/\(transfers[transferIndex].totalChunks)"
        )

        // Only mark chunk as sent if frames were actually sent (window wasn't full)
        guard frameSent else {
            // Window is full - mark chunk as needing retry and wait a bit longer before retrying
            var transfer = transfers[transferIndex]
            transfer.markChunkNeedsRetry(nextChunk)
            transfers[transferIndex] = transfer
            
            // Wait longer before retrying (200ms) to give window time to open
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms delay
                sendNextChunk(for: transferId, to: destination, path: path, axdpSessionId: axdpSessionId)
            }
            return
        }

        // Mark chunk as sent and update progress - use explicit reassignment for SwiftUI
        var transfer = transfers[transferIndex]
        transfer.markChunkSent(nextChunk)
        // NOTE: Don't mark as completed here - wait for ACK from receiver
        // transfer.markChunkCompleted(nextChunk)  // REMOVED - only mark completed on ACK
        // Update bytesTransmitted for air rate calculation (actual bytes sent over air)
        transfer.bytesTransmitted += chunkData.count
        if nextChunk == actualTotalChunks - 1, transfer.dataPhaseCompletedAt == nil {
            transfer.dataPhaseCompletedAt = Date()
        }
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

    /// Start the background task that periodically sends completion-request (ACK 0xFFFFFFFE) for transfers awaiting completion.
    /// Receiver responds with completion ACK or NACK with SACK bitmap; sender then selectively retransmits only missing chunks.
    private func startAwaitingCompletionRequestTaskIfNeeded() {
        guard awaitingCompletionRequestTask == nil || awaitingCompletionRequestTask?.isCancelled == true else { return }
        awaitingCompletionRequestTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.completionRequestIntervalSeconds * 1_000_000_000)
                guard !Task.isCancelled else { break }
                sendCompletionRequestForAwaitingCompletionTransfers()
            }
        }
    }

    /// For each transfer in .awaitingCompletion, send completion request (ACK 0xFFFFFFFE) so receiver responds with ACK or NACK+SACK.
    private func sendCompletionRequestForAwaitingCompletionTransfers() {
        for transfer in transfers where transfer.status == .awaitingCompletion {
            guard let axdpSessionId = transferSessionIds[transfer.id] else { continue }
            let destParts = transfer.destination.uppercased().split(separator: "-")
            let destCall = String(destParts.first ?? "")
            let destSSID = destParts.count > 1 ? Int(destParts[1]) ?? 0 : 0
            let destAddress = AX25Address(call: destCall, ssid: destSSID)
            let path = sessionManager.sessions.values
                .first { $0.remoteAddress == destAddress && $0.state == .connected }?.path ?? DigiPath()
            let completionRequest = AXDP.Message(
                type: .ack,
                sessionId: axdpSessionId,
                messageId: SessionCoordinator.completionRequestMessageId
            )
            _ = sendAXDPPayload(
                completionRequest.encode(),
                to: destAddress,
                path: path,
                displayInfo: "AXDP completion request"
            )
            TxLog.debug(.axdp, "Sent completion request", [
                "file": transfer.fileName,
                "axdpSession": axdpSessionId,
                "dest": destAddress.display
            ])
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

            _ = sendAXDPPayload(
                ackMessage.encode(),
                to: sourceAddress,
                path: path,
                displayInfo: "AXDP ACK (accept transfer)"
            )

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

            _ = sendAXDPPayload(
                nackMessage.encode(),
                to: sourceAddress,
                path: path,
                displayInfo: "AXDP NACK (decline transfer)"
            )

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
    let fileSize: Int  // Original (decompressed) file size from FILE_META
    let expectedChunks: Int
    let chunkSize: Int
    let sha256: Data

    /// Compression algorithm used for whole-file compression (from FILE_META)
    /// If not .none, we need to decompress after reassembly
    let compressionAlgorithm: AXDPCompression.Algorithm

    var receivedChunks: Set<Int> = []
    var chunkData: [Int: Data] = [:]
    var totalBytesReceived: Int = 0
    var startTime: Date?
    var endTime: Date?

    init(
        axdpSessionId: UInt32,
        sourceCallsign: String,
        fileName: String,
        fileSize: Int,
        expectedChunks: Int,
        chunkSize: Int,
        sha256: Data,
        compressionAlgorithm: AXDPCompression.Algorithm = .none
    ) {
        self.axdpSessionId = axdpSessionId
        self.sourceCallsign = sourceCallsign
        self.fileName = fileName
        self.fileSize = fileSize
        self.expectedChunks = expectedChunks
        self.chunkSize = chunkSize
        self.sha256 = sha256
        self.compressionAlgorithm = compressionAlgorithm
    }

    var isComplete: Bool {
        receivedChunks.count >= expectedChunks
    }

    var progress: Double {
        guard expectedChunks > 0 else { return 0 }
        return Double(receivedChunks.count) / Double(expectedChunks)
    }

    mutating func receiveChunk(index: Int, data: Data) {
        // Don't count duplicates
        guard !receivedChunks.contains(index) else {
            #if DEBUG
            print("[AXDP TRACE][InboundState] Duplicate chunk ignored | index=\(index) receivedCount=\(receivedChunks.count) expected=\(expectedChunks)")
            #endif
            return
        }

        if startTime == nil {
            startTime = Date()
        }

        receivedChunks.insert(index)
        chunkData[index] = data
        totalBytesReceived += data.count

        // Set endTime when complete - this is used for metrics
        if isComplete {
            endTime = Date()
            #if DEBUG
            print("[AXDP TRACE][InboundState] Transfer complete detected | receivedCount=\(receivedChunks.count) expectedChunks=\(expectedChunks) file=\(fileName)")
            #endif
        }
    }

    /// Reassemble file from chunks.
    /// If compression was used, this returns the compressed data - caller must decompress.
    func reassembleFile() -> Data? {
        guard isComplete else { return nil }

        var assembled = Data()
        for i in 0..<expectedChunks {
            guard let chunk = chunkData[i] else { return nil }
            assembled.append(chunk)
        }
        return assembled
    }

    /// Reassemble and decompress file if necessary.
    /// Returns the original uncompressed file data, or nil if reassembly/decompression fails.
    func reassembleAndDecompressFile() -> Data? {
        guard let assembled = reassembleFile() else { return nil }

        // If no compression was used, return as-is
        guard compressionAlgorithm != .none else {
            return assembled
        }

        // Decompress the whole file
        // Use absoluteMaxFileTransferLen for whole-file decompression (not per-message limit)
        TxLog.debug(.compression, "Decompressing whole file", [
            "file": fileName,
            "algorithm": compressionAlgorithm.displayName,
            "compressedSize": assembled.count,
            "expectedSize": fileSize
        ])

        guard let decompressed = AXDPCompression.decompress(
            assembled,
            algorithm: compressionAlgorithm,
            originalLength: UInt32(fileSize),
            maxLength: AXDPCompression.absoluteMaxFileTransferLen
        ) else {
            TxLog.error(.compression, "Failed to decompress file", error: nil, [
                "file": fileName,
                "algorithm": compressionAlgorithm.displayName,
                "compressedSize": assembled.count,
                "expectedSize": fileSize
            ])
            return nil
        }

        let savingsPercent = Double(assembled.count) / Double(decompressed.count) * 100
        TxLog.inbound(.compression, "Whole-file decompression successful", [
            "file": fileName,
            "algorithm": compressionAlgorithm.displayName,
            "compressed": assembled.count,
            "decompressed": decompressed.count,
            "ratio": String(format: "%.1f%%", savingsPercent)
        ])

        return decompressed
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

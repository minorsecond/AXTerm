//
//  TerminalTxViewModel.swift
//  AXTerm
//
//  ViewModel for Terminal TX compose and queue management.
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 10.5
//

import Foundation

// MARK: - Connection Mode

/// Transport mode for transmission
enum TxConnectionMode: String, CaseIterable, Codable {
    case datagram = "Datagram"   // UI frames - no connection, best effort
    case connected = "Connected" // SABM/UA session with I-frames

    var description: String {
        switch self {
        case .datagram:
            return "One-way datagram (UI frame)"
        case .connected:
            return "Two-way session (SABM → I-frames)"
        }
    }

    /// Whether this mode provides delivery confirmation
    var hasAcks: Bool {
        switch self {
        case .datagram: return false
        case .connected: return true
        }
    }
}

/// ViewModel managing terminal TX state: compose input, queue, and history.
/// Note: This is a struct for testability. Wrap in ObservableObject for SwiftUI use.
struct TerminalTxViewModel {

    // MARK: - Compose State

    /// Text being composed for transmission
    var composeText: String = ""

    /// Destination callsign (e.g., "N0CALL" or "N0CALL-5")
    var destinationCall: String = ""

    /// Digipeater path (e.g., "WIDE1-1,WIDE2-1")
    var digiPath: String = ""

    /// Source callsign (typically from settings)
    var sourceCall: String = ""

    /// Connection mode (datagram vs connected)
    var connectionMode: TxConnectionMode = .connected  // Default to connected for proper packet radio behavior

    /// Whether to use AXDP encoding (vs plain text)
    /// Default true so connected sessions use AXDP when peer supports it.
    /// Toggle off for legacy/non-AXDP stations.
    var useAXDP: Bool = true

    // MARK: - Queue State

    /// Current TX queue entries
    private(set) var queueEntries: [TxQueueEntry] = []

    /// Internal scheduler for queue management
    private var scheduler = TxScheduler()

    // MARK: - History

    /// Recent destination callsigns (most recent first)
    private var destinationHistory: [String] = []

    /// Maximum history entries to keep
    private let maxHistoryEntries = 20

    // MARK: - Computed Properties

    /// Whether the current compose state is valid for sending
    /// Note: Empty destination is allowed (uses "CQ" for broadcast)
    var canSend: Bool {
        !composeText.isEmpty &&
        (destinationCall.isEmpty || isValidCallsign(destinationCall))
    }

    /// Effective destination (CQ if empty for broadcast)
    var effectiveDestination: String {
        destinationCall.isEmpty ? "CQ" : destinationCall
    }

    /// Current character count
    var characterCount: Int {
        composeText.count
    }

    /// Estimated payload size in bytes (with AXDP overhead)
    var estimatedPayloadSize: Int {
        // AXDP header (4) + TLVs overhead (~20) + text
        let textBytes = composeText.utf8.count
        return 4 + 20 + textBytes
    }

    /// Recent destinations for quick selection
    var recentDestinations: [String] {
        destinationHistory
    }

    /// Queue statistics
    var queueStats: TxQueueStatistics {
        scheduler.statistics
    }

    // MARK: - Actions

    /// Build an OutboundFrame from current compose state.
    /// Returns nil if state is invalid.
    /// Note: For connected mode, this builds a frame that the session manager
    /// will convert to proper I-frames with sequence numbers.
    func buildOutboundFrame() -> OutboundFrame? {
        guard canSend else { return nil }

        let source = parseCallsign(sourceCall.isEmpty ? "NOCALL" : sourceCall)
        let destination = parseCallsign(effectiveDestination)
        let path = parsePath(digiPath)

        // Build payload based on AXDP setting
        let payload: Data
        if useAXDP {
            // AXDP-encoded payload (for AXDP-aware peers)
            payload = buildChatPayload(text: composeText)
        } else {
            // Plain text payload (for legacy/standard peers)
            // This avoids Direwolf's APRS decoder confusion
            payload = Data(composeText.utf8)
        }

        // Frame type depends on connection mode
        // Note: For connected mode, the session manager will convert this
        // to I-frames with proper sequence numbers
        let frameType: String
        let controlByte: UInt8?

        switch connectionMode {
        case .datagram:
            frameType = "ui"
            controlByte = 0x03  // UI frame
        case .connected:
            // Mark as needing connected-mode handling
            // Session manager will convert to I-frame with N(S)/N(R)
            frameType = "i"
            controlByte = nil  // Will be set by session manager
        }

        return OutboundFrame(
            destination: destination,
            source: source,
            path: path,
            payload: payload,
            priority: .interactive,
            frameType: frameType,
            pid: 0xF0,
            controlByte: controlByte,
            displayInfo: composeText,
            isUserPayload: true
        )
    }

    /// Enqueue the current message for transmission.
    /// Returns the frame ID if successful, nil if invalid.
    @discardableResult
    mutating func enqueueCurrentMessage() -> UUID? {
        guard let frame = buildOutboundFrame() else { return nil }

        scheduler.enqueue(frame)

        // Update queue entries for UI
        if let entry = scheduler.getEntry(for: frame.id) {
            queueEntries.append(entry)
        }

        // Add to history (use effective destination for broadcast)
        addToHistory(effectiveDestination)

        // Clear compose text but keep destination
        composeText = ""

        return frame.id
    }

    /// Cancel a queued frame.
    mutating func cancelFrame(_ frameId: UUID) {
        scheduler.cancel(frameId: frameId)

        // Update local entry
        if let index = queueEntries.firstIndex(where: { $0.frame.id == frameId }) {
            queueEntries[index].state.markCancelled()
        }
    }

    /// Update frame state (called when transport reports status).
    mutating func updateFrameState(frameId: UUID, status: TxFrameStatus) {
        switch status {
        case .sent:
            scheduler.markSent(frameId: frameId)
        case .awaitingAck:
            scheduler.markAwaitingAck(frameId: frameId)
        case .acked:
            scheduler.markAcked(frameId: frameId)
        case .failed:
            scheduler.markFailed(frameId: frameId, reason: "Transmission failed")
        default:
            break
        }

        // Sync local entry
        if let index = queueEntries.firstIndex(where: { $0.frame.id == frameId }),
           let updated = scheduler.getEntry(for: frameId) {
            queueEntries[index] = updated
        }
    }

    /// Dequeue the next frame ready for transmission.
    mutating func dequeueNext() -> TxQueueEntry? {
        let now = Date().timeIntervalSince1970
        guard let entry = scheduler.dequeueNext(now: now) else { return nil }

        // Update local entry
        if let index = queueEntries.firstIndex(where: { $0.frame.id == entry.frame.id }) {
            queueEntries[index] = entry
        }

        return entry
    }

    /// Clear completed entries from queue display.
    mutating func clearCompleted() {
        queueEntries.removeAll { entry in
            switch entry.state.status {
            case .acked, .failed, .cancelled:
                return true
            default:
                return false
            }
        }

        // Also prune scheduler
        scheduler.pruneCompleted(olderThan: Date().addingTimeInterval(-3600))
    }

    // MARK: - Private Helpers

    private func isValidCallsign(_ call: String) -> Bool {
        let base = call.split(separator: "-").first.map(String.init) ?? call
        // Basic validation: 3-7 alphanumeric characters
        let validChars = CharacterSet.alphanumerics
        guard base.count >= 3 && base.count <= 7 else { return false }
        return base.unicodeScalars.allSatisfy { validChars.contains($0) }
    }

    private func parseCallsign(_ input: String) -> AX25Address {
        let parts = input.uppercased().split(separator: "-")
        let call = String(parts.first ?? "NOCALL")
        let ssid = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        return AX25Address(call: call, ssid: ssid)
    }

    private func parsePath(_ input: String) -> DigiPath {
        guard !input.isEmpty else { return DigiPath() }

        let calls = input
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return DigiPath.from(calls)
    }

    private func buildChatPayload(text: String) -> Data {
        // Create AXDP chat message
        let message = AXDP.Message(
            type: .chat,
            sessionId: 0,
            messageId: UInt32.random(in: 1...UInt32.max),
            payload: Data(text.utf8)
        )
        return message.encode()
    }

    private mutating func addToHistory(_ destination: String) {
        let normalized = destination.uppercased()

        // Remove if already in history
        destinationHistory.removeAll { $0 == normalized }

        // Add to front
        destinationHistory.insert(normalized, at: 0)

        // Trim if needed
        if destinationHistory.count > maxHistoryEntries {
            destinationHistory = Array(destinationHistory.prefix(maxHistoryEntries))
        }
    }
}

//
//  TerminalTxViewModel.swift
//  AXTerm
//
//  ViewModel for Terminal TX compose and queue management.
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 10.5
//

import Foundation

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
    var canSend: Bool {
        !composeText.isEmpty &&
        !destinationCall.isEmpty &&
        isValidCallsign(destinationCall)
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
    func buildOutboundFrame() -> OutboundFrame? {
        guard canSend else { return nil }

        let source = parseCallsign(sourceCall.isEmpty ? "NOCALL" : sourceCall)
        let destination = parseCallsign(destinationCall)
        let path = parsePath(digiPath)

        // Build AXDP chat message payload
        let payload = buildChatPayload(text: composeText)

        return OutboundFrame(
            destination: destination,
            source: source,
            path: path,
            payload: payload,
            priority: .interactive,
            frameType: "ui",
            pid: 0xF0,
            displayInfo: String(composeText.prefix(50))
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

        // Add to history
        addToHistory(destinationCall)

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

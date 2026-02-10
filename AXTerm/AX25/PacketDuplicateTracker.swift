//
//  PacketDuplicateTracker.swift
//  AXTerm
//
//  Detects packet duplicates using (src, dst, pid, ax25Ns, payloadHash).
//

import Foundation

/// Duplicate classification for packet evidence handling.
nonisolated enum PacketDuplicateStatus: Equatable {
    case unique
    /// Duplicate within ingestion de-dup window (KISS artifacts). Ignore entirely.
    case ingestionDedup
    /// Duplicate within retry window (likely retransmission). Penalize.
    case retryDuplicate
}

/// Signature used for duplicate detection.
nonisolated private struct PacketSignature: Hashable {
    let from: String
    let to: String
    let pid: UInt8?
    let ns: Int?
    let payloadHash: Int
}

/// Tracks recent packet signatures to detect duplicates and retries deterministically.
nonisolated struct PacketDuplicateTracker {
    let source: CaptureSourceType
    let ingestionDedupWindow: TimeInterval
    let retryDuplicateWindow: TimeInterval

    private var ingestionSeen: [PacketSignature: Date] = [:]
    private var retrySeen: [PacketSignature: Date] = [:]

    init(
        source: CaptureSourceType,
        ingestionDedupWindow: TimeInterval,
        retryDuplicateWindow: TimeInterval
    ) {
        self.source = source
        self.ingestionDedupWindow = ingestionDedupWindow
        self.retryDuplicateWindow = retryDuplicateWindow
    }

    mutating func status(for packet: Packet, at timestamp: Date) -> PacketDuplicateStatus {
        guard let from = packet.from?.display, let to = packet.to?.display else { return .unique }

        let decoded = packet.controlFieldDecoded
        let signature = PacketSignature(
            from: CallsignValidator.normalize(from),
            to: CallsignValidator.normalize(to),
            pid: packet.pid,
            ns: decoded.ns,
            payloadHash: packet.info.hashValue
        )

        pruneOldEntries(cutoff: timestamp.addingTimeInterval(-max(ingestionDedupWindow, retryDuplicateWindow)))

        if source == .kiss && ingestionDedupWindow > 0 {
            if let last = ingestionSeen[signature],
               timestamp.timeIntervalSince(last) <= ingestionDedupWindow {
                ingestionSeen[signature] = timestamp
                return .ingestionDedup
            }
            ingestionSeen[signature] = timestamp
        }

        // Retry detection only applies to I-frames with N(S) available.
        if decoded.frameClass == .I, decoded.ns != nil, retryDuplicateWindow > 0 {
            if let last = retrySeen[signature],
               timestamp.timeIntervalSince(last) <= retryDuplicateWindow {
                retrySeen[signature] = timestamp
                return .retryDuplicate
            }
            retrySeen[signature] = timestamp
        }

        return .unique
    }

    private mutating func pruneOldEntries(cutoff: Date) {
        ingestionSeen = ingestionSeen.filter { $0.value >= cutoff }
        retrySeen = retrySeen.filter { $0.value >= cutoff }
    }
}

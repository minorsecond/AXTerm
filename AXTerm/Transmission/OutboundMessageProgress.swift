//
//  OutboundMessageProgress.swift
//  AXTerm
//
//  Tracks send/ack progress for outbound messages so the sender can show
//  progressive highlighting (pending → sent → acked).
//

import Foundation
import SwiftUI

/// Tracks progress of an outbound message for UI highlighting
nonisolated struct OutboundMessageProgress: Identifiable, Equatable {
    let id: UUID
    let text: String
    let totalBytes: Int
    var bytesSent: Int
    var bytesAcked: Int
    let destination: String
    /// The peer whose acknowledgments advance this progress.
    ///
    /// Normally the destination itself. Through a NET/ROM circuit the two are
    /// different stations: the operator is sending to KB5YZB-7, but the frames
    /// ride the link to DRLNOD and it is DRLNOD's RRs that come back. Matching
    /// acks against the destination there matches nothing, and the indicator
    /// reads "Sending…" forever while the reply is already on screen
    /// (2026-08-26).
    let ackPeer: String
    let timestamp: Date
    /// True for AXDP/connected mode (has ACKs); false for UI/datagram (fire-and-forget)
    let hasAcks: Bool
    
    /// The V(S) sequence number when this message started transmitting.
    /// Used with modulo arithmetic to correctly calculate acknowledged chunks.
    let startingVs: Int
    
    /// Total number of I-frame chunks for this message (ceil(totalBytes/paclen))
    let totalChunks: Int
    
    /// Packet length used to fragment this message
    let paclen: Int
    
    /// The last V(A) value we processed. Used to compute deltas with modulo-8 arithmetic.
    var lastKnownVa: Int

    /// Cumulative count of chunks acknowledged (handles wraparound correctly)
    var chunksAcked: Int

    /// Digipeaters heard retransmitting this message's I-frames (H-bit set),
    /// in the order first heard. Evidence the frame cleared a hop — NOT
    /// delivery: digipeating is fire-and-forget, so only the peer's ack
    /// proves receipt. On multi-hop paths this grows hop by hop for as many
    /// digis as we can actually hear (usually the first, sometimes the
    /// second — distant hops are beyond our RF horizon by construction).
    var relayedDigis: [String] = []

    /// When the most recent digipeat echo was heard.
    var lastRelayAt: Date?

    var isComplete: Bool {
        if hasAcks {
            return bytesAcked >= totalBytes
        }
        return bytesSent >= totalBytes
    }

    /// Record a heard digipeat echo, merging newly heard digis in first-heard
    /// order without duplicates.
    mutating func recordRelay(digis: [String], at date: Date) {
        for digi in digis where !relayedDigis.contains(digi) {
            relayedDigis.append(digi)
        }
        lastRelayAt = date
    }

    /// The delivery lifecycle phase, layered like chat-message states:
    /// sent (left our TNC) → relayed (a digi retransmitted it) → delivered
    /// (the peer's N(R) covers it). For datagram sends (no acks) "relayed"
    /// is the strongest evidence that will ever exist, and "delivered" is
    /// never claimed.
    enum DeliveryPhase: Equatable {
        case queued
        case sending
        case relayed
        case partiallyAcked
        case delivered
        case sentDatagram   // fire-and-forget send finished, no ack possible
    }

    var deliveryPhase: DeliveryPhase {
        if hasAcks {
            if isComplete { return .delivered }
            if bytesAcked > 0 { return .partiallyAcked }
            if !relayedDigis.isEmpty { return .relayed }
            if bytesSent > 0 { return .sending }
            return .queued
        }
        if !relayedDigis.isEmpty { return .relayed }
        if isComplete { return .sentDatagram }
        if bytesSent > 0 { return .sending }
        return .queued
    }

    /// Byte ranges for UI highlighting: [0, bytesAcked), [bytesAcked, bytesSent), [bytesSent, totalBytes)
    var ackedEndIndex: Int { min(bytesAcked, totalBytes) }
    var sentEndIndex: Int { min(bytesSent, totalBytes) }
}

/// A message going out, as the Session history shows it (park rehearsal
/// 2026-10-08, finding 39). It used to sit in a panel floating over the
/// foot of the history, which covered the last lines and came and went with
/// each send. Like Messages: the line dimmed while it waits for the air,
/// "Sending…" under it while acknowledgments come in, then "Delivered",
/// which stays until the next line so nothing collapses under the reader.
nonisolated enum InlineSendStatus: Equatable {
    /// Not on the air yet: the line itself, dimmed.
    case waiting(text: String)
    /// On the air; the line is in the history above.
    case sending(acknowledged: Int, of: Int)
    case delivered

    /// - Parameters:
    ///   - deliveredAtLineCount: the history's line count when the last
    ///     connected send was fully acknowledged, if it was.
    ///   - lineCount: the history's line count now.
    static func make(progress: OutboundMessageProgress?, deliveredAtLineCount: Int?,
                     lineCount: Int) -> InlineSendStatus? {
        if let progress, !(progress.hasAcks && progress.isComplete) {
            if progress.bytesSent < progress.totalBytes { return .waiting(text: progress.text) }
            // A broadcast on the air has no acknowledgments to wait for.
            return progress.hasAcks ? .sending(acknowledged: progress.chunksAcked, of: progress.totalChunks) : nil
        }
        if let deliveredAtLineCount, deliveredAtLineCount == lineCount { return .delivered }
        return nil
    }
}

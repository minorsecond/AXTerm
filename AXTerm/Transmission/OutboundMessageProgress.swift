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

    /// A frame of it has gone to the radio. Until then it is waiting.
    var onAir = false
    /// Sent as one AXDP message, which the other station sees only when it
    /// has all arrived.
    var viaAXDP = false
    /// The session's counts when the message started (`apply`).
    var sentBase = 0
    var ackedBase = 0

    /// Brings the counts up to date from the session's own: bytes sent for
    /// the first time, and bytes of acknowledged frames, since the message
    /// started. Retransmissions, other traffic on the link and a paclen that
    /// changes midway leave them right, which counting frames by paclen did
    /// not (retest 2026-10-10, finding 8).
    mutating func apply(sessionBytesSent: Int, sessionBytesAcked: Int) {
        bytesSent = min(totalBytes, max(bytesSent, sessionBytesSent - sentBase))
        bytesAcked = min(totalBytes, max(bytesAcked, sessionBytesAcked - ackedBase))
    }

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
    case sending(acked: Int, total: Int, axdpPeer: String?)
    case delivered
    /// A message from the far end is arriving (`AXDPPartialMessage`).
    case receiving(from: String, amount: String)
    /// A mailbox's marked text download is arriving (`TextDownloadProgress`).
    case receivingFile(name: String, percent: Int)

    /// - Parameters:
    ///   - deliveredAtLineCount: the history's line count when the last
    ///     connected send was fully acknowledged, if it was.
    ///   - lineCount: the history's line count now.
    ///   - incoming: a message from the far end partway in, shown when
    ///     nothing is going out.
    ///   - download: a marked text download partway in, shown after both.
    static func make(progress: OutboundMessageProgress?, deliveredAtLineCount: Int?,
                     lineCount: Int,
                     incoming: (from: String, message: AXDPPartialMessage)? = nil,
                     download: TextDownloadProgress? = nil) -> InlineSendStatus? {
        // A message going out holds the row; one coming in comes next.
        if let progress, !(progress.hasAcks && progress.isComplete) {
            // Waiting means nothing of it is on the air yet; a long message
            // used to read "Waiting to send…" until its last frame had gone.
            if !progress.onAir { return .waiting(text: progress.text) }
            // A broadcast on the air has no acknowledgments to wait for.
            if progress.hasAcks {
                return .sending(acked: progress.bytesAcked, total: progress.totalBytes,
                                axdpPeer: progress.viaAXDP ? progress.destination : nil)
            }
        }
        if let incoming { return .receiving(from: incoming.from, amount: incoming.message.amount) }
        if let download { return .receivingFile(name: download.name, percent: download.percent) }
        if let progress, !(progress.hasAcks && progress.isComplete) { return nil }
        if let deliveredAtLineCount, deliveredAtLineCount == lineCount { return .delivered }
        return nil
    }

    /// "Delivered 9.7 of 26.8 KB" beside the progress bar.
    static func deliveredAmount(acked: Int, total: Int) -> String {
        "Delivered " + AXDPPartialMessage(type: nil, received: acked, total: total).amount
    }

    /// An AXDP message shows on the other station only when it is whole, so
    /// the bar says so rather than suggesting they are reading along.
    static func axdpNote(peer: String) -> String {
        "\(peer) sees it when it has all arrived"
    }

    /// Whether the history should follow a change to this row: when it
    /// appears, goes or becomes a different kind of row. A count changing
    /// inside it is not one; on the iPad every delivery of a long message,
    /// and every acknowledgment of a line going out, scrolled to the marker
    /// below the padding and then back (retest 2026-10-10, findings 7 and 10).
    static func needsScroll(from old: InlineSendStatus?, to new: InlineSendStatus?) -> Bool {
        old?.kind != new?.kind
    }

    /// The row's shape, whatever its counts say.
    private var kind: Int {
        switch self {
        case .waiting: return 0
        case .sending(_, let total, _): return total > InlineSendStatus.progressBarBytes ? 2 : 1
        case .delivered: return 3
        case .receiving: return 4
        case .receivingFile: return 5
        }
    }

    /// Bytes above which a message going out gets a progress bar: more than
    /// two frames at the largest paclen.
    static let progressBarBytes = 512
}

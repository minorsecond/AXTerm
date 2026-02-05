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
struct OutboundMessageProgress: Identifiable, Equatable {
    let id: UUID
    let text: String
    let totalBytes: Int
    var bytesSent: Int
    var bytesAcked: Int
    let destination: String
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

    var isComplete: Bool {
        if hasAcks {
            return bytesAcked >= totalBytes
        }
        return bytesSent >= totalBytes
    }

    /// Byte ranges for UI highlighting: [0, bytesAcked), [bytesAcked, bytesSent), [bytesSent, totalBytes)
    var ackedEndIndex: Int { min(bytesAcked, totalBytes) }
    var sentEndIndex: Int { min(bytesSent, totalBytes) }
}

//
//  TxScheduler.swift
//  AXTerm
//
//  TX queue manager with priority ordering and per-destination pacing.
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 4
//

import Foundation

/// Statistics about the TX queue state
struct TxQueueStatistics {
    var totalQueued: Int = 0
    var totalSent: Int = 0
    var totalAcked: Int = 0
    var totalFailed: Int = 0
    var byPriority: [TxPriority: Int] = [:]
}

/// TX scheduler managing outbound frame queue with priority and pacing.
///
/// Features:
/// - Priority queue (interactive > normal > bulk)
/// - FIFO within same priority
/// - Per-destination rate limiting via TokenBucket
/// - Frame state tracking (queued → sending → sent → acked/failed)
struct TxScheduler {

    // MARK: - Configuration

    private let ratePerSec: Double
    private let burstCapacity: Double

    // MARK: - State

    /// Priority queue entries (sorted by priority descending, then enqueue time)
    private var queue: [TxQueueEntry] = []

    /// All entries by frame ID (for state tracking after dequeue)
    private var entriesById: [UUID: TxQueueEntry] = [:]

    /// Per-destination token buckets for rate limiting
    private var buckets: [String: TokenBucket] = [:]

    /// Sequential order counter for FIFO within priority
    private var enqueueCounter: UInt64 = 0

    // MARK: - Init

    /// Create a TX scheduler.
    /// - Parameters:
    ///   - ratePerSec: Token refill rate per destination (frames/sec)
    ///   - burstCapacity: Maximum burst tokens per destination
    init(ratePerSec: Double = 2.0, burstCapacity: Double = 5.0) {
        self.ratePerSec = ratePerSec
        self.burstCapacity = burstCapacity
    }

    // MARK: - Queue Operations

    /// Current number of frames waiting in queue
    var queueDepth: Int {
        queue.count
    }

    /// Enqueue a frame for transmission.
    /// - Parameter frame: The outbound frame to queue
    mutating func enqueue(_ frame: OutboundFrame) {
        var entry = TxQueueEntry(frame: frame)
        entry.enqueueOrder = enqueueCounter
        enqueueCounter += 1

        queue.append(entry)
        entriesById[frame.id] = entry

        // Keep queue sorted by priority (descending) then enqueue order (ascending)
        sortQueue()
    }

    /// Dequeue the next frame if pacing allows.
    /// - Parameter now: Current time for rate limiting
    /// - Returns: The queue entry with state set to `.sending`, or nil if queue empty or rate-limited
    mutating func dequeueNext(now: TimeInterval) -> TxQueueEntry? {
        // Find first frame that passes rate limiting
        for (index, entry) in queue.enumerated() {
            let destKey = entry.frame.destination.display

            // Get or create bucket for this destination
            if buckets[destKey] == nil {
                buckets[destKey] = TokenBucket(ratePerSec: ratePerSec, capacity: burstCapacity, now: now)
            }

            // Check if we can send to this destination
            if buckets[destKey]!.allow(cost: 1.0, now: now) {
                // Remove from queue
                var dequeuedEntry = queue.remove(at: index)

                // Update state to sending
                dequeuedEntry.state.markSending()

                // Update stored entry
                entriesById[dequeuedEntry.frame.id] = dequeuedEntry

                return dequeuedEntry
            }
        }

        return nil
    }

    /// Get entry for a frame ID (whether in queue or already dequeued).
    func getEntry(for frameId: UUID) -> TxQueueEntry? {
        entriesById[frameId]
    }

    // MARK: - State Updates

    /// Mark a frame as successfully sent to TNC.
    mutating func markSent(frameId: UUID) {
        guard var entry = entriesById[frameId] else { return }
        entry.state.markSent()
        entriesById[frameId] = entry
    }

    /// Mark a frame as awaiting acknowledgment.
    mutating func markAwaitingAck(frameId: UUID) {
        guard var entry = entriesById[frameId] else { return }
        entry.state.markAwaitingAck()
        entriesById[frameId] = entry
    }

    /// Mark a frame as acknowledged.
    mutating func markAcked(frameId: UUID) {
        guard var entry = entriesById[frameId] else { return }
        entry.state.markAcked()
        entriesById[frameId] = entry
    }

    /// Mark a frame as failed.
    mutating func markFailed(frameId: UUID, reason: String) {
        guard var entry = entriesById[frameId] else { return }
        entry.state.markFailed(reason: reason)
        entriesById[frameId] = entry
    }

    /// Re-queue a frame for retry (e.g., after timeout).
    mutating func requeueForRetry(frameId: UUID) {
        guard var entry = entriesById[frameId] else { return }

        // Keep the existing state (including attempt count)
        // Just put it back in the queue
        entry.state.status = .queued

        queue.append(entry)
        entriesById[frameId] = entry

        sortQueue()
    }

    /// Cancel a queued frame.
    mutating func cancel(frameId: UUID) {
        // Remove from queue
        queue.removeAll { $0.frame.id == frameId }

        // Update state
        if var entry = entriesById[frameId] {
            entry.state.markCancelled()
            entriesById[frameId] = entry
        }
    }

    // MARK: - Statistics

    /// Get current queue statistics.
    var statistics: TxQueueStatistics {
        var stats = TxQueueStatistics()

        stats.totalQueued = queue.count

        // Count by priority in queue
        for entry in queue {
            stats.byPriority[entry.frame.priority, default: 0] += 1
        }

        // Count sent/acked/failed from all entries
        for entry in entriesById.values {
            switch entry.state.status {
            case .sent, .awaitingAck:
                stats.totalSent += 1
            case .acked:
                stats.totalAcked += 1
            case .failed:
                stats.totalFailed += 1
            default:
                break
            }
        }

        return stats
    }

    // MARK: - Cleanup

    /// Remove old completed entries (acked, failed, cancelled) to free memory.
    /// - Parameter olderThan: Remove entries completed before this date
    mutating func pruneCompleted(olderThan: Date) {
        let cutoff = olderThan

        entriesById = entriesById.filter { (_, entry) in
            switch entry.state.status {
            case .acked:
                return (entry.state.ackedAt ?? Date.distantPast) > cutoff
            case .failed, .cancelled:
                return entry.frame.createdAt > cutoff
            default:
                return true  // Keep active entries
            }
        }
    }

    // MARK: - Private

    private mutating func sortQueue() {
        queue.sort { a, b in
            // Higher priority first
            if a.frame.priority != b.frame.priority {
                return a.frame.priority > b.frame.priority
            }
            // Then FIFO by enqueue order
            return a.enqueueOrder < b.enqueueOrder
        }
    }
}


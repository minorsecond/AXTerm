//
//  TxSchedulerIntegrationTests.swift
//  AXTermTests
//
//  TDD tests for TxScheduler - the TX queue manager with priority and pacing.
//

import XCTest
@testable import AXTerm

final class TxSchedulerIntegrationTests: XCTestCase {

    // MARK: - Basic Queue Operations

    func testEnqueueAndDequeue() {
        var scheduler = TxScheduler()

        let frame = makeTestFrame(destination: "TEST", priority: .normal)
        scheduler.enqueue(frame)

        XCTAssertEqual(scheduler.queueDepth, 1)

        let dequeued = scheduler.dequeueNext(now: 0)
        XCTAssertNotNil(dequeued)
        XCTAssertEqual(dequeued?.frame.id, frame.id)
        XCTAssertEqual(scheduler.queueDepth, 0)
    }

    func testDequeueEmptyQueueReturnsNil() {
        var scheduler = TxScheduler()
        let dequeued = scheduler.dequeueNext(now: 0)
        XCTAssertNil(dequeued)
    }

    func testEnqueueMultipleFrames() {
        var scheduler = TxScheduler()

        let frame1 = makeTestFrame(destination: "A", priority: .normal)
        let frame2 = makeTestFrame(destination: "B", priority: .normal)
        let frame3 = makeTestFrame(destination: "C", priority: .normal)

        scheduler.enqueue(frame1)
        scheduler.enqueue(frame2)
        scheduler.enqueue(frame3)

        XCTAssertEqual(scheduler.queueDepth, 3)
    }

    // MARK: - Priority Ordering

    func testHigherPriorityDequeuedFirst() {
        var scheduler = TxScheduler()

        let bulkFrame = makeTestFrame(destination: "BULK", priority: .bulk)
        let normalFrame = makeTestFrame(destination: "NORMAL", priority: .normal)
        let interactiveFrame = makeTestFrame(destination: "INTERACTIVE", priority: .interactive)

        // Enqueue in reverse priority order
        scheduler.enqueue(bulkFrame)
        scheduler.enqueue(normalFrame)
        scheduler.enqueue(interactiveFrame)

        // Should dequeue in priority order (highest first)
        let first = scheduler.dequeueNext(now: 0)
        XCTAssertEqual(first?.frame.destination.call, "INTERACTIVE")

        let second = scheduler.dequeueNext(now: 0)
        XCTAssertEqual(second?.frame.destination.call, "NORMAL")

        let third = scheduler.dequeueNext(now: 0)
        XCTAssertEqual(third?.frame.destination.call, "BULK")
    }

    func testSamePriorityFIFO() {
        var scheduler = TxScheduler()

        let frame1 = makeTestFrame(destination: "A", priority: .normal)
        let frame2 = makeTestFrame(destination: "B", priority: .normal)
        let frame3 = makeTestFrame(destination: "C", priority: .normal)

        scheduler.enqueue(frame1)
        scheduler.enqueue(frame2)
        scheduler.enqueue(frame3)

        // Same priority should be FIFO
        XCTAssertEqual(scheduler.dequeueNext(now: 0)?.frame.destination.call, "A")
        XCTAssertEqual(scheduler.dequeueNext(now: 0)?.frame.destination.call, "B")
        XCTAssertEqual(scheduler.dequeueNext(now: 0)?.frame.destination.call, "C")
    }

    // MARK: - Pacing / Rate Limiting

    func testPacingLimitsDequeue() {
        // Low rate: 1 frame per second, capacity 1
        var scheduler = TxScheduler(ratePerSec: 1.0, burstCapacity: 1.0)

        // Both frames to SAME destination to test rate limiting
        let frame1 = makeTestFrame(destination: "SAME-DEST", priority: .normal)
        let frame2 = makeTestFrame(destination: "SAME-DEST", priority: .normal)

        scheduler.enqueue(frame1)
        scheduler.enqueue(frame2)

        // First frame should dequeue (uses burst capacity)
        let first = scheduler.dequeueNext(now: 0)
        XCTAssertNotNil(first)

        // Second frame should be blocked by rate limit (same destination, bucket exhausted)
        let second = scheduler.dequeueNext(now: 0)
        XCTAssertNil(second, "Should be rate-limited for same destination")

        // After 1 second, should have 1 new token and be able to dequeue
        let secondRetry = scheduler.dequeueNext(now: 1.0)
        XCTAssertNotNil(secondRetry)
    }

    func testPacingPerDestination() {
        var scheduler = TxScheduler(ratePerSec: 1.0, burstCapacity: 1.0)

        let frameA = makeTestFrame(destination: "DEST-A", priority: .normal)
        let frameB = makeTestFrame(destination: "DEST-B", priority: .normal)

        scheduler.enqueue(frameA)
        scheduler.enqueue(frameB)

        // Both should dequeue because they're to different destinations
        let first = scheduler.dequeueNext(now: 0)
        XCTAssertNotNil(first)

        let second = scheduler.dequeueNext(now: 0)
        XCTAssertNotNil(second, "Different destination should have its own rate limit")
    }

    func testBurstCapacity() {
        // Rate 2/sec, burst capacity 5
        var scheduler = TxScheduler(ratePerSec: 2.0, burstCapacity: 5.0)

        // Enqueue 7 frames to same destination
        for i in 0..<7 {
            scheduler.enqueue(makeTestFrame(destination: "BURST", priority: .normal))
        }

        // First 5 should dequeue immediately (burst)
        for i in 0..<5 {
            let frame = scheduler.dequeueNext(now: 0)
            XCTAssertNotNil(frame, "Frame \(i) should dequeue from burst capacity")
        }

        // 6th should be blocked
        XCTAssertNil(scheduler.dequeueNext(now: 0))

        // After 0.5 seconds, should have 1 more token
        XCTAssertNotNil(scheduler.dequeueNext(now: 0.5))
    }

    // MARK: - Frame State Tracking

    func testFrameStateTracking() {
        var scheduler = TxScheduler()

        let frame = makeTestFrame(destination: "TEST", priority: .normal)
        scheduler.enqueue(frame)

        // Initial state should be queued
        let entry = scheduler.getEntry(for: frame.id)
        XCTAssertEqual(entry?.state.status, .queued)

        // After dequeue, state should be sending
        let dequeued = scheduler.dequeueNext(now: 0)
        XCTAssertEqual(dequeued?.state.status, .sending)
        XCTAssertEqual(dequeued?.state.attempts, 1)
    }

    func testMarkFrameSent() {
        var scheduler = TxScheduler()

        let frame = makeTestFrame(destination: "TEST", priority: .normal)
        scheduler.enqueue(frame)
        _ = scheduler.dequeueNext(now: 0)

        scheduler.markSent(frameId: frame.id)

        let entry = scheduler.getEntry(for: frame.id)
        XCTAssertEqual(entry?.state.status, .sent)
        XCTAssertNotNil(entry?.state.sentAt)
    }

    func testMarkFrameAcked() {
        var scheduler = TxScheduler()

        let frame = makeTestFrame(destination: "TEST", priority: .normal)
        scheduler.enqueue(frame)
        _ = scheduler.dequeueNext(now: 0)
        scheduler.markSent(frameId: frame.id)

        scheduler.markAcked(frameId: frame.id)

        let entry = scheduler.getEntry(for: frame.id)
        XCTAssertEqual(entry?.state.status, .acked)
        XCTAssertNotNil(entry?.state.ackedAt)
    }

    func testMarkFrameFailed() {
        var scheduler = TxScheduler()

        let frame = makeTestFrame(destination: "TEST", priority: .normal)
        scheduler.enqueue(frame)
        _ = scheduler.dequeueNext(now: 0)

        scheduler.markFailed(frameId: frame.id, reason: "Timeout after 10 retries")

        let entry = scheduler.getEntry(for: frame.id)
        XCTAssertEqual(entry?.state.status, .failed)
        XCTAssertEqual(entry?.state.errorMessage, "Timeout after 10 retries")
    }

    // MARK: - Retry / Re-queue

    func testRequeueForRetry() {
        var scheduler = TxScheduler()

        let frame = makeTestFrame(destination: "TEST", priority: .normal)
        scheduler.enqueue(frame)
        let entry = scheduler.dequeueNext(now: 0)!

        // Re-enqueue for retry
        scheduler.requeueForRetry(frameId: frame.id)

        // Should be back in queue
        XCTAssertEqual(scheduler.queueDepth, 1)

        // Dequeue again - attempts should increment
        let retry = scheduler.dequeueNext(now: 1.0)
        XCTAssertEqual(retry?.state.attempts, 2)
    }

    // MARK: - Cancel

    func testCancelFrame() {
        var scheduler = TxScheduler()

        let frame = makeTestFrame(destination: "TEST", priority: .normal)
        scheduler.enqueue(frame)

        scheduler.cancel(frameId: frame.id)

        // Should not be dequeueable
        XCTAssertNil(scheduler.dequeueNext(now: 0))

        // State should be cancelled
        let entry = scheduler.getEntry(for: frame.id)
        XCTAssertEqual(entry?.state.status, .cancelled)
    }

    // MARK: - Queue Statistics

    func testQueueStatistics() {
        var scheduler = TxScheduler()

        scheduler.enqueue(makeTestFrame(destination: "A", priority: .interactive))
        scheduler.enqueue(makeTestFrame(destination: "B", priority: .normal))
        scheduler.enqueue(makeTestFrame(destination: "C", priority: .normal))
        scheduler.enqueue(makeTestFrame(destination: "D", priority: .bulk))

        let stats = scheduler.statistics

        XCTAssertEqual(stats.totalQueued, 4)
        XCTAssertEqual(stats.byPriority[.interactive], 1)
        XCTAssertEqual(stats.byPriority[.normal], 2)
        XCTAssertEqual(stats.byPriority[.bulk], 1)
    }

    // MARK: - Helpers

    private func makeTestFrame(
        destination: String,
        priority: TxPriority,
        payload: Data = Data("test".utf8)
    ) -> OutboundFrame {
        OutboundFrame(
            destination: AX25Address(call: destination, ssid: 0),
            source: AX25Address(call: "N0CALL", ssid: 1),
            payload: payload,
            priority: priority
        )
    }
}

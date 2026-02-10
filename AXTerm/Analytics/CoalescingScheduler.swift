//
//  CoalescingScheduler.swift
//  AXTerm
//
//  Created by AXTerm on 2026-03-08.
//

import Foundation

/// Runs a single enqueued async action after the configured delay, always cancelling
/// any pending work before scheduling a new task. Canceling/weak captures ensure the
/// scheduler can be deallocated immediately without leaving a running `Task`.
/// CoalescingScheduler keeps exactly one pending task, cancels it before scheduling
/// the next, and clears the reference so teardown never races with an executing task.
/// Scheduling and cancellation are thread-safe and do not capture `self` strongly,
/// so the scheduler can be dropped as soon as work is enqueued.
final class CoalescingScheduler: @unchecked Sendable {
    private let delay: Duration
    private var task: Task<Void, Never>?
    private let lock = NSLock()

    init(delay: Duration) {
        self.delay = delay
    }

    func schedule(action: @escaping @Sendable () async -> Void) {
        let work = Task {
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            await action()
        }

        lock.lock()
        task?.cancel()
        task = work
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        task?.cancel()
        task = nil
        lock.unlock()
    }

    deinit {
        cancel()
    }
}

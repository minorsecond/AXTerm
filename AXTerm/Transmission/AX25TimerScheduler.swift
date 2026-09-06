//
//  AX25TimerScheduler.swift
//  AXTerm
//

import Foundation

public protocol AnyCancellableTask: Sendable {
    // Nonisolated: these are cancelled from `deinit`, which belongs to no
    // actor. Cancelling a timer is also the one thing that must always be
    // possible, from wherever the object is being torn down.
    nonisolated func cancel()
}

// Wrapper for standard Swift Task
struct SwiftTaskCancellable: AnyCancellableTask {
    let task: Task<Void, Never>
    
    func cancel() {
        task.cancel()
    }
}

public protocol AX25TimerScheduler: Sendable {
    /// Schedule a task to run after a certain delay.
    /// - Parameters:
    ///   - delay: The delay in seconds
    ///   - action: The action to execute when the timer fires
    /// - Returns: A cancellable task token
    func schedule(delay: TimeInterval, action: @escaping @MainActor @Sendable () -> Void) -> AnyCancellableTask

    /// Monotonic current time in seconds.
    /// Used for RTT measurement so tests can substitute a deterministic virtual clock
    /// instead of wall-clock `Date()`. Real implementations return seconds since an
    /// arbitrary fixed epoch (e.g. `Date().timeIntervalSinceReferenceDate`).
    var currentTime: TimeInterval { get }
}

/// A default clock that uses real wall-clock time via Swift Concurrency `Task.sleep`
// Nonisolated for the same reason as `CoreLocationGPSProvider`: it is a
// default argument, evaluated wherever the caller is.
nonisolated public struct AX25SystemTimerScheduler: AX25TimerScheduler {
    public init() {}

    public var currentTime: TimeInterval {
        // Use TimeInterval since reference date for a stable monotonic-ish wall clock.
        Date().timeIntervalSinceReferenceDate
    }
    
    public func schedule(delay: TimeInterval, action: @escaping @MainActor @Sendable () -> Void) -> AnyCancellableTask {
        let task = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    action()
                }
            } catch {
                // Task cancelled
            }
        }
        return SwiftTaskCancellable(task: task)
    }
}

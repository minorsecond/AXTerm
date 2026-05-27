//
//  AX25TimerScheduler.swift
//  AXTerm
//

import Foundation

public protocol AnyCancellableTask: Sendable {
    func cancel()
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
}

/// A default clock that uses real wall-clock time via Swift Concurrency `Task.sleep`
public struct AX25SystemTimerScheduler: AX25TimerScheduler {
    public init() {}
    
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

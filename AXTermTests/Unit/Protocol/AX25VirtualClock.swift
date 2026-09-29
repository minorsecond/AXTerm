//
//  AX25VirtualClock.swift
//  AXTermTests
//

import Foundation
@testable import AXTerm

@MainActor
public final class AX25VirtualClock: AX25TimerScheduler {
    public var currentTime: TimeInterval = 0.0
    
    private struct ScheduledTask {
        let id: UUID
        let fireTime: TimeInterval
        let action: @MainActor @Sendable () -> Void
        var cancelled: Bool = false
    }
    
    private var tasks: [ScheduledTask] = []
    
    public init() {}
    
    public func schedule(delay: TimeInterval, action: @escaping @MainActor @Sendable () -> Void) -> AnyCancellableTask {
        let id = UUID()
        let fireTime = currentTime + delay
        
        let task = ScheduledTask(id: id, fireTime: fireTime, action: action)
        tasks.append(task)
        // Keep them sorted by fire time
        tasks.sort { $0.fireTime < $1.fireTime }
        
        return VirtualTaskCancellable(clock: self, id: id)
    }
    
    public func cancel(id: UUID) {
        if let index = tasks.firstIndex(where: { $0.id == id }) {
            tasks[index].cancelled = true
        }
    }
    
    public func advance(by interval: TimeInterval) {
        let targetTime = currentTime + interval
        
        while let first = tasks.first, first.fireTime <= targetTime {
            // Remove the first task
            let task = tasks.removeFirst()
            
            // Advance time to when the task fires
            currentTime = task.fireTime
            
            // Execute if not cancelled
            if !task.cancelled {
                task.action()
            }
        }
        
        // Advance to the target time
        currentTime = targetTime
    }
    
    /// Count of active (not fired, not cancelled) tasks
    public var activeTaskCount: Int {
        tasks.filter { !$0.cancelled }.count
    }
}

private struct VirtualTaskCancellable: AnyCancellableTask {
    weak var clock: AX25VirtualClock?
    let id: UUID
    
    func cancel() {
        // Must be synchronous: VirtualClock.advance() is synchronous and checks the `cancelled`
        // flag immediately. Using Task { @MainActor in } here defers cancellation to the next
        // runloop iteration, allowing already-cancelled tasks to fire during advance().
        // Since all callers are @MainActor, we can safely call cancel(id:) directly.
        // Note: MainActor.assumeIsolated is used because AnyCancellableTask.cancel() is
        // nonisolated but callers always invoke from the main actor during tests.
        MainActor.assumeIsolated {
            clock?.cancel(id: id)
        }
    }
}

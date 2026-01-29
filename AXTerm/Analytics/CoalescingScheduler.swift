//
//  CoalescingScheduler.swift
//  AXTerm
//
//  Created by AXTerm on 2026-03-08.
//

import Foundation

final class CoalescingScheduler {
    private let delay: Duration
    private var task: Task<Void, Never>?

    init(delay: Duration) {
        self.delay = delay
    }

    func schedule(action: @escaping @Sendable () async -> Void) {
        task?.cancel()
        task = Task {
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

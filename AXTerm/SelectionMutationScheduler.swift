//
//  SelectionMutationScheduler.swift
//  AXTerm
//
//  Created by Ross Wardrup on 3/2/26.
//

import Foundation

@MainActor
final class SelectionMutationScheduler {
    private var task: Task<Void, Never>?

    func schedule(_ mutation: @MainActor @escaping () -> Void) {
        task?.cancel()
        task = Task { @MainActor in
            await Task.yield()
            mutation()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

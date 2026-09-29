//
//  AutoScrollDecision.swift
//  AXTerm
//
//  Created by AXTerm on 2026-03-08.
//

import Foundation

nonisolated enum AutoScrollDecision {
    static func shouldAutoScroll(
        isUserAtTarget: Bool,
        followNewest: Bool,
        didRequestScrollToTarget: Bool
    ) -> Bool {
        // If the user explicitly requested it, always scroll.
        // Otherwise, only follow live data if they are already at the target point.
        didRequestScrollToTarget || (followNewest && isUserAtTarget)
    }
}

//
//  AutoScrollDecision.swift
//  AXTerm
//
//  Created by AXTerm on 2026-03-08.
//

import Foundation

enum AutoScrollDecision {
    static func shouldAutoScroll(
        isUserAtTop: Bool,
        followNewest: Bool,
        didRequestScrollToTop: Bool
    ) -> Bool {
        didRequestScrollToTop || followNewest || isUserAtTop
    }
}

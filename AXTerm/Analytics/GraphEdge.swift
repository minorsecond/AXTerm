//
//  GraphEdge.swift
//  AXTerm
//
//  Created by AXTerm on 2026-02-20.
//

import Foundation

nonisolated struct GraphEdge: Hashable, Sendable {
    let source: String
    let target: String
    let count: Int
    let bytes: Int?
}

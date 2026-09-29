//
//  GraphNode.swift
//  AXTerm
//
//  Created by AXTerm on 2026-02-20.
//

import Foundation

nonisolated struct GraphNode: Hashable, Sendable {
    let id: String
    let degree: Int
    let count: Int
    let bytes: Int?
}

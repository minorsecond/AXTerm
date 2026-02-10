//
//  ClockProviding.swift
//  AXTerm
//
//  Simple clock protocol for deterministic time-based behavior.
//

import Foundation

nonisolated protocol ClockProviding {
    var now: Date { get }
}

nonisolated struct SystemClock: ClockProviding, Sendable {
    var now: Date { Date() }
}

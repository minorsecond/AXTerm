//
//  ClockProviding.swift
//  AXTerm
//
//  Simple clock protocol for deterministic time-based behavior.
//

import Foundation

protocol ClockProviding {
    var now: Date { get }
}

struct SystemClock: ClockProviding {
    var now: Date { Date() }
}

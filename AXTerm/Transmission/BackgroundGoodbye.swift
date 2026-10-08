//
//  BackgroundGoodbye.swift
//  AXTerm
//

import Foundation

/// How an iPhone or iPad spends its background time saying goodbye.
///
/// AXTerm has no background mode, so iOS suspends it a few seconds after it
/// leaves the screen, and its AX.25 links died without a DISC: the far
/// station polled a dead link until it gave up (the iOS side of smoke run
/// 2026-10-03-1, issue 85). Leaving the screen now asks for background time.
/// A short grace first lets a quick trip to another app keep the session;
/// then each live link gets its DISC and up to `settleCap` for the UA, DM or
/// a T1 on the air, and the time is handed back with a margin to spare.
nonisolated enum BackgroundGoodbye: Equatable {

    struct Plan: Equatable {
        /// How long to wait before saying goodbye, in case the operator comes
        /// straight back.
        let grace: TimeInterval
        /// The longest the DISCs are given to settle.
        let settleCap: TimeInterval
    }

    /// Kept back from the background allowance for the radio and the
    /// background task to wind down before iOS suspends the app.
    static let reserve: TimeInterval = 3
    static let longestGrace: TimeInterval = 10
    static let longestSettle: TimeInterval = 12
    /// What iOS usually allows, used when it reports an unbounded time (it
    /// does while the app is still in the foreground).
    static let usualAllowance: TimeInterval = 30

    /// Whether a radio's connection outlasts iOS suspending the app. A
    /// Bluetooth TNC does: the app keeps Bluetooth running in the background
    /// (`bluetooth-central`), so its calls are left up. A network TNC's
    /// socket is dropped with the app, so its calls are closed first.
    static func survivesSuspension(_ kind: RadioTransportKind) -> Bool {
        kind == .ble
    }

    static func plan(backgroundTimeRemaining remaining: TimeInterval) -> Plan {
        let budget = remaining.isFinite && remaining < 600 ? remaining : usualAllowance
        let usable = max(0, budget - reserve)
        let settle = min(longestSettle, usable)
        let grace = max(0, min(longestGrace, usable - settle))
        return Plan(grace: grace, settleCap: settle)
    }
}

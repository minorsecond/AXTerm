//
//  T1TestSupport.swift
//  AXTermTests
//
//  When a session's T1 resend will happen, for tests that drive a virtual
//  clock up to it. T1 runs for T1V from when our frames have left the radio
//  (spec 7.3), and the resend goes out when it fires.
//

import Foundation
@testable import AXTerm

extension AX25Session {
    /// Seconds from `now` until T1's resend has gone out: T1's start plus
    /// T1V, plus a little.
    func secondsToT1Resend(now: TimeInterval) -> TimeInterval {
        ((t1StartedAt ?? now) + timers.rto) - now + 0.01
    }
}

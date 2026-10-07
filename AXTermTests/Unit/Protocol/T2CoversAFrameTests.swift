//
//  T2CoversAFrameTests.swift
//  AXTermTests
//
//  T2 restarts on each frame of a burst, so it has to outlast the gap
//  between one frame's end and the next one's: a full frame's airtime. It
//  was capped at 2/3 of the initial SRT, and a link resuming a learned T1V
//  near 5 s got T2 ≈ 1.67 s, shorter than a 256-byte frame at 1200 bit/s
//  (1.83 s). The phone then answered every frame of A (705)'s bursts with
//  its own RR (smoke run 2026-10-03-1, test 13.3, issue 107).
//

import XCTest
@testable import AXTerm

final class T2CoversAFrameTests: XCTestCase {

    private let fullFrameAirtime = Double(256 + 18) * 8 / 1200

    func testALearnedShortSRTNoLongerPullsT2BelowAFullFrame() {
        let timers = AX25SessionTimers(initialSRT: 3.0, resumingT1V: 5.0, t2AckDelay: 2.0, maxFrameBytes: 256)
        XCTAssertGreaterThan(timers.t2AckDelay, fullFrameAirtime,
                             "one frame of a burst must not run T2 out before the next arrives")
        XCTAssertEqual(timers.t2AckDelay, 2.0, accuracy: 1e-9, "the configured T2 still holds")
    }

    func testAFrameLongerThanTheDefaultT2RaisesTheDefault() {
        // The default when nothing is configured: at least a full frame and a
        // tenth, so a 256-byte burst is acked once.
        XCTAssertGreaterThanOrEqual(AX25SessionTimers.defaultT2(maxFrameBytes: 256), fullFrameAirtime * 1.1 - 1e-9)
        XCTAssertEqual(AX25SessionTimers.defaultT2(maxFrameBytes: 64), 2.0, accuracy: 1e-9)
    }

    func testAnExplicitlyShortT2IsKept() {
        let timers = AX25SessionTimers(initialSRT: 3.0, t2AckDelay: 0.1, maxFrameBytes: 256)
        XCTAssertEqual(timers.t2AckDelay, 0.1, accuracy: 1e-9)
    }

    func testWithoutAFrameSizeTheCapIsAsBefore() {
        let timers = AX25SessionTimers(initialSRT: 3.0, resumingT1V: 5.0, t2AckDelay: 2.0)
        XCTAssertEqual(timers.t2AckDelay, 2.5 * 2.0 / 3.0, accuracy: 1e-9)
    }
}

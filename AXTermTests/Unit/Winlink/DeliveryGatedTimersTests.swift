//
//  DeliveryGatedTimersTests.swift
//  AXTermTests
//
//  A Winlink wait for the other station's reply starts counting only once
//  what we sent has been delivered (park rehearsal 2026-10-08). The engine
//  armed its two-minute reply timer as soon as it handed our messages to the
//  link; a 25 KB photo at the 46 B/s measured that day takes about nine
//  minutes on the air, and the peer cannot reply to what it has not
//  received. The old fix stretched the timer by an assumed 50 B/s, which the
//  same link fell well below while it recovered from lost frames.
//

import XCTest
@testable import AXTerm

@MainActor
final class DeliveryGatedTimersTests: XCTestCase {
    private var started: [(B2FSessionEngine.TimerKind, Int)] = []
    private var canceled: [B2FSessionEngine.TimerKind] = []

    private func makeTimers() -> DeliveryGatedTimers {
        DeliveryGatedTimers(start: { [unowned self] in self.started.append(($0, $1)) },
                            cancel: { [unowned self] in self.canceled.append($0) })
    }

    func testAReplyWaitStartsOnceEverythingSentIsDelivered() {
        let timers = makeTimers()
        timers.noteSubmitted(25_000)
        timers.request(.response, seconds: 120)
        XCTAssertTrue(started.isEmpty, "the photo is still going out")

        timers.noteDelivered(12_000)
        XCTAssertTrue(started.isEmpty)

        timers.noteDelivered(25_000)
        XCTAssertEqual(started.map(\.0), [.response])
        XCTAssertEqual(started.first?.1, 120, "the full wait, counted from delivery")
    }

    func testAWaitStartsAtOnceWhenNothingIsOutstanding() {
        let timers = makeTimers()
        timers.noteSubmitted(40)
        timers.noteDelivered(40)
        timers.request(.binary, seconds: 120)
        XCTAssertEqual(started.map(\.0), [.binary])
    }

    func testTheOperatorsDeadlineIsNeverHeld() {
        let timers = makeTimers()
        timers.noteSubmitted(25_000)
        timers.request(.selection, seconds: 60)
        XCTAssertEqual(started.map(\.0), [.selection], "it measures a person, not the link")
    }

    func testACanceledWaitDoesNotStartLater() {
        let timers = makeTimers()
        timers.noteSubmitted(25_000)
        timers.request(.response, seconds: 120)
        timers.cancel(.response)
        timers.noteDelivered(25_000)
        XCTAssertTrue(started.isEmpty)
        XCTAssertEqual(canceled, [.response])
    }

    func testANewRequestReplacesOneStillWaiting() {
        let timers = makeTimers()
        timers.noteSubmitted(25_000)
        timers.request(.response, seconds: 120)
        timers.request(.response, seconds: 90)
        timers.noteDelivered(25_000)
        XCTAssertEqual(started.map(\.1), [90])
    }
}

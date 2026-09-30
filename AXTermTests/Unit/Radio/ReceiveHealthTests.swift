//
//  ReceiveHealthTests.swift
//  AXTermTests
//
//  A connected radio that decodes nothing gets a warning, from its own
//  traffic and nothing else, and a radio that has just connected never does.
//

import XCTest
@testable import AXTerm

final class ReceiveHealthTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func minutes(_ m: Double) -> Date { t0.addingTimeInterval(m * 60) }

    func testNotConnectedSaysNothing() {
        XCTAssertNil(ReceiveHealth.assess(connectedAt: nil, lastRx: nil, transmittedSinceConnect: 10,
                                          now: minutes(90)))
    }

    func testJustConnectedSaysNothing() {
        XCTAssertNil(ReceiveHealth.assess(connectedAt: t0, lastRx: nil, transmittedSinceConnect: 0,
                                          now: minutes(1)))
        XCTAssertNil(ReceiveHealth.assess(connectedAt: t0, lastRx: nil, transmittedSinceConnect: 5,
                                          now: minutes(1)),
                     "several frames in the first minute are not yet evidence")
    }

    func testTwentyQuietMinutesOnAPRSIsWorthSaying() {
        XCTAssertNil(ReceiveHealth.assess(connectedAt: t0, lastRx: minutes(2), transmittedSinceConnect: 0,
                                          now: minutes(21)))
        XCTAssertEqual(ReceiveHealth.assess(connectedAt: t0, lastRx: minutes(2), transmittedSinceConnect: 0,
                                            now: minutes(36)),
                       .quiet(minutes: 34))
    }

    func testSilenceSinceConnectingCounts() {
        XCTAssertEqual(ReceiveHealth.assess(connectedAt: t0, lastRx: nil, transmittedSinceConnect: 0,
                                            now: minutes(40)),
                       .quiet(minutes: 40))
    }

    /// Frames heard before a reconnect say nothing about the receiver now,
    /// and the quiet time counts from the reconnect, not from those frames.
    func testTrafficBeforeTheLinkCameUpDoesNotCount() {
        let connected = minutes(60)
        XCTAssertNil(ReceiveHealth.assess(connectedAt: connected, lastRx: minutes(55),
                                          transmittedSinceConnect: 0, now: minutes(70)))
        XCTAssertEqual(ReceiveHealth.assess(connectedAt: connected, lastRx: minutes(55),
                                            transmittedSinceConnect: 0, now: minutes(85)),
                       .quiet(minutes: 25))
    }

    func testAPacketChannelGetsLonger() {
        let packet = ReceiveHealth.quietAfter(onAPRS: false)
        XCTAssertNil(ReceiveHealth.assess(connectedAt: t0, lastRx: nil, transmittedSinceConnect: 0,
                                          now: minutes(40), quietAfter: packet))
        XCTAssertEqual(ReceiveHealth.assess(connectedAt: t0, lastRx: nil, transmittedSinceConnect: 0,
                                            now: minutes(61), quietAfter: packet),
                       .quiet(minutes: 61))
    }

    func testTransmittingIntoNothing() {
        XCTAssertEqual(ReceiveHealth.assess(connectedAt: t0, lastRx: nil, transmittedSinceConnect: 3,
                                            now: minutes(6)),
                       .nothingHeardAfterTransmitting(frames: 3, minutes: 6))
        XCTAssertNil(ReceiveHealth.assess(connectedAt: t0, lastRx: nil, transmittedSinceConnect: 2,
                                          now: minutes(6)),
                     "two frames can both go unanswered on a quiet channel")
        XCTAssertNil(ReceiveHealth.assess(connectedAt: t0, lastRx: minutes(3), transmittedSinceConnect: 8,
                                          now: minutes(6)),
                     "one decoded frame since connecting shows the receiver works")
    }

    func testTheMessagesSayWhatToCheck() {
        XCTAssertEqual(ReceiveHealth.message(.quiet(minutes: 34)),
                       "Nothing received for 34 min. Check the radio's volume, squelch and antenna.")
        XCTAssertTrue(ReceiveHealth.message(.nothingHeardAfterTransmitting(frames: 4, minutes: 9))
            .hasPrefix("Sent 4 frames in 9 min and heard nothing back."))
    }
}

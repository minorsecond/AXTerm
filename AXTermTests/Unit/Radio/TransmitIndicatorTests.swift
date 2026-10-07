//
//  TransmitIndicatorTests.swift
//  AXTermTests
//
//  A light that is red while the station transmits, on the Mac, iPhone and
//  iPad (operator, 2026-10-07). The toolbar's dot used to flash a quarter
//  second per frame handed over, whatever the radio did. A sound modem
//  reports its PTT, so its light follows the radio. A TNC reports nothing,
//  so its light is an estimate: from the hand-off, its TX delay and the
//  frame's airtime, with frames handed over back to back sharing one key-up.
//

import XCTest
@testable import AXTerm

final class TransmitIndicatorTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testATNCFrameLightsForTXDelayPlusAirtime() {
        var light = TransmitIndicator()
        // 60 bytes + 4 of flags and FCS = 512 bits = 0.427 s at 1200 bit/s.
        light.noteHandedOff(bytes: 60, txDelay: 0.8, at: t0)
        XCTAssertTrue(light.isTransmitting(at: t0.addingTimeInterval(1.0)))
        XCTAssertFalse(light.isTransmitting(at: t0.addingTimeInterval(1.3)))
        XCTAssertEqual(light.endsAt!.timeIntervalSince(t0), 0.8 + 512.0 / 1200, accuracy: 1e-6)
    }

    func testFramesBackToBackShareOneKeyUp() {
        var light = TransmitIndicator()
        light.noteHandedOff(bytes: 60, txDelay: 0.8, at: t0)
        light.noteHandedOff(bytes: 60, txDelay: 0.8, at: t0.addingTimeInterval(0.01))
        XCTAssertEqual(light.endsAt!.timeIntervalSince(t0), 0.8 + 2 * 512.0 / 1200, accuracy: 1e-6,
                       "the second frame adds its airtime, not another TX delay")
    }

    func testAFrameAfterTheLastEndedKeysUpAgain() {
        var light = TransmitIndicator()
        light.noteHandedOff(bytes: 60, txDelay: 0.8, at: t0)
        let later = t0.addingTimeInterval(5)
        light.noteHandedOff(bytes: 60, txDelay: 0.8, at: later)
        XCTAssertEqual(light.endsAt!.timeIntervalSince(later), 0.8 + 512.0 / 1200, accuracy: 1e-6)
    }

    func testASoundModemFollowsItsPTT() {
        var light = TransmitIndicator()
        light.notePTT(true)
        XCTAssertTrue(light.isTransmitting(at: t0))
        light.notePTT(false)
        XCTAssertFalse(light.isTransmitting(at: t0))
    }

    func testOnceAModemReportsPTTHandOffsDoNotLightIt() {
        var light = TransmitIndicator()
        light.notePTT(false)
        light.noteHandedOff(bytes: 60, txDelay: 0.8, at: t0)
        XCTAssertFalse(light.isTransmitting(at: t0.addingTimeInterval(0.5)),
                       "the modem's own PTT says when it keys; a hand-off can wait for the channel")
    }
}

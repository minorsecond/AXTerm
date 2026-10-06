//
//  ReportedTransmissionEndTests.swift
//  AXTermTests
//
//  T1 runs from when our frames have left the radio (spec 7.3). The
//  manager estimates that moment from the key-up time the modem has
//  measured so far, and a sound modem also reports when each transmission
//  really ends. The report wins when it is later.
//
//  Smoke run 2026-10-03-1, issue 83: A (705) handed its SABM to the modem
//  at 15:21:34Z and B (ID-50) heard it 2.85 s later, because keying the
//  IC-705 through Warbler took far longer than the smoothed key-up time
//  said. T1 ran from the estimate, the SABM went out again, the second SABM
//  reset B's link, the second UA reached A while connected, and A
//  re-established the link (as the 2.2 SDL calls for on an unexpected UA),
//  which took the NET/ROM circuit down with it.
//

import XCTest
@testable import AXTerm

@MainActor
final class ReportedTransmissionEndTests: XCTestCase {

    private let peer = AX25Address(call: "K0EPI", ssid: 3)
    private let local = AX25Address(call: "K0EPI", ssid: 2)

    private func manager() -> (AX25SessionManager, AX25VirtualClock) {
        let clock = AX25VirtualClock()
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "NOCALL", ssid: 0), clock: clock)
        manager.localCallsign = local
        manager.defaultConfig = AX25SessionConfig(initialRto: 3.0)
        return (manager, clock)
    }

    private func sabmTimes(_ manager: AX25SessionManager, _ clock: AX25VirtualClock) -> () -> [Double] {
        var times: [Double] = []
        manager.onSendFrame = { frame in
            if frame.frameType == "u" { times.append(clock.currentTime) }
        }
        return { times }
    }

    func testT1RunsFromWhenTheRadioSaysTheSABMWentOut() throws {
        let (manager, clock) = manager()
        let retries = sabmTimes(manager, clock)
        _ = try XCTUnwrap(manager.connect(to: peer))

        // The radio keys slowly: the SABM is on the air until 2.85 s.
        clock.advance(by: 2.85)
        manager.transmissionEnded(on: .primary)

        clock.advance(by: 2.9)
        XCTAssertEqual(retries(), [], "T1 fired before 3 s had passed since the SABM went out")
        clock.advance(by: 0.2)
        XCTAssertEqual(retries().count, 1)
        XCTAssertEqual(retries().first ?? 0, 2.85 + 3.0, accuracy: 0.02)
    }

    func testAUAAfterTheSlowKeyUpConnectsWithoutASecondSABM() throws {
        let (manager, clock) = manager()
        let retries = sabmTimes(manager, clock)
        _ = try XCTUnwrap(manager.connect(to: peer))
        clock.advance(by: 2.85)
        manager.transmissionEnded(on: .primary)
        clock.advance(by: 1.1)
        _ = manager.handleInboundUA(from: peer, path: DigiPath(), radio: .primary)

        let session = try XCTUnwrap(manager.existingSession(for: peer, path: DigiPath(), radio: .primary))
        XCTAssertEqual(session.state, .connected)
        XCTAssertEqual(retries(), [])
        XCTAssertEqual(session.timers.srt, 3.0 * 7 / 8 + 1.1 / 8, accuracy: 1e-6,
                       "the round trip T1 measured starts when the SABM went out")
    }

    /// A transmission that carried none of this link's frames says nothing
    /// about when they left, so it does not hold this link's T1 back.
    func testSomeoneElsesTransmissionDoesNotPostponeT1() throws {
        let (manager, clock) = manager()
        let retries = sabmTimes(manager, clock)
        let sabm = try XCTUnwrap(manager.connect(to: peer))
        let air = Double(AX25Session.airBytes(sabm)) * 8 / 1200
        clock.advance(by: air)
        manager.transmissionEnded(on: .primary)      // the SABM

        clock.advance(by: 2.0)
        manager.transmissionEnded(on: .primary)      // a beacon, later

        clock.advance(by: 1.1)
        XCTAssertEqual(retries().count, 1)
        XCTAssertEqual(retries().first ?? 0, air + 3.0, accuracy: 0.02)
    }

    func testAnotherRadiosTransmissionDoesNotPostponeT1() throws {
        let (manager, clock) = manager()
        let retries = sabmTimes(manager, clock)
        let sabm = try XCTUnwrap(manager.connect(to: peer))
        let air = Double(AX25Session.airBytes(sabm)) * 8 / 1200
        clock.advance(by: 2.0)
        manager.transmissionEnded(on: RadioID(rawValue: "radio-other"))
        clock.advance(by: 1.1 + air)
        XCTAssertEqual(retries().count, 1)
        XCTAssertEqual(retries().first ?? 0, air + 3.0, accuracy: 0.02)
    }

    /// The report only ever moves the start later: one that arrives before
    /// the estimate (a fast radio) leaves T1 where it was.
    func testAnEarlyReportDoesNotShortenT1() throws {
        let (manager, clock) = manager()
        let retries = sabmTimes(manager, clock)
        let sabm = try XCTUnwrap(manager.connect(to: peer))
        let air = Double(AX25Session.airBytes(sabm)) * 8 / 1200
        clock.advance(by: air / 2)
        manager.transmissionEnded(on: .primary)
        clock.advance(by: air / 2 + 3.05)
        XCTAssertEqual(retries().count, 1)
        XCTAssertEqual(retries().first ?? 0, air + 3.0, accuracy: 0.02)
    }

    func testAStoppedT1StaysStopped() throws {
        let (manager, clock) = manager()
        _ = try XCTUnwrap(manager.connect(to: peer))
        clock.advance(by: 1.0)
        _ = manager.handleInboundUA(from: peer, path: DigiPath(), radio: .primary)
        let session = try XCTUnwrap(manager.existingSession(for: peer, path: DigiPath(), radio: .primary))
        XCTAssertNil(session.t1StartedAt)
        manager.transmissionEnded(on: .primary)
        XCTAssertNil(session.t1StartedAt, "a late report restarted a T1 that the UA had stopped")
    }
}

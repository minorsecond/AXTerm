//
//  CarModeTests.swift
//  AXTermTests
//
//  The map's car mode (operator, 2026-10-07): only what helps at a glance,
//  your own position followed like a navigation app, and one line saying
//  when you last beaconed and which digipeaters repeated it.
//

import XCTest
@testable import AXTerm

final class CarModeTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let me = AX25Address(call: "K0EPI", ssid: 9)

    private func heard(_ via: [AX25Address], at offset: TimeInterval, from: AX25Address? = nil) -> Packet {
        Packet(timestamp: now.addingTimeInterval(offset), from: from ?? me,
               to: AX25Address(call: "APZAXT"), via: via, frameType: .ui)
    }

    func testCarModeDrawsOnlyWhatHelpsAtAGlance() {
        let car = CarMode.Chrome(carMode: true)
        XCTAssertFalse(car.rings)
        XCTAssertFalse(car.trails)
        XCTAssertFalse(car.paths)
        XCTAssertFalse(car.overlays)
        XCTAssertFalse(car.legend)
        XCTAssertFalse(car.banners)
        XCTAssertFalse(car.trafficStrip)
        XCTAssertFalse(car.toolbar)
        let normal = CarMode.Chrome(carMode: false)
        XCTAssertTrue(normal.rings && normal.trails && normal.legend && normal.toolbar)
    }

    func testTheDigipeatersThatRepeatedTheLastBeacon() {
        let packets = [
            heard([AX25Address(call: "W0NED", repeated: true), AX25Address(call: "WIDE1", repeated: true),
                   AX25Address(call: "WIDE2", ssid: 1)], at: -20),
            heard([AX25Address(call: "BVILLE", repeated: true), AX25Address(call: "WIDE2", ssid: 1)], at: -19),
            heard([AX25Address(call: "OLDIGI", repeated: true)], at: -200),        // before the beacon
            heard([AX25Address(call: "W0NED", repeated: true)], at: -18,
                  from: AX25Address(call: "N0CALL", ssid: 9)),                       // someone else
            heard([AX25Address(call: "WIDE1", ssid: 1)], at: -21),                   // direct copy
        ]
        XCTAssertEqual(CarMode.heardBy(packets, ownAddresses: [me.display], since: now.addingTimeInterval(-21)),
                       ["W0NED", "BVILLE"])
    }

    func testTheBeaconLine() {
        XCTAssertEqual(CarMode.beaconLine(lastBeacon: nil, now: now, heardBy: []), "No beacon yet")
        XCTAssertEqual(CarMode.beaconLine(lastBeacon: now.addingTimeInterval(-40), now: now, heardBy: ["W0NED"]),
                       "Beaconed 40 s ago · heard by W0NED")
        XCTAssertEqual(CarMode.beaconLine(lastBeacon: now.addingTimeInterval(-185), now: now, heardBy: []),
                       "Beaconed 3 min ago · no digipeater heard it")
        XCTAssertEqual(CarMode.beaconLine(lastBeacon: now.addingTimeInterval(-10), now: now,
                                          heardBy: ["W0NED", "BVILLE"]),
                       "Beaconed 10 s ago · heard by W0NED, BVILLE")
    }
}

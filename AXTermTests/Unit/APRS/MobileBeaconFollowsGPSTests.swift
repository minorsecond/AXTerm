//
//  MobileBeaconFollowsGPSTests.swift
//  AXTermTests
//
//  On a drive the iPhone beaconed K0EPI-9 every minute, and every beacon
//  carried the same position, the one from when the operator set it up. The
//  beacon read the location service's cached fix, and on iOS nothing ever
//  asked for another; the Mac re-read it only every 5 minutes (smoke run
//  2026-10-03-1, APRS drive test, issue 118). A position beacon that
//  follows the station now asks for a fix no older than half its interval
//  before it is built.
//

import XCTest
@testable import AXTerm

@MainActor
final class MobileBeaconFollowsGPSTests: XCTestCase {

    private func setUp(position: @escaping () -> (latitude: Double, longitude: Double)?)
    -> (SessionCoordinator, AppSettingsStore, RadioID) {
        let settings = AppSettingsStore(defaults: TestDefaults.make("MobileBeaconFollowsGPS"))
        let radio = settings.activeRadios[0].id
        settings.updateRadio(radio) {
            $0.aprsEnabled = true
            var aprs = APRSPositionConfig.followingStation
            aprs.symbolCode = ">"
            $0.beacon = BeaconConfig(enabled: true, kind: .aprsPosition, intervalMinutes: 1, aprs: aprs)
        }
        let coordinator = SessionCoordinator()
        coordinator.localCallsign = "K0EPI-9"
        coordinator.appSettings = settings
        coordinator.aprsLocationProvider = position
        return (coordinator, settings, radio)
    }

    func testATimedBeaconAsksForAFreshFixFirstAndSendsIt() async throws {
        var where_ = (latitude: 39.60, longitude: -104.80)
        let (coordinator, settings, radio) = setUp(position: { where_ })
        defer { SessionCoordinator.shared = nil }
        var askedFor: [TimeInterval] = []
        coordinator.aprsLocationRefresh = { maxAge in
            askedFor.append(maxAge)
            where_ = (latitude: 39.65, longitude: -104.70)   // the car has moved
        }
        var sent: [OutboundFrame] = []
        coordinator.onFrameHandedToRadio = { sent.append($0) }

        await coordinator.sendBeaconWithFreshPosition(for: radio, settings: settings)

        XCTAssertEqual(askedFor, [30], "a fix no older than half the 1-minute interval")
        let frame = try XCTUnwrap(sent.first)
        let moved = APRSBeacon.infoField(APRSBeacon.PositionReport(
            latitude: 39.65, longitude: -104.70, symbolTable: "/", symbolCode: ">",
            ambiguity: 0, comment: "", compressed: false))
        XCTAssertEqual(String(decoding: frame.payload, as: UTF8.self), moved, "the new position goes out")
    }

    func testAFixedPositionBeaconDoesNotAskForAFix() async {
        let (coordinator, settings, radio) = setUp(position: { (39.6, -104.8) })
        defer { SessionCoordinator.shared = nil }
        settings.updateRadio(radio) {
            $0.beacon.aprs?.useGPS = false
            $0.beacon.aprs?.latitude = 39.6
            $0.beacon.aprs?.longitude = -104.8
        }
        var asked = 0
        coordinator.aprsLocationRefresh = { _ in asked += 1 }
        await coordinator.sendBeaconWithFreshPosition(for: radio, settings: settings)
        XCTAssertEqual(asked, 0)
    }
}

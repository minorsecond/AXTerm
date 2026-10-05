//
//  StationFrameOriginTests.swift
//  AXTermTests
//

import XCTest
@testable import AXTerm

/// A station whose own traffic is piped in from the internet must say so, a
/// gateway that relays other stations' traffic must say that instead, and both
/// must survive a relaunch.
///
/// `update(with:)` and `rebuild(from:)` are two implementations of the same
/// derivation; anything recorded in one and not the other vanishes on the next
/// launch. That has already cost this app APRS positions, radio traffic
/// classification, telemetry and the incident layer.
final class StationFrameOriginTests: XCTestCase {

    private let radio = RadioID(rawValue: "a")

    private func packet(_ info: String, from: String, ssid: Int = 0,
                        via: [AX25Address] = [], at: TimeInterval) -> Packet {
        Packet(timestamp: Date(timeIntervalSince1970: at),
               from: AX25Address(call: from, ssid: ssid),
               to: AX25Address(call: "APRS"), via: via,
               frameType: .ui, control: 0x03, pid: 0xF0,
               info: Data(info.utf8), rawAx25: Data([0x01]), radioID: radio)
    }

    /// Verbatim from the prod log: W3OO-1 putting K0VJ-10's internet traffic
    /// onto the channel.
    private let gated = "}K0VJ-10>APFII0,TCPIP,W3OO-1*::OTA      :ack5421"

    /// W3OO-1 is a gateway: it relays K0VJ-10's internet traffic, and its
    /// own transmitter is the one heard. Until smoke run 2026-10-03-1 (issue
    /// 27) it was filed as gated traffic itself, and its card said its
    /// traffic came "from the internet, not from its own transmitter".
    func testAGatewayIsRecordedAsRelayingNotAsGated() {
        var tracker = StationTracker()
        tracker.update(with: packet(gated, from: "W3OO", ssid: 1, at: 10))

        let station = tracker.stations.first { $0.call == "W3OO-1" }!
        XCTAssertEqual(station.relaysForOthers, APRSGatewayActivity(lastSource: "K0VJ-10", viaInternet: true))
        XCTAssertEqual(station.frameOrigin, .radio, "its own transmitter was heard")
    }

    func testARebuildKeepsIt() {
        let packets = [packet(gated, from: "W3OO", ssid: 1, at: 10)]
        var live = StationTracker()
        for p in packets { live.update(with: p) }

        var rebuilt = StationTracker()
        rebuilt.rebuild(from: packets)

        XCTAssertEqual(rebuilt.stations.first { $0.call == "W3OO-1" }?.relaysForOthers,
                       live.stations.first { $0.call == "W3OO-1" }?.relaysForOthers,
                       "a relaunch must not lose the fact that this station is a gateway")
        XCTAssertNotNil(rebuilt.stations.first { $0.call == "W3OO-1" }!.relaysForOthers)
    }

    /// A gateway that also beacons its own position is still a gateway; a
    /// later plain frame must not clear the fact.
    func testAPlainFrameDoesNotClearIt() {
        var tracker = StationTracker()
        tracker.update(with: packet(gated, from: "W3OO", ssid: 1, at: 10))
        tracker.update(with: packet("!3937.00N/10443.00W-", from: "W3OO", ssid: 1, at: 20))

        XCTAssertNotNil(tracker.stations.first { $0.call == "W3OO-1" }!.relaysForOthers)
    }

    func testTheGatewaysCardSaysWhatItDoes() {
        var tracker = StationTracker()
        tracker.update(with: packet(gated, from: "W3OO", ssid: 1, at: 10))
        tracker.update(with: packet("!3937.00N/10443.00W-", from: "W3OO", ssid: 1, at: 20))
        let entries = HeardStationMap.entries(stations: tracker.stations, directory: [:], gatewayGrids: [:])
        let entry = entries.first { $0.callsign == "W3OO-1" }!
        let card = HeardStationMap.detail(for: entry, observer: nil, now: Date(timeIntervalSince1970: 30))
        XCTAssertTrue(card.contains("Gateway: relays other stations' packets onto RF from the internet"), card)
        XCTAssertTrue(card.contains("Its own transmitter is heard here."), card)
        XCTAssertFalse(card.contains("not from its own transmitter"), card)
    }

    /// A packet whose own path says it came over the internet is still badged.
    func testAnInternetPathIsStillRecorded() {
        var tracker = StationTracker()
        tracker.update(with: packet("!3937.00N/10443.00W-", from: "K0ABC",
                                    via: [AX25Address(call: "TCPIP", ssid: 0, repeated: true)], at: 10))
        XCTAssertEqual(tracker.stations.first { $0.call == "K0ABC" }?.frameOrigin, .internetPath)
    }

    /// KC0AUH-2: far away, but its frame makes no claim. Distance is
    /// `StationPlausibility`'s business, not this one's.
    func testADistantStationIsNotBadgedOnSuspicion() {
        var tracker = StationTracker()
        tracker.update(with: packet(
            "!3745.40ND10052.08W# Finney Co. Wide Area Digi",
            from: "KC0AUH", ssid: 2,
            via: [AX25Address(call: "WA6IFI", ssid: 6, repeated: true)], at: 10))

        let station = tracker.stations.first { $0.call == "KC0AUH-2" }!
        XCTAssertEqual(station.frameOrigin, .radio)
        XCTAssertFalse(station.frameOrigin.isFromInternet)
    }

    func testOrdinaryStationsStayUnclaimed() {
        var tracker = StationTracker()
        tracker.update(with: packet("!3933.48N/10447.65W#LSA WIDE1 DigiGate",
                                    from: "WQ8M", ssid: 9, at: 10))
        XCTAssertEqual(tracker.stations.first { $0.call == "WQ8M-9" }?.frameOrigin, .radio)
    }
}

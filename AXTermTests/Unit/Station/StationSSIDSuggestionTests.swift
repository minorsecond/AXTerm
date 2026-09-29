import XCTest
@testable import AXTerm

/// Splitting a callsign into the operator's part and the radio's part.
///
/// The split is what makes a second device set itself up without colliding
/// with the first: the base is a licence and travels, the SSID is a station
/// and must not.
/// The half of a callsign that identifies a station rather than a person.
///
/// The splitting itself is `CallsignParser`'s, and tested with the network
/// graph that has always used it. What is asserted here is the meaning this
/// feature depends on: a bare callsign and `-0` are the same address, so a
/// second device must not be handed either when one is in use.
final class StationIdentitySplitTests: XCTestCase {

    func testABareCallsignAndSSIDZeroAreTheSameAddress() {
        XCTAssertNil(CallsignParser.parse("K0EPI").ssid)
        XCTAssertNil(CallsignParser.parse("K0EPI-0").ssid)
        XCTAssertEqual(CallsignParser.parse("K0EPI-0").full, "K0EPI")
    }

    func testTheBaseIsTheLicenceAndTheSSIDIsTheStation() {
        let parsed = CallsignParser.parse("k0epi-7")
        XCTAssertEqual(parsed.base, "K0EPI")
        XCTAssertEqual(parsed.ssid, 7)
        XCTAssertEqual(parsed.full, "K0EPI-7")
    }
}

/// Choosing an SSID for a device that has not got one.
final class StationSSIDSuggestionTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func lease(_ device: String, callsign: String,
                       endpoint: String = "100.77.243.13:8001",
                       duration: TimeInterval = StationIdentityLease.duration)
        -> StationIdentityLease {
        StationIdentityLease(deviceID: device, deviceName: device.capitalized,
                             callsign: callsign, endpoint: endpoint,
                             at: t0, duration: duration)
    }

    // MARK: - Picking a free one

    /// The whole point: a new device inherits the licence and takes an SSID
    /// nobody else is on.
    func testANewDeviceGetsTheCallsignAndAFreeSSID() throws {
        let suggestion = try XCTUnwrap(StationSSIDSuggestion.suggestion(
            syncedBase: "K0EPI",
            leases: [lease("home", callsign: "K0EPI-7")],
            at: t0.addingTimeInterval(60)))

        XCTAssertEqual(suggestion.base, "K0EPI")
        XCTAssertNotEqual(suggestion.ssid, 7, "it must not take the SSID already in use")
        XCTAssertEqual(suggestion.ssid, 1)
    }

    func testItSkipsEverySSIDAlreadyInUse() throws {
        let leases = [
            lease("home", callsign: "K0EPI-1"),
            lease("laptop", callsign: "K0EPI-2"),
            lease("shack", callsign: "K0EPI-3"),
        ]
        let suggestion = try XCTUnwrap(StationSSIDSuggestion.suggestion(
            syncedBase: "K0EPI", leases: leases, at: t0.addingTimeInterval(60)))
        XCTAssertEqual(suggestion.ssid, 4)
    }

    /// A different operator's callsign on the channel is not this operator's
    /// problem — those SSIDs stay available.
    func testAnotherCallsignDoesNotReserveSSIDs() throws {
        let suggestion = try XCTUnwrap(StationSSIDSuggestion.suggestion(
            syncedBase: "K0EPI",
            leases: [lease("theirs", callsign: "W0ARP-1")],
            at: t0.addingTimeInterval(60)))
        XCTAssertEqual(suggestion.ssid, 1)
    }

    /// A lapsed lease is a device that is gone. Holding its SSID reserved
    /// forever would walk the operator up the range for no reason.
    func testALapsedLeaseDoesNotReserveItsSSID() throws {
        let stale = lease("old", callsign: "K0EPI-1", duration: 60)
        let suggestion = try XCTUnwrap(StationSSIDSuggestion.suggestion(
            syncedBase: "K0EPI", leases: [stale], at: t0.addingTimeInterval(600)))
        XCTAssertEqual(suggestion.ssid, 1)
    }

    /// A bare callsign occupies SSID 0, so a device on `K0EPI` must be
    /// counted — otherwise the next device is handed 0 and collides.
    func testABareCallsignOccupiesSSIDZero() {
        let taken = StationSSIDSuggestion.takenSSIDs(
            from: [lease("home", callsign: "K0EPI")], base: "K0EPI",
            at: t0.addingTimeInterval(60))
        XCTAssertEqual(taken, [0])
    }

    /// 0 is offered last on purpose: a bare callsign is the value most likely
    /// to be in use somewhere this app cannot see — a Winlink account, a club
    /// roster, another radio entirely.
    func testSSIDZeroIsOfferedLast() {
        let allButZero = Set(1...15)
        XCTAssertEqual(StationSSIDSuggestion.freeSSID(taken: allButZero), 0)
        XCTAssertEqual(StationSSIDSuggestion.freeSSID(taken: []), 1)
    }

    /// Known non-AXTerm stations can be reserved. This station's own LinBPQ
    /// runs as K0EPI-7 on the same KISS port, and colliding with it breaks
    /// exactly as badly as colliding with another AXTerm.
    func testReservedSSIDsAreAvoided() {
        XCTAssertEqual(StationSSIDSuggestion.freeSSID(taken: [], avoiding: [1, 2]), 3)
    }

    /// Every SSID spoken for is a real problem, not something to paper over
    /// by reusing one.
    func testNoFreeSSIDReturnsNilRatherThanColliding() {
        XCTAssertNil(StationSSIDSuggestion.freeSSID(taken: Set(0...15)))
        XCTAssertNil(StationSSIDSuggestion.suggestion(
            syncedBase: "K0EPI",
            leases: (0...15).map { lease("d\($0)", callsign: "K0EPI-\($0)") },
            at: t0.addingTimeInterval(60)))
    }

    /// A first device has nothing to inherit. Inventing a callsign would be
    /// worse than asking for one.
    func testNoSyncedCallsignMeansNoSuggestion() {
        XCTAssertNil(StationSSIDSuggestion.suggestion(
            syncedBase: nil, leases: [], at: t0))
        XCTAssertNil(StationSSIDSuggestion.suggestion(
            syncedBase: "   ", leases: [], at: t0))
    }

    // MARK: - Explaining

    /// A value that appeared on its own invites the operator to "correct" it
    /// to the one their other radio uses — which is the collision. So it says
    /// where the callsign came from, what is already taken, and why.
    func testTheExplanationSaysWhereItCameFromAndWhatIsTaken() {
        let identity = ParsedCallsign(base: "K0EPI", ssid: 1)
        let text = StationSSIDSuggestion.explanation(
            for: identity,
            otherDevices: [lease("home", callsign: "K0EPI-7")],
            at: t0.addingTimeInterval(60))

        XCTAssertTrue(text.contains("K0EPI"), text)
        XCTAssertTrue(text.contains("K0EPI-7"), text)
        XCTAssertTrue(text.contains("Home"), text)
        XCTAssertTrue(text.lowercased().contains("breaks ax.25"), text)
    }

    func testTheExplanationWorksWithNoOtherDevices() {
        let text = StationSSIDSuggestion.explanation(
            for: ParsedCallsign(base: "K0EPI", ssid: 1), otherDevices: [], at: t0)
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(text.contains("K0EPI"))
    }
}

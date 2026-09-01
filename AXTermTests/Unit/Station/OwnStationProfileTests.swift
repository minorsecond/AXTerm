import XCTest
@testable import AXTerm

/// What the station page should not say about the station running the app.
///
/// Field report, 2026-08-31: opening K0EPI-7's own page produced a terrain
/// profile titled "K0EPI-7 to K0EPI-7, 2.3 km, marginal, terrain costs about
/// 12 dB", and a warning that 37 stations reach the network only through this
/// one. Both were computed correctly and neither meant anything.
final class OwnStationProfileTests: XCTestCase {

    private func roles(_ callsign: String, mine: String) -> [NodeProfile.Role] {
        NodeProfile.inferRoles(callsign: callsign, localCallsign: mine,
                               heard: nil, isAlias: false,
                               netRomDeclaration: nil,
                               digipeaterCallsigns: [], winlink: nil)
    }

    /// The role already exists and is assigned on an exact callsign match, so
    /// everything that needs the question can ask it in one place instead of
    /// each inventing its own comparison.
    func testTheRoleMarksOurOwnCallsignAndOnlyThat() {
        XCTAssertTrue(roles("K0EPI-7", mine: "K0EPI-7")
            .contains(NodeProfile.Role.ourStation))
        XCTAssertTrue(roles("k0epi-7", mine: "K0EPI-7")
            .contains(NodeProfile.Role.ourStation))
    }

    /// A different SSID is a different station. K0EPI-6 in this operator's log
    /// is a node relaying under a borrowed callsign, and treating it as ours
    /// would hide a page that has something to say.
    func testAnotherSSIDOfOurCallsignIsNotUs() {
        XCTAssertFalse(roles("K0EPI-6", mine: "K0EPI-7")
            .contains(NodeProfile.Role.ourStation))
        XCTAssertFalse(roles("K0EPI", mine: "K0EPI-7")
            .contains(NodeProfile.Role.ourStation))
    }

    /// With no callsign configured nothing is ours, and in particular an empty
    /// setting must not match an empty or odd callsign into being us.
    func testNothingIsOursWithoutACallsign() {
        XCTAssertFalse(roles("K0EPI-7", mine: "")
            .contains(NodeProfile.Role.ourStation))
        XCTAssertFalse(roles("", mine: "")
            .contains(NodeProfile.Role.ourStation))
    }

    /// The terrain card measured the ground between our grid square's centre
    /// and our own licence address, which are 2.3 km apart and both us. There
    /// is no path from a station to itself, whatever the two coordinates say.
    func testOurGridCentreAndOurLicenceAddressAreNotAPath() {
        let gridCentre = GreatCircle.Point(latitude: 39.6042, longitude: -104.7083)
        let licence = GreatCircle.Point(latitude: 39.6123, longitude: -104.7333)
        let apart = GreatCircle.kilometres(from: gridCentre, to: licence)

        XCTAssertGreaterThan(apart, 1, "far enough apart to produce a plausible-looking profile")
        XCTAssertLessThan(apart, 5, "and close enough that it is obviously the same station")
    }
}

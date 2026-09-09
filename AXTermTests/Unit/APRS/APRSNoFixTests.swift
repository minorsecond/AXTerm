import XCTest
@testable import AXTerm

/// Frames that carry a position field without carrying a position.
///
/// Found by comparing half an hour of our own reception against the APRS-IS
/// feed on 2026-09-09. Both frames below were really on 144.390 that morning.
final class APRSNoFixTests: XCTestCase {

    /// NI0W-9 at 15:32:58Z, destination `PPP0PP`: every Mic-E latitude digit
    /// zero. A Yaesu FTM-400DR with no GPS lock beacons this — the position
    /// fields are present and mean "I do not know where I am".
    ///
    /// Decoded literally it is 0°N 0°E, in the Gulf of Guinea, 13 000 km from
    /// the station that sent it. Putting a station there is worse than not
    /// placing it: the operator gets a dot at coordinates nobody transmitted,
    /// and on a map that auto-fits its stations, one of them drags the whole
    /// view off Africa and turns everything real into a single cluster.
    ///
    /// No igate carried this frame, so nothing but our own radio ever saw it.
    func testAMicEWithNoGPSFixIsNotAPosition() throws {
        let info = try XCTUnwrap(Data(hexString: "6076581C6C201C6B2F6022444B7D5F250D"))
        XCTAssertNil(APRSParser.parse(destination: "PPP0PP", info: info),
                     "all-zero latitude digits mean no fix, not the Gulf of Guinea")
    }

    /// The same rule for the other encodings, which have the same sentinel.
    func testAZeroPositionIsNeverAFix() {
        XCTAssertNil(APRSParser.parse(destination: "APZAXT",
                                      info: Data("!0000.00N/00000.00W-no fix".utf8)))
        XCTAssertNil(APRSParser.parse(destination: "APZAXT",
                                      info: Data("!0000.00S/00000.00E-no fix".utf8)))
    }

    /// And a station that really is near the origin is still a station. The
    /// rule is for the exact sentinel, not for a neighbourhood of it — there
    /// is no threshold at which a real position becomes a fiction.
    func testAPositionNearButNotAtTheOriginSurvives() throws {
        let report = try XCTUnwrap(
            APRSParser.parse(destination: "APZAXT",
                             info: Data("!0000.60N/00000.60E-Gulf of Guinea buoy".utf8)))
        XCTAssertEqual(report.latitude, 0.01, accuracy: 0.0001)
        XCTAssertEqual(report.longitude, 0.01, accuracy: 0.0001)
    }

    /// NI0W-9 again, the copy N0IGD gated at 15:36:38Z — the same station a
    /// few minutes later, corrupted somewhere between its transmitter and the
    /// gate. Direwolf calls its symbol table invalid; the course decodes to
    /// 579°, which is not a direction.
    ///
    /// The position in it is fine and worth keeping. The course is not: an
    /// arrow drawn at 579° points somewhere the station is not going, and a
    /// heading nobody can act on is worse than an absent one.
    func testACourseOutsideTheCompassIsNotACourse() throws {
        let report = try XCTUnwrap(
            APRSParser.parse(destination: "TPRTTT", info: Data("`q[oJak/`\"DX}_%".utf8)),
            "the position is still good")
        XCTAssertEqual(report.latitude, 40.4073, accuracy: 0.001)
        XCTAssertNil(report.courseDegrees, "579° is not a bearing")
    }

    /// A course of exactly 360 is how APRS writes due north in the
    /// uncompressed extension, and 0 means "unknown" there. Neither is out of
    /// range, and the guard must not eat them.
    func testTheCompassBoundsThemselvesAreKept() throws {
        let north = try XCTUnwrap(
            APRSParser.parse(destination: "APZAXT",
                             info: Data("!3936.70N/10443.90W-360/010".utf8)))
        XCTAssertEqual(north.courseDegrees, 360)
    }
}

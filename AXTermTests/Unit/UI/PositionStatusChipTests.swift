import XCTest
@testable import AXTerm

/// When the toolbar says something about position, and when it keeps quiet.
///
/// The quiet cases are the ones worth pinning down. A chip that speaks when
/// everything is fine is the failure mode this type exists to avoid, and it
/// is the one that would never show up as a bug report — it would just
/// gradually stop being read.
final class PositionStatusChipTests: XCTestCase {

    private let somewhere = StationPosition(
        point: GreatCircle.Point(latitude: 39.6, longitude: -104.7),
        source: .gridSquare)

    private func fix(_ source: StationLocation.Source) -> StationLocation {
        StationLocation(latitude: 39.6, longitude: -104.7, gridSquare: "DM79po",
                        source: source, timestamp: Date(timeIntervalSince1970: 0))
    }

    private func chip(position: StationPosition?,
                      usesDeviceLocation: Bool = false,
                      deviceFix: StationLocation? = nil,
                      gpsError: GPSError? = nil) -> PositionStatusChip {
        PositionStatusChip(position: position,
                           usesDeviceLocation: usesDeviceLocation,
                           deviceFix: deviceFix,
                           gpsError: gpsError)
    }

    // MARK: - Silence

    /// A grid square is a position. Coarse is not the same as missing, and
    /// the pages that care about the difference say so themselves.
    func testAGridSquareAloneSaysNothing() {
        XCTAssertNil(chip(position: somewhere).problem)
    }

    /// The whole point: device location on and working is the normal case.
    func testDeviceLocationWorkingSaysNothing() {
        XCTAssertNil(chip(position: somewhere,
                          usesDeviceLocation: true,
                          deviceFix: fix(.gps)).problem)
    }

    /// Switched off is a choice, not a fault.
    func testDeviceLocationSwitchedOffSaysNothing() {
        XCTAssertNil(chip(position: somewhere,
                          usesDeviceLocation: false,
                          gpsError: .denied).problem)
    }

    // MARK: - Worth interrupting for

    func testNoPositionAtAllIsReported() {
        XCTAssertEqual(chip(position: nil).problem, .noPosition)
    }

    /// No position outranks a GPS complaint: without any position the map
    /// and terrain are unavailable outright, which is the bigger fact.
    func testNoPositionOutranksAGPSFailure() {
        XCTAssertEqual(chip(position: nil,
                            usesDeviceLocation: true,
                            gpsError: .denied).problem, .noPosition)
    }

    func testDeniedAccessIsReported() {
        XCTAssertEqual(chip(position: somewhere,
                            usesDeviceLocation: true,
                            gpsError: .denied).problem, .denied)
    }

    func testWaitingForAFixIsReported() {
        XCTAssertEqual(chip(position: somewhere,
                            usesDeviceLocation: true,
                            gpsError: .timeout).problem, .noFix)
    }

    /// A grid-square fallback is stored in `lastLocation` when GPS fails, so
    /// a caller that passed it as the fix would silence the chip with the
    /// very thing that proves it should be speaking. `deviceFix` is nil here
    /// because the caller filtered it correctly.
    func testAGridFallbackIsNotAFix() {
        XCTAssertEqual(chip(position: somewhere,
                            usesDeviceLocation: true,
                            deviceFix: nil,
                            gpsError: .timeout).problem, .noFix)
    }

    /// The launch case, and the reason this needs a failed attempt rather
    /// than a missing fix: for the second between the window appearing and
    /// the first fix landing, device location is on and there is no
    /// coordinate yet. Reporting that blinked the toolbar orange on every
    /// launch and then took it back.
    func testAnAttemptStillInFlightSaysNothing() {
        XCTAssertNil(chip(position: somewhere,
                          usesDeviceLocation: true,
                          deviceFix: nil,
                          gpsError: nil).problem)
    }

    /// Every state names where to fix it; a chip that only complains is
    /// half a feature.
    func testEveryProblemSaysWhereToGo() {
        for problem in [PositionStatusChip.Problem.noPosition, .denied, .noFix] {
            XCTAssertTrue(problem.help.contains("Settings")
                          || problem.help.contains("System Settings"),
                          "\(problem.label) does not say where to go")
            XCTAssertFalse(problem.label.isEmpty)
        }
    }
}
